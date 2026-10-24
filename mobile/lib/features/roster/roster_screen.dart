import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/cached_fetch.dart';
import '../../core/models/auth_models.dart';
import '../../core/models/club_models.dart';
import '../../core/providers.dart';
import '../../core/sync/pending_action.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/state_views.dart';
import '../auth/auth_controller.dart';
import '../fixtures/data/league_repository.dart';
import '../fixtures/widgets/league_picker.dart';
import 'data/roster_repository.dart';

/// Club manager: own club's squad(s). Super-admin: any league's roster.
class RosterScreen extends ConsumerStatefulWidget {
  const RosterScreen({super.key});

  @override
  ConsumerState<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends ConsumerState<RosterScreen> {
  String? _adminLeagueId;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).user!;
    final isAdmin = user.role == UserRole.superAdmin;

    Widget body;
    if (isAdmin) {
      body = AsyncBody(
        value: ref.watch(leaguesProvider),
        onRetry: () => ref.invalidate(leaguesProvider),
        data: (leagues) {
          if (leagues.data.isEmpty) return const EmptyView(title: 'No leagues');
          final leagueId = _adminLeagueId ?? leagues.data.first.leagueId;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
                child: LeaguePicker(
                  leagues: leagues.data,
                  selectedLeagueId: leagueId,
                  onLeagueChanged: (id) => setState(() => _adminLeagueId = id),
                ),
              ),
              Expanded(
                child: AsyncBody(
                  value: ref.watch(rosterProvider(leagueId)),
                  onRetry: () => ref.invalidate(rosterProvider(leagueId)),
                  data: (roster) => _RosterBody(
                      roster: roster,
                      ownClubId: null,
                      query: _query,
                      onQuery: _setQuery),
                ),
              ),
            ],
          );
        },
      );
    } else if (user.clubId == null) {
      body = const EmptyView(
          title: 'No club assigned',
          message: 'Your account is not linked to a club.');
    } else {
      body = AsyncBody(
        value: ref.watch(clubRosterProvider(user.clubId!)),
        onRetry: () => ref.invalidate(clubRosterProvider(user.clubId!)),
        data: (roster) => roster == null
            ? const EmptyView(
                title: 'No roster found',
                message:
                    'Your club is not registered in any league roster you can access.',
                icon: Icons.groups_outlined,
              )
            : _RosterBody(
                roster: roster,
                ownClubId: user.clubId,
                query: _query,
                onQuery: _setQuery),
      );
    }

    return AppScaffold(title: 'Roster management', body: body);
  }

  void _setQuery(String q) => setState(() => _query = q);
}

class _RosterBody extends ConsumerWidget {
  const _RosterBody(
      {required this.roster,
      required this.ownClubId,
      required this.query,
      required this.onQuery});

  final Cached<RosterResponse> roster;
  final String? ownClubId;
  final String query;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = roster.data;
    final own = ownClubId == null
        ? r.squads
        : r.squads.where((s) => s.clubId == ownClubId).toList();
    final others = ownClubId == null
        ? const <Squad>[]
        : r.squads.where((s) => s.clubId != ownClubId).toList();
    final q = query.toLowerCase();
    bool match(SquadPlayer p) =>
        q.isEmpty ||
        p.name.toLowerCase().contains(q) ||
        p.position.toLowerCase().contains(q) ||
        p.playerId.toLowerCase().contains(q);
    final queued = (ref.watch(_queuedTransfersProvider).valueOrNull ??
            const <PendingAction>[])
        .where((a) => a.payload['league_id'] == r.leagueId)
        .toList();

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(rosterProvider(r.leagueId));
        try {
          await ref.read(rosterProvider(r.leagueId).future);
        } catch (_) {}
      },
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (roster.fromCache) ...[
            CachedBanner(cachedAt: roster.cachedAt),
            const SizedBox(height: AppSpacing.md)
          ],
          _LeagueRules(roster: r),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: () => context.push(
                '/roster/transfer?league=${Uri.encodeComponent(r.leagueId)}'),
            icon: const Icon(Icons.swap_horiz),
            label: const Text('New transfer, loan or release'),
          ),
          if (queued.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            SectionCard(
              title: 'Waiting to sync (${queued.length})',
              icon: Icons.schedule,
              trailing: TextButton(
                  onPressed: () => context.push('/sync'),
                  child: const Text('Open')),
              child: Column(
                children: [
                  for (final a in queued)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                          a.state == PendingState.rejected
                              ? Icons.error_outline
                              : Icons.cloud_upload_outlined,
                          color: AppColors.warning),
                      title: Text(a.label),
                      subtitle: Text(a.state == PendingState.rejected
                          ? 'Rejected — see Sync status'
                          : 'Saved on device'),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          TextField(
            decoration: const InputDecoration(
                hintText: 'Search players or positions',
                prefixIcon: Icon(Icons.search),
                isDense: true),
            onChanged: onQuery,
          ),
          const SizedBox(height: AppSpacing.md),
          for (final squad in own) ...[
            _SquadCard(
                squad: squad, roster: r, filter: match, manageable: true),
            const SizedBox(height: AppSpacing.md),
          ],
          if (others.isNotEmpty) ...[
            Text('Other squads in this league',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            for (final squad in others)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: Text(squad.name),
                  subtitle: Text(
                      '${squad.players.length} / ${r.maxSquadSize} players'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

final _queuedTransfersProvider =
    FutureProvider.autoDispose<List<PendingAction>>((ref) async {
  // Re-run whenever the queue changes size.
  ref.watch(syncControllerProvider.select((s) => s.pending + s.rejected));
  final all = await ref.watch(actionQueueProvider).all();
  return all.where((a) => a.type == PendingAction.rosterTransfer).toList();
});

class _LeagueRules extends StatelessWidget {
  const _LeagueRules({required this.roster});
  final RosterResponse roster;

  @override
  Widget build(BuildContext context) {
    final w = roster.transferWindow;
    final today = isoDate(DateTime.now());
    final open = w.contains(today);
    return SectionCard(
      title: 'League ${roster.leagueId}',
      icon: Icons.rule,
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          LabelBadge(
            icon: open ? Icons.lock_open : Icons.lock_outline,
            text:
                'Window ${formatDate(w.open)} – ${formatDate(w.close)} (${open ? 'open' : 'closed today'})',
            color: open ? AppColors.success : AppColors.danger,
          ),
          LabelBadge(
              icon: Icons.groups,
              text: 'Max ${roster.maxSquadSize} per squad',
              color: AppColors.navySoft),
          for (final e in roster.requiredPositions.entries)
            LabelBadge(
                icon: Icons.sports,
                text: 'Min ${e.value} × ${e.key.toUpperCase()}',
                color: AppColors.info),
        ],
      ),
    );
  }
}

class _SquadCard extends StatelessWidget {
  const _SquadCard(
      {required this.squad,
      required this.roster,
      required this.filter,
      required this.manageable});

  final Squad squad;
  final RosterResponse roster;
  final bool Function(SquadPlayer) filter;
  final bool manageable;

  @override
  Widget build(BuildContext context) {
    final players = squad.players.where(filter).toList();
    return SectionCard(
      title: squad.name,
      icon: Icons.shield,
      trailing: Text('${squad.players.length}/${roster.maxSquadSize}',
          style: const TextStyle(fontWeight: FontWeight.w700)),
      child: players.isEmpty
          ? const Text('No players match.')
          : Column(
              children: [
                for (final p in players)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: TeamAvatar(name: p.name, size: 36),
                    title: Text(p.name),
                    subtitle: Text(
                        '${p.position.toUpperCase()} · ${humanize(p.role)}'),
                    trailing: p.onLoan
                        ? const LabelBadge(
                            icon: Icons.swap_horiz,
                            text: 'On loan',
                            color: AppColors.warning)
                        : const Icon(Icons.more_vert),
                    onTap: () => _showPlayerActions(context, p),
                  ),
              ],
            ),
    );
  }

  void _showPlayerActions(BuildContext context, SquadPlayer p) {
    String route(String type) =>
        '/roster/transfer?league=${Uri.encodeComponent(roster.leagueId)}'
        '&player=${Uri.encodeComponent(p.playerId)}&type=$type';
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
                title: Text(p.name, style: Theme.of(ctx).textTheme.titleMedium),
                subtitle: Text(p.playerId)),
            ListTile(
              leading: const Icon(Icons.person_search),
              title: const Text('Profile & history'),
              onTap: () {
                Navigator.pop(ctx);
                context.push('/player/${Uri.encodeComponent(p.playerId)}');
              },
            ),
            if (manageable) ...[
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('Transfer'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push(route('transfer'));
                },
              ),
              ListTile(
                leading: const Icon(Icons.schedule_send),
                title: const Text('Loan'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push(route('loan'));
                },
              ),
              ListTile(
                leading: const Icon(Icons.logout, color: AppColors.danger),
                title: const Text('Release'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push(route('release'));
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
