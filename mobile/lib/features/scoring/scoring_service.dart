import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/json.dart';
import '../../core/models/match_models.dart';
import '../../core/sync/pending_action.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/util/ids.dart';
import '../auth/auth_controller.dart';
import '../fixtures/data/league_repository.dart';

sealed class ScoringOutcome {
  const ScoringOutcome();
}

class ScoringConfirmed extends ScoringOutcome {
  const ScoringConfirmed(this.ack, {required this.replay});
  final EventAck ack;
  final bool replay;
}

class ScoringQueued extends ScoringOutcome {
  const ScoringQueued(this.action);
  final PendingAction action;
}

/// Builds A6 event bodies and either posts them or queues them for sync.
class ScoringService {
  ScoringService(this._ref);
  final Ref _ref;

  /// Exact A6 request body.
  static Json buildEventBody({
    required String matchId,
    required String type,
    required Json payload,
    String? eventId,
  }) =>
      {
        'event_id': eventId ?? newId('evt'),
        'match_id': matchId,
        'type': type,
        'payload': payload,
      };

  /// Posts when online. Throws ApiException for server rejections; callers
  /// may catch a connectivity error and call [queue] with the same body (same
  /// event_id), so a request that did reach the server is deduplicated on sync.
  Future<ScoringOutcome> submit(Json body, {required int observedVersion, required String label}) async {
    if (!_ref.read(syncControllerProvider).online) {
      return queue(body, observedVersion: observedVersion, label: label);
    }
    final (ack, replay) = await _ref.read(leagueRepositoryProvider).postEvent(body);
    return ScoringConfirmed(ack, replay: replay);
  }

  Future<ScoringQueued> queue(Json body, {required int observedVersion, required String label}) async {
    final owner = _ref.read(authControllerProvider).user?.userId ?? 'unknown';
    final action = PendingAction.forScoreEvent(
      eventBody: body,
      baseVersion: observedVersion,
      label: label,
      owner: owner,
    );
    await _ref.read(syncControllerProvider.notifier).enqueue(action);
    return ScoringQueued(action);
  }
}

final scoringServiceProvider = Provider((ref) => ScoringService(ref));
