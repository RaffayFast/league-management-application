import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/error_messages.dart';
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

final _queueProvider = FutureProvider.autoDispose<List<PendingAction>>((ref) {
  ref.watch(syncControllerProvider.select((s) => (s.pending, s.rejected, s.lastSyncAt)));
  return ref.watch(actionQueueProvider).all();
});

final _historyProvider = FutureProvider.autoDispose<List<SyncHistoryEntry>>((ref) {
  ref.watch(syncControllerProvider.select((s) => s.lastSyncAt));
  return ref.watch(actionQueueProvider).history();
});

/// Plain-language meaning of a server resolution (api_contract.md A12).
String explainResolution(SyncHistoryEntry e) {
  switch (e.status) {
    case 'applied':
      return e.resolution == 'rebased_append'
          ? 'Applied. The match had changed since you went offline, so it was added on top of the newer version'
              '${e.serverVersion != null ? ' (now v${e.serverVersion})' : ''}.'
          : 'Applied${e.serverVersion != null ? ' (match now v${e.serverVersion})' : ''}.';
    case 'duplicate':
      return 'Already on the server — nothing was applied twice.';
    case 'rejected':
      return 'Not applied: ${describeErrorCode(e.errorCode, fallback: 'the server rejected it.')}';
    default:
      return humanize(e.status);
  }
}

class SyncStatusScreen extends ConsumerWidget {
  const SyncStatusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncControllerProvider);
    final me = ref.watch(authControllerProvider).user?.userId;
    final controller = ref.read(syncControllerProvider.notifier);
    final queue = ref.watch(_queueProvider);
    final history = ref.watch(_historyProvider);

    final (IconData icon, String title, String detail) = !s.hasNetwork
        ? (Icons.cloud_off, 'Offline', 'No network. Eligible actions are saved on this device.')
        : !s.serverReachable
            ? (Icons.dns_outlined, 'Server unreachable', 'The network is up but the server is not answering. Check Settings.')
            : (Icons.cloud_done_outlined, 'Online', 'Connected to the server.');

    return AppScaffold(
      title: 'Sync status',
      body: RefreshIndicator(
        onRefresh: () async {
          await controller.refreshCounts();
          ref.invalidate(_queueProvider);
          ref.invalidate(_historyProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(icon, size: 32, color: AppColors.navy),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: Theme.of(context).textTheme.titleLarge),
                              Text(detail, style: const TextStyle(color: AppColors.textMuted)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        LabelBadge(icon: Icons.schedule, text: '${s.pending} pending', color: AppColors.info),
                        if (s.rejected > 0)
                          LabelBadge(icon: Icons.error_outline, text: '${s.rejected} need attention', color: AppColors.danger),
                        if (s.lastSyncAt != null)
                          LabelBadge(
                            icon: Icons.history,
                            text: 'Last sync ${relativeAge(s.lastSyncAt!)}',
                            color: AppColors.navySoft,
                          ),
                      ],
                    ),
                    if (s.lastMessage != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(s.lastMessage!, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    FilledButton.icon(
                      onPressed: s.syncing || !s.hasNetwork || s.pending == 0
                          ? null
                          : () async {
                              final report = await controller.syncNow();
                              if (context.mounted && report != null && report.transportError != null) {
                                showSnack(context, friendlyError(report.transportError!), error: true);
                              }
                            },
                      icon: s.syncing
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.sync),
                      label: Text(s.syncing ? 'Syncing…' : 'Sync now'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Queued on this device', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            queue.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text(friendlyError(e)),
              data: (items) => items.isEmpty
                  ? const Card(child: ListTile(leading: Icon(Icons.done_all), title: Text('Nothing waiting to sync.')))
                  : Column(
                      children: [
                        for (final a in items) ...[
                          _QueuedTile(action: a, mine: a.owner == me, onRetry: controller.retry, onDiscard: controller.discard),
                          const SizedBox(height: AppSpacing.sm),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(child: Text('Recent results', style: Theme.of(context).textTheme.titleMedium)),
                TextButton(
                  onPressed: () async {
                    await ref.read(actionQueueProvider).clearHistory();
                    ref.invalidate(_historyProvider);
                  },
                  child: const Text('Clear'),
                ),
              ],
            ),
            history.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text(friendlyError(e)),
              data: (items) => items.isEmpty
                  ? const EmptyView(title: 'No sync results yet', icon: Icons.history)
                  : Column(
                      children: [
                        for (final e in items)
                          Card(
                            child: ListTile(
                              leading: Icon(
                                switch (e.status) {
                                  'applied' => Icons.check_circle,
                                  'duplicate' => Icons.copy_all,
                                  _ => Icons.cancel,
                                },
                                color: e.status == 'rejected' ? AppColors.danger : AppColors.success,
                              ),
                              title: Text(e.label),
                              subtitle: Text('${explainResolution(e)}\n${formatDateTime(e.syncedAt)}'),
                              isThreeLine: true,
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueuedTile extends StatelessWidget {
  const _QueuedTile({required this.action, required this.mine, required this.onRetry, required this.onDiscard});

  final PendingAction action;
  final bool mine;
  final Future<void> Function(String) onRetry;
  final Future<void> Function(String) onDiscard;

  @override
  Widget build(BuildContext context) {
    final rejected = action.state == PendingState.rejected;
    final kind = action.type == PendingAction.scoreEvent ? 'Score event' : 'Roster move';
    final target = action.type == PendingAction.scoreEvent ? 'Match ${action.target}' : 'Player ${action.target}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(action.type == PendingAction.scoreEvent ? Icons.scoreboard_outlined : Icons.swap_horiz),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(action.label, style: const TextStyle(fontWeight: FontWeight.w700))),
                rejected
                    ? const LabelBadge(icon: Icons.error_outline, text: 'Rejected', color: AppColors.danger)
                    : const LabelBadge(icon: Icons.schedule, text: 'Pending', color: AppColors.warning),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text('$kind · $target · queued ${formatDateTime(action.queuedAt)}'
                '${action.baseVersion != null ? ' · based on v${action.baseVersion}' : ''}',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
            if (!mine)
              const Text('Queued by another account — sign in as that user to send it.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
            if (action.lastError != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                rejected
                    ? describeErrorCode(action.lastError)
                    : 'Last attempt failed: ${describeErrorCode(action.lastError)} It will be retried.',
                style: TextStyle(color: rejected ? AppColors.danger : AppColors.warning, fontWeight: FontWeight.w600),
              ),
              Text('Code: ${action.lastError}', style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
            ],
            if (rejected && mine)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () async {
                      final ok = await confirmAction(
                        context,
                        title: 'Discard action?',
                        message: 'The server rejected "${action.label}". Discarding removes it from this device.',
                        confirmLabel: 'Discard',
                        destructive: true,
                      );
                      if (ok) await onDiscard(action.actionId);
                    },
                    child: const Text('Discard'),
                  ),
                  FilledButton.tonal(onPressed: () => onRetry(action.actionId), child: const Text('Retry')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
