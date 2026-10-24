import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/auth_controller.dart';
import 'data/cached_fetch.dart';
import 'network/api_client.dart';
import 'storage/cache_store.dart';
import 'storage/local_db.dart';
import 'storage/secure_store.dart';
import 'storage/settings_store.dart';
import 'sync/action_queue.dart';
import 'sync/connectivity_service.dart';
import 'sync/sync_controller.dart';
import 'sync/sync_service.dart';

/// Opened in main() and injected with an override.
final localDbProvider = Provider<LocalDb>(
    (ref) => throw UnimplementedError('localDbProvider must be overridden'));

/// Current server URL; initial value loaded from SQLite in main().
final baseUrlProvider = StateProvider<String>(
    (ref) => throw UnimplementedError('baseUrlProvider must be overridden'));

/// Bumped after sync or mutations so data providers refetch.
final refreshTickProvider = StateProvider<int>((ref) => 0);

final settingsStoreProvider =
    Provider((ref) => SettingsStore(ref.watch(localDbProvider)));
final cacheStoreProvider =
    Provider((ref) => CacheStore(ref.watch(localDbProvider)));
final actionQueueProvider =
    Provider((ref) => ActionQueue(ref.watch(localDbProvider)));
final secureStoreProvider = Provider((ref) => SecureStore());
final connectivityServiceProvider = Provider((ref) => ConnectivityService());

/// Mutable holder so the API client never needs to rebuild when the token changes.
class TokenHolder {
  String? token;
}

final tokenHolderProvider = Provider((ref) => TokenHolder());

final apiClientProvider = Provider<ApiClient>((ref) {
  final holder = ref.watch(tokenHolderProvider);
  return ApiClient(
    baseUrl: ref.watch(baseUrlProvider),
    tokenProvider: () => holder.token,
    onUnauthorized: () =>
        ref.read(authControllerProvider.notifier).sessionExpired(),
    onReachability: (ok) =>
        ref.read(syncControllerProvider.notifier).setServerReachable(ok),
  );
});

final cachedFetcherProvider = Provider((ref) => CachedFetcher(
      api: ref.watch(apiClientProvider),
      cache: ref.watch(cacheStoreProvider),
      isOffline: () => !ref.read(syncControllerProvider).hasNetwork,
    ));

final syncServiceProvider = Provider((ref) => SyncService(
      api: ref.watch(apiClientProvider),
      queue: ref.watch(actionQueueProvider),
      deviceId: ref.watch(settingsStoreProvider).deviceId,
    ));
