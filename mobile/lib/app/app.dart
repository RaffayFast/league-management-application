import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/sync/sync_controller.dart';
import '../core/theme/app_theme.dart';
import '../features/auth/auth_controller.dart';
import 'router.dart';

class LeagueHubApp extends ConsumerWidget {
  const LeagueHubApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Start connectivity monitoring immediately, before any screen asks.
    ref.watch(syncControllerProvider.select((s) => s.hasNetwork));
    final tenantColor = ref.watch(authControllerProvider.select((a) => a.session?.tenant?.primaryColor));

    return MaterialApp.router(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(tenantPrimary: parseHexColor(tenantColor)),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
