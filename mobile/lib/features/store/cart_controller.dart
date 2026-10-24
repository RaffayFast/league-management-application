import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/json.dart';
import '../../core/models/store_models.dart';
import '../../core/util/ids.dart';
import '../auth/auth_controller.dart';

class CartLine {
  const CartLine(
      {required this.product, required this.variant, required this.quantity});
  final Product product;
  final Variant variant;
  final int quantity;

  int get lineTotalMinor => variant.priceMinor * quantity;

  CartLine copyWith({int? quantity}) => CartLine(
      product: product, variant: variant, quantity: quantity ?? this.quantity);
}

class CartState {
  const CartState(
      {this.lines = const [], this.discountCode, required this.orderId});

  final List<CartLine> lines;
  final String? discountCode;

  /// Reused across retries of the same cart so a timed-out checkout replays
  /// (200 + stored order) instead of charging twice. Renewed when the cart changes.
  final String orderId;

  int get itemCount => lines.fold(0, (n, l) => n + l.quantity);

  /// Client-side estimate from catalogue prices; the server's order is authoritative.
  int get estimatedSubtotalMinor =>
      lines.fold(0, (n, l) => n + l.lineTotalMinor);

  /// A10 items: unique variants, quantity 1-10.
  List<Json> toCheckoutItems() => [
        for (final l in lines)
          {'variant_id': l.variant.variantId, 'quantity': l.quantity}
      ];
}

class CartController extends StateNotifier<CartState> {
  CartController() : super(CartState(orderId: newId('ord')));

  static const maxLines = 10;
  static const maxQuantity = 10;

  /// Returns false if the cart already has the maximum number of distinct items.
  bool add(Product product, Variant variant, int quantity) {
    final lines = [...state.lines];
    final i = lines.indexWhere((l) => l.variant.variantId == variant.variantId);
    if (i >= 0) {
      final q = (lines[i].quantity + quantity).clamp(1, maxQuantity);
      lines[i] = lines[i].copyWith(quantity: q);
    } else {
      if (lines.length >= maxLines) return false;
      lines.add(CartLine(
          product: product,
          variant: variant,
          quantity: quantity.clamp(1, maxQuantity)));
    }
    _set(lines);
    return true;
  }

  /// Sets a line to exactly [quantity], adding it if missing. Used to copy the server cart into
  /// checkout, so repeating the copy never doubles quantities. Returns false when the cart is full.
  bool setLine(Product product, Variant variant, int quantity) {
    final lines = [...state.lines];
    final i = lines.indexWhere((l) => l.variant.variantId == variant.variantId);
    final q = quantity.clamp(1, maxQuantity);
    if (i >= 0) {
      if (lines[i].quantity == q) return true;
      lines[i] = lines[i].copyWith(quantity: q);
    } else {
      if (lines.length >= maxLines) return false;
      lines.add(CartLine(product: product, variant: variant, quantity: q));
    }
    _set(lines);
    return true;
  }

  void setQuantity(String variantId, int quantity) {
    _set([
      for (final l in state.lines)
        if (l.variant.variantId == variantId)
          l.copyWith(quantity: quantity.clamp(1, maxQuantity))
        else
          l,
    ]);
  }

  void remove(String variantId) =>
      _set(state.lines.where((l) => l.variant.variantId != variantId).toList());

  void setDiscountCode(String? code) {
    final c = code?.trim().toUpperCase();
    final normalized = (c == null || c.isEmpty) ? null : c;
    if (normalized == state.discountCode) {
      return; // keep orderId for idempotent retries
    }
    state = CartState(
        lines: state.lines, discountCode: normalized, orderId: newId('ord'));
  }

  void clear() => state = CartState(orderId: newId('ord'));

  void _set(List<CartLine> lines) => state = CartState(
      lines: lines, discountCode: state.discountCode, orderId: newId('ord'));
}

/// Cart is per signed-in user; switching accounts starts an empty cart.
final cartProvider = StateNotifierProvider<CartController, CartState>((ref) {
  ref.watch(authControllerProvider.select((a) => a.user?.userId));
  return CartController();
});
