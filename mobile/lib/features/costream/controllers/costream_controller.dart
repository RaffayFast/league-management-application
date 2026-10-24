import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/network/sse_connection.dart';
import '../../../core/providers.dart';
import '../../../core/sync/sync_controller.dart';
import '../models/costream_session.dart';

class CostreamState {
  const CostreamState({
    this.session,
    this.waiting = false,
    this.connection = RealtimeStatus.connecting,
    this.error,
    this.lastHandoff,
    this.updatedAt,
  });

  /// Last session the server reported; kept while offline and marked stale by [connection].
  final CostreamSession? session;

  /// The server answered 404 STREAM_NOT_FOUND: the hosts have not started (or it was removed).
  final bool waiting;
  final RealtimeStatus connection;
  final String? error;
  final HostHandoff? lastHandoff;
  final DateTime? updatedAt;
}

/// Follows one co-stream session.
///
/// The backend has no session event stream, so the public view is re-read every
/// [interval] (2 s keeps a host handoff visible within the 3 s cross-surface target). Polls never
/// overlap. Failures back off up to 30 s, and a connectivity return refreshes at once. Host changes
/// are detected only by comparing server snapshots.
class CostreamController extends StateNotifier<CostreamState> {
  CostreamController(this._api, this.sessionId,
      {this.interval = const Duration(seconds: 2)})
      : super(const CostreamState()) {
    unawaited(_poll());
  }

  final ApiClient _api;
  final String sessionId;
  final Duration interval;
  Timer? _timer;
  bool _inFlight = false;
  int _failures = 0;

  Future<void> refresh() async {
    _timer?.cancel();
    await _poll();
  }

  Future<void> _poll() async {
    if (_inFlight || !mounted) return;
    _inFlight = true;
    try {
      final data = await _api.get(
          '/api/v1/live/costream/${Uri.encodeComponent(sessionId)}',
          auth: false);
      if (!mounted) return;
      final next =
          parseOrThrow(data, CostreamSession.fromJson, 'co-stream session');
      _failures = 0;
      final previous = state.session;
      var handoff = state.lastHandoff;
      if (previous != null &&
          previous.activeHost != null &&
          previous.activeHost != next.activeHost) {
        handoff = HostHandoff(
            from: previous.activeHost!,
            to: next.activeHost,
            at: DateTime.now());
      }
      state = CostreamState(
        session: next,
        connection: RealtimeStatus.live,
        lastHandoff: handoff,
        updatedAt: DateTime.now(),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      _failures++;
      if (e.code == 'STREAM_NOT_FOUND') {
        _failures = 0;
        state = CostreamState(
            waiting: true,
            connection: RealtimeStatus.live,
            updatedAt: DateTime.now());
      } else {
        state = CostreamState(
          session: state.session,
          waiting: state.waiting,
          connection: e.isConnectivity
              ? RealtimeStatus.offline
              : RealtimeStatus.reconnecting,
          error: friendlyError(e),
          lastHandoff: state.lastHandoff,
          updatedAt: state.updatedAt,
        );
      }
    } finally {
      _inFlight = false;
      if (mounted) _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    final ended = state.session != null && !state.session!.isActive;
    var delay = ended ? const Duration(seconds: 15) : interval;
    if (_failures > 0) {
      final backoff = interval * (1 << (_failures.clamp(1, 4)));
      delay = backoff > const Duration(seconds: 30)
          ? const Duration(seconds: 30)
          : backoff;
    }
    _timer = Timer(delay, () => unawaited(_poll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final costreamControllerProvider = StateNotifierProvider.autoDispose
    .family<CostreamController, CostreamState, String>((ref, sessionId) {
  final controller =
      CostreamController(ref.watch(apiClientProvider), sessionId);
  ref.listen<bool>(syncControllerProvider.select((s) => s.hasNetwork),
      (previous, hasNetwork) {
    if (hasNetwork && previous == false) unawaited(controller.refresh());
  });
  return controller;
});
