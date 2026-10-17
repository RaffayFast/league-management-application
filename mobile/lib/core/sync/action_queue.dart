import 'package:sqflite/sqflite.dart';

import '../storage/local_db.dart';
import 'pending_action.dart';

/// Persistent queue of offline actions (table `pending_actions`) plus the
/// history of server outcomes (table `sync_history`).
class ActionQueue {
  ActionQueue(this._db);
  final LocalDb _db;

  Database get _sql => _db.db;

  Future<void> enqueue(PendingAction action) =>
      _sql.insert('pending_actions', action.toRow(), conflictAlgorithm: ConflictAlgorithm.abort);

  /// Actions still waiting to be sent, oldest first (the server also sorts by queued_at).
  Future<List<PendingAction>> pending({String? owner}) async {
    final rows = await _sql.query(
      'pending_actions',
      where: owner == null ? 'state = ?' : 'state = ? AND owner = ?',
      whereArgs: owner == null ? ['pending'] : ['pending', owner],
      orderBy: 'queued_at ASC, rowid ASC',
    );
    return rows.map(PendingAction.fromRow).toList();
  }

  /// Everything still in the queue, including rejected actions awaiting a decision.
  Future<List<PendingAction>> all() async {
    final rows = await _sql.query('pending_actions', orderBy: 'queued_at ASC, rowid ASC');
    return rows.map(PendingAction.fromRow).toList();
  }

  Future<int> count({PendingState state = PendingState.pending}) async {
    final rows = await _sql.rawQuery(
      'SELECT COUNT(*) AS n FROM pending_actions WHERE state = ?',
      [state.name],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<void> remove(String actionId) =>
      _sql.delete('pending_actions', where: 'action_id = ?', whereArgs: [actionId]);

  Future<void> markRejected(String actionId, String errorCode) => _sql.rawUpdate(
        'UPDATE pending_actions SET state = ?, last_error = ?, attempts = attempts + 1 WHERE action_id = ?',
        ['rejected', errorCode, actionId],
      );

  /// Transport failure: the action stays pending and will be retried.
  Future<void> markAttemptFailed(String actionId, String errorCode) => _sql.rawUpdate(
        'UPDATE pending_actions SET last_error = ?, attempts = attempts + 1 WHERE action_id = ?',
        [errorCode, actionId],
      );

  /// User chose to retry a rejected action (same action_id, so the server dedupes).
  Future<void> requeue(String actionId) => _sql.rawUpdate(
        'UPDATE pending_actions SET state = ?, last_error = NULL WHERE action_id = ?',
        ['pending', actionId],
      );

  Future<void> addHistory(SyncHistoryEntry entry) => _sql.insert('sync_history', entry.toRow());

  Future<List<SyncHistoryEntry>> history({int limit = 50}) async {
    final rows = await _sql.query('sync_history', orderBy: 'id DESC', limit: limit);
    return rows.map(SyncHistoryEntry.fromRow).toList();
  }

  Future<void> clearHistory() => _sql.delete('sync_history');
}
