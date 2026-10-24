import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/store_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/state_views.dart';
import 'cart_controller.dart';
import 'data/store_repository.dart';

class CatalogueScreen extends ConsumerWidget {
  const CatalogueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(productsProvider);
    final cartCount = ref.watch(cartProvider.select((c) => c.itemCount));

    return AppScaffold(
      title: 'Store',
      actions: [
        IconButton(
          tooltip: 'My receipts',
          icon: const Icon(Icons.receipt_long_outlined),
          onPressed: () => context.push('/receipts'),
        ),
        IconButton(
          tooltip: 'Cart, $cartCount items',
          onPressed: () => context.push('/cart'),
          icon: Badge(
            isLabelVisible: cartCount > 0,
            label: Text('$cartCount'),
            child: const Icon(Icons.shopping_cart_outlined),
          ),
        ),
      ],
      body: AsyncBody(
        value: async,
        onRetry: () => ref.invalidate(productsProvider),
        data: (cached) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(productsProvider);
            try {
              await ref.read(productsProvider.future);
            } catch (_) {}
          },
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              if (cached.fromCache) ...[
                CachedBanner(cachedAt: cached.cachedAt),
                const SizedBox(height: AppSpacing.md)
              ],
              const _DiscountHint(),
              const SizedBox(height: AppSpacing.md),
              if (cached.data.isEmpty)
                const SizedBox(
                    height: 300,
                    child: EmptyView(
                        title: 'No products yet',
                        icon: Icons.storefront_outlined))
              else
                for (final p in cached.data) ...[
                  _ProductCard(product: p),
                  const SizedBox(height: AppSpacing.md),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscountHint extends StatelessWidget {
  const _DiscountHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
          color: AppColors.navy,
          borderRadius: BorderRadius.circular(AppSpacing.radius)),
      child: const Row(
        children: [
          Icon(Icons.local_offer_outlined, color: AppColors.lime),
          SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Have a discount code? Enter it in your cart — the server checks it at checkout.',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product});
  final Product product;

  @override
  Widget build(BuildContext context) {
    final price = product.fromPriceMinor;
    final soldOut = product.totalStock == 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            context.push('/product/${Uri.encodeComponent(product.productId)}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                    color: const Color(0xFFEFF2F7),
                    borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.checkroom,
                    size: 36,
                    color: AppColors.navySoft,
                    semanticLabel: 'Product image unavailable'),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(product.name,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(product.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.textMuted)),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (price != null)
                          Text(formatMoney(price),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 16)),
                        soldOut
                            ? const LabelBadge(
                                icon: Icons.remove_shopping_cart,
                                text: 'Sold out',
                                color: AppColors.danger)
                            : LabelBadge(
                                icon: Icons.inventory_2_outlined,
                                text: '${product.totalStock} in stock',
                                color: AppColors.success),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
