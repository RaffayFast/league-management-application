import 'package:flutter_test/flutter_test.dart';
import 'package:leaguehub/core/data/cached_fetch.dart';
import 'package:leaguehub/core/models/json.dart';
import 'package:leaguehub/core/models/league_models.dart';
import 'package:leaguehub/core/network/api_exception.dart';
import 'package:leaguehub/core/storage/cache_store.dart';

import 'helpers.dart';

const _standings = {
  'league_id': 'league-alpha-1',
  'sport_id': 'football',
  'qualification_spots': 1,
  'table': [
    {'rank': 1, 'team_id': 'club-alpha-1', 'played': 1, 'won': 1, 'drawn': 0, 'lost': 0, 'scored': 2,
      'conceded': 1, 'diff': 1, 'points': 3, 'fair_play': 0, 'status': 'still_possible', 'resolved_by': null},
  ],
  'h2h': {},
};

void main() {
  group('ApiClient error mapping', () {
    test('contract envelope becomes ApiException with code, status and details', () async {
      final adapter = FakeAdapter((o) async => jsonResponse({
            'error': {'code': 'OUT_OF_STOCK', 'message': 'gone', 'details': {'variant_id': 'var-jersey-001-M'}},
          }, 409));
      final client = testClient(adapter);
      await expectLater(
        client.post('/api/v1/store/checkout', {}),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'OUT_OF_STOCK')
            .having((e) => e.statusCode, 'status', 409)
            .having((e) => e.details['variant_id'], 'details', 'var-jersey-001-M')),
      );
    });

    test('401 on an authenticated call triggers session expiry', () async {
      var expired = false;
      final adapter = FakeAdapter((o) async => jsonResponse({
            'error': {'code': 'UNAUTHENTICATED', 'message': 'no', 'details': {}},
          }, 401));
      final client = testClient(adapter, onUnauthorized: () => expired = true);
      await expectLater(client.get('/api/v1/leagues'), throwsA(isA<ApiException>()));
      expect(expired, isTrue);
    });

    test('connection errors are connectivity errors and mark the server unreachable', () async {
      bool? reachable;
      final adapter = FakeAdapter((o) async => connectionError(o));
      final client = testClient(adapter, onReachability: (r) => reachable = r);
      await expectLater(
        client.get('/api/v1/leagues'),
        throwsA(isA<ApiException>().having((e) => e.isConnectivity, 'connectivity', isTrue)),
      );
      expect(reachable, isFalse);
    });

    test('201 vs 200 distinguishes first create from idempotent replay', () async {
      var status = 201;
      final adapter = FakeAdapter((o) async => jsonResponse({'event_id': 'e1'}, status));
      final client = testClient(adapter);
      expect((await client.send('POST', '/api/v1/events', body: {})).isReplay, isFalse);
      status = 200;
      expect((await client.send('POST', '/api/v1/events', body: {})).isReplay, isTrue);
    });
  });

  group('offline cache', () {
    late CacheStore cache;
    late FakeAdapter adapter;
    var offline = false;

    setUp(() async {
      final (db, _) = await openTestDb();
      cache = CacheStore(db);
      adapter = FakeAdapter((o) async => jsonResponse(_standings));
      offline = false;
    });

    CachedFetcher fetcher() => CachedFetcher(api: testClient(adapter), cache: cache, isOffline: () => offline);
    const path = '/api/v1/leagues/league-alpha-1/standings';

    test('live data is cached, then served from SQLite when the server is unreachable', () async {
      final live = await fetcher().fetch(path, StandingsResponse.fromJson);
      expect(live.fromCache, isFalse);

      adapter.handler = (o) async => connectionError(o);
      final cached = await fetcher().fetch(path, StandingsResponse.fromJson);
      expect(cached.fromCache, isTrue);
      expect(cached.cachedAt, isNotNull);
      expect(cached.data.table.single.teamId, 'club-alpha-1');
    });

    test('known-offline reads go straight to the cache without a request', () async {
      await fetcher().fetch(path, StandingsResponse.fromJson);
      final before = adapter.requests.length;
      offline = true;
      final res = await fetcher().fetch(path, StandingsResponse.fromJson);
      expect(res.fromCache, isTrue);
      expect(adapter.requests.length, before);
    });

    test('offline with nothing cached is a connectivity error', () async {
      offline = true;
      await expectLater(
        fetcher().fetch('/api/v1/never-fetched', (j) => asMap(j)),
        throwsA(isA<ApiException>().having((e) => e.isConnectivity, 'connectivity', isTrue)),
      );
    });

    test('server rejections are not masked by stale cache', () async {
      await fetcher().fetch(path, StandingsResponse.fromJson);
      adapter.handler = (o) async => jsonResponse({
            'error': {'code': 'FORBIDDEN', 'message': 'no', 'details': {}},
          }, 403);
      await expectLater(
        fetcher().fetch(path, StandingsResponse.fromJson),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FORBIDDEN')),
      );
    });
  });
}
