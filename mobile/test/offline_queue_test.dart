import 'package:flutter_test/flutter_test.dart';
import 'package:leaguehub/core/models/club_models.dart';
import 'package:leaguehub/core/sync/action_queue.dart';
import 'package:leaguehub/core/sync/pending_action.dart';
import 'package:leaguehub/features/scoring/scoring_service.dart';

import 'helpers.dart';

final _ts = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$');

PendingAction _score({String owner = 'user-organizer', int base = 3, DateTime? at}) => PendingAction.forScoreEvent(
      eventBody: ScoringService.buildEventBody(
        matchId: 'm1',
        type: 'score',
        payload: {'team_id': 't1', 'event_type': 'goal'},
        eventId: 'evt-9',
      ),
      baseVersion: base,
      label: 'Goal — t1',
      owner: owner,
      now: at,
    );

PendingAction _transfer({int base = 1, DateTime? at}) => PendingAction.forRosterTransfer(
      transferBody: const TransferRequest(
        requestId: 'tr-001',
        leagueId: 'league-alpha-1',
        playerId: 'demo-pa-05',
        type: TransferType.loan,
        fromSquadId: 'sq-alpha-1',
        toSquadId: 'sq-alpha-2',
        effectiveDate: '2026-10-20',
        loanEndDate: '2026-11-20',
        reason: 'Development',
        requestedBy: 'manager@nascon.test',
      ).toJson(),
      baseVersion: base,
      label: 'Loan Fahad → Beta United',
      owner: 'user-manager',
      now: at,
    );

void main() {
  test('score_event envelope matches A12 and wraps the exact A6 body', () {
    final env = _score().toEnvelope();
    expect(env.keys.toSet(), {'action_id', 'type', 'queued_at', 'base_version', 'payload'});
    expect(env['type'], 'score_event');
    expect(env['base_version'], 3);
    expect(env['queued_at'], matches(_ts));
    expect(env['payload'], {
      'event_id': 'evt-9',
      'match_id': 'm1',
      'type': 'score',
      'payload': {'team_id': 't1', 'event_type': 'goal'},
    });
  });

  test('roster_transfer envelope carries the complete A9 request and audit-count base_version', () {
    final a = _transfer(base: 2);
    final env = a.toEnvelope();
    expect(env['type'], 'roster_transfer');
    expect(env['base_version'], 2);
    final payload = env['payload'] as Map<String, dynamic>;
    expect(payload.keys.toSet(), {
      'request_id', 'league_id', 'player_id', 'type', 'from_squad_id', 'to_squad_id',
      'effective_date', 'loan_end_date', 'reason', 'requested_by',
    });
    expect(payload['loan_end_date'], '2026-11-20');
    expect(a.target, 'demo-pa-05');
  });

  test('queue persists across a database reopen (force-close) in queued_at order', () async {
    final (db, path) = await openTestDb();
    final queue = ActionQueue(db);
    await queue.enqueue(_transfer(at: DateTime.utc(2026, 10, 17, 11, 1)));
    await queue.enqueue(_score(at: DateTime.utc(2026, 10, 17, 11, 0)));
    await db.close();

    final (reopened, _) = await openTestDb(path);
    final again = ActionQueue(reopened);
    final pending = await again.pending();
    expect(pending.map((a) => a.type), ['score_event', 'roster_transfer']);
    expect(pending.first.payload['match_id'], 'm1');
    expect(pending.first.baseVersion, 3);
    expect(await again.count(), 2);
    await reopened.close();
  });

  test('pending() can be scoped to the owner; rejected actions are not resent', () async {
    final (db, _) = await openTestDb();
    final queue = ActionQueue(db);
    final mine = _score();
    await queue.enqueue(mine);
    await queue.enqueue(_transfer());
    expect((await queue.pending(owner: 'user-organizer')).single.actionId, mine.actionId);

    await queue.markRejected(mine.actionId, 'MATCH_NOT_IN_PROGRESS');
    expect(await queue.pending(owner: 'user-organizer'), isEmpty);
    expect(await queue.count(state: PendingState.rejected), 1);

    await queue.requeue(mine.actionId);
    expect((await queue.pending(owner: 'user-organizer')).single.lastError, isNull);
    await db.close();
  });

  test('duplicate action ids are refused locally', () async {
    final (db, _) = await openTestDb();
    final queue = ActionQueue(db);
    final a = _score();
    await queue.enqueue(a);
    await expectLater(queue.enqueue(a), throwsA(anything));
    await db.close();
  });
}
