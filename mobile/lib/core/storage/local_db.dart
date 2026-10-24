import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// SQLite database backing the offline cache and the persistent action queue.
/// Survives force-close and restart; nothing offline-critical lives only in memory.
class LocalDb {
  LocalDb(this.db);

  final Database db;

  static const _version = 1;

  static Future<LocalDb> open({DatabaseFactory? factory, String? path}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), 'leaguehub.db');
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(version: _version, onCreate: _create),
    );
    return LocalDb(db);
  }

  static Future<void> _create(Database db, int version) async {
    await db
        .execute('CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    await db.execute(
      'CREATE TABLE cache (key TEXT PRIMARY KEY, json TEXT NOT NULL, updated_at TEXT NOT NULL)',
    );
    await db.execute('''
      CREATE TABLE pending_actions (
        action_id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        queued_at TEXT NOT NULL,
        base_version INTEGER,
        payload TEXT NOT NULL,
        label TEXT NOT NULL,
        target TEXT NOT NULL,
        state TEXT NOT NULL,
        last_error TEXT,
        attempts INTEGER NOT NULL DEFAULT 0,
        owner TEXT NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE sync_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        action_id TEXT NOT NULL,
        type TEXT NOT NULL,
        label TEXT NOT NULL,
        status TEXT NOT NULL,
        resolution TEXT,
        error_code TEXT,
        server_version INTEGER,
        synced_at TEXT NOT NULL
      )''');
    await db.execute(
      'CREATE TABLE receipts (order_id TEXT PRIMARY KEY, json TEXT NOT NULL, created_at TEXT NOT NULL, owner TEXT NOT NULL)',
    );
  }

  Future<String?> getValue(String key) async {
    final rows =
        await db.query('kv', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setValue(String key, String value) =>
      db.insert('kv', {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> close() => db.close();
}
