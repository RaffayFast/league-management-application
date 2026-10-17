import 'package:flutter/material.dart';

import '../../core/models/auth_models.dart';

/// UI-side permission hints mirroring the backend matrix (api_contract.md Part B).
/// These only decide what is *shown*; the server enforces every request.
class Permissions {
  Permissions._();

  /// POST /api/v1/events: super_admin; league_organizer for own league.
  static bool canScore(AppUser? user, String? leagueId) {
    if (user == null) return false;
    if (user.role == UserRole.superAdmin) return true;
    return user.role == UserRole.leagueOrganizer && leagueId != null && user.leagueId == leagueId;
  }

  /// POST /api/v1/roster/transfer: super_admin; club_manager for own club's squads.
  static bool canManageRoster(AppUser? user) =>
      user != null && (user.role == UserRole.superAdmin || user.role == UserRole.clubManager);

  static bool canManageClub(AppUser? user, String clubId) {
    if (user == null) return false;
    if (user.role == UserRole.superAdmin) return true;
    return user.role == UserRole.clubManager && user.clubId == clubId;
  }
}

class DashboardAction {
  const DashboardAction(this.id, this.label, this.icon, this.route, {this.highlight = false});
  final String id;
  final String label;
  final IconData icon;
  final String route;
  final bool highlight;
}

/// Quick actions per role. Pure so it can be unit tested.
List<DashboardAction> dashboardActionsFor(AppUser user) {
  const fixtures = DashboardAction('fixtures', 'Fixtures', Icons.event_note, '/fixtures');
  const standings = DashboardAction('standings', 'Standings', Icons.leaderboard, '/standings');
  const store = DashboardAction('store', 'Store', Icons.storefront, '/store');
  const sync = DashboardAction('sync', 'Sync status', Icons.sync, '/sync');

  switch (user.role) {
    case UserRole.superAdmin:
      return const [
        DashboardAction('roster', 'Roster admin', Icons.groups, '/roster'),
        fixtures,
        standings,
        store,
        sync,
      ];
    case UserRole.leagueOrganizer:
      return const [
        DashboardAction('score', 'Score a match', Icons.scoreboard, '/fixtures?scoring=1', highlight: true),
        fixtures,
        standings,
        sync,
      ];
    case UserRole.clubManager:
      return [
        const DashboardAction('roster', 'Manage roster', Icons.groups, '/roster', highlight: true),
        if (user.clubId != null) DashboardAction('club', 'My club', Icons.shield, '/club/${user.clubId}'),
        fixtures,
        store,
        sync,
      ];
    case UserRole.player:
      return [
        if (user.playerId != null)
          DashboardAction('me', 'My profile', Icons.person, '/player/${user.playerId}', highlight: true),
        if (user.clubId != null) DashboardAction('club', 'My club', Icons.shield, '/club/${user.clubId}'),
        fixtures,
        standings,
      ];
    case UserRole.viewer:
    case UserRole.unknown:
      return const [fixtures, standings, store];
  }
}
