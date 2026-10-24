import 'dart:math' as math;

import '../config/app_config.dart';
import '../models/sync_models.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';
import '../util/formatters.dart';
import 'action_queue.dart';
import 'pending_action.dart';

class SyncItemOutcome {
  const SyncItemOutcome(this.action, this.result);
  final PendingAction action;
  final SyncResult result;
}

class SyncReport {
  final List<SyncItemOutcome> outcomes = [];

  /// Set when the request never got a usable answer; affected actions stay pending.
  ApiException? transportError;

  int get applied => outcomes.where((o) => o.result.isApplied).length;
  int get duplicate => outcomes.where((o) => o.result.isDuplicate).length;
  int get rejected => outcomes.where((o) => o.result.isRejected).length;
  bool get isEmpty => outcomes.isEmpty && transportError == null;

  /// Match ids / player ids touched, so the UI can refresh them.
  Set<String> get touchedTargets =>
      outcomes.map((o) => o.action.target).toSet();
}

/// Sends queued actions to POST /api/v1/sync and applies each per-action
/// result to the local queue. Nothing is removed unless the server answered.
class SyncService {
  SyncService({required this.api, required this.queue, required this.deviceId});

  final ApiClient api;
  final ActionQueue queue;
  final Future<String> Function() deviceId;

  Future<SyncReport> syncPending({required String owner}) async {
    final report = SyncReport();
    final actions = await queue.pending(owner: owner);
    if (actions.isEmpty) return report;
    final device = await deviceId();

    for (var start = 0;
        start < actions.length;
        start += AppConfig.maxSyncBatch) {
      final end = math.min(start + AppConfig.maxSyncBatch, actions.length);
      final chunk = actions.sublist(start, end);
      final body = {
        'device_id': device,
        'actions': chunk.map((a) => a.toEnvelope()).toList()
      };

      SyncResponse response;
      try {
        response = parseOrThrow(await api.post('/api/v1/sync', body),
            SyncResponse.fromJson, 'sync response');
      } on ApiException catch (e) {
        report.transportError = e;
        if (e.kind == ApiErrorKind.http && e.statusCode == 400) {
          // The server refused the whole envelope; resending it unchanged cannot help.
          for (final a in chunk) {
            await queue.markRejected(a.actionId, e.code);
          }
        } else {
          // Network, timeout, 401, 5xx, malformed: keep everything pending. The
          // server may have applied some actions; resending reuses the same
          // action_ids, so they come back as "duplicate" rather than twice.
          for (final a in chunk) {
            await queue.markAttemptFailed(a.actionId, e.code);
          }
        }
        return report;
      }

      await applyResults(chunk, response.results, report);
    }
    return report;
  }

  /// Applies server results to the queue. Public for unit tests.
  Future<void> applyResults(List<PendingAction> sent, List<SyncResult> results,
      SyncReport report) async {
    final byId = {for (final r in results) r.actionId: r};
    final now = utcTimestamp();
    for (final action in sent) {
      final result = byId[action.actionId];
      if (result == null) {
        await queue.markAttemptFailed(action.actionId, 'NO_RESULT');
        continue;
      }
      report.outcomes.add(SyncItemOutcome(action, result));
      if (result.isApplied || result.isDuplicate) {
        await queue.remove(action.actionId);
      } else {
        await queue.markRejected(
            action.actionId, result.errorCode ?? 'REJECTED');
      }
      await queue.addHistory(SyncHistoryEntry(
        actionId: action.actionId,
        type: action.type,
        label: action.label,
        status: result.status,
        resolution: result.resolution,
        errorCode: result.errorCode,
        serverVersion: result.serverVersion,
        syncedAt: now,
      ));
    }
  }
}
