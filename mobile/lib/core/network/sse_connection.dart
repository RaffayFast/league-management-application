import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

import 'api_client.dart';
import 'api_exception.dart';
import 'sse.dart';

/// State of a realtime subscription, shown to the viewer.
enum RealtimeStatus {
  connecting,
  live,
  reconnecting,

  /// The device or server is unreachable; retrying with backoff.
  offline,

  /// The server rejected the subscription (4xx); retrying would not help.
  failed,

  closed,
}

/// Keeps one Server-Sent Events subscription alive on the shared [ApiClient].
///
/// - At most one connection is open at a time. Each attempt has its own CancelToken, and events
///   from a superseded attempt are ignored, so a reconnect can never double-subscribe.
/// - Reconnects use bounded exponential backoff with jitter, never shorter than the server's
///   `retry:` hint.
/// - A 4xx answer stops retrying and reports [RealtimeStatus.failed].
/// - [close] cancels the timer, the stream and the HTTP connection.
class SseConnection {
  SseConnection({
    required this.api,
    required this.path,
    required this.onEvent,
    this.onStatus,
    this.minBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    Random? random,
  }) : _random = random ?? Random();

  final ApiClient api;
  final String path;
  final void Function(SseEvent event) onEvent;
  final void Function(RealtimeStatus status, ApiException? error)? onStatus;
  final Duration minBackoff;
  final Duration maxBackoff;
  final Random _random;

  CancelToken? _token;
  StreamSubscription<SseEvent>? _sub;
  Timer? _retryTimer;
  Duration? _serverRetry;
  int _failures = 0;
  bool _everConnected = false;
  bool _closed = false;

  bool get isClosed => _closed;

  void start() {
    if (_closed || _token != null) return;
    unawaited(_connect());
  }

  /// Skips the backoff wait, e.g. when connectivity returns or the viewer taps Retry.
  void reconnectNow() {
    if (_closed) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _teardown();
    unawaited(_connect());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    final sub = _sub;
    _sub = null;
    _token?.cancel('closed');
    _token = null;
    await sub?.cancel();
  }

  void _teardown() {
    _sub?.cancel();
    _sub = null;
    _token?.cancel('superseded');
    _token = null;
  }

  Future<void> _connect() async {
    if (_closed) return;
    final token = CancelToken();
    _token = token;
    onStatus?.call(
        _everConnected || _failures > 0
            ? RealtimeStatus.reconnecting
            : RealtimeStatus.connecting,
        null);
    final parser = SseParser();
    final Stream<SseEvent> stream;
    try {
      stream =
          await api.openEventStream(path, cancelToken: token, parser: parser);
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.cancelled) {
        return; // closed or superseded while connecting
      }
      _dropped(token, e);
      return;
    }
    if (_closed || !identical(token, _token)) {
      token.cancel('superseded');
      return;
    }
    _everConnected = true;
    onStatus?.call(RealtimeStatus.live, null);
    var receivedAny = false;
    _sub = stream.listen(
      (event) {
        if (!identical(token, _token)) return;
        if (!receivedAny) {
          receivedAny = true;
          _failures =
              0; // reset only once the server actually delivered something
        }
        _serverRetry = parser.retryHint ?? _serverRetry;
        onEvent(event);
      },
      onError: (Object error, StackTrace _) {
        final mapped = _mapStreamError(error);
        if (mapped == null) return; // our own cancellation
        _dropped(token, mapped);
      },
      onDone: () => _dropped(token, null),
      cancelOnError: true,
    );
  }

  void _dropped(CancelToken token, ApiException? error) {
    if (_closed || !identical(token, _token)) return;
    _teardown();
    _failures++;
    final status = error?.statusCode;
    final rejected = status != null &&
        status >= 400 &&
        status < 500 &&
        status != 408 &&
        status != 429;
    if (rejected) {
      onStatus?.call(RealtimeStatus.failed, error);
      return;
    }
    onStatus?.call(
        error != null && error.isConnectivity
            ? RealtimeStatus.offline
            : RealtimeStatus.reconnecting,
        error);
    _retryTimer?.cancel();
    _retryTimer = Timer(_backoff(error), () {
      _retryTimer = null;
      unawaited(_connect());
    });
  }

  Duration _backoff(ApiException? error) {
    final floor = [
      minBackoff,
      _serverRetry ?? Duration.zero,
      Duration(seconds: error?.retryAfterSeconds ?? 0)
    ].reduce((a, b) => a > b ? a : b);
    final exp = floor * pow(2, min(_failures - 1, 6)).toInt();
    final capped = exp > maxBackoff ? maxBackoff : exp;
    final jitter = 0.8 +
        _random.nextDouble() *
            0.4; // +-20 % so many viewers do not reconnect in lockstep
    return capped * jitter;
  }

  static ApiException? _mapStreamError(Object error) {
    if (error is ApiException) {
      return error.kind == ApiErrorKind.cancelled ? null : error;
    }
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.cancel:
          return null;
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
          return ApiException.timeout();
        default:
          return ApiException.network('The live connection dropped');
      }
    }
    if (error is FormatException) {
      return ApiException.malformed(
          'The live stream sent text the app cannot decode');
    }
    return ApiException.network('The live connection dropped');
  }
}
