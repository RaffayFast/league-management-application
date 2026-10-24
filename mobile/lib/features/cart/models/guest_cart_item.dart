import '../../../core/models/json.dart';
import 'merch_offer.dart';

/// One merchandise line staged on this device before sign-in. Staging never reserves stock; the
/// server checks stock only when the cart is merged.
class GuestCartItem {
  const GuestCartItem({
    required this.variantId,
    required this.productId,
    required this.productName,
    required this.variantLabel,
    required this.quantity,
    required this.currency,
    required this.addedAt,
    this.unitPriceMinor,
    this.size,
    this.color,
  });

  factory GuestCartItem.fromOffer(
          MerchOffer offer, int quantity, DateTime now) =>
      GuestCartItem(
        variantId: offer.variantId,
        productId: offer.productId,
        productName: offer.name,
        variantLabel: offer.variantLabel,
        quantity: quantity,
        currency: offer.currency,
        unitPriceMinor: offer.priceMinor,
        size: offer.size,
        color: offer.color,
        addedAt: now,
      );

  final String variantId;
  final String productId;
  final String productName;
  final String variantLabel;
  final int quantity;
  final String currency;

  /// Catalogue price when it was staged; the server's price at merge time is authoritative.
  final int? unitPriceMinor;
  final String? size;
  final String? color;
  final DateTime addedAt;

  int? get lineTotalMinor =>
      unitPriceMinor == null ? null : unitPriceMinor! * quantity;

  GuestCartItem copyWith({int? quantity}) => GuestCartItem(
        variantId: variantId,
        productId: productId,
        productName: productName,
        variantLabel: variantLabel,
        quantity: quantity ?? this.quantity,
        currency: currency,
        unitPriceMinor: unitPriceMinor,
        size: size,
        color: color,
        addedAt: addedAt,
      );

  Json toJson() => {
        'variant_id': variantId,
        'product_id': productId,
        'product_name': productName,
        'variant_label': variantLabel,
        'quantity': quantity,
        'currency': currency,
        'unit_price_minor': unitPriceMinor,
        'size': size,
        'color': color,
        'added_at': addedAt.toUtc().toIso8601String(),
      };

  static GuestCartItem? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final j = asMap(raw);
    final variantId = asStringOrNull(j['variant_id']);
    final quantity = asIntOrNull(j['quantity']);
    if (variantId == null ||
        variantId.isEmpty ||
        quantity == null ||
        quantity < 1) {
      return null;
    }
    return GuestCartItem(
      variantId: variantId,
      productId: asString(j['product_id']),
      productName: asString(j['product_name'], variantId),
      variantLabel: asString(j['variant_label'], variantId),
      quantity: quantity,
      currency: asString(j['currency'], 'PKR'),
      unitPriceMinor: asIntOrNull(j['unit_price_minor']),
      size: asStringOrNull(j['size']),
      color: asStringOrNull(j['color']),
      addedAt:
          DateTime.tryParse(asString(j['added_at'])) ?? DateTime.now().toUtc(),
    );
  }
}

/// A merge request frozen before it is sent. It is persisted, so a retry after a timeout or an app
/// restart sends exactly the same body. The server treats that as a replay (200 with the original
/// result), so nothing is added twice.
class PendingMerge {
  const PendingMerge({
    required this.guestToken,
    required this.accountId,
    required this.accountEmail,
    required this.lines,
    required this.startedAt,
    this.attempts = 0,
    this.lastErrorCode,
  });

  final String guestToken;

  /// The member account the merge was started for (the server takes it from the bearer token).
  final String accountId;
  final String accountEmail;

  /// `guest_cart` exactly as sent: variant id and quantity, in order.
  final List<(String, int)> lines;
  final DateTime startedAt;
  final int attempts;
  final String? lastErrorCode;

  int get totalQuantity => lines.fold(0, (n, l) => n + l.$2);

  /// Body of `POST /api/v1/guest/cart/merge` (models/guest_cart.py MemberCartMergeRequest).
  Json toRequestBody() => {
        'guest_token': guestToken,
        'guest_cart': [
          for (final (variantId, quantity) in lines)
            {'variant_id': variantId, 'quantity': quantity},
        ],
      };

  PendingMerge copyWith({int? attempts, String? lastErrorCode}) => PendingMerge(
        guestToken: guestToken,
        accountId: accountId,
        accountEmail: accountEmail,
        lines: lines,
        startedAt: startedAt,
        attempts: attempts ?? this.attempts,
        lastErrorCode: lastErrorCode ?? this.lastErrorCode,
      );

  Json toJson() => {
        'guest_token': guestToken,
        'account_id': accountId,
        'account_email': accountEmail,
        'lines': [
          for (final (variantId, quantity) in lines)
            {'variant_id': variantId, 'quantity': quantity},
        ],
        'started_at': startedAt.toUtc().toIso8601String(),
        'attempts': attempts,
        'last_error_code': lastErrorCode,
      };

  static PendingMerge? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final j = asMap(raw);
    final token = asStringOrNull(j['guest_token']);
    final account = asStringOrNull(j['account_id']);
    if (token == null || account == null) return null;
    final lines = <(String, int)>[];
    for (final l in asList(j['lines'])) {
      final m = asMap(l);
      final id = asStringOrNull(m['variant_id']);
      final q = asIntOrNull(m['quantity']);
      if (id == null || q == null) {
        return null; // a damaged snapshot must not be replayed partially
      }
      lines.add((id, q));
    }
    if (lines.isEmpty) return null;
    return PendingMerge(
      guestToken: token,
      accountId: account,
      accountEmail: asString(j['account_email']),
      lines: lines,
      startedAt: DateTime.tryParse(asString(j['started_at'])) ??
          DateTime.now().toUtc(),
      attempts: asInt(j['attempts']),
      lastErrorCode: asStringOrNull(j['last_error_code']),
    );
  }
}

/// What the server confirmed for a merge (200 response). The signature is stored as received.
class MergeReceipt {
  const MergeReceipt({
    required this.guestToken,
    required this.mergedAt,
    required this.mergedQuantity,
    required this.cartTotalItems,
    required this.cartSubtotalMinor,
    required this.currency,
    required this.signature,
    required this.writeBlockVerified,
    required this.writeRejectionCode,
  });

  final String guestToken;
  final DateTime mergedAt;
  final int mergedQuantity;
  final int cartTotalItems;
  final int cartSubtotalMinor;
  final String currency;
  final String signature;
  final bool writeBlockVerified;
  final int writeRejectionCode;

  Json toJson() => {
        'guest_token': guestToken,
        'merged_at': mergedAt.toUtc().toIso8601String(),
        'merged_quantity': mergedQuantity,
        'cart_total_items': cartTotalItems,
        'cart_subtotal_minor': cartSubtotalMinor,
        'currency': currency,
        'signature': signature,
        'write_block_verified': writeBlockVerified,
        'write_rejection_code': writeRejectionCode,
      };

  static MergeReceipt? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final j = asMap(raw);
    final token = asStringOrNull(j['guest_token']);
    if (token == null) return null;
    return MergeReceipt(
      guestToken: token,
      mergedAt:
          DateTime.tryParse(asString(j['merged_at'])) ?? DateTime.now().toUtc(),
      mergedQuantity: asInt(j['merged_quantity']),
      cartTotalItems: asInt(j['cart_total_items']),
      cartSubtotalMinor: asInt(j['cart_subtotal_minor']),
      currency: asString(j['currency'], 'PKR'),
      signature: asString(j['signature']),
      writeBlockVerified: asBool(j['write_block_verified']),
      writeRejectionCode: asInt(j['write_rejection_code']),
    );
  }
}

/// One line of the member's server cart (`active_cart.items`).
class MemberCartLine {
  const MemberCartLine(
      {required this.variantId,
      required this.quantity,
      required this.unitPriceMinor});
  final String variantId;
  final int quantity;
  final int unitPriceMinor;

  int get lineTotalMinor => quantity * unitPriceMinor;
}

/// The member's persistent server cart: `GET /api/v1/cart` and `active_cart` of a merge.
class MemberCart {
  const MemberCart({
    required this.userId,
    required this.currency,
    required this.totalItems,
    required this.subtotalMinor,
    required this.lines,
  });

  final String userId;
  final String currency;
  final int totalItems;
  final int subtotalMinor;
  final List<MemberCartLine> lines;

  static MemberCart fromJson(Json j) {
    final lines = <MemberCartLine>[];
    for (final raw in asList(j['items'])) {
      final m = asMap(raw);
      final id = asStringOrNull(m['variant_id']);
      if (id == null) throw MalformedResponse('Cart line without variant_id');
      lines.add(MemberCartLine(
          variantId: id,
          quantity: asInt(m['quantity']),
          unitPriceMinor: asInt(m['unit_price_minor'])));
    }
    return MemberCart(
      userId: asString(j['user_id']),
      currency: asString(j['currency'], 'PKR'),
      totalItems: asInt(j['total_items']),
      subtotalMinor: asInt(j['subtotal_minor']),
      lines: lines,
    );
  }
}
