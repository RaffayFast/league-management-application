import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/club_models.dart';
import '../../core/network/api_exception.dart';
import '../../core/sync/pending_action.dart';
import '../../core/sync/sync_controller.dart';
import '../auth/auth_controller.dart';
import 'data/roster_repository.dart';

sealed class TransferOutcome {
  const TransferOutcome();
}

class TransferConfirmed extends TransferOutcome {
  const TransferConfirmed(this.response, {required this.replay});
  final TransferResponse response;
  final bool replay;
}

class TransferQueued extends TransferOutcome {
  const TransferQueued(this.action);
  final PendingAction action;
}

class TransferService {
  TransferService(this._ref);
  final Ref _ref;

  Future<TransferOutcome> submit(TransferRequest request,
      {required String label}) async {
    if (!_ref.read(syncControllerProvider).online) {
      return queue(request, label: label);
    }
    final (response, replay) =
        await _ref.read(rosterRepositoryProvider).transfer(request);
    return TransferConfirmed(response, replay: replay);
  }

  /// base_version = number of audit entries last observed for the player
  /// (live when reachable, otherwise from the SQLite cache, otherwise 0).
  Future<int> observedHistoryCount(String playerId) async {
    try {
      final history =
          await _ref.read(rosterRepositoryProvider).history(playerId);
      return history.data.history.length;
    } on ApiException {
      return 0;
    }
  }

  Future<TransferQueued> queue(TransferRequest request,
      {required String label}) async {
    final owner = _ref.read(authControllerProvider).user?.userId ?? 'unknown';
    final action = PendingAction.forRosterTransfer(
      transferBody: request.toJson(),
      baseVersion: await observedHistoryCount(request.playerId),
      label: label,
      owner: owner,
    );
    await _ref.read(syncControllerProvider.notifier).enqueue(action);
    return TransferQueued(action);
  }
}

final transferServiceProvider = Provider((ref) => TransferService(ref));
