import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../models/json.dart';
import 'api_exception.dart';
import 'sse.dart';

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

  Future<dynamic> get(String path,
          {Map<String, dynamic>? query, bool auth = true}) async =>
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

  /// GET of a non-JSON resource, such as a Guest Web Player page, returned as text.
  Future<String> getText(String path, {bool auth = false}) async {
    final response = await _raw<dynamic>(
      path,
      auth: auth,
      options: Options(
          method: 'GET',
          responseType: ResponseType.plain,
          headers: {'Accept': 'text/html'}),
    );
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) return '${response.data ?? ''}';
    throw ApiException.fromResponse(status, _decodeJsonOrNull(response.data));
  }

  /// GET without following redirects; returns the `Location` of a 3xx answer.
  ///
  /// Used for printed QR short links: `GET /q/{code}` answers 302 with the entity's current route.
  Future<String> redirectLocation(String path) async {
    final response = await _raw<dynamic>(
      path,
      auth: false,
      options: Options(
          method: 'GET',
          followRedirects: false,
          responseType: ResponseType.plain),
    );
    final status = response.statusCode ?? 0;
    final location = response.headers.value('location');
    if (status >= 300 &&
        status < 400 &&
        location != null &&
        location.isNotEmpty) {
      return location;
    }
    if (status >= 200 && status < 300) {
      throw ApiException.malformed(
          'Expected a redirect from $path but got $status');
    }
    throw ApiException.fromResponse(status, _decodeJsonOrNull(response.data));
  }

  /// Opens a Server-Sent Events stream (`text/event-stream`) on the same Dio client and base URL.
  ///
  /// The connection stays open until [cancelToken] is cancelled or the server ends the stream.
  /// [idleTimeout] must exceed the server's keep-alive interval (15 s), because Dio applies its
  /// receive timeout between chunks. A non-2xx answer throws [ApiException] with the contract
  /// error code, so an error body is never parsed as events.
  Future<Stream<SseEvent>> openEventStream(
    String path, {
    required CancelToken cancelToken,
    bool auth = false,
    Duration idleTimeout = const Duration(seconds: 45),
    SseParser? parser,
  }) async {
    final response = await _raw<ResponseBody>(
      path,
      auth: auth,
      cancelToken: cancelToken,
      options: Options(
        method: 'GET',
        responseType: ResponseType.stream,
        receiveTimeout: idleTimeout,
        headers: {'Accept': 'text/event-stream', 'Cache-Control': 'no-cache'},
      ),
    );
    final body = response.data;
    if (body == null) {
      throw ApiException.malformed('The event stream had no body');
    }
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      final text = await _readText(body.stream);
      cancelToken.cancel('error status $status');
      throw ApiException.fromResponse(
        status,
        _decodeJsonOrNull(text),
        retryAfterHeader: response.headers.value('retry-after'),
      );
    }
    final type =
        (response.headers.value(Headers.contentTypeHeader) ?? '').toLowerCase();
    if (!type.startsWith('text/event-stream')) {
      cancelToken.cancel('not an event stream');
      throw ApiException.malformed(
          'Expected an event stream but the server sent "$type"');
    }
    return parseSse(body.stream, parser: parser);
  }

  /// Shared transport for the non-JSON helpers: bearer token, Dio failures normalised, reachability.
  Future<Response<T>> _raw<T>(String path,
      {required Options options,
      bool auth = true,
      CancelToken? cancelToken}) async {
    final token = auth ? tokenProvider() : null;
    if (token != null) {
      options.headers = {...?options.headers, 'Authorization': 'Bearer $token'};
    }
    try {
      final response = await _dio.request<T>(path,
          options: options, cancelToken: cancelToken);
      onReachability?.call(true);
      if (response.statusCode == 401 && token != null) onUnauthorized?.call();
      return response;
    } on DioException catch (e) {
      final error = _fromDio(e);
      if (error.isConnectivity) onReachability?.call(false);
      throw error;
    }
  }

  static Future<String> _readText(Stream<List<int>> bytes,
      {int limit = 64 * 1024}) async {
    final buffer = <int>[];
    await for (final chunk in bytes) {
      buffer.addAll(chunk);
      if (buffer.length >= limit) break;
    }
    return utf8.decode(buffer, allowMalformed: true);
  }

  static dynamic _decodeJsonOrNull(dynamic data) {
    if (data is! String) return data;
    try {
      return jsonDecode(data);
    } on FormatException {
      return null; // an HTML error page: the status code alone describes the failure
    }
  }

  ApiException _fromDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException.timeout();
      case DioExceptionType.cancel:
        return const ApiException(
            kind: ApiErrorKind.cancelled,
            code: 'CANCELLED',
            message: 'Request cancelled');
      case DioExceptionType.badResponse:
        final r = e.response;
        return ApiException.fromResponse(r?.statusCode ?? 0, r?.data);
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
      default:
        if (e.error is FormatException) {
          return ApiException.malformed('Response was not valid JSON');
        }
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
