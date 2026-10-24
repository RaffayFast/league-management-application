import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/data/cached_fetch.dart';
import '../../../core/models/json.dart';
import '../../../core/models/store_models.dart';
import '../../../core/network/api_client.dart';
import '../../../core/providers.dart';
import '../../../core/storage/local_db.dart';
import '../../../core/util/formatters.dart';

class StoredReceipt {
  const StoredReceipt(this.order, this.createdAt);
  final OrderResponse order;
  final String createdAt;
}

/// Catalogue (B8), checkout (A10 via /api/v1/store/checkout) and local receipts.
/// The backend has no "get order" route, so successful orders are kept in SQLite
/// to reopen receipts later.
class StoreRepository {
  StoreRepository(this._fetcher, this._api, this._db);

  final CachedFetcher _fetcher;
  final ApiClient _api;
  final LocalDb _db;

  Future<Cached<List<Product>>> products() => _fetcher.fetch(
      '/api/v1/store/products',
      (j) => mapList(j['products'], Product.fromJson));

  Future<OrderResponse> checkout({
    required String orderId,
    required String customerId,
    required List<Json> items,
    required String? discountCode,
    required PaymentToken token,
  }) async {
    final response = await _api.send('POST', '/api/v1/store/checkout', body: {
      'order_id': orderId,
      'customer_id': customerId,
      'items': items,
      'discount_code': discountCode,
      'payment': {'token': token.token},
    });
    final order = parseOrThrow(response.data, OrderResponse.fromJson, 'order');
    await _db.db.insert(
      'receipts',
      {
        'order_id': order.orderId,
        'json': jsonEncode(response.data),
        'created_at': utcTimestamp(),
        'owner': customerId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return order;
  }

  Future<List<StoredReceipt>> receipts(String owner) async {
    final rows = await _db.db.query('receipts',
        where: 'owner = ?', whereArgs: [owner], orderBy: 'created_at DESC');
    return rows
        .map((r) => StoredReceipt(
            OrderResponse.fromJson(asMap(jsonDecode(r['json'] as String))),
            r['created_at'] as String))
        .toList();
  }

  Future<OrderResponse?> receipt(String orderId) async {
    final rows = await _db.db.query('receipts',
        where: 'order_id = ?', whereArgs: [orderId], limit: 1);
    if (rows.isEmpty) return null;
    return OrderResponse.fromJson(
        asMap(jsonDecode(rows.first['json'] as String)));
  }

  /// Decodes the server's receipt.pdf_base64 into the app documents folder.
  Future<File> savePdf(OrderResponse order) async {
    final dir = Directory(
        p.join((await getApplicationDocumentsDirectory()).path, 'receipts'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(p.join(dir.path, '${order.orderId}.pdf'));
    await file.writeAsBytes(base64Decode(order.receipt.pdfBase64), flush: true);
    return file;
  }
}

final storeRepositoryProvider = Provider((ref) => StoreRepository(
      ref.watch(cachedFetcherProvider),
      ref.watch(apiClientProvider),
      ref.watch(localDbProvider),
    ));

final productsProvider =
    FutureProvider.autoDispose<Cached<List<Product>>>((ref) {
  ref.watch(refreshTickProvider);
  return ref.watch(storeRepositoryProvider).products();
});
