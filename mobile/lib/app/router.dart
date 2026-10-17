import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth_controller.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/permissions.dart';
import '../features/clubs/club_screen.dart';
import '../features/clubs/player_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/fixtures/fixtures_screen.dart';
import '../features/match_detail/match_detail_screen.dart';
import '../features/roster/roster_screen.dart';
import '../features/roster/transfer_form_screen.dart';
import '../features/settings/profile_screen.dart';
import '../features/settings/server_settings_screen.dart';
import '../features/standings/standings_screen.dart';
import '../features/store/cart_screen.dart';
import '../features/store/catalogue_screen.dart';
import '../features/store/product_screen.dart';
import '../features/store/receipt_screen.dart';
import '../features/store/receipts_screen.dart';
import '../features/sync_status/sync_status_screen.dart';
import 'home_shell.dart';

/// Re-evaluates redirects whenever the auth state changes.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen(authControllerProvider, (_, __) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final loc = state.matchedLocation;
      if (auth.status == AuthStatus.unknown) return loc == '/splash' ? null : '/splash';

      const publicRoutes = {'/login', '/settings'};
      if (auth.status == AuthStatus.signedOut) return publicRoutes.contains(loc) ? null : '/login';

      if (loc == '/login' || loc == '/splash') return '/home';
      if (loc.startsWith('/roster') && !Permissions.canManageRoster(auth.user)) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const _Splash()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/settings', builder: (_, __) => const ServerSettingsScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => HomeShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, __) => const DashboardScreen())]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/fixtures',
              builder: (_, state) => FixturesScreen(scoringMode: state.uri.queryParameters['scoring'] == '1'),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/standings',
              builder: (_, state) => StandingsScreen(initialLeagueId: state.uri.queryParameters['league']),
            ),
          ]),
          StatefulShellBranch(routes: [GoRoute(path: '/store', builder: (_, __) => const CatalogueScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen())]),
        ],
      ),
      GoRoute(path: '/match/:id', builder: (_, s) => MatchDetailScreen(matchId: s.pathParameters['id']!)),
      GoRoute(path: '/club/:id', builder: (_, s) => ClubScreen(clubId: s.pathParameters['id']!)),
      GoRoute(path: '/player/:id', builder: (_, s) => PlayerScreen(playerId: s.pathParameters['id']!)),
      GoRoute(path: '/roster', builder: (_, __) => const RosterScreen()),
      GoRoute(
        path: '/roster/transfer',
        builder: (_, s) => TransferFormScreen(
          leagueId: s.uri.queryParameters['league']!,
          initialPlayerId: s.uri.queryParameters['player'],
          initialType: s.uri.queryParameters['type'],
        ),
      ),
      GoRoute(path: '/product/:id', builder: (_, s) => ProductScreen(productId: s.pathParameters['id']!)),
      GoRoute(path: '/cart', builder: (_, __) => const CartScreen()),
      GoRoute(path: '/receipts', builder: (_, __) => const ReceiptsScreen()),
      GoRoute(path: '/receipt/:id', builder: (_, s) => ReceiptScreen(orderId: s.pathParameters['id']!)),
      GoRoute(path: '/sync', builder: (_, __) => const SyncStatusScreen()),
    ],
  );
});

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}
