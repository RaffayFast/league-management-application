import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/cached_fetch.dart';
import '../../../core/models/club_models.dart';
import '../../../core/providers.dart';

class ClubRepository {
  ClubRepository(this._fetcher);
  final CachedFetcher _fetcher;

  Future<Cached<Club>> club(String clubId) => _fetcher.fetch(
      '/api/v1/clubs/${Uri.encodeComponent(clubId)}', Club.fromJson);
}

final clubRepositoryProvider =
    Provider((ref) => ClubRepository(ref.watch(cachedFetcherProvider)));

final clubProvider =
    FutureProvider.autoDispose.family<Cached<Club>, String>((ref, clubId) {
  ref.watch(refreshTickProvider);
  return ref.watch(clubRepositoryProvider).club(clubId);
});
