import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/league_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/state_views.dart';
import '../auth/auth_controller.dart';
import 'data/league_repository.dart';
import 'widgets/fixture_card.dart';
import 'widgets/league_picker.dart';

enum _StatusFilter { all, live, upcoming, completed, other }

class FixturesScreen extends ConsumerStatefulWidget {
  const FixturesScreen({super.key, this.scoringMode = false});

  /// Organizer shortcut: preselect own league and show matches that can be scored.
  final bool scoringMode;

  @override
  ConsumerState<FixturesScreen> createState() => _FixturesScreenState();
}

class _FixturesScreenState extends ConsumerState<FixturesScreen> {
  String? _leagueId;
  String? _sport;
  _StatusFilter _status = _StatusFilter.all;
  String _query = '';

  @override
  void initState() {
    super.initState();
    if (widget.scoringMode) _status = _StatusFilter.live;
  }

  @override
  void didUpdateWidget(covariant FixturesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scoringMode && !oldWidget.scoringMode) {
      setState(() {
        _status = _StatusFilter.live;
        _leagueId = ref.read(authControllerProvider).user?.leagueId ?? _leagueId;
      });
    }
  }

  bool _matches(Fixture f) {
    final statusOk = switch (_status) {
      _StatusFilter.all => true,
      _StatusFilter.live => f.status == MatchStatus.inProgress,
      _StatusFilter.upcoming => f.status == MatchStatus.upcoming,
      _StatusFilter.completed => f.status == MatchStatus.completed,
      _StatusFilter.other => !{MatchStatus.inProgress, MatchStatus.upcoming, MatchStatus.completed}.contains(f.status),
    };
    if (!statusOk) return false;
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return f.homeLabel.toLowerCase().contains(q) || f.awayLabel.toLowerCase().contains(q) || f.matchId.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final leaguesAsync = ref.watch(leaguesProvider);
    final user = ref.watch(authControllerProvider).user;

    return AppScaffold(
      title: widget.scoringMode ? 'Pick a match to score' : 'Fixtures',
      body: AsyncBody(
        value: leaguesAsync,
        onRetry: () => ref.invalidate(leaguesProvider),
        data: (leagues) {
          if (leagues.data.isEmpty) {
            return const EmptyView(title: 'No leagues yet', message: 'Leagues you can access will appear here.', icon: Icons.emoji_events_outlined);
          }
          final ids = leagues.data.map((l) => l.leagueId).toSet();
          final preferred = widget.scoringMode ? user?.leagueId : null;
          final leagueId = (_leagueId != null && ids.contains(_leagueId))
              ? _leagueId!
              : (preferred != null && ids.contains(preferred) ? preferred : leagues.data.first.leagueId);
          final league = leagues.data.firstWhere((l) => l.leagueId == leagueId);

          return Column(
            children: [
              if (leagues.fromCache) CachedBanner(cachedAt: leagues.cachedAt),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
                child: Column(
                  children: [
                    LeaguePicker(
                      leagues: leagues.data,
                      selectedLeagueId: leagueId,
                      selectedSport: _sport,
                      onSportChanged: (s) => setState(() {
                        _sport = s;
                        if (s != null && league.sportId != s) {
                          _leagueId = leagues.data.firstWhere((l) => l.sportId == s).leagueId;
                        }
                      }),
                      onLeagueChanged: (id) => setState(() => _leagueId = id),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      decoration: const InputDecoration(
                        hintText: 'Search team or match',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => _query = v.trim()),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final s in _StatusFilter.values) ...[
                            FilterChip(
                              label: Text(switch (s) {
                                _StatusFilter.all => 'All',
                                _StatusFilter.live => 'Live',
                                _StatusFilter.upcoming => 'Upcoming',
                                _StatusFilter.completed => 'Completed',
                                _StatusFilter.other => 'Postponed / other',
                              }),
                              selected: _status == s,
                              onSelected: (_) => setState(() => _status = s),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _FixtureList(league: league, filter: _matches)),
            ],
          );
        },
      ),
    );
  }
}

class _FixtureList extends ConsumerWidget {
  const _FixtureList({required this.league, required this.filter});
  final League league;
  final bool Function(Fixture) filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(fixturesProvider(league.leagueId));
    Future<void> refresh() async {
      ref.invalidate(fixturesProvider(league.leagueId));
      try {
        await ref.read(fixturesProvider(league.leagueId).future);
      } catch (_) {
        // Error state is rendered by AsyncBody.
      }
    }

    return AsyncBody(
      value: async,
      onRetry: () => ref.invalidate(fixturesProvider(league.leagueId)),
      data: (res) {
        final items = res.data.fixtures.where(filter).toList();
        return RefreshIndicator(
          onRefresh: refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              if (res.fromCache) ...[
                CachedBanner(cachedAt: res.cachedAt),
                const SizedBox(height: AppSpacing.md),
              ],
              if (res.data.fixtures.isEmpty)
                const SizedBox(height: 320, child: EmptyView(title: 'No matches yet', message: 'This league has no fixtures scheduled.', icon: Icons.event_busy))
              else if (items.isEmpty)
                const SizedBox(height: 320, child: EmptyView(title: 'No matches match your filters', icon: Icons.filter_alt_off))
              else
                for (final f in items) ...[
                  FixtureCard(fixture: f),
                  const SizedBox(height: AppSpacing.md),
                ],
            ],
          ),
        );
      },
    );
  }
}
