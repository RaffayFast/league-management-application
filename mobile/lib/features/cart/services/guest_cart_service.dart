import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/json.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/providers.dart';
import '../../../core/storage/local_db.dart';
import '../models/guest_cart_item.dart';

/// Everything the guest cart keeps on the device (SQLite `kv` table, key [GuestCartService.storageKey]).
class GuestCartSnapshot {
  const GuestCartSnapshot({
    this.items = const [],
    this.guestToken,
    this.guestTokenExpiresAt,
    this.pending,
    this.lastReceipt,
    this.names = const {},
  });

  final List<GuestCartItem> items;

  /// Read-only guest token from `POST /api/v1/guest/session`; spent once a merge succeeds.
  final String? guestToken;
  final DateTime? guestTokenExpiresAt;
  final PendingMerge? pending;
  final MergeReceipt? lastReceipt;

  /// Display names of variants merged earlier, so the server cart (ids only) stays readable.
  final Map<String, String> names;

  Json toJson() => {
        'version': 1,
        'items': [for (final i in items) i.toJson()],
        'guest_token': guestToken,
        'guest_token_expires_at':
            guestTokenExpiresAt?.toUtc().toIso8601String(),
        'pending_merge': pending?.toJson(),
        'last_receipt': lastReceipt?.toJson(),
        'names': names,
      };

  static GuestCartSnapshot fromJson(Json j) => GuestCartSnapshot(
        items: asList(j['items'])
            .map(GuestCartItem.tryParse)
            .whereType<GuestCartItem>()
            .toList(),
        guestToken: asStringOrNull(j['guest_token']),
        guestTokenExpiresAt:
            DateTime.tryParse(asString(j['guest_token_expires_at'])),
        pending: PendingMerge.tryParse(j['pending_merge']),
        lastReceipt: MergeReceipt.tryParse(j['last_receipt']),
        names: {
          for (final e in asMap(j['names']).entries)
            if (e.value is String) e.key: e.value as String
        },
      );
}

/// Guest session issued by the backend.
class GuestSession {
  const GuestSession(this.token, this.expiresAt);
  final String token;
  final DateTime? expiresAt;
}

/// The server's 200 answer to a merge.
class MergeResult {
  const MergeResult({
    required this.guestToken,
    required this.cartMerged,
    required this.activeCart,
    required this.signature,
    required this.writeBlockVerified,
    required this.writeRejectionCode,
  });

  final String guestToken;
  final bool cartMerged;
  final MemberCart activeCart;
  final String signature;
  final bool writeBlockVerified;
  final int writeRejectionCode;

  static MergeResult fromJson(Json j) => MergeResult(
        guestToken: asString(j['guest_token']),
        cartMerged: asBool(j['cart_merged']),
        activeCart:
            MemberCart.fromJson(requireMap(j['active_cart'], 'active_cart')),
        signature: asString(j['signature']),
        writeBlockVerified: asBool(j['write_block_verified']),
        writeRejectionCode: asInt(j['write_rejection_code']),
      );
}

/// Persistence and API calls for the guest cart.
///
/// Routes (routers/guest_cart.py):
/// - `POST /api/v1/guest/session`: issues a read-only guest token (no auth).
/// - `POST /api/v1/guest/cart/merge`: the member route. The registered user comes from the member
///   token; the body is `{guest_token, guest_cart:[{variant_id, quantity}]}` with 1-10 lines.
///   (`/audit/v1/guest/cart-merge` is the autograder route with a `registered_user_id` body field;
///   `/audit/v1/guest/cart/merge` does not exist.)
/// - `GET /api/v1/cart`: the member's persistent cart.
class GuestCartService {
  GuestCartService(this._api, this._db);

  final ApiClient _api;
  final LocalDb _db;

  static const storageKey = 'guest_cart.v1';

  /// Loads the snapshot. A damaged value is kept under a backup key rather than silently dropped.
  Future<GuestCartSnapshot> load() async {
    final raw = await _db.getValue(storageKey);
    if (raw == null) return const GuestCartSnapshot();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return GuestCartSnapshot.fromJson(asMap(decoded));
    } on FormatException {
      // handled below
    }
    await _db.setValue('$storageKey.damaged', raw);
    return const GuestCartSnapshot();
  }

  Future<void> save(GuestCartSnapshot snapshot) =>
      _db.setValue(storageKey, jsonEncode(snapshot.toJson()));

  Future<GuestSession> issueGuestSession() async {
    final response =
        await _api.send('POST', '/api/v1/guest/session', auth: false);
    final j = requireMapOrThrow(response.data, 'guest session');
    final token = asStringOrNull(j['guest_token']);
    if (token == null || !token.startsWith('guest_')) {
      throw ApiException.malformed('The guest session has no guest token');
    }
    return GuestSession(token, DateTime.tryParse(asString(j['expires_at'])));
  }

  Future<MergeResult> merge(PendingMerge pending) async {
    final response = await _api.send('POST', '/api/v1/guest/cart/merge',
        body: pending.toRequestBody());
    return parseOrThrow(response.data, MergeResult.fromJson, 'cart merge');
  }

  Future<MemberCart> memberCart() async {
    final data = await _api.get('/api/v1/cart');
    return parseOrThrow(data, MemberCart.fromJson, 'member cart');
  }

  static Json requireMapOrThrow(dynamic data, String what) {
    if (data is Map) return asMap(data);
    throw ApiException.malformed('Unexpected shape for $what');
  }
}

final guestCartServiceProvider = Provider(
  (ref) => GuestCartService(
      ref.watch(apiClientProvider), ref.watch(localDbProvider)),
);
