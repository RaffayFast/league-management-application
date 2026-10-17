import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/util/formatters.dart';
import '../../core/util/validators.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/state_views.dart';
import 'cart_controller.dart';
import 'data/store_repository.dart';

class ProductScreen extends ConsumerStatefulWidget {
  const ProductScreen({super.key, required this.productId});
  final String productId;

  @override
  ConsumerState<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends ConsumerState<ProductScreen> {
  String? _variantId;
  int _qty = 1;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(productsProvider);
    return AppScaffold(
      title: 'Product',
      body: AsyncBody(
        value: async,
        onRetry: () => ref.invalidate(productsProvider),
        data: (cached) {
          final product = cached.data.where((p) => p.productId == widget.productId).firstOrNull;
          if (product == null) {
            return const EmptyView(title: 'Product not found', message: 'It may no longer be available.');
          }
          final variant = product.variants.where((v) => v.variantId == _variantId).firstOrNull ??
              product.variants.where((v) => v.inStock).firstOrNull ??
              product.variants.firstOrNull;
          final inCart = ref.watch(cartProvider).lines.where((l) => l.variant.variantId == variant?.variantId).firstOrNull?.quantity ?? 0;
          final available = (variant?.stock ?? 0) - inCart;
          final qty = clampQuantity(_qty, available);

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              if (cached.fromCache) ...[CachedBanner(cachedAt: cached.cachedAt), const SizedBox(height: AppSpacing.md)],
              Container(
                height: 180,
                decoration: BoxDecoration(color: const Color(0xFFEFF2F7), borderRadius: BorderRadius.circular(AppSpacing.radius)),
                child: const Center(child: Icon(Icons.checkroom, size: 96, color: AppColors.navySoft, semanticLabel: 'No product image')),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(product.name, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: AppSpacing.xs),
              Text('${humanize(product.category)}${product.clubId != null ? ' · ${product.clubId}' : ''}',
                  style: const TextStyle(color: AppColors.textMuted)),
              const SizedBox(height: AppSpacing.md),
              Text(product.description),
              const SizedBox(height: AppSpacing.lg),
              Text('Choose an option', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final v in product.variants)
                    ChoiceChip(
                      label: Text('${v.label}${v.color != null ? ' · ${v.color}' : ''}${v.inStock ? '' : ' (sold out)'}'),
                      selected: v.variantId == variant?.variantId,
                      onSelected: v.inStock ? (_) => setState(() {
                            _variantId = v.variantId;
                            _qty = 1;
                          }) : null,
                    ),
                ],
              ),
              if (variant != null) ...[
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    Text(formatMoney(variant.priceMinor, variant.currency),
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                    const Spacer(),
                    variant.inStock
                        ? LabelBadge(icon: Icons.inventory_2_outlined, text: '${variant.stock} in stock', color: AppColors.success)
                        : const LabelBadge(icon: Icons.remove_shopping_cart, text: 'Sold out', color: AppColors.danger),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    const Text('Quantity'),
                    const Spacer(),
                    IconButton.outlined(
                      tooltip: 'Decrease quantity',
                      onPressed: qty > 1 ? () => setState(() => _qty = qty - 1) : null,
                      icon: const Icon(Icons.remove),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                      child: Text('$qty', style: Theme.of(context).textTheme.titleLarge, semanticsLabel: 'Quantity $qty'),
                    ),
                    IconButton.outlined(
                      tooltip: 'Increase quantity',
                      onPressed: qty < clampQuantity(99, available) ? () => setState(() => _qty = qty + 1) : null,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                if (inCart > 0)
                  Text('$inCart already in your cart', style: const TextStyle(color: AppColors.textMuted)),
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  onPressed: available < 1 || qty < 1
                      ? null
                      : () {
                          final added = ref.read(cartProvider.notifier).add(product, variant, qty);
                          showSnack(
                            context,
                            added ? 'Added $qty × ${product.name} (${variant.label}) to cart' : 'Your cart is full (10 different items max).',
                            error: !added,
                          );
                        },
                  icon: const Icon(Icons.add_shopping_cart),
                  label: Text(available < 1 ? 'No more stock available' : 'Add to cart'),
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: () => context.push('/cart'),
                  icon: const Icon(Icons.shopping_cart_checkout),
                  label: const Text('Go to cart'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
