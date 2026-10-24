import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'local_db.dart';

class CachedEntry {
  const CachedEntry(this.json, this.updatedAt);
  final dynamic json;
  final DateTime updatedAt;
}

/// Raw-response cache keyed by API path. Screens re-parse cached JSON with the
/// same model code used for live responses.
class CacheStore {
  CacheStore(this._db);
  final LocalDb _db;

  Future<void> put(String key, dynamic json) => _db.db.insert(
        'cache',
        {
          'key': key,
          'json': jsonEncode(json),
          'updated_at': DateTime.now().toUtc().toIso8601String()
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<CachedEntry?> get(String key) async {
    final rows = await _db.db
        .query('cache', where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    try {
      return CachedEntry(
        jsonDecode(rows.first['json'] as String),
        DateTime.parse(rows.first['updated_at'] as String),
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> clear() => _db.db.delete('cache');
}
