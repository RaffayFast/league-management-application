import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/auth_models.dart';
import '../models/json.dart';

/// Session persistence in the Android Keystore-backed secure storage.
/// Only the token and user/tenant metadata are stored — never the password.
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
                aOptions: AndroidOptions(encryptedSharedPreferences: true));

  final FlutterSecureStorage _storage;
  static const _sessionKey = 'leaguehub.session';

  Future<void> saveSession(Session session) =>
      _storage.write(key: _sessionKey, value: jsonEncode(session.toJson()));

  Future<Session?> readSession() async {
    try {
      final raw = await _storage.read(key: _sessionKey);
      if (raw == null) return null;
      final session = Session.fromJson(asMap(jsonDecode(raw)));
      return session.token.isEmpty ? null : session;
    } catch (_) {
      // Corrupt or undecryptable entry (e.g. after a backup restore): start clean.
      await clear();
      return null;
    }
  }

  Future<void> clear() => _storage.delete(key: _sessionKey);
}
