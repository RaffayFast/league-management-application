import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/error_messages.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/state_views.dart';
import '../../core/widgets/status_banner.dart';
import '../auth/auth_controller.dart';
import '../auth/progressive_auth_sheet.dart';
import '../store/cart_controller.dart';
import '../store/data/store_repository.dart';
import 'controllers/guest_cart_controller.dart';
import 'models/guest_cart_item.dart';

/// Guest cart: staged items, progressive sign-in, merge into the member cart, and the server's
/// confirmed member cart afterwards.
class GuestCartScreen extends ConsumerStatefulWidget {
  const GuestCartScreen({super.key});

  @override
  ConsumerState<GuestCartScreen> createState() => _GuestCartScreenState();
}

class _GuestCartScreenState extends ConsumerState<GuestCartScreen> {
  bool _loadingCheckout = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(authControllerProvider).status == AuthStatus.signedIn) {
        ref.read(guestCartControllerProvider.notifier).refreshMemberCart();
      }
    });
  }

  Future<void> _checkout() async {
    final controller = ref.read(guestCartControllerProvider.notifier);
    if (ref.read(authControllerProvider).status != AuthStatus.signedIn) {
      final ok = await showProgressiveAuthSheet(context,
          reason: 'Sign in to check out');
      if (!ok || !mounted) return;
    }
    await controller.mergeIntoAccount();
  }

  /// Copies the server's confirmed cart into the existing member checkout and opens it.
  Future<void> _continueToCheckout() async {
    final cart = ref.read(guestCartControllerProvider).memberCart;
    if (cart == null || cart.lines.isEmpty) return;
    setState(() => _loadingCheckout = true);
    try {
      final products =
          (await ref.read(storeRepositoryProvider).products()).data;
      if (!mounted) return;
      final checkout = ref.read(cartProvider.notifier);
      final missing = <String>[];
      var clamped = false;
      for (final line in cart.lines) {
        final match = [
          for (final p in products)
            for (final v in p.variants)
              if (v.variantId == line.variantId) (p, v),
        ].firstOrNull;
        if (match == null) {
          missing.add(line.variantId);
          continue;
        }
        if (line.quantity > CartController.maxQuantity) clamped = true;
        if (!checkout.setLine(match.$1, match.$2, line.quantity)) {
          missing.add(line.variantId);
        }
      }
      if (missing.isNotEmpty || clamped) {
        showSnack(
          context,
          [
            if (missing.isNotEmpty)
              '${missing.length} item(s) are not in your store catalogue and were left out.',
            if (clamped) 'Checkout allows at most 10 of one item.',
          ].join(' '),
          error: true,
        );
      }
      context.push('/cart');
    } on ApiException catch (e) {
      if (mounted) {
        showSnack(context, 'Could not load the store: ${friendlyError(e)}',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _loadingCheckout = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(guestCartControllerProvider);
    final controller = ref.read(guestCartControllerProvider.notifier);
    final auth = ref.watch(authControllerProvider);
    final signedIn = auth.status == AuthStatus.signedIn;
    final hasNetwork =
        ref.watch(syncControllerProvider.select((s) => s.hasNetwork));

    return AppScaffold(
      title: signedIn ? 'Guest cart & account cart' : 'Guest cart',
      body: !state.loaded
          ? const SkeletonList(count: 3)
          : RefreshIndicator(
              onRefresh: () async {
                if (signedIn) await controller.refreshMemberCart();
              },
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  if (!hasNetwork) ...[
                    const StatusBanner(
                      tone: StatusTone.offline,
                      message:
                          'You are offline. Items stay on this device and can be merged when you are back online.',
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  if (state.storageError != null) ...[
                    StatusBanner(
                        tone: StatusTone.error, message: state.storageError!),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  if (state.message != null) ...[
                    StatusBanner(
                      tone: state.messageTone,
                      message: state.message!,
                      onDismiss: state.busy ? null : controller.dismissMessage,
                      actionLabel: state.needsSignIn ? 'Sign in' : null,
                      onAction: state.needsSignIn
                          ? () async {
                              final ok = await showProgressiveAuthSheet(context,
                                  reason: 'Sign in to finish the merge');
                              if (ok) await controller.mergeIntoAccount();
                            }
                          : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  _GuestItemsSection(state: state, controller: controller),
                  const SizedBox(height: AppSpacing.md),
                  _MergeActions(
                    state: state,
                    signedIn: signedIn,
                    accountId: auth.user?.userId,
                    onCheckout: _checkout,
                    onDiscard: () async {
                      final ok = await confirmAction(
                        context,
                        title: 'Discard the unconfirmed merge?',
                        message:
                            'If the earlier request did reach the server, these items may already be in that '
                            "account's cart. Your items stay here either way.",
                        confirmLabel: 'Discard',
                        destructive: true,
                      );
                      if (ok) controller.discardPendingMerge();
                    },
                  ),
                  if (signedIn) ...[
                    const SizedBox(height: AppSpacing.lg),
                    _MemberCartSection(
                      state: state,
                      loadingCheckout: _loadingCheckout,
                      onRefresh: controller.refreshMemberCart,
                      onCheckout: _continueToCheckout,
                    ),
                  ],
                  if (state.lastReceipt != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    _ReceiptNote(receipt: state.lastReceipt!),
                  ],
                ],
              ),
            ),
    );
  }
}

class _GuestItemsSection extends StatelessWidget {
  const _GuestItemsSection({required this.state, required this.controller});
  final GuestCartState state;
  final GuestCartController controller;

  @override
  Widget build(BuildContext context) {
    if (state.items.isEmpty) {
      return SectionCard(
        title: 'Items on this device',
        icon: Icons.shopping_bag_outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Your guest cart is empty. Add merchandise from a live match or co-stream page.',
                style: TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: AppSpacing.sm),
            TextButton.icon(
              onPressed: () => context.push('/scan'),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan a match QR code'),
            ),
          ],
        ),
      );
    }
    final subtotal = state.subtotalMinor;
    final locked = state.busy;
    return SectionCard(
      title: 'Items on this device',
      icon: Icons.shopping_bag_outlined,
      trailing: Text('${state.itemCount} item(s)',
          style: const TextStyle(color: AppColors.textMuted)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in state.items) ...[
            _GuestLine(
              item: item,
              problem: state.lineProblems[item.variantId],
              locked: locked,
              onQuantity: (q) => controller.setQuantity(item.variantId, q),
              onRemove: () async {
                final ok = await confirmAction(
                  context,
                  title: 'Remove ${item.productName}?',
                  message: 'It is only removed from this device.',
                  confirmLabel: 'Remove',
                  destructive: true,
                );
                if (ok) controller.remove(item.variantId);
              },
            ),
            const Divider(height: AppSpacing.lg),
          ],
          Row(
            children: [
              const Expanded(
                  child: Text('Estimated subtotal',
                      style: TextStyle(fontWeight: FontWeight.w700))),
              Text(
                subtotal == null
                    ? 'Price shown at checkout'
                    : formatMoney(subtotal, state.currency),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'Nothing is reserved until checkout. The server confirms prices and stock when the cart is merged.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _GuestLine extends StatelessWidget {
  const _GuestLine({
    required this.item,
    required this.problem,
    required this.locked,
    required this.onQuantity,
    required this.onRemove,
  });

  final GuestCartItem item;
  final String? problem;
  final bool locked;
  final ValueChanged<int> onQuantity;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final variant = [
      item.variantLabel,
      if (item.size != null) 'Size ${item.size}',
      if (item.color != null) item.color!
    ];
    return Semantics(
      container: true,
      label:
          '${item.productName}, ${variant.join(', ')}, quantity ${item.quantity}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.productName,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(variant.toSet().join(' · '),
                        style: const TextStyle(color: AppColors.textMuted)),
                    if (item.unitPriceMinor != null)
                      Text(
                          '${formatMoney(item.unitPriceMinor!, item.currency)} each',
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 12)),
                  ],
                ),
              ),
              IconButton(
                  tooltip: 'Remove',
                  onPressed: locked ? null : onRemove,
                  icon: const Icon(Icons.delete_outline)),
            ],
          ),
          Row(
            children: [
              IconButton.outlined(
                tooltip: 'Decrease quantity',
                onPressed: locked || item.quantity <= 1
                    ? null
                    : () => onQuantity(item.quantity - 1),
                icon: const Icon(Icons.remove),
              ),
              SizedBox(
                width: 44,
                child: Text('${item.quantity}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              IconButton.outlined(
                tooltip: 'Increase quantity',
                onPressed:
                    locked || item.quantity >= GuestCartController.maxQuantity
                        ? null
                        : () => onQuantity(item.quantity + 1),
                icon: const Icon(Icons.add),
              ),
              const Spacer(),
              if (item.lineTotalMinor != null)
                Text(formatMoney(item.lineTotalMinor!, item.currency),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(problem!,
                  style: const TextStyle(
                      color: AppColors.danger, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

class _MergeActions extends StatelessWidget {
  const _MergeActions({
    required this.state,
    required this.signedIn,
    required this.accountId,
    required this.onCheckout,
    required this.onDiscard,
  });

  final GuestCartState state;
  final bool signedIn;
  final String? accountId;
  final VoidCallback onCheckout;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final pending = state.pending;
    if (!state.hasSomethingToMerge) return const SizedBox.shrink();
    final foreignPending =
        pending != null && accountId != null && pending.accountId != accountId;
    final label = switch ((signedIn, pending != null, state.phase)) {
      (false, _, _) => 'Sign in to check out',
      (true, true, _) => 'Finish merging (${pending!.totalQuantity} item(s))',
      (true, false, MergePhase.failed) => 'Try the merge again',
      _ => 'Merge into my account cart',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pending != null && !foreignPending)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text(
              'Pending: ${pending.totalQuantity} item(s) for ${pending.accountEmail}, attempt ${pending.attempts}'
              '${pending.lastErrorCode == null ? '' : ' (last: ${pending.lastErrorCode})'}.',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: state.busy || foreignPending ? null : onCheckout,
          icon: state.busy
              ? const ButtonSpinner()
              : Icon(signedIn ? Icons.merge_type : Icons.login),
          label: Text(state.busy ? 'Merging…' : label),
        ),
        if (foreignPending) ...[
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48)),
            onPressed: state.busy ? null : onDiscard,
            child: const Text('Discard the unconfirmed merge'),
          ),
        ],
      ],
    );
  }
}

class _MemberCartSection extends StatelessWidget {
  const _MemberCartSection({
    required this.state,
    required this.loadingCheckout,
    required this.onRefresh,
    required this.onCheckout,
  });

  final GuestCartState state;
  final bool loadingCheckout;
  final VoidCallback onRefresh;
  final VoidCallback onCheckout;

  @override
  Widget build(BuildContext context) {
    final cart = state.memberCart;
    return SectionCard(
      title: 'Your account cart (from the server)',
      icon: Icons.cloud_done_outlined,
      trailing: IconButton(
        tooltip: 'Refresh account cart',
        onPressed: state.memberCartLoading ? null : onRefresh,
        icon: state.memberCartLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.refresh),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.memberCartError != null)
            StatusBanner(
                tone: StatusTone.error,
                dense: true,
                message: state.memberCartError!,
                onAction: onRefresh),
          if (cart == null &&
              state.memberCartError == null &&
              !state.memberCartLoading)
            const Text('Not loaded yet.',
                style: TextStyle(color: AppColors.textMuted)),
          if (cart != null && cart.lines.isEmpty)
            const Text('Your account cart is empty.',
                style: TextStyle(color: AppColors.textMuted)),
          if (cart != null && cart.lines.isNotEmpty) ...[
            for (final line in cart.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  children: [
                    Expanded(child: Text(state.nameFor(line.variantId))),
                    Text('× ${line.quantity}',
                        style: const TextStyle(color: AppColors.textMuted)),
                    const SizedBox(width: AppSpacing.md),
                    Text(formatMoney(line.lineTotalMinor, cart.currency),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            const Divider(),
            Row(
              children: [
                Expanded(
                    child: Text(
                        '${cart.totalItems} item(s) confirmed by the server',
                        style: const TextStyle(fontWeight: FontWeight.w700))),
                Text(formatMoney(cart.subtotalMinor, cart.currency),
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
              onPressed: loadingCheckout ? null : onCheckout,
              icon: loadingCheckout
                  ? const ButtonSpinner()
                  : const Icon(Icons.shopping_cart_checkout),
              label: const Text('Continue to checkout'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReceiptNote extends StatelessWidget {
  const _ReceiptNote({required this.receipt});
  final MergeReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final sig = receipt.signature.length > 16
        ? '${receipt.signature.substring(0, 16)}…'
        : receipt.signature;
    return Text(
      'Last merge: ${receipt.mergedQuantity} item(s) on ${formatDateTime(receipt.mergedAt.toIso8601String())}. '
      'Server signature $sig',
      style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
    );
  }
}
