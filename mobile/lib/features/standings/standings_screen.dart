import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/league_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/state_views.dart';
import '../fixtures/data/league_repository.dart';
import '../fixtures/widgets/league_picker.dart';

/// Renders the server's Standings object as-is: order, ranks and qualification
/// status all come from the backend (A8); nothing is recomputed here.
class StandingsScreen extends ConsumerStatefulWidget {
  const StandingsScreen({super.key, this.initialLeagueId});
  final String? initialLeagueId;

  @override
  ConsumerState<StandingsScreen> createState() => _StandingsScreenState();
}

class _StandingsScreenState extends ConsumerState<StandingsScreen> {
  String? _leagueId;

  @override
  void initState() {
    super.initState();
    _leagueId = widget.initialLeagueId;
  }

  @override
  void didUpdateWidget(covariant StandingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialLeagueId != null && widget.initialLeagueId != oldWidget.initialLeagueId) {
      setState(() => _leagueId = widget.initialLeagueId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final leaguesAsync = ref.watch(leaguesProvider);
    return AppScaffold(
      title: 'Standings',
      body: AsyncBody(
        value: leaguesAsync,
        onRetry: () => ref.invalidate(leaguesProvider),
        data: (leagues) {
          if (leagues.data.isEmpty) {
            return const EmptyView(title: 'No leagues yet', icon: Icons.leaderboard_outlined);
          }
          final ids = leagues.data.map((l) => l.leagueId).toSet();
          final leagueId = _leagueId != null && ids.contains(_leagueId) ? _leagueId! : leagues.data.first.leagueId;
          final league = leagues.data.firstWhere((l) => l.leagueId == leagueId);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
                child: LeaguePicker(
                  leagues: leagues.data,
                  selectedLeagueId: leagueId,
                  onLeagueChanged: (id) => setState(() => _leagueId = id),
                ),
              ),
              Expanded(child: _StandingsBody(league: league)),
            ],
          );
        },
      ),
    );
  }
}

class _StandingsBody extends ConsumerWidget {
  const _StandingsBody({required this.league});
  final League league;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(standingsProvider(league.leagueId));
    return AsyncBody(
      value: async,
      onRetry: () => ref.invalidate(standingsProvider(league.leagueId)),
      data: (res) {
        final s = res.data;
        // Team ids are club ids for app leagues; map to names via cached fixtures when known.
        final names = <String, String>{};
        final fixtures = ref.watch(fixturesProvider(league.leagueId)).valueOrNull?.data.fixtures ?? const [];
        for (final f in fixtures) {
          if (f.homeTeamId != null && f.homeName != null) names[f.homeTeamId!] = f.homeName!;
          if (f.awayTeamId != null && f.awayName != null) names[f.awayTeamId!] = f.awayName!;
        }

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(standingsProvider(league.leagueId));
            try {
              await ref.read(standingsProvider(league.leagueId).future);
            } catch (_) {}
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              if (res.fromCache) ...[CachedBanner(cachedAt: res.cachedAt), const SizedBox(height: AppSpacing.md)],
              Text(league.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${humanize(s.sportId)} · Top ${s.qualificationSpots} qualify',
                style: const TextStyle(color: AppColors.textMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              if (s.table.isEmpty)
                const SizedBox(height: 280, child: EmptyView(title: 'No standings yet', message: 'Standings appear once teams are registered.'))
              else
                LayoutBuilder(
                  builder: (context, c) => c.maxWidth >= 600
                      ? _WideTable(rows: s.table, names: names, spots: s.qualificationSpots)
                      : Column(
                          children: [
                            for (final r in s.table) ...[
                              _RowCard(row: r, name: names[r.teamId] ?? r.teamId, qualifies: r.rank <= s.qualificationSpots),
                              const SizedBox(height: AppSpacing.sm),
                            ],
                          ],
                        ),
                ),
              const SizedBox(height: AppSpacing.md),
              const _Legend(),
            ],
          ),
        );
      },
    );
  }
}

class _RowCard extends StatelessWidget {
  const _RowCard({required this.row, required this.name, required this.qualifies});
  final StandingRow row;
  final String name;
  final bool qualifies;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget stat(String label, Object value) => Column(
          children: [
            Text('$value', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: AppColors.textMuted)),
          ],
        );

    return Semantics(
      label: 'Rank ${row.rank}, $name, ${row.points} points, played ${row.played}, '
          'won ${row.won}, drawn ${row.drawn}, lost ${row.lost}, goal difference ${row.diff}. '
          '${row.statusRaw.replaceAll('_', ' ')}.',
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          side: BorderSide(color: qualifies ? AppColors.limeDeep : AppColors.border, width: qualifies ? 1.5 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          onTap: () => context.push('/club/${Uri.encodeComponent(row.teamId)}'),
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 32,
                        child: Text('${row.rank}', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                      ),
                      TeamAvatar(name: name, size: 32),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: Text(name, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis)),
                      Text('${row.points} pts', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      stat('P', row.played),
                      stat('W', row.won),
                      stat('D', row.drawn),
                      stat('L', row.lost),
                      stat('F', row.scored),
                      stat('A', row.conceded),
                      stat('Diff', row.diff > 0 ? '+${row.diff}' : row.diff),
                      stat('FP', row.fairPlay),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      QualificationBadge(status: row.status),
                      if (row.resolvedBy != null) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Flexible(
                          child: Text(
                            'Tie broken by ${humanize(row.resolvedBy!)}',
                            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WideTable extends StatelessWidget {
  const _WideTable({required this.rows, required this.names, required this.spots});
  final List<StandingRow> rows;
  final Map<String, String> names;
  final int spots;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          showCheckboxColumn: false,
          columns: const [
            DataColumn(label: Text('#'), numeric: true),
            DataColumn(label: Text('Team')),
            DataColumn(label: Text('P'), numeric: true),
            DataColumn(label: Text('W'), numeric: true),
            DataColumn(label: Text('D'), numeric: true),
            DataColumn(label: Text('L'), numeric: true),
            DataColumn(label: Text('F'), numeric: true),
            DataColumn(label: Text('A'), numeric: true),
            DataColumn(label: Text('Diff'), numeric: true),
            DataColumn(label: Text('FP'), numeric: true),
            DataColumn(label: Text('Pts'), numeric: true),
            DataColumn(label: Text('Status')),
          ],
          rows: [
            for (final r in rows)
              DataRow(
                onSelectChanged: (_) => context.push('/club/${Uri.encodeComponent(r.teamId)}'),
                cells: [
                  DataCell(Text('${r.rank}${r.rank <= spots ? ' ✓' : ''}')),
                  DataCell(Text(names[r.teamId] ?? r.teamId)),
                  DataCell(Text('${r.played}')),
                  DataCell(Text('${r.won}')),
                  DataCell(Text('${r.drawn}')),
                  DataCell(Text('${r.lost}')),
                  DataCell(Text('${r.scored}')),
                  DataCell(Text('${r.conceded}')),
                  DataCell(Text(r.diff > 0 ? '+${r.diff}' : '${r.diff}')),
                  DataCell(Text('${r.fairPlay}')),
                  DataCell(Text('${r.points}', style: const TextStyle(fontWeight: FontWeight.w800))),
                  DataCell(QualificationBadge(status: r.status)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'P played · W won · D drawn · L lost · F scored · A conceded · FP fair play. '
      'Ranking and qualification status come from the league server.',
      style: TextStyle(color: AppColors.textMuted, fontSize: 12),
    );
  }
}
