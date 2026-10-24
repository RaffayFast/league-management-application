import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/data/cached_fetch.dart';
import '../../core/models/match_models.dart';
import '../../core/models/league_models.dart';
import '../../core/network/api_exception.dart';
import '../../core/providers.dart';
import '../../core/sync/pending_action.dart';
import '../../core/sync/sync_controller.dart';
import '../fixtures/data/league_repository.dart';

/// Loads a match and keeps it fresh by polling. The backend has no WebSocket/SSE
/// route, so this polls every [AppConfig.livePollInterval] while the match is not
/// finished, backing off on 429 and on errors (api_contract.md §0).
class MatchController extends StateNotifier<AsyncValue<Cached<ScoreObject>>> {
  MatchController(this._ref, this.matchId) : super(const AsyncValue.loading()) {
    _ref.listen<int>(refreshTickProvider, (_, __) => refresh());
    refresh();
  }

  final Ref _ref;
  final String matchId;
  Timer? _timer;
  Duration _interval = AppConfig.livePollInterval;
  bool _loading = false;

  bool get polling => _timer != null;

  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final result = await _ref.read(leagueRepositoryProvider).match(matchId);
      if (!mounted) return;
      state = AsyncValue.data(result);
      _interval = AppConfig.livePollInterval;
    } on ApiException catch (e, st) {
      if (!mounted) return;
      if (e.code == 'RATE_LIMITED') {
        final hinted = e.retryAfterSeconds;
        _interval = hinted != null
            ? Duration(
                seconds: math.max(hinted, AppConfig.livePollInterval.inSeconds))
            : _backoff();
      } else {
        _interval = _backoff();
      }
      // Keep showing the last good data; only surface errors when there is none.
      if (!state.hasValue) state = AsyncValue.error(e, st);
    } catch (e, st) {
      if (mounted && !state.hasValue) state = AsyncValue.error(e, st);
    } finally {
      _loading = false;
      _schedule();
    }
  }

  Duration _backoff() {
    final doubled = _interval * 2;
    return doubled > AppConfig.maxPollInterval
        ? AppConfig.maxPollInterval
        : doubled;
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!mounted) return;
    final status = state.valueOrNull?.data.status;
    final finished = status == MatchStatus.completed ||
        status == MatchStatus.cancelled ||
        status == MatchStatus.abandoned;
    if (finished || !_ref.read(syncControllerProvider).hasNetwork) return;
    _timer = Timer(_interval, refresh);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final matchControllerProvider = StateNotifierProvider.autoDispose
    .family<MatchController, AsyncValue<Cached<ScoreObject>>, String>(
        (ref, id) => MatchController(ref, id));

/// Locally queued (not yet confirmed) actions for a match or player.
final pendingForTargetProvider = FutureProvider.autoDispose
    .family<List<PendingAction>, String>((ref, target) async {
  ref.watch(syncControllerProvider.select((s) => s.pending + s.rejected));
  final all = await ref.watch(actionQueueProvider).all();
  return all.where((a) => a.target == target).toList();
});
