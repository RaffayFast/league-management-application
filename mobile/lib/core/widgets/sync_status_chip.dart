import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../sync/sync_controller.dart';
import '../theme/app_theme.dart';

/// Always-visible connection + queue indicator (icon + text, never colour alone).
/// Lives in every app bar; tapping opens the Sync Status screen.
class SyncStatusChip extends ConsumerWidget {
  const SyncStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncControllerProvider);

    final (IconData icon, String text, Color bg, Color fg) = switch (s) {
      SyncState(syncing: true) => (
          Icons.sync,
          'Syncing',
          AppColors.lime,
          AppColors.navy
        ),
      SyncState(hasNetwork: false) => (
          Icons.cloud_off,
          'Offline',
          const Color(0xFFFFE3E0),
          AppColors.danger
        ),
      SyncState(serverReachable: false) => (
          Icons.dns_outlined,
          'No server',
          const Color(0xFFFFF1D6),
          AppColors.warning
        ),
      _ => (
          Icons.cloud_done_outlined,
          'Online',
          const Color(0xFFE5F6E8),
          AppColors.success
        ),
    };
    final waiting = s.pending + s.rejected;
    final label = waiting > 0 ? '$text · $waiting pending' : text;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Semantics(
        button: true,
        label: 'Connection: $label. Open sync status.',
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => context.push('/sync'),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                  color: bg, borderRadius: BorderRadius.circular(20)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: fg),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          color: fg,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
