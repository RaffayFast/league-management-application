import '../models/json.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';
import '../storage/cache_store.dart';

/// A value plus where it came from, so screens can label stale data.
class Cached<T> {
  const Cached(this.data, {this.fromCache = false, this.cachedAt});
  final T data;
  final bool fromCache;
  final DateTime? cachedAt;
}

/// Network-first reads with SQLite fallback. Live responses are cached raw and
/// re-parsed with the same model code when offline.
class CachedFetcher {
  CachedFetcher({required this.api, required this.cache, required this.isOffline});

  final ApiClient api;
  final CacheStore cache;
  final bool Function() isOffline;

  Future<Cached<T>> fetch<T>(
    String path,
    T Function(Json) parse, {
    Map<String, dynamic>? query,
    String? cacheKey,
  }) async {
    final key = cacheKey ?? path;

    // Known offline: skip the connect timeout and go straight to the cache.
    if (isOffline()) {
      final hit = await cache.get(key);
      if (hit != null) return Cached(parseOrThrow(hit.json, parse, path), fromCache: true, cachedAt: hit.updatedAt);
      throw ApiException.network('Offline and nothing cached yet');
    }

    try {
      final data = await api.get(path, query: query);
      final parsed = parseOrThrow(data, parse, path);
      await cache.put(key, data);
      return Cached(parsed);
    } on ApiException catch (e) {
      if (!e.isConnectivity) rethrow;
      final hit = await cache.get(key);
      if (hit == null) rethrow;
      return Cached(parseOrThrow(hit.json, parse, path), fromCache: true, cachedAt: hit.updatedAt);
    }
  }
}
