import '../models/json.dart';

enum ApiErrorKind {
  /// Could not reach the server (no route, DNS, refused, airplane mode).
  network,

  /// Server did not answer in time. The request may or may not have been applied.
  timeout,

  /// Server answered with the contract error envelope or a non-2xx status.
  http,

  /// 5xx.
  server,

  /// 2xx with a body the app cannot interpret.
  malformed,

  cancelled,
}

/// Normalised error for every API call. Mirrors the contract envelope
/// `{"error":{"code","message","details"}}`.
class ApiException implements Exception {
  const ApiException({
    required this.kind,
    required this.code,
    required this.message,
    this.statusCode,
    this.details = const {},
  });

  final ApiErrorKind kind;
  final String code;
  final String message;
  final int? statusCode;
  final Json details;

  /// True when the server was never reached or did not answer: the action can be
  /// queued for offline sync and cached data can be shown.
  bool get isConnectivity =>
      kind == ApiErrorKind.network || kind == ApiErrorKind.timeout;

  List<String> get fields =>
      asList(details['fields']).map((e) => e.toString()).toList();

  int? get retryAfterSeconds => asIntOrNull(details['retry_after_seconds']);

  factory ApiException.network([String message = 'Server unreachable']) =>
      ApiException(
          kind: ApiErrorKind.network, code: 'NETWORK_ERROR', message: message);

  factory ApiException.timeout() => const ApiException(
      kind: ApiErrorKind.timeout,
      code: 'TIMEOUT',
      message: 'Request timed out');

  factory ApiException.malformed(String message) => ApiException(
      kind: ApiErrorKind.malformed,
      code: 'MALFORMED_RESPONSE',
      message: message);

  /// Builds from a non-2xx response body; tolerates bodies that are not envelopes.
  factory ApiException.fromResponse(int status, dynamic body,
      {String? retryAfterHeader}) {
    final error = body is Map ? asMap(body['error']) : <String, dynamic>{};
    final details = asMap(error['details']);
    if (status == 429 &&
        retryAfterHeader != null &&
        !details.containsKey('retry_after_seconds')) {
      details['retry_after_seconds'] = int.tryParse(retryAfterHeader);
    }
    final code = asString(
        error['code'], status >= 500 ? 'SERVER_ERROR' : 'HTTP_$status');
    return ApiException(
      kind: status >= 500 ? ApiErrorKind.server : ApiErrorKind.http,
      code: code,
      message: asString(error['message'], 'Request failed ($status)'),
      statusCode: status,
      details: details,
    );
  }

  @override
  String toString() => 'ApiException($code, $statusCode): $message';
}
