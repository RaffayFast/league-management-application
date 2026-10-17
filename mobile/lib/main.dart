import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/app.dart';
import 'core/providers.dart';
import 'core/storage/local_db.dart';
import 'core/storage/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize SQLite FFI driver for Windows desktop
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final db = await LocalDb.open();
  final baseUrl = await SettingsStore(db).baseUrl();

  runApp(ProviderScope(
    overrides: [
      localDbProvider.overrideWithValue(db),
      baseUrlProvider.overrideWith((ref) => baseUrl),
    ],
    child: const LeagueHubApp(),
  ));
}