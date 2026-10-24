import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/json.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/widgets/status_banner.dart';
import '../../auth/auth_controller.dart';
import '../models/guest_cart_item.dart';
import '../models/merch_offer.dart';
import '../services/guest_cart_service.dart';

enum MergePhase {
  idle,
  merging,

  /// The last request may or may not have reached the server; the frozen request is kept.
  uncertain,
  failed,
  merged,
}

enum AddResult { added, increased, atMaximum, cartFull, outOfStock, notLoaded }

const _keep = Object();

class GuestCartState {
  const GuestCartState({
    this.loaded = false,
    this.items = const [],
    this.guestToken,
    this.guestTokenExpiresAt,
    this.pending,
    this.lastReceipt,
    this.names = const {},
    this.phase = MergePhase.idle,
    this.message,
    this.messageTone = StatusTone.info,
    this.needsSignIn = false,
    this.lineProblems = const {},
    this.memberCart,
    this.memberCartLoading = false,
    this.memberCartError,
    this.storageError,
  });

  final bool loaded;
  final List<GuestCartItem> items;
  final String? guestToken;
  final DateTime? guestTokenExpiresAt;
  final PendingMerge? pending;
  final MergeReceipt? lastReceipt;
  final Map<String, String> names;
  final MergePhase phase;
  final String? message;
  final StatusTone messageTone;

  /// The merge needs a (fresh) member session first.
  final bool needsSignIn;

  /// Per-variant problems reported by the server (stock, discontinued).
  final Map<String, String> lineProblems;
  final MemberCart? memberCart;
  final bool memberCartLoading;
  final String? memberCartError;
  final String? storageError;

  int get itemCount => items.fold(0, (n, i) => n + i.quantity);

  /// Null when any staged price is unknown.
  int? get subtotalMinor {
    var total = 0;
    for (final i in items) {
      final line = i.lineTotalMinor;
      if (line == null) return null;
      total += line;
    }
    return total;
  }

  String get currency => items.isEmpty ? 'PKR' : items.first.currency;
  bool get busy => phase == MergePhase.merging;
  bool get hasSomethingToMerge => items.isNotEmpty || pending != null;

  String nameFor(String variantId) {
    for (final i in items) {
      if (i.variantId == variantId) {
        return '${i.productName} · ${i.variantLabel}';
      }
    }
    return names[variantId] ?? variantId;
  }

  GuestCartSnapshot toSnapshot() => GuestCartSnapshot(
        items: items,
        guestToken: guestToken,
        guestTokenExpiresAt: guestTokenExpiresAt,
        pending: pending,
        lastReceipt: lastReceipt,
        names: names,
      );

  GuestCartState copyWith({
    bool? loaded,
    List<GuestCartItem>? items,
    Object? guestToken = _keep,
    Object? guestTokenExpiresAt = _keep,
    Object? pending = _keep,
    Object? lastReceipt = _keep,
    Map<String, String>? names,
    MergePhase? phase,
    Object? message = _keep,
    StatusTone? messageTone,
    bool? needsSignIn,
    Map<String, String>? lineProblems,
    Object? memberCart = _keep,
    bool? memberCartLoading,
    Object? memberCartError = _keep,
    Object? storageError = _keep,
  }) =>
      GuestCartState(
        loaded: loaded ?? this.loaded,
        items: items ?? this.items,
        guestToken: identical(guestToken, _keep)
            ? this.guestToken
            : guestToken as String?,
        guestTokenExpiresAt: identical(guestTokenExpiresAt, _keep)
            ? this.guestTokenExpiresAt
            : guestTokenExpiresAt as DateTime?,
        pending:
            identical(pending, _keep) ? this.pending : pending as PendingMerge?,
        lastReceipt: identical(lastReceipt, _keep)
            ? this.lastReceipt
            : lastReceipt as MergeReceipt?,
        names: names ?? this.names,
        phase: phase ?? this.phase,
        message: identical(message, _keep) ? this.message : message as String?,
        messageTone: messageTone ?? this.messageTone,
        needsSignIn: needsSignIn ?? this.needsSignIn,
        lineProblems: lineProblems ?? this.lineProblems,
        memberCart: identical(memberCart, _keep)
            ? this.memberCart
            : memberCart as MemberCart?,
        memberCartLoading: memberCartLoading ?? this.memberCartLoading,
        memberCartError: identical(memberCartError, _keep)
            ? this.memberCartError
            : memberCartError as String?,
        storageError: identical(storageError, _keep)
            ? this.storageError
            : storageError as String?,
      );
}

/// The device's guest cart, shared by every screen, persisted in SQLite and merged into the
/// member's server cart after sign-in.
///
/// Merge safety:
/// 1. The request is frozen (guest token, account, lines) and written to disk before it is sent.
/// 2. Retries send that identical body. The server answers a replay with the original result
///    (200), so a timeout followed by a retry never adds items twice.
/// 3. Local items are removed only after a 200 with `cart_merged: true` for this guest token,
///    and only by the quantities that were sent. Items added meanwhile stay.
/// 4. Definitive refusals (stock, unknown variant, validation) clear the frozen request.
///    Merges are atomic on the server, so nothing changed there.
class GuestCartController extends StateNotifier<GuestCartState> {
  GuestCartController(this._ref) : super(const GuestCartState()) {
    unawaited(_load());
  }

  final Ref _ref;
  static const maxLines = 10;
  static const maxQuantity = 10;
  static const _maxAutoRetries = 3;

  GuestCartService get _service => _ref.read(guestCartServiceProvider);

  Future<void> _writes = Future.value();
  bool _merging = false;
  bool _rotateAndRetry = false;
  Timer? _retryTimer;
  int _autoRetries = 0;

  Future<void> _load() async {
    GuestCartSnapshot snapshot;
    String? storageError;
    try {
      snapshot = await _service.load();
    } on Exception catch (e) {
      snapshot = const GuestCartSnapshot();
      storageError = 'The saved guest cart could not be read: $e';
    }
    if (!mounted) return;
    state = state.copyWith(
      loaded: true,
      items: snapshot.items,
      guestToken: snapshot.guestToken,
      guestTokenExpiresAt: snapshot.guestTokenExpiresAt,
      pending: snapshot.pending,
      lastReceipt: snapshot.lastReceipt,
      names: snapshot.names,
      phase: snapshot.pending == null ? MergePhase.idle : MergePhase.uncertain,
      message: snapshot.pending == null
          ? null
          : 'A merge started earlier was not confirmed. It will be finished with the same request.',
      messageTone: StatusTone.warning,
      storageError: storageError,
    );
    _resumeIfPossible();
  }

  /// Queues a write; writes happen in order and failures are shown, not swallowed.
  void _persist() => unawaited(_persistNow());

  Future<void> _persistNow() {
    final snapshot = state.toSnapshot();
    _writes = _writes.then((_) => _service.save(snapshot)).then((_) {
      if (mounted && state.storageError != null) {
        state = state.copyWith(storageError: null);
      }
    }, onError: (Object e) {
      if (mounted) {
        state = state.copyWith(
            storageError: 'Could not save the cart on this device: $e');
      }
    });
    return _writes;
  }

  // ------------------------------------------------------------------ editing

  AddResult add(MerchOffer offer, {int quantity = 1}) {
    if (!state.loaded) return AddResult.notLoaded;
    if (!offer.inStock) return AddResult.outOfStock;
    final items = [...state.items];
    final i = items.indexWhere((x) => x.variantId == offer.variantId);
    AddResult result;
    if (i >= 0) {
      if (items[i].quantity >= maxQuantity) return AddResult.atMaximum;
      items[i] = items[i].copyWith(
          quantity: (items[i].quantity + quantity).clamp(1, maxQuantity));
      result = AddResult.increased;
    } else {
      if (items.length >= maxLines) return AddResult.cartFull;
      items.add(GuestCartItem.fromOffer(
          offer, quantity.clamp(1, maxQuantity), DateTime.now().toUtc()));
      result = AddResult.added;
    }
    _setItems(items, touched: offer.variantId);
    return result;
  }

  void setQuantity(String variantId, int quantity) {
    _setItems(
      [
        for (final i in state.items)
          if (i.variantId == variantId)
            i.copyWith(quantity: quantity.clamp(1, maxQuantity))
          else
            i,
      ],
      touched: variantId,
    );
  }

  void remove(String variantId) =>
      _setItems(state.items.where((i) => i.variantId != variantId).toList(),
          touched: variantId);

  void _setItems(List<GuestCartItem> items, {required String touched}) {
    final problems = Map<String, String>.from(state.lineProblems)
      ..remove(touched);
    state = state.copyWith(
      items: items,
      lineProblems: problems,
      phase:
          state.phase == MergePhase.merged || state.phase == MergePhase.failed
              ? MergePhase.idle
              : state.phase,
    );
    _persist();
  }

  void dismissMessage() => state = state.copyWith(message: null);

  // ------------------------------------------------------------------ session changes

  void onAuthChanged(String? userId) {
    if (userId == null) {
      _retryTimer?.cancel();
      state = state.copyWith(
          memberCart: null, memberCartError: null, needsSignIn: false);
      return;
    }
    state = state.copyWith(needsSignIn: false);
    _resumeIfPossible();
  }

  void onConnectivityRestored() {
    if (state.phase == MergePhase.uncertain) unawaited(mergeIntoAccount());
  }

  void _resumeIfPossible() {
    final user = _ref.read(authControllerProvider).user;
    final pending = state.pending;
    if (!state.loaded ||
        user == null ||
        pending == null ||
        pending.accountId != user.userId) {
      return;
    }
    unawaited(mergeIntoAccount());
  }

  /// Gives up an unconfirmed merge that belongs to another account. The guest token is replaced
  /// too, so a later merge can never collide with the abandoned one.
  void discardPendingMerge() {
    _retryTimer?.cancel();
    state = state.copyWith(
      pending: null,
      guestToken: null,
      guestTokenExpiresAt: null,
      phase: MergePhase.idle,
      message:
          'The unconfirmed merge was discarded. Your items are still here.',
      messageTone: StatusTone.info,
    );
    _persist();
  }

  // ------------------------------------------------------------------ merge

  Future<void> mergeIntoAccount({bool afterRotation = false}) async {
    if (_merging || !state.loaded) return;
    final user = _ref.read(authControllerProvider).user;
    if (user == null) {
      state = state.copyWith(
        needsSignIn: true,
        message: 'Sign in or create an account to check out.',
        messageTone: StatusTone.info,
      );
      return;
    }
    final existing = state.pending;
    if (existing != null && existing.accountId != user.userId) {
      state = state.copyWith(
        phase: MergePhase.failed,
        message:
            'A merge started for ${existing.accountEmail} was not confirmed. Sign in as that account to finish '
            'it, or discard it to merge into this account.',
        messageTone: StatusTone.warning,
      );
      return;
    }
    if (existing == null && state.items.isEmpty) return;

    _merging = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    state = state.copyWith(
        phase: MergePhase.merging,
        message: null,
        needsSignIn: false,
        lineProblems: const {});
    try {
      var pending = existing;
      if (pending == null) {
        final lines = [for (final i in state.items) (i.variantId, i.quantity)];
        var token = state.guestToken;
        final expires = state.guestTokenExpiresAt;
        if (token == null ||
            (expires != null && expires.isBefore(DateTime.now()))) {
          final session = await _service.issueGuestSession();
          if (!mounted) return;
          token = session.token;
          state = state.copyWith(
              guestToken: token, guestTokenExpiresAt: session.expiresAt);
        }
        pending = PendingMerge(
          guestToken: token,
          accountId: user.userId,
          accountEmail: user.email,
          lines: lines,
          startedAt: DateTime.now().toUtc(),
        );
      }
      pending = pending.copyWith(attempts: pending.attempts + 1);
      state = state.copyWith(pending: pending);
      await _persistNow(); // the frozen request is on disk before it leaves the device

      final result = await _service.merge(pending);
      if (!mounted) return;
      if (!result.cartMerged || result.guestToken != pending.guestToken) {
        throw ApiException.malformed(
            'The server answered without confirming this merge');
      }
      _applyMerged(pending, result);
      _autoRetries = 0;
    } on ApiException catch (e) {
      if (mounted) _applyFailure(e, afterRotation: afterRotation);
    } finally {
      _merging = false;
    }
    if (!mounted) return;
    if (state.phase == MergePhase.merged) unawaited(refreshMemberCart());
    if (_rotateAndRetry) {
      _rotateAndRetry = false;
      await mergeIntoAccount(afterRotation: true);
    }
  }

  void _applyMerged(PendingMerge pending, MergeResult result) {
    final sent = {for (final (id, q) in pending.lines) id: q};
    final remaining = <GuestCartItem>[];
    for (final item in state.items) {
      final left = item.quantity - (sent[item.variantId] ?? 0);
      if (left > 0) remaining.add(item.copyWith(quantity: left));
    }
    final names = {
      ...state.names,
      for (final i in state.items)
        i.variantId: '${i.productName} · ${i.variantLabel}',
    };
    state = state.copyWith(
      items: remaining,
      pending: null,
      guestToken: null, // a merged guest token cannot merge another cart
      guestTokenExpiresAt: null,
      names: names,
      lastReceipt: MergeReceipt(
        guestToken: pending.guestToken,
        mergedAt: DateTime.now().toUtc(),
        mergedQuantity: pending.totalQuantity,
        cartTotalItems: result.activeCart.totalItems,
        cartSubtotalMinor: result.activeCart.subtotalMinor,
        currency: result.activeCart.currency,
        signature: result.signature,
        writeBlockVerified: result.writeBlockVerified,
        writeRejectionCode: result.writeRejectionCode,
      ),
      memberCart: result.activeCart,
      phase: MergePhase.merged,
      message: 'Merged ${pending.totalQuantity} item(s) into your account cart.'
          '${remaining.isEmpty ? '' : ' Items you added while it was merging are still here.'}',
      messageTone: StatusTone.success,
    );
    _persist();
  }

  void _applyFailure(ApiException e, {required bool afterRotation}) {
    final pending = state.pending;
    if (pending == null) {
      // Nothing was sent yet (the guest session request failed).
      state = state.copyWith(
        phase: MergePhase.failed,
        message: 'Could not start the merge: ${friendlyError(e)}',
        messageTone: StatusTone.error,
      );
      return;
    }
    final uncertain = e.isConnectivity ||
        e.kind == ApiErrorKind.server ||
        e.kind == ApiErrorKind.malformed ||
        e.statusCode == 429;
    if (uncertain) {
      state = state.copyWith(
        pending: pending.copyWith(lastErrorCode: e.code),
        phase: MergePhase.uncertain,
        message:
            'Merge not confirmed: ${friendlyError(e)} Your items are safe on this device. Retrying sends the '
            'identical request, so nothing is added twice.',
        messageTone: StatusTone.warning,
      );
      _persist();
      _scheduleAutoRetry(e);
      return;
    }
    if (e.statusCode == 401 ||
        e.code == 'UNAUTHENTICATED' ||
        e.code == 'GUEST_WRITE_FORBIDDEN') {
      state = state.copyWith(
        pending: pending.copyWith(lastErrorCode: e.code),
        phase: MergePhase.failed,
        needsSignIn: true,
        message:
            'The server did not accept your session, so the merge is not confirmed. Sign in again as '
            '${pending.accountEmail} to finish it.',
        messageTone: StatusTone.warning,
      );
      _persist();
      return;
    }

    final variantId = asStringOrNull(e.details['variant_id']);
    switch (e.code) {
      case 'GUEST_TOKEN_ALREADY_MERGED':
        // The token was used for a different cart or account earlier; this cart was not merged.
        state = state.copyWith(
            pending: null, guestToken: null, guestTokenExpiresAt: null);
        _persist();
        if (!afterRotation) {
          _rotateAndRetry = true;
          state = state.copyWith(
            phase: MergePhase.idle,
            message:
                'This guest session was already merged once, so the merge restarts with a new guest session.',
            messageTone: StatusTone.info,
          );
          return;
        }
        _fail(describeErrorCode(e.code));
      case 'VALIDATION_ERROR':
        final fields = e.fields;
        final badToken = fields.any((f) => f.contains('guest_token'));
        state = state.copyWith(
            pending: null, guestToken: badToken ? null : state.guestToken);
        _persist();
        if (badToken && !afterRotation) {
          _rotateAndRetry = true;
          state = state.copyWith(
              phase: MergePhase.idle,
              message: 'The guest session was not valid; starting a new one.');
          return;
        }
        _fail(friendlyError(e));
      case 'OUT_OF_STOCK':
        final available = asIntOrNull(e.details['available']);
        state = state.copyWith(
          pending: null,
          lineProblems: {
            if (variantId != null)
              variantId: available == null
                  ? 'Not enough stock'
                  : 'Only $available available, including your account cart',
          },
        );
        _persist();
        _fail(
            'Not enough stock for one item, so nothing was merged. Lower the quantity and try again.');
      case 'VARIANT_NOT_FOUND':
        state = state.copyWith(
          pending: null,
          lineProblems: {
            if (variantId != null)
              variantId: 'No longer sold. Remove it to continue.'
          },
        );
        _persist();
        _fail('One item is no longer sold, so nothing was merged.');
      case 'PLAYER_NOT_FOUND':
        state = state.copyWith(pending: null);
        _persist();
        _fail(
            'The server could not find your member record, so the cart was not merged.');
      default:
        // Any other refusal: merges are atomic on the server, so nothing changed there.
        state = state.copyWith(pending: null);
        _persist();
        _fail(friendlyError(e));
    }
  }

  void _fail(String message) => state = state.copyWith(
      phase: MergePhase.failed,
      message: message,
      messageTone: StatusTone.error);

  void _scheduleAutoRetry(ApiException e) {
    if (_autoRetries >= _maxAutoRetries) return;
    if (!_ref.read(syncControllerProvider).hasNetwork) {
      return; // resumed when connectivity returns
    }
    _autoRetries++;
    final seconds = e.retryAfterSeconds ?? (1 << _autoRetries);
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: seconds), () {
      _retryTimer = null;
      if (mounted && state.phase == MergePhase.uncertain) {
        unawaited(mergeIntoAccount());
      }
    });
  }

  // ------------------------------------------------------------------ member cart

  Future<void> refreshMemberCart() async {
    if (_ref.read(authControllerProvider).user == null) return;
    state = state.copyWith(memberCartLoading: true, memberCartError: null);
    try {
      final cart = await _service.memberCart();
      if (mounted) {
        state = state.copyWith(memberCart: cart, memberCartLoading: false);
      }
    } on ApiException catch (e) {
      if (mounted) {
        state = state.copyWith(
            memberCartLoading: false, memberCartError: friendlyError(e));
      }
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }
}

/// App-wide: the same guest cart on every screen.
final guestCartControllerProvider =
    StateNotifierProvider<GuestCartController, GuestCartState>((ref) {
  final controller = GuestCartController(ref);
  ref.listen<String?>(authControllerProvider.select((a) => a.user?.userId),
      (previous, userId) {
    if (previous != userId) controller.onAuthChanged(userId);
  });
  ref.listen<bool>(syncControllerProvider.select((s) => s.hasNetwork),
      (previous, hasNetwork) {
    if (hasNetwork && previous == false) controller.onConnectivityRestored();
  });
  return controller;
});
