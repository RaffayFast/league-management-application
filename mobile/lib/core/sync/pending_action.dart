import 'dart:convert';

import '../models/json.dart';
import '../util/formatters.dart';
import '../util/ids.dart';

enum PendingState { pending, rejected }

/// A locally queued mutation, stored in SQLite until the server confirms it.
/// [toEnvelope] produces exactly the A12 action shape.
class PendingAction {
  const PendingAction({
    required this.actionId,
    required this.type,
    required this.queuedAt,
    required this.baseVersion,
    required this.payload,
    required this.label,
    required this.target,
    required this.state,
    this.lastError,
    this.attempts = 0,
    required this.owner,
  });

  static const scoreEvent = 'score_event';
  static const rosterTransfer = 'roster_transfer';

  final String actionId;
  final String type;
  final String queuedAt;
  final int? baseVersion;
  final Json payload;
  final String label;

  /// match_id for score events, player_id for roster transfers.
  final String target;
  final PendingState state;
  final String? lastError;
  final int attempts;

  /// user_id that queued it; only that user's token may send it.
  final String owner;

  /// [eventBody] must be the exact A6 request body (event_id, match_id, type, payload).
  factory PendingAction.forScoreEvent({
    required Json eventBody,
    required int baseVersion,
    required String label,
    required String owner,
    DateTime? now,
  }) =>
      PendingAction(
        actionId: newId('act'),
        type: scoreEvent,
        queuedAt: utcTimestamp(now),
        baseVersion: baseVersion,
        payload: eventBody,
        label: label,
        target: asString(eventBody['match_id']),
        state: PendingState.pending,
        owner: owner,
      );

  /// [transferBody] must be the complete A9 transfer request.
  /// [baseVersion] = number of audit entries last observed for the player.
  factory PendingAction.forRosterTransfer({
    required Json transferBody,
    required int baseVersion,
    required String label,
    required String owner,
    DateTime? now,
  }) =>
      PendingAction(
        actionId: newId('act'),
        type: rosterTransfer,
        queuedAt: utcTimestamp(now),
        baseVersion: baseVersion,
        payload: transferBody,
        label: label,
        target: asString(transferBody['player_id']),
        state: PendingState.pending,
        owner: owner,
      );

  Json toEnvelope() => {
        'action_id': actionId,
        'type': type,
        'queued_at': queuedAt,
        'base_version': baseVersion,
        'payload': payload,
      };

  Map<String, Object?> toRow() => {
        'action_id': actionId,
        'type': type,
        'queued_at': queuedAt,
        'base_version': baseVersion,
        'payload': jsonEncode(payload),
        'label': label,
        'target': target,
        'state': state.name,
        'last_error': lastError,
        'attempts': attempts,
        'owner': owner,
      };

  factory PendingAction.fromRow(Map<String, Object?> row) => PendingAction(
        actionId: row['action_id'] as String,
        type: row['type'] as String,
        queuedAt: row['queued_at'] as String,
        baseVersion: row['base_version'] as int?,
        payload: asMap(jsonDecode(row['payload'] as String)),
        label: row['label'] as String,
        target: row['target'] as String,
        state: (row['state'] as String) == 'rejected' ? PendingState.rejected : PendingState.pending,
        lastError: row['last_error'] as String?,
        attempts: (row['attempts'] as int?) ?? 0,
        owner: row['owner'] as String,
      );
}

/// Outcome of an action after a sync, kept so rejections are never lost.
class SyncHistoryEntry {
  const SyncHistoryEntry({
    required this.actionId,
    required this.type,
    required this.label,
    required this.status,
    this.resolution,
    this.errorCode,
    this.serverVersion,
    required this.syncedAt,
  });

  final String actionId;
  final String type;
  final String label;
  final String status;
  final String? resolution;
  final String? errorCode;
  final int? serverVersion;
  final String syncedAt;

  Map<String, Object?> toRow() => {
        'action_id': actionId,
        'type': type,
        'label': label,
        'status': status,
        'resolution': resolution,
        'error_code': errorCode,
        'server_version': serverVersion,
        'synced_at': syncedAt,
      };

  factory SyncHistoryEntry.fromRow(Map<String, Object?> row) => SyncHistoryEntry(
        actionId: row['action_id'] as String,
        type: row['type'] as String,
        label: row['label'] as String,
        status: row['status'] as String,
        resolution: row['resolution'] as String?,
        errorCode: row['error_code'] as String?,
        serverVersion: row['server_version'] as int?,
        syncedAt: row['synced_at'] as String,
      );
}
