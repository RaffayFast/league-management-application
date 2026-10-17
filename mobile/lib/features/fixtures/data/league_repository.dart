import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/cached_fetch.dart';
import '../../../core/models/json.dart';
import '../../../core/models/league_models.dart';
import '../../../core/models/match_models.dart';
import '../../../core/network/api_client.dart';
import '../../../core/providers.dart';

/// Leagues, fixtures, standings, matches and sport configs (B2–B5, A6 via /api/v1/events).
class LeagueRepository {
  LeagueRepository(this._fetcher, this._api);

  final CachedFetcher _fetcher;
  final ApiClient _api;

  Future<Cached<List<League>>> leagues() => _fetcher.fetch(
        '/api/v1/leagues',
        (j) => mapList(j['leagues'], League.fromJson),
      );

  Future<Cached<FixturesResponse>> fixtures(String leagueId) => _fetcher.fetch(
        '/api/v1/leagues/${Uri.encodeComponent(leagueId)}/fixtures',
        FixturesResponse.fromJson,
      );

  Future<Cached<StandingsResponse>> standings(String leagueId) => _fetcher.fetch(
        '/api/v1/leagues/${Uri.encodeComponent(leagueId)}/standings',
        StandingsResponse.fromJson,
      );

  Future<Cached<ScoreObject>> match(String matchId) => _fetcher.fetch(
        '/api/v1/matches/${Uri.encodeComponent(matchId)}',
        ScoreObject.fromJson,
      );

  Future<Cached<SportConfig>> sport(String sportId) => _fetcher.fetch(
        '/api/v1/sports/${Uri.encodeComponent(sportId)}',
        SportConfig.fromJson,
      );

  /// POST /api/v1/events with the exact A6 body. Returns the ack and whether it was a replay.
  Future<(EventAck, bool)> postEvent(Json eventBody) async {
    final response = await _api.send('POST', '/api/v1/events', body: eventBody);
    return (parseOrThrow(response.data, EventAck.fromJson, 'event ack'), response.isReplay);
  }
}

final leagueRepositoryProvider = Provider(
  (ref) => LeagueRepository(ref.watch(cachedFetcherProvider), ref.watch(apiClientProvider)),
);

final leaguesProvider = FutureProvider.autoDispose<Cached<List<League>>>((ref) {
  ref.watch(refreshTickProvider);
  return ref.watch(leagueRepositoryProvider).leagues();
});

final fixturesProvider = FutureProvider.autoDispose.family<Cached<FixturesResponse>, String>((ref, leagueId) {
  ref.watch(refreshTickProvider);
  return ref.watch(leagueRepositoryProvider).fixtures(leagueId);
});

final standingsProvider = FutureProvider.autoDispose.family<Cached<StandingsResponse>, String>((ref, leagueId) {
  ref.watch(refreshTickProvider);
  return ref.watch(leagueRepositoryProvider).standings(leagueId);
});

final sportProvider = FutureProvider.autoDispose.family<Cached<SportConfig>, String>((ref, sportId) {
  return ref.watch(leagueRepositoryProvider).sport(sportId);
});

/// All fixtures across visible leagues; used for club/team views and dashboards.
final allFixturesProvider = FutureProvider.autoDispose<List<Fixture>>((ref) async {
  final leagues = await ref.watch(leaguesProvider.future);
  final out = <Fixture>[];
  for (final league in leagues.data) {
    try {
      out.addAll((await ref.watch(fixturesProvider(league.leagueId).future)).data.fixtures);
    } catch (_) {
      // One unavailable league must not hide the others.
    }
  }
  return out;
});
