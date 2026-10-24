import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/auth_models.dart';
import '../../core/models/club_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/state_views.dart';
import '../auth/auth_controller.dart';
import '../auth/permissions.dart';
import '../roster/data/roster_repository.dart';
import '../roster/widgets/history_list.dart';

/// Player information assembled from the league roster (B7) and the immutable
/// roster history (A9 history). There is no dedicated player-profile route.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key, required this.playerId});
  final String playerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(rosterHistoryProvider(playerId));
    final user = ref.watch(authControllerProvider).user;

    return AppScaffold(
      title: 'Player',
      body: AsyncBody(
        value: historyAsync,
        onRetry: () => ref.invalidate(rosterHistoryProvider(playerId)),
        data: (cached) {
          final history = cached.data;
          final roster =
              ref.watch(rosterProvider(history.leagueId)).valueOrNull?.data;
          SquadPlayer? player;
          Squad? squad;
          for (final s in roster?.squads ?? const <Squad>[]) {
            for (final p in s.players) {
              if (p.playerId == playerId) {
                player = p;
                squad = s;
              }
            }
          }
          String squadName(String? id) =>
              roster?.squad(id)?.name ?? id ?? 'No squad';
          final canManage = Permissions.canManageRoster(user) &&
              (user!.role == UserRole.superAdmin ||
                  squad?.clubId == user.clubId);

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              if (cached.fromCache) ...[
                CachedBanner(cachedAt: cached.cachedAt),
                const SizedBox(height: AppSpacing.md)
              ],
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Row(
                    children: [
                      TeamAvatar(name: player?.name ?? playerId, size: 56),
                      const SizedBox(width: AppSpacing.lg),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(player?.name ?? playerId,
                                style: Theme.of(context).textTheme.titleLarge),
                            if (player != null)
                              Text(
                                  '${player.position.toUpperCase()} · ${humanize(player.role)}',
                                  style: const TextStyle(
                                      color: AppColors.textMuted)),
                            const SizedBox(height: AppSpacing.sm),
                            Wrap(
                              spacing: AppSpacing.sm,
                              runSpacing: AppSpacing.xs,
                              children: [
                                LabelBadge(
                                    icon: Icons.shield_outlined,
                                    text: squadName(history.currentSquadId),
                                    color: AppColors.navySoft),
                                if (history.parentSquadId != null)
                                  LabelBadge(
                                    icon: Icons.swap_horiz,
                                    text:
                                        'On loan from ${squadName(history.parentSquadId)}',
                                    color: AppColors.warning,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (squad != null) ...[
                const SizedBox(height: AppSpacing.md),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.shield),
                    title: Text(squad.name),
                    subtitle: const Text('Open club profile'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context
                        .push('/club/${Uri.encodeComponent(squad!.clubId)}'),
                  ),
                ),
              ],
              if (canManage && roster != null) ...[
                const SizedBox(height: AppSpacing.md),
                SectionCard(
                  title: 'Roster actions',
                  icon: Icons.manage_accounts_outlined,
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      for (final (type, icon, label) in [
                        ('transfer', Icons.swap_horiz, 'Transfer'),
                        ('loan', Icons.schedule_send, 'Loan'),
                        ('release', Icons.logout, 'Release'),
                      ])
                        OutlinedButton.icon(
                          onPressed: () => context.push(
                            '/roster/transfer?league=${Uri.encodeComponent(roster.leagueId)}'
                            '&player=${Uri.encodeComponent(playerId)}&type=$type',
                          ),
                          icon: Icon(icon),
                          label: Text(label),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              SectionCard(
                title: 'Registration history',
                icon: Icons.history,
                child: HistoryList(history: history, squadName: squadName),
              ),
            ],
          );
        },
      ),
    );
  }
}
