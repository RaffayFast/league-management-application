import 'json.dart';

class Variant {
  const Variant({
    required this.variantId,
    required this.label,
    this.size,
    this.color,
    required this.priceMinor,
    required this.currency,
    required this.stock,
  });

  final String variantId;
  final String label;
  final String? size;
  final String? color;
  final int priceMinor;
  final String currency;
  final int stock;

  bool get inStock => stock > 0;

  factory Variant.fromJson(Json j) => Variant(
        variantId: asString(j['variant_id']),
        label: asString(j['label'], asString(j['variant_id'])),
        size: asStringOrNull(j['size']),
        color: asStringOrNull(j['color']),
        priceMinor: asInt(j['price_minor']),
        currency: asString(j['currency'], 'PKR'),
        stock: asInt(j['stock']),
      );
}

/// B8 product.
class Product {
  const Product({
    required this.productId,
    this.clubId,
    required this.name,
    required this.description,
    required this.category,
    required this.variants,
  });

  final String productId;
  final String? clubId;
  final String name;
  final String description;
  final String category;
  final List<Variant> variants;

  int get totalStock => variants.fold(0, (sum, v) => sum + v.stock);
  int? get fromPriceMinor =>
      variants.isEmpty ? null : variants.map((v) => v.priceMinor).reduce((a, b) => a < b ? a : b);

  factory Product.fromJson(Json j) => Product(
        productId: asString(j['product_id']),
        clubId: asStringOrNull(j['club_id']),
        name: asString(j['name']),
        description: asString(j['description']),
        category: asString(j['category']),
        variants: mapList(j['variants'], Variant.fromJson),
      );
}

class OrderItem {
  const OrderItem({required this.variantId, required this.quantity, required this.unitPriceMinor});
  final String variantId;
  final int quantity;
  final int unitPriceMinor;

  int get lineTotalMinor => quantity * unitPriceMinor;

  factory OrderItem.fromJson(Json j) => OrderItem(
        variantId: asString(j['variant_id']),
        quantity: asInt(j['quantity']),
        unitPriceMinor: asInt(j['unit_price_minor']),
      );
}

class PaymentInfo {
  const PaymentInfo({required this.authorizationId, required this.captureId, required this.state});
  final String authorizationId;
  final String captureId;
  final String state;

  factory PaymentInfo.fromJson(Json j) => PaymentInfo(
        authorizationId: asString(j['authorization_id']),
        captureId: asString(j['capture_id']),
        state: asString(j['state']),
      );
}

class ReceiptPayload {
  const ReceiptPayload({
    required this.orderId,
    required this.customerId,
    required this.items,
    required this.subtotalMinor,
    required this.discountMinor,
    required this.totalMinor,
    required this.currency,
    required this.paidAt,
  });

  final String orderId;
  final String customerId;
  final List<OrderItem> items;
  final int subtotalMinor;
  final int discountMinor;
  final int totalMinor;
  final String currency;
  final String paidAt;

  factory ReceiptPayload.fromJson(Json j) => ReceiptPayload(
        orderId: asString(j['order_id']),
        customerId: asString(j['customer_id']),
        items: mapList(j['items'], OrderItem.fromJson),
        subtotalMinor: asInt(j['subtotal_minor']),
        discountMinor: asInt(j['discount_minor']),
        totalMinor: asInt(j['total_minor']),
        currency: asString(j['currency'], 'PKR'),
        paidAt: asString(j['paid_at']),
      );
}

class Receipt {
  const Receipt({required this.payload, required this.signature, required this.pdfBase64});
  final ReceiptPayload payload;
  final String signature;
  final String pdfBase64;

  factory Receipt.fromJson(Json j) => Receipt(
        payload: ReceiptPayload.fromJson(asMap(j['payload'])),
        signature: asString(j['signature']),
        pdfBase64: asString(j['pdf_base64']),
      );
}

/// A10 Order object.
class OrderResponse {
  const OrderResponse({
    required this.orderId,
    required this.status,
    required this.currency,
    required this.items,
    required this.subtotalMinor,
    required this.discountMinor,
    required this.totalMinor,
    required this.payment,
    required this.receipt,
  });

  final String orderId;
  final String status;
  final String currency;
  final List<OrderItem> items;
  final int subtotalMinor;
  final int discountMinor;
  final int totalMinor;
  final PaymentInfo payment;
  final Receipt receipt;

  factory OrderResponse.fromJson(Json j) {
    if (j['order_id'] is! String || j['receipt'] is! Map) {
      throw MalformedResponse('order response is missing order_id or receipt');
    }
    return OrderResponse(
      orderId: asString(j['order_id']),
      status: asString(j['status']),
      currency: asString(j['currency'], 'PKR'),
      items: mapList(j['items'], OrderItem.fromJson),
      subtotalMinor: asInt(j['subtotal_minor']),
      discountMinor: asInt(j['discount_minor']),
      totalMinor: asInt(j['total_minor']),
      payment: PaymentInfo.fromJson(asMap(j['payment'])),
      receipt: Receipt.fromJson(asMap(j['receipt'])),
    );
  }
}

/// Mock gateway tokens accepted by the backend (api_contract.md A10).
enum PaymentToken {
  success('tok_success', 'Test card — approves'),
  declined('tok_declined', 'Test card — declined'),
  captureFail('tok_capture_fail', 'Test card — capture fails');

  const PaymentToken(this.token, this.label);
  final String token;
  final String label;
}
