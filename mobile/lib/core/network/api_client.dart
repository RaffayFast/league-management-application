import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../models/json.dart';
import 'api_exception.dart';

class ApiResponse {
  const ApiResponse(this.statusCode, this.data);
  final int statusCode;
  final dynamic data;

  /// 201 = created first time; 200 = idempotent replay (api_contract.md §0).
  bool get isReplay => statusCode == 200;
}

/// Single entry point for HTTP. Adds the bearer token, normalises every failure
/// into [ApiException] and reports reachability so the status bar stays honest.
class ApiClient {
  ApiClient({
    required String baseUrl,
    required this.tokenProvider,
    this.onUnauthorized,
    this.onReachability,
    HttpClientAdapter? adapter,
  }) : _dio = Dio(BaseOptions(
          baseUrl: normalizeBaseUrl(baseUrl),
          connectTimeout: AppConfig.connectTimeout,
          receiveTimeout: AppConfig.receiveTimeout,
          sendTimeout: AppConfig.receiveTimeout,
          contentType: Headers.jsonContentType,
          responseType: ResponseType.json,
          // Non-2xx responses are handled by us so the envelope is never lost.
          validateStatus: (_) => true,
        )) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  final Dio _dio;
  final String? Function() tokenProvider;
  final void Function()? onUnauthorized;
  final void Function(bool reachable)? onReachability;

  String get baseUrl => _dio.options.baseUrl;

  static String normalizeBaseUrl(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query, bool auth = true}) async =>
      (await send('GET', path, query: query, auth: auth)).data;

  Future<dynamic> post(String path, Object? body, {bool auth = true}) async =>
      (await send('POST', path, body: body, auth: auth)).data;

  Future<ApiResponse> send(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool auth = true,
  }) async {
    final headers = <String, dynamic>{};
    final token = auth ? tokenProvider() : null;
    if (token != null) headers['Authorization'] = 'Bearer $token';

    Response<dynamic> response;
    try {
      response = await _dio.request<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: Options(method: method, headers: headers),
      );
    } on DioException catch (e) {
      final error = _fromDio(e);
      if (error.isConnectivity) onReachability?.call(false);
      throw error;
    }

    onReachability?.call(true);
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) {
      return ApiResponse(status, response.data);
    }
    final error = ApiException.fromResponse(
      status,
      response.data,
      retryAfterHeader: response.headers.value('retry-after'),
    );
    if (status == 401 && token != null) onUnauthorized?.call();
    throw error;
  }

  ApiException _fromDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException.timeout();
      case DioExceptionType.cancel:
        return const ApiException(kind: ApiErrorKind.cancelled, code: 'CANCELLED', message: 'Request cancelled');
      case DioExceptionType.badResponse:
        final r = e.response;
        return ApiException.fromResponse(r?.statusCode ?? 0, r?.data);
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        if (e.error is FormatException) return ApiException.malformed('Response was not valid JSON');
        return ApiException.network();
    }
  }
}

/// Converts a parsing failure into an [ApiException] so screens only handle one type.
T parseOrThrow<T>(dynamic data, T Function(Json) parse, String what) {
  try {
    return parse(requireMap(data, what));
  } on MalformedResponse catch (e) {
    throw ApiException.malformed(e.message);
  } on TypeError {
    throw ApiException.malformed('Unexpected shape for $what');
  }
}
