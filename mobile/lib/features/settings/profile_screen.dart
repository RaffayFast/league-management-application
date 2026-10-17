import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/models/auth_models.dart';
import '../../core/providers.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/dialogs.dart';
import '../auth/auth_controller.dart';
import '../auth/permissions.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authControllerProvider).session;
    final sync = ref.watch(syncControllerProvider);
    final baseUrl = ref.watch(baseUrlProvider);
    if (session == null) return const SizedBox.shrink();
    final user = session.user;

    return AppScaffold(
      title: 'Profile',
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                children: [
                  TeamAvatar(name: user.name, size: 56),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.name, style: Theme.of(context).textTheme.titleLarge),
                        Text(user.email, style: const TextStyle(color: AppColors.textMuted)),
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.xs,
                          children: [
                            LabelBadge(icon: Icons.badge_outlined, text: roleLabel(user.role), color: AppColors.navySoft),
                            if (session.tenant != null)
                              LabelBadge(icon: Icons.apartment, text: session.tenant!.name, color: AppColors.info),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Card(
            child: Column(
              children: [
                if (user.leagueId != null)
                  ListTile(leading: const Icon(Icons.emoji_events_outlined), title: const Text('League'), subtitle: Text(user.leagueId!)),
                if (user.clubId != null)
                  ListTile(
                    leading: const Icon(Icons.shield_outlined),
                    title: const Text('Club'),
                    subtitle: Text(user.clubId!),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/club/${Uri.encodeComponent(user.clubId!)}'),
                  ),
                if (user.playerId != null)
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: const Text('My player profile'),
                    subtitle: Text(user.playerId!),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/player/${Uri.encodeComponent(user.playerId!)}'),
                  ),
                if (Permissions.canManageRoster(user))
                  ListTile(
                    leading: const Icon(Icons.groups_outlined),
                    title: const Text('Roster management'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/roster'),
                  ),
                ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('My receipts'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/receipts'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(sync.online ? Icons.cloud_done_outlined : Icons.cloud_off),
                  title: Text(sync.online ? 'Online' : (sync.hasNetwork ? 'Server unreachable' : 'Offline')),
                  subtitle: Text('${sync.pending} pending · ${sync.rejected} need attention'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/sync'),
                ),
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('Sync now'),
                  enabled: sync.hasNetwork && !sync.syncing,
                  onTap: () async {
                    await ref.read(syncControllerProvider.notifier).syncNow();
                    final msg = ref.read(syncControllerProvider).lastMessage;
                    if (context.mounted && msg != null) showSnack(context, msg);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Server address'),
                  subtitle: Text(baseUrl),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/settings'),
                ),
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('App version'),
                  subtitle: Text('${AppConfig.appName} ${AppConfig.appVersion}'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () async {
              final pending = sync.pending + sync.rejected;
              final ok = await confirmAction(
                context,
                title: 'Sign out?',
                message: pending > 0
                    ? 'You have $pending action(s) waiting to sync. They stay on this device and will be sent next time you sign in.'
                    : 'You can sign back in at any time.',
                confirmLabel: 'Sign out',
              );
              if (ok) await ref.read(authControllerProvider.notifier).logout();
            },
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
