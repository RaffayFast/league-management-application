import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/club_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/state_views.dart';
import '../auth/auth_controller.dart';
import '../auth/permissions.dart';
import '../fixtures/data/league_repository.dart';
import '../fixtures/widgets/fixture_card.dart';
import 'data/club_repository.dart';

class ClubScreen extends ConsumerWidget {
  const ClubScreen({super.key, required this.clubId});
  final String clubId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(clubProvider(clubId));
    final user = ref.watch(authControllerProvider).user;

    return AppScaffold(
      title: 'Club',
      body: AsyncBody(
        value: async,
        onRetry: () => ref.invalidate(clubProvider(clubId)),
        data: (cached) {
          final club = cached.data;
          final fixtures = (ref.watch(allFixturesProvider).valueOrNull ??
                  const [])
              .where((f) => f.homeTeamId == clubId || f.awayTeamId == clubId)
              .toList();
          final canManage = Permissions.canManageClub(user, clubId);

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(clubProvider(clubId));
              try {
                await ref.read(clubProvider(clubId).future);
              } catch (_) {}
            },
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                if (cached.fromCache) ...[
                  CachedBanner(cachedAt: cached.cachedAt),
                  const SizedBox(height: AppSpacing.md)
                ],
                _Header(club: club),
                if (canManage) ...[
                  const SizedBox(height: AppSpacing.md),
                  FilledButton.icon(
                    onPressed: () => context.push('/roster'),
                    icon: const Icon(Icons.groups),
                    label: const Text('Manage roster'),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                if (club.homeVenue != null || club.social.isNotEmpty)
                  _VenueSocial(club: club),
                const SizedBox(height: AppSpacing.md),
                SectionCard(
                  title: 'Roster (${club.roster.length})',
                  icon: Icons.groups_outlined,
                  child: club.roster.isEmpty
                      ? const Text('No registered players.')
                      : Column(
                          children: [
                            for (final p in club.roster)
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
                                    : const Icon(Icons.chevron_right),
                                onTap: () => context.push(
                                    '/player/${Uri.encodeComponent(p.playerId)}'),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: AppSpacing.md),
                SectionCard(
                  title: 'Staff',
                  icon: Icons.badge_outlined,
                  child: club.staff.isEmpty
                      ? const Text('No staff listed.')
                      : Column(
                          children: [
                            for (final s in club.staff)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.person_outline),
                                title: Text(s.name),
                                subtitle: Text(humanize(s.role)),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: AppSpacing.md),
                if (club.seasons.isNotEmpty) ...[
                  SectionCard(
                    title: 'Season history',
                    icon: Icons.history_edu,
                    child: Column(
                      children: [
                        for (final s in club.seasons)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(s.season),
                            subtitle: Text(
                                'Played ${s.played} · Won ${s.won} · Drawn ${s.drawn} · Lost ${s.lost}'),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                SectionCard(
                  title: 'Fixtures & results',
                  icon: Icons.event_note_outlined,
                  child: fixtures.isEmpty
                      ? const Text(
                          'No fixtures found for this club in your leagues.')
                      : Column(
                          children: [
                            for (final f in fixtures) ...[
                              FixtureCard(fixture: f),
                              const SizedBox(height: AppSpacing.sm),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.club});
  final Club club;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
          color: AppColors.navy,
          borderRadius: BorderRadius.circular(AppSpacing.radius)),
      child: Row(
        children: [
          TeamAvatar(name: club.name, size: 64),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(club.name,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: Colors.white, fontWeight: FontWeight.w800)),
                const SizedBox(height: AppSpacing.xs),
                Text('${club.clubId} · ${club.tenantId}',
                    style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VenueSocial extends StatelessWidget {
  const _VenueSocial({required this.club});
  final Club club;

  @override
  Widget build(BuildContext context) {
    final venue = club.homeVenue;
    return SectionCard(
      title: 'Home & social',
      icon: Icons.stadium_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (venue != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.place_outlined),
              title: Text(venue.name),
              subtitle: venue.lat != null && venue.lng != null
                  ? Text(
                      '${venue.lat!.toStringAsFixed(4)}, ${venue.lng!.toStringAsFixed(4)}')
                  : null,
            ),
          if (club.social.isNotEmpty)
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final e in club.social.entries)
                  Chip(
                      avatar: const Icon(Icons.alternate_email, size: 16),
                      label: Text('${humanize(e.key)}: ${e.value}')),
              ],
            ),
        ],
      ),
    );
  }
}
