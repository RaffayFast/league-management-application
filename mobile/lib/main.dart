import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/app.dart';
import 'core/providers.dart';
import 'core/storage/local_db.dart';
import 'core/storage/settings_store.dart';
import 'features/streaming/services/media_playback_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize SQLite FFI driver for Windows desktop
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // libmpv for HLS on Windows; a failure is shown by the player instead of crashing the app.
  MediaPlaybackService.initializeForPlatform();

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
