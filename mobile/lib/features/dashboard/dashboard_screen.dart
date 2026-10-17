import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/auth_models.dart';
import '../../core/models/json.dart';
import '../../core/models/league_models.dart';
import '../../core/network/error_messages.dart';
import '../../core/providers.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/dialogs.dart';
import '../auth/auth_controller.dart';
import '../auth/permissions.dart';
import '../clubs/data/club_repository.dart';
import '../fixtures/data/league_repository.dart';
import '../fixtures/widgets/fixture_card.dart';
import '../roster/data/roster_repository.dart';

/// Top-level routes that are bottom-navigation branches (use go, not push).
const _branchRoutes = {'/home', '/fixtures', '/standings', '/store', '/profile'};

final _serverHealthProvider = FutureProvider.autoDispose<String>((ref) async {
  ref.watch(refreshTickProvider);
  final data = await ref.watch(apiClientProvider).get('/health', auth: false);
  return asString(asMap(data)['status'], 'unknown');
});

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authControllerProvider).session;
    if (session == null) return const SizedBox.shrink();
    final user = session.user;
    final actions = dashboardActionsFor(user);

    return AppScaffold(
      title: 'LeagueHub',
      body: RefreshIndicator(
        onRefresh: () async {
          ref.read(refreshTickProvider.notifier).state++;
          await ref.read(syncControllerProvider.notifier).refreshCounts();
        },
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            _Greeting(user: user, tenantName: session.tenant?.name),
            const SizedBox(height: AppSpacing.lg),
            _QuickActions(actions: actions),
            const SizedBox(height: AppSpacing.lg),
            ...switch (user.role) {
              UserRole.superAdmin => [const _AdminOverview()],
              UserRole.leagueOrganizer => [_OrganizerSection(leagueId: user.leagueId)],
              UserRole.clubManager => [_ClubSection(clubId: user.clubId, manage: true)],
              UserRole.player => [_PlayerSection(user: user)],
              _ => [const _LiveAndUpcoming(title: 'Live & upcoming')],
            },
          ],
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.user, this.tenantName});
  final AppUser user;
  final String? tenantName;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(color: AppColors.navy, borderRadius: BorderRadius.circular(AppSpacing.radius)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Welcome back,', style: TextStyle(color: Colors.white.withValues(alpha: 0.75))),
          Text(user.name,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              LabelBadge(icon: Icons.badge_outlined, text: roleLabel(user.role), color: AppColors.navy, background: AppColors.lime),
              if (tenantName != null)
                LabelBadge(icon: Icons.apartment, text: tenantName!, color: Colors.white, background: primary),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.actions});
  final List<DashboardAction> actions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final columns = c.maxWidth >= 520 ? 4 : 2;
      final width = (c.maxWidth - AppSpacing.md * (columns - 1)) / columns;
      return Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.md,
        children: [
          for (final a in actions)
            SizedBox(
              width: width,
              child: Card(
                color: a.highlight ? AppColors.lime : null,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () {
                    if (_branchRoutes.contains(Uri.parse(a.route).path)) {
                      context.go(a.route);
                    } else {
                      context.push(a.route);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(a.icon, color: AppColors.navy),
                        const SizedBox(height: AppSpacing.sm),
                        Text(a.label, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }
}

class _FixtureList extends StatelessWidget {
  const _FixtureList({required this.fixtures, required this.empty});
  final List<Fixture> fixtures;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (fixtures.isEmpty) return Text(empty, style: const TextStyle(color: AppColors.textMuted));
    return Column(
      children: [
        for (final f in fixtures.take(5)) ...[
          FixtureCard(fixture: f),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

List<Fixture> _liveFirst(Iterable<Fixture> all) {
  int rank(Fixture f) => switch (f.status) {
        MatchStatus.inProgress => 0,
        MatchStatus.upcoming => 1,
        _ => 2,
      };
  final list = all.where((f) => f.status == MatchStatus.inProgress || f.status == MatchStatus.upcoming).toList()
    ..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return (a.scheduledAt ?? DateTime(9999)).compareTo(b.scheduledAt ?? DateTime(9999));
    });
  return list;
}

class _LiveAndUpcoming extends ConsumerWidget {
  const _LiveAndUpcoming({required this.title, this.teamId});
  final String title;
  final String? teamId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(allFixturesProvider);
    return SectionCard(
      title: title,
      icon: Icons.sports_score,
      trailing: TextButton(onPressed: () => context.go('/fixtures'), child: const Text('All')),
      child: async.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => Text(friendlyError(e)),
        data: (all) => _FixtureList(
          fixtures: _liveFirst(teamId == null ? all : all.where((f) => f.homeTeamId == teamId || f.awayTeamId == teamId)),
          empty: 'No live or upcoming matches.',
        ),
      ),
    );
  }
}

class _AdminOverview extends ConsumerWidget {
  const _AdminOverview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leagues = ref.watch(leaguesProvider);
    final health = ref.watch(_serverHealthProvider);
    final sync = ref.watch(syncControllerProvider);
    return Column(
      children: [
        SectionCard(
          title: 'System status',
          icon: Icons.monitor_heart_outlined,
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              health.when(
                loading: () => const LabelBadge(icon: Icons.hourglass_top, text: 'Checking server', color: AppColors.info),
                error: (e, _) => const LabelBadge(icon: Icons.error_outline, text: 'Server unreachable', color: AppColors.danger),
                data: (s) => LabelBadge(
                  icon: s == 'ok' ? Icons.check_circle : Icons.warning_amber,
                  text: 'Server: $s',
                  color: s == 'ok' ? AppColors.success : AppColors.warning,
                ),
              ),
              LabelBadge(icon: Icons.schedule, text: '${sync.pending} queued on device', color: AppColors.navySoft),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SectionCard(
          title: 'Leagues across tenants',
          icon: Icons.emoji_events_outlined,
          child: leagues.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(friendlyError(e)),
            data: (res) {
              final byTenant = <String, List<League>>{};
              for (final l in res.data) {
                byTenant.putIfAbsent(l.tenantId ?? 'No tenant', () => []).add(l);
              }
              return Column(
                children: [
                  for (final entry in byTenant.entries)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      leading: const Icon(Icons.apartment),
                      title: Text(entry.key),
                      subtitle: Text('${entry.value.length} league(s)'),
                      children: [
                        for (final l in entry.value)
                          ListTile(
                            title: Text(l.name),
                            subtitle: Text(humanize(l.sportId)),
                            trailing: const Icon(Icons.leaderboard_outlined),
                            onTap: () => context.go('/standings?league=${Uri.encodeComponent(l.leagueId)}'),
                          ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const _LiveAndUpcoming(title: 'Live & upcoming (all tenants)'),
      ],
    );
  }
}

class _OrganizerSection extends ConsumerWidget {
  const _OrganizerSection({required this.leagueId});
  final String? leagueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (leagueId == null) return const _LiveAndUpcoming(title: 'Live & upcoming');
    final async = ref.watch(fixturesProvider(leagueId!));
    return Column(
      children: [
        SectionCard(
          title: 'Your league · $leagueId',
          icon: Icons.emoji_events,
          trailing: TextButton(
            onPressed: () => context.go('/standings?league=${Uri.encodeComponent(leagueId!)}'),
            child: const Text('Standings'),
          ),
          child: async.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(friendlyError(e)),
            data: (res) {
              final live = res.data.fixtures.where((f) => f.status == MatchStatus.inProgress).toList();
              final upcoming = res.data.fixtures.where((f) => f.status == MatchStatus.upcoming).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (res.fromCache) const Text('Offline copy', style: TextStyle(color: AppColors.warning)),
                  Text('Live now (${live.length}) — tap to score', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: AppSpacing.sm),
                  _FixtureList(fixtures: live, empty: 'No matches in progress.'),
                  const SizedBox(height: AppSpacing.md),
                  Text('Upcoming (${upcoming.length})', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: AppSpacing.sm),
                  _FixtureList(fixtures: upcoming, empty: 'Nothing scheduled.'),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ClubSection extends ConsumerWidget {
  const _ClubSection({required this.clubId, required this.manage});
  final String? clubId;
  final bool manage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (clubId == null) return const _LiveAndUpcoming(title: 'Live & upcoming');
    final club = ref.watch(clubProvider(clubId!));
    return Column(
      children: [
        SectionCard(
          title: 'Your club',
          icon: Icons.shield,
          child: club.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(friendlyError(e)),
            data: (res) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: TeamAvatar(name: res.data.name),
                  title: Text(res.data.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${res.data.roster.length} registered players'
                      '${res.fromCache ? ' · offline copy' : ''}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/club/${Uri.encodeComponent(clubId!)}'),
                ),
                if (manage) ...[
                  const SizedBox(height: AppSpacing.sm),
                  FilledButton.icon(
                    onPressed: () => context.push('/roster'),
                    icon: const Icon(Icons.groups),
                    label: const Text('Manage roster'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _LiveAndUpcoming(title: 'Club fixtures', teamId: clubId),
      ],
    );
  }
}

class _PlayerSection extends ConsumerWidget {
  const _PlayerSection({required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerId = user.playerId;
    return Column(
      children: [
        if (playerId != null)
          SectionCard(
            title: 'My registration',
            icon: Icons.person,
            child: ref.watch(rosterHistoryProvider(playerId)).when(
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => Text(friendlyError(e)),
                  data: (res) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Squad: ${res.data.currentSquadId ?? 'not registered'}'),
                    subtitle: Text('League ${res.data.leagueId} · ${res.data.history.length} recorded move(s)'
                        '${res.data.parentSquadId != null ? ' · on loan from ${res.data.parentSquadId}' : ''}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/player/${Uri.encodeComponent(playerId)}'),
                  ),
                ),
          ),
        const SizedBox(height: AppSpacing.md),
        _ClubSection(clubId: user.clubId, manage: false),
      ],
    );
  }
}
