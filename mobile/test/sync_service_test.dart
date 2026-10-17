import 'package:flutter_test/flutter_test.dart';
import 'package:leaguehub/core/network/api_exception.dart';
import 'package:leaguehub/core/sync/action_queue.dart';
import 'package:leaguehub/core/sync/pending_action.dart';
import 'package:leaguehub/core/sync/sync_service.dart';

import 'helpers.dart';

PendingAction _action(String label, {String owner = 'me', int base = 1}) => PendingAction.forScoreEvent(
      eventBody: {
        'event_id': 'evt-$label',
        'match_id': 'm1',
        'type': 'score',
        'payload': {'team_id': 't1', 'event_type': 'goal'},
      },
      baseVersion: base,
      label: label,
      owner: owner,
    );

void main() {
  late ActionQueue queue;
  late FakeAdapter adapter;
  late SyncService service;

  setUp(() async {
    final (db, _) = await openTestDb();
    queue = ActionQueue(db);
    adapter = FakeAdapter((o) async => jsonResponse({}));
    service = SyncService(api: testClient(adapter), queue: queue, deviceId: () async => 'dev-test');
  });

  test('sends the A12 envelope to /api/v1/sync with only the owner\'s actions', () async {
    final a = _action('a');
    await queue.enqueue(a);
    await queue.enqueue(_action('other', owner: 'someone-else'));
    adapter.handler = (o) async => jsonResponse({
          'device_id': 'dev-test',
          'results': [
            {'action_id': a.actionId, 'status': 'applied', 'resolution': 'appended', 'error_code': null,
              'processed_order': 1, 'server_version': 4, 'signature': 'sig'},
          ],
          'summary': {'applied': 1, 'rejected': 0, 'duplicate': 0},
        });

    await service.syncPending(owner: 'me');

    final req = adapter.requests.single;
    expect(req.path, '/api/v1/sync');
    expect(req.method, 'POST');
    expect(req.headers['Authorization'], 'Bearer token');
    final body = req.data as Map<String, dynamic>;
    expect(body['device_id'], 'dev-test');
    final actions = body['actions'] as List;
    expect(actions, hasLength(1));
    expect((actions.single as Map)['action_id'], a.actionId);
  });

  test('applied and duplicate are removed; rejected stays visible with its reason', () async {
    final applied = _action('applied');
    final dup = _action('dup');
    final rejected = _action('rejected');
    for (final a in [applied, dup, rejected]) {
      await queue.enqueue(a);
    }
    adapter.handler = (o) async => jsonResponse({
          'device_id': 'dev-test',
          'results': [
            {'action_id': applied.actionId, 'status': 'applied', 'resolution': 'rebased_append', 'error_code': null,
              'processed_order': 1, 'server_version': 7, 'signature': 's1'},
            {'action_id': dup.actionId, 'status': 'duplicate', 'resolution': 'skipped_duplicate', 'error_code': null,
              'processed_order': 2, 'server_version': 7, 'signature': 's2'},
            {'action_id': rejected.actionId, 'status': 'rejected', 'resolution': 'server_wins',
              'error_code': 'MATCH_NOT_IN_PROGRESS', 'processed_order': 3, 'server_version': 7, 'signature': null},
          ],
          'summary': {'applied': 1, 'rejected': 1, 'duplicate': 1},
        });

    final report = await service.syncPending(owner: 'me');

    expect(report.applied, 1);
    expect(report.duplicate, 1);
    expect(report.rejected, 1);
    final remaining = await queue.all();
    expect(remaining.single.actionId, rejected.actionId);
    expect(remaining.single.state, PendingState.rejected);
    expect(remaining.single.lastError, 'MATCH_NOT_IN_PROGRESS');
    final history = await queue.history();
    expect(history.map((h) => h.status).toSet(), {'applied', 'duplicate', 'rejected'});
    expect(history.firstWhere((h) => h.status == 'applied').resolution, 'rebased_append');
  });

  test('network failure keeps every action pending and records the attempt', () async {
    final a = _action('a');
    await queue.enqueue(a);
    adapter.handler = (o) async => connectionError(o);

    final report = await service.syncPending(owner: 'me');

    expect(report.transportError?.kind, ApiErrorKind.network);
    final pending = await queue.pending(owner: 'me');
    expect(pending.single.actionId, a.actionId);
    expect(pending.single.attempts, 1);
    expect(pending.single.lastError, 'NETWORK_ERROR');
    expect(await queue.history(), isEmpty);
  });

  test('a result missing from the response leaves that action pending', () async {
    final a = _action('a');
    final b = _action('b');
    await queue.enqueue(a);
    await queue.enqueue(b);
    adapter.handler = (o) async => jsonResponse({
          'device_id': 'dev-test',
          'results': [
            {'action_id': a.actionId, 'status': 'applied', 'resolution': 'appended', 'error_code': null,
              'processed_order': 1, 'server_version': 2, 'signature': 's'},
          ],
        });
    await service.syncPending(owner: 'me');
    expect((await queue.pending()).single.actionId, b.actionId);
  });

  test('a 400 envelope rejection marks the batch rejected instead of retrying forever', () async {
    await queue.enqueue(_action('a'));
    adapter.handler = (o) async => jsonResponse({
          'error': {'code': 'VALIDATION_ERROR', 'message': 'bad', 'details': {'fields': ['actions.0.queued_at']}},
        }, 400);
    final report = await service.syncPending(owner: 'me');
    expect(report.transportError?.code, 'VALIDATION_ERROR');
    expect(await queue.count(state: PendingState.rejected), 1);
    expect(await queue.pending(), isEmpty);
  });

  test('nothing queued means no request', () async {
    final report = await service.syncPending(owner: 'me');
    expect(report.isEmpty, isTrue);
    expect(adapter.requests, isEmpty);
  });
}
