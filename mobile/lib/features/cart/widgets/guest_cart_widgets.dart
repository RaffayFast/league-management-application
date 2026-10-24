import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/formatters.dart';
import '../../../core/widgets/dialogs.dart';
import '../../auth/auth_controller.dart';
import '../controllers/guest_cart_controller.dart';
import '../models/merch_offer.dart';

/// App-bar button for the guest cart with an item-count badge.
class GuestCartButton extends ConsumerWidget {
  const GuestCartButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count =
        ref.watch(guestCartControllerProvider.select((s) => s.itemCount));
    final pending =
        ref.watch(guestCartControllerProvider.select((s) => s.pending != null));
    return IconButton(
      tooltip: count == 0
          ? 'Guest cart'
          : 'Guest cart, $count item(s)${pending ? ', merge pending' : ''}',
      onPressed: () => context.push('/guest-cart'),
      icon: Badge(
        isLabelVisible: count > 0 || pending,
        label: Text(pending && count == 0 ? '!' : '$count'),
        backgroundColor: pending ? AppColors.warning : AppColors.live,
        child: const Icon(Icons.shopping_bag_outlined),
      ),
    );
  }
}

/// The match / co-stream merchandise card. Guests stage the item in the guest cart; members open
/// the product in the store, where the member cart and checkout already live.
class MerchOfferCard extends ConsumerWidget {
  const MerchOfferCard({super.key, required this.offer});
  final MerchOffer offer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(
        authControllerProvider.select((a) => a.status == AuthStatus.signedIn));
    final theme = Theme.of(context);
    final details = [
      offer.variantLabel,
      if (offer.priceMinor != null)
        formatMoney(offer.priceMinor!, offer.currency)
    ];

    void add() {
      final result = ref.read(guestCartControllerProvider.notifier).add(offer);
      final (message, error) = switch (result) {
        AddResult.added => ('Added to your guest cart', false),
        AddResult.increased => ('Quantity updated in your guest cart', false),
        AddResult.atMaximum => (
            'You already have the maximum of 10 of this item',
            true
          ),
        AddResult.cartFull => (
            'The guest cart holds at most 10 different items',
            true
          ),
        AddResult.outOfStock => ('This item is out of stock', true),
        AddResult.notLoaded => (
            'The cart is still loading; try again in a moment',
            true
          ),
      };
      showSnack(context, message, error: error);
    }

    return Semantics(
      container: true,
      label: 'merch-offer ${offer.productId}',
      child: Card(
        color: const Color(0xFFF4FBE4),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              const CircleAvatar(
                radius: 24,
                backgroundColor: AppColors.navy,
                child: Icon(Icons.checkroom, color: AppColors.lime),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Match-day pick',
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: AppColors.limeDeep)),
                    Text(offer.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16)),
                    Text(details.join(' · '),
                        style: const TextStyle(color: AppColors.textMuted)),
                    if (!offer.inStock)
                      const Text('Out of stock',
                          style: TextStyle(
                              color: AppColors.danger,
                              fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (signedIn)
                OutlinedButton(
                  style:
                      OutlinedButton.styleFrom(minimumSize: const Size(48, 44)),
                  onPressed: () => context
                      .push('/product/${Uri.encodeComponent(offer.productId)}'),
                  child: const Text('View'),
                )
              else
                FilledButton.icon(
                  style:
                      FilledButton.styleFrom(minimumSize: const Size(48, 44)),
                  onPressed: offer.inStock ? add : null,
                  icon: const Icon(Icons.add_shopping_cart, size: 18),
                  label: const Text('Add'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reminder shown to members when items from guest browsing are waiting to be merged.
class GuestCartBanner extends ConsumerWidget {
  const GuestCartBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count =
        ref.watch(guestCartControllerProvider.select((s) => s.itemCount));
    final pending =
        ref.watch(guestCartControllerProvider.select((s) => s.pending != null));
    if (count == 0 && !pending) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Card(
        color: const Color(0xFFFFF8E6),
        child: ListTile(
          leading:
              const Icon(Icons.shopping_bag_outlined, color: AppColors.warning),
          title: Text(pending
              ? 'A guest cart merge is not confirmed yet'
              : '$count item(s) saved while browsing as a guest'),
          subtitle: const Text('Review them and merge into your account cart.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/guest-cart'),
        ),
      ),
    );
  }
}
