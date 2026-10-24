import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/models/store_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/state_views.dart';
import 'data/store_repository.dart';

final _receiptProvider =
    FutureProvider.autoDispose.family<OrderResponse?, String>(
  (ref, orderId) => ref.watch(storeRepositoryProvider).receipt(orderId),
);

/// Shows a receipt stored from a successful checkout response. Receipts are
/// never created locally — only server orders with status "paid" reach here.
class ReceiptScreen extends ConsumerStatefulWidget {
  const ReceiptScreen({super.key, required this.orderId});
  final String orderId;

  @override
  ConsumerState<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends ConsumerState<ReceiptScreen> {
  bool _saving = false;
  String? _savedPath;

  Future<void> _openPdf(OrderResponse order) async {
    setState(() => _saving = true);
    try {
      final file = await ref.read(storeRepositoryProvider).savePdf(order);
      setState(() => _savedPath = file.path);
      final result = await OpenFilex.open(file.path, type: 'application/pdf');
      if (!mounted) return;
      if (result.type != ResultType.done) {
        showSnack(context,
            'Saved the PDF, but no app could open it. Install a PDF viewer to view it.',
            error: true);
      }
    } catch (_) {
      if (mounted) {
        showSnack(context, 'Could not save the receipt PDF.', error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_receiptProvider(widget.orderId));
    final variants = <String, String>{};
    for (final p
        in ref.watch(productsProvider).valueOrNull?.data ?? const <Product>[]) {
      for (final v in p.variants) {
        variants[v.variantId] = '${p.name} — ${v.label}';
      }
    }

    return AppScaffold(
      title: 'Receipt',
      body: AsyncBody(
        value: async,
        onRetry: () => ref.invalidate(_receiptProvider(widget.orderId)),
        data: (order) {
          if (order == null) {
            return const EmptyView(
                title: 'Receipt not found on this device',
                icon: Icons.receipt_long_outlined);
          }
          final r = order.receipt.payload;
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.xl),
                decoration: BoxDecoration(
                    color: AppColors.navy,
                    borderRadius: BorderRadius.circular(AppSpacing.radius)),
                child: Column(
                  children: [
                    const Icon(Icons.check_circle,
                        color: AppColors.lime, size: 48),
                    const SizedBox(height: AppSpacing.sm),
                    Text('Payment ${order.payment.state}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: AppSpacing.xs),
                    Text(formatMoney(order.totalMinor, order.currency),
                        style: const TextStyle(
                            color: AppColors.lime,
                            fontSize: 28,
                            fontWeight: FontWeight.w800)),
                    Text(formatDateTime(r.paidAt),
                        style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              SectionCard(
                title: 'Order ${order.orderId}',
                icon: Icons.receipt_long,
                trailing: LabelBadge(
                    icon: Icons.verified,
                    text: humanize(order.status),
                    color: AppColors.success),
                child: Column(
                  children: [
                    _Row('Customer', r.customerId),
                    _Row('Authorization', order.payment.authorizationId),
                    _Row('Capture', order.payment.captureId),
                    const Divider(),
                    for (final i in order.items)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                  '${variants[i.variantId] ?? i.variantId}\n'
                                  '${i.quantity} × ${formatMoney(i.unitPriceMinor, order.currency)}'),
                            ),
                            Text(formatMoney(i.lineTotalMinor, order.currency),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    const Divider(),
                    _Row('Subtotal',
                        formatMoney(order.subtotalMinor, order.currency)),
                    _Row(
                        'Discount',
                        order.discountMinor == 0
                            ? '—'
                            : '−${formatMoney(order.discountMinor, order.currency)}'),
                    _Row('Total paid',
                        formatMoney(order.totalMinor, order.currency),
                        bold: true),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              SectionCard(
                title: 'Signature',
                icon: Icons.fingerprint,
                child: SelectableText(
                  order.receipt.signature,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: AppColors.textMuted),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: _saving || order.receipt.pdfBase64.isEmpty
                    ? null
                    : () => _openPdf(order),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.picture_as_pdf),
                label: const Text('Save & open PDF receipt'),
              ),
              if (_savedPath != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text('Saved to $_savedPath',
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12)),
                ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton(
                  onPressed: () => context.go('/store'),
                  child: const Text('Back to store')),
            ],
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.bold = false});
  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: const TextStyle(color: AppColors.textMuted))),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                      fontSize: bold ? 16 : null)),
            ),
          ],
        ),
      );
}
