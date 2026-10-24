import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/store_models.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/error_messages.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/state_views.dart';
import '../auth/auth_controller.dart';
import '../cart/widgets/guest_cart_widgets.dart';
import 'cart_controller.dart';
import 'data/store_repository.dart';

class CartScreen extends ConsumerStatefulWidget {
  const CartScreen({super.key});

  @override
  ConsumerState<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends ConsumerState<CartScreen> {
  final _code = TextEditingController();
  PaymentToken _token = PaymentToken.success;
  bool _busy = false;
  String? _error;
  IconData _errorIcon = Icons.error_outline;

  @override
  void initState() {
    super.initState();
    _code.text = ref.read(cartProvider).discountCode ?? '';
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _checkout(CartState cart) async {
    final user = ref.read(authControllerProvider).user!;
    ref.read(cartProvider.notifier).setDiscountCode(_code.text);
    final current = ref.read(cartProvider);

    final ok = await confirmAction(
      context,
      title: 'Confirm payment',
      message:
          'Pay for ${current.itemCount} item(s), estimated ${formatMoney(current.estimatedSubtotalMinor)} before discount, '
          'with "${_token.label}"?\n\nThe final amount is calculated by the server.',
      confirmLabel: 'Pay now',
    );
    if (!ok || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final order = await ref.read(storeRepositoryProvider).checkout(
            orderId: current.orderId,
            customerId: user.userId,
            items: current.toCheckoutItems(),
            discountCode: current.discountCode,
            token: _token,
          );
      ref.read(cartProvider.notifier).clear();
      ref.invalidate(productsProvider);
      if (mounted) {
        context
            .pushReplacement('/receipt/${Uri.encodeComponent(order.orderId)}');
      }
    } on ApiException catch (e) {
      ref.invalidate(productsProvider); // stock may have changed
      setState(() {
        _errorIcon = switch (e.code) {
          'PAYMENT_DECLINED' ||
          'PAYMENT_CAPTURE_FAILED' =>
            Icons.credit_card_off,
          'OUT_OF_STOCK' => Icons.remove_shopping_cart,
          'INVALID_DISCOUNT_CODE' => Icons.local_offer_outlined,
          _ => Icons.error_outline,
        };
        _error = e.isConnectivity
            ? 'We could not confirm your payment because the server did not answer. '
                'Tap Pay again — the same order reference is reused, so you will not be charged twice.'
            : friendlyError(e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final online = ref.watch(syncControllerProvider.select((s) => s.online));
    final controller = ref.read(cartProvider.notifier);

    return AppScaffold(
      title: 'Cart',
      body: cart.lines.isEmpty
          ? Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
                  child: GuestCartBanner(),
                ),
                Expanded(
                  child: MessageView(
                    icon: Icons.shopping_cart_outlined,
                    title: 'Your cart is empty',
                    message: 'Browse the store to add merchandise.',
                    actionLabel: 'Open store',
                    onAction: () => context.go('/store'),
                  ),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                const GuestCartBanner(),
                for (final line in cart.lines) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                    '${line.product.name} — ${line.variant.label}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                              ),
                              IconButton(
                                tooltip: 'Remove ${line.variant.label}',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () =>
                                    controller.remove(line.variant.variantId),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              IconButton.outlined(
                                tooltip: 'Decrease',
                                onPressed: line.quantity > 1
                                    ? () => controller.setQuantity(
                                        line.variant.variantId,
                                        line.quantity - 1)
                                    : null,
                                icon: const Icon(Icons.remove),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.md),
                                child: Text('${line.quantity}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                              ),
                              IconButton.outlined(
                                tooltip: 'Increase',
                                onPressed: line.quantity < line.variant.stock &&
                                        line.quantity <
                                            CartController.maxQuantity
                                    ? () => controller.setQuantity(
                                        line.variant.variantId,
                                        line.quantity + 1)
                                    : null,
                                icon: const Icon(Icons.add),
                              ),
                              const Spacer(),
                              Text(formatMoney(line.lineTotalMinor),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                          Text(
                              '${formatMoney(line.variant.priceMinor)} each · ${line.variant.stock} in stock when loaded',
                              style: const TextStyle(
                                  color: AppColors.textMuted, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Discount code (optional)',
                    helperText: 'Checked by the server when you pay',
                    prefixIcon: Icon(Icons.local_offer_outlined),
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
                const SizedBox(height: AppSpacing.lg),
                SectionCard(
                  title: 'Test payment method',
                  icon: Icons.credit_card,
                  child: RadioGroupCompat(
                    value: _token,
                    onChanged: (t) => setState(() => _token = t),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      children: [
                        _SummaryRow('Subtotal (estimated)',
                            formatMoney(cart.estimatedSubtotalMinor)),
                        const SizedBox(height: AppSpacing.xs),
                        _SummaryRow(
                          'Discount',
                          _code.text.trim().isEmpty
                              ? '—'
                              : 'Applied by server at checkout',
                        ),
                        const Divider(),
                        const Text(
                          'Final total, discount and stock are confirmed by the server when you pay.',
                          style: TextStyle(
                              color: AppColors.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(_errorIcon, color: AppColors.danger),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(_error!,
                                style: const TextStyle(
                                    color: AppColors.danger,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                if (!online)
                  const Padding(
                    padding: EdgeInsets.only(bottom: AppSpacing.sm),
                    child: LabelBadge(
                        icon: Icons.cloud_off,
                        text: 'Checkout needs a connection to the server',
                        color: AppColors.warning),
                  ),
                FilledButton.icon(
                  onPressed: _busy || !online ? null : () => _checkout(cart),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.lock_outline),
                  label: Text(_busy ? 'Processing payment…' : 'Pay now'),
                ),
              ],
            ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: Text(label)),
          Flexible(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontWeight: FontWeight.w700))),
        ],
      );
}

/// Payment option list built from plain ListTiles so it works across Flutter
/// versions (Radio's group API changed in 3.32).
class RadioGroupCompat extends StatelessWidget {
  const RadioGroupCompat(
      {super.key, required this.value, required this.onChanged});
  final PaymentToken value;
  final ValueChanged<PaymentToken> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final t in PaymentToken.values)
          ListTile(
            contentPadding: EdgeInsets.zero,
            selected: t == value,
            leading: Icon(t == value
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked),
            title: Text(t.label),
            subtitle: Text(t.token),
            onTap: () => onChanged(t),
          ),
      ],
    );
  }
}
