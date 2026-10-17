import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/cached_fetch.dart';
import '../../../core/models/club_models.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/providers.dart';
import '../../fixtures/data/league_repository.dart';

class RosterRepository {
  RosterRepository(this._fetcher, this._api);

  final CachedFetcher _fetcher;
  final ApiClient _api;

  Future<Cached<RosterResponse>> roster(String leagueId) =>
      _fetcher.fetch('/api/v1/roster/${Uri.encodeComponent(leagueId)}', RosterResponse.fromJson);

  Future<Cached<RosterHistory>> history(String playerId, {String? asOf}) => _fetcher.fetch(
        '/api/v1/roster/history/${Uri.encodeComponent(playerId)}',
        RosterHistory.fromJson,
        query: asOf == null ? null : {'as_of': asOf},
        cacheKey: '/api/v1/roster/history/$playerId?as_of=${asOf ?? ''}',
      );

  /// POST /api/v1/roster/transfer. Returns the response and whether it was a replay.
  Future<(TransferResponse, bool)> transfer(TransferRequest request) async {
    final response = await _api.send('POST', '/api/v1/roster/transfer', body: request.toJson());
    return (parseOrThrow(response.data, TransferResponse.fromJson, 'transfer response'), response.isReplay);
  }
}

final rosterRepositoryProvider = Provider(
  (ref) => RosterRepository(ref.watch(cachedFetcherProvider), ref.watch(apiClientProvider)),
);

final rosterProvider = FutureProvider.autoDispose.family<Cached<RosterResponse>, String>((ref, leagueId) {
  ref.watch(refreshTickProvider);
  return ref.watch(rosterRepositoryProvider).roster(leagueId);
});

final rosterHistoryProvider = FutureProvider.autoDispose.family<Cached<RosterHistory>, String>((ref, playerId) {
  ref.watch(refreshTickProvider);
  return ref.watch(rosterRepositoryProvider).history(playerId);
});

/// The league roster that contains a club's squad. There is no club->league
/// route, so visible leagues are scanned (there are only a handful).
final clubRosterProvider = FutureProvider.autoDispose.family<Cached<RosterResponse>?, String>((ref, clubId) async {
  final leagues = await ref.watch(leaguesProvider.future);
  for (final league in leagues.data) {
    try {
      final roster = await ref.watch(rosterProvider(league.leagueId).future);
      if (roster.data.squads.any((s) => s.clubId == clubId)) return roster;
    } on ApiException catch (e) {
      if (e.code == 'LEAGUE_NOT_FOUND' || e.code == 'FORBIDDEN') continue;
      if (e.isConnectivity) continue;
      rethrow;
    }
  }
  return null;
});
