import '../config/app_config.dart';
import '../util/ids.dart';
import 'local_db.dart';

/// Non-secret settings persisted in SQLite: server URL and the device id used
/// in offline-sync envelopes.
class SettingsStore {
  SettingsStore(this._db);
  final LocalDb _db;

  static const _baseUrlKey = 'base_url';
  static const _deviceIdKey = 'device_id';

  Future<String> baseUrl() async => await _db.getValue(_baseUrlKey) ?? AppConfig.defaultBaseUrl;

  Future<void> setBaseUrl(String url) => _db.setValue(_baseUrlKey, url);

  /// Generated once per install and reused for every sync request.
  Future<String> deviceId() async {
    final existing = await _db.getValue(_deviceIdKey);
    if (existing != null) return existing;
    final id = newId('dev');
    await _db.setValue(_deviceIdKey, id);
    return id;
  }
}
