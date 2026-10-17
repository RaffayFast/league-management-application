import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/state_views.dart';
import '../auth/auth_controller.dart';
import 'data/store_repository.dart';

final _receiptsProvider = FutureProvider.autoDispose<List<StoredReceipt>>((ref) {
  final userId = ref.watch(authControllerProvider.select((a) => a.user?.userId));
  if (userId == null) return Future.value(const []);
  return ref.watch(storeRepositoryProvider).receipts(userId);
});

class ReceiptsScreen extends ConsumerWidget {
  const ReceiptsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppScaffold(
      title: 'My receipts',
      body: AsyncBody(
        value: ref.watch(_receiptsProvider),
        onRetry: () => ref.invalidate(_receiptsProvider),
        data: (receipts) => receipts.isEmpty
            ? const EmptyView(
                title: 'No receipts yet',
                message: 'Receipts from purchases made on this device appear here.',
                icon: Icons.receipt_long_outlined,
              )
            : ListView.separated(
                padding: const EdgeInsets.all(AppSpacing.lg),
                itemCount: receipts.length,
                separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                itemBuilder: (_, i) {
                  final o = receipts[i].order;
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.receipt_long),
                      title: Text(formatMoney(o.totalMinor, o.currency), style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text('${o.orderId}\n${formatDateTime(o.receipt.payload.paidAt)}'),
                      isThreeLine: true,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/receipt/${Uri.encodeComponent(o.orderId)}'),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
