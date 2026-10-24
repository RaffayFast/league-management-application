import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/sync/sync_controller.dart';
import '../core/theme/app_theme.dart';
import '../features/auth/auth_controller.dart';
import '../features/cart/controllers/guest_cart_controller.dart';
import 'router.dart';

class LeagueHubApp extends ConsumerStatefulWidget {
  const LeagueHubApp({super.key});

  @override
  ConsumerState<LeagueHubApp> createState() => _LeagueHubAppState();
}

class _LeagueHubAppState extends ConsumerState<LeagueHubApp> {
  @override
  void initState() {
    super.initState();
    // nascon:// deep links (Day 2 spec 6.3): navigate once the router exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(deepLinkServiceProvider).start();
      ref.read(guestCartControllerProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Start connectivity monitoring immediately, before any screen asks.
    ref.watch(syncControllerProvider.select((s) => s.hasNetwork));
    final tenantColor = ref.watch(
        authControllerProvider.select((a) => a.session?.tenant?.primaryColor));

    return MaterialApp.router(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(tenantPrimary: parseHexColor(tenantColor)),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
