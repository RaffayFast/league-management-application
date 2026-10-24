import '../../../core/models/json.dart';

/// The product card the backend pins to a match or co-stream page (routers/guest_web.py `offer`).
///
/// Guests cannot list the catalogue (`GET /api/v1/store/products` needs an account), so this is how
/// a guest sees merchandise: one variant, either the pinned one or the first in stock.
class MerchOffer {
  const MerchOffer({
    required this.productId,
    required this.name,
    required this.variantId,
    required this.variantLabel,
    required this.priceMinor,
    required this.currency,
    required this.inStock,
    this.description,
    this.size,
    this.color,
  });

  final String productId;
  final String name;
  final String variantId;
  final String variantLabel;
  final int? priceMinor;
  final String currency;
  final bool inStock;
  final String? description;
  final String? size;
  final String? color;

  /// Null when the payload lacks the ids needed to stage the item.
  static MerchOffer? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final j = asMap(raw);
    final productId = asStringOrNull(j['product_id']);
    final variantId = asStringOrNull(j['variant_id']);
    if (productId == null ||
        productId.isEmpty ||
        variantId == null ||
        variantId.isEmpty) {
      return null;
    }
    return MerchOffer(
      productId: productId,
      name: asString(j['name'], 'Merchandise'),
      variantId: variantId,
      variantLabel: asString(j['label'], variantId),
      priceMinor: asIntOrNull(j['price_minor']),
      currency: asString(j['currency'], 'PKR'),
      inStock: asBool(j['in_stock'], true),
      description: asStringOrNull(j['description']),
      size: asStringOrNull(j['size']),
      color: asStringOrNull(j['color']),
    );
  }
}
