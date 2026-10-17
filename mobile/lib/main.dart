import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/providers.dart';
import 'core/storage/local_db.dart';
import 'core/storage/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
