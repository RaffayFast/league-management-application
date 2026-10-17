import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/auth_models.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/providers.dart';
import '../../core/sync/sync_controller.dart';

enum AuthStatus { unknown, signedOut, signedIn }

class AuthState {
  const AuthState(this.status, {this.session, this.message});

  final AuthStatus status;
  final Session? session;

  /// Shown on the login screen, e.g. after an expired session.
  final String? message;

  AppUser? get user => session?.user;
}

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>((ref) => AuthController(ref));

/// Real authentication against POST /api/v1/auth/login; session restored from
/// secure storage on start-up so cached screens work offline.
class AuthController extends StateNotifier<AuthState> {
  AuthController(this._ref) : super(const AuthState(AuthStatus.unknown)) {
    _restore();
  }

  final Ref _ref;

  Future<void> _restore() async {
    final session = await _ref.read(secureStoreProvider).readSession();
    if (session == null) {
      state = const AuthState(AuthStatus.signedOut);
      return;
    }
    if (session.isExpired) {
      await _ref.read(secureStoreProvider).clear();
      state = const AuthState(AuthStatus.signedOut, message: 'Your session expired. Please sign in again.');
      return;
    }
    _ref.read(tokenHolderProvider).token = session.token;
    state = AuthState(AuthStatus.signedIn, session: session);
    unawaited(refreshProfile());
    unawaited(_ref.read(syncControllerProvider.notifier).syncNow());
  }

  /// Refreshes user/tenant from GET /api/v1/me. Offline is fine: the stored
  /// session stays; a 401 triggers [sessionExpired] via the API client.
  Future<void> refreshProfile() async {
    final session = state.session;
    if (session == null) return;
    try {
      final data = await _ref.read(apiClientProvider).get('/api/v1/me');
      if (data is! Map) return;
      final user = AppUser.fromJson(Map<String, dynamic>.from(data['user'] as Map));
      final tenant = data['tenant'] is Map ? Tenant.fromJson(Map<String, dynamic>.from(data['tenant'] as Map)) : null;
      final updated = session.copyWith(user: user, tenant: tenant);
      await _ref.read(secureStoreProvider).saveSession(updated);
      if (mounted && state.status == AuthStatus.signedIn) {
        state = AuthState(AuthStatus.signedIn, session: updated);
      }
    } on ApiException {
      // Keep the cached session; status chip already reflects connectivity.
    } on TypeError {
      // Ignore a malformed /me; the login payload is still valid.
    }
  }

  /// Throws [ApiException] with a contract error code on failure.
  Future<void> login(String email, String password) async {
    final response = await _ref.read(apiClientProvider).send(
          'POST',
          '/api/v1/auth/login',
          body: {'email': email.trim(), 'password': password},
          auth: false,
        );
    final login = parseOrThrow(response.data, LoginResponse.fromJson, 'login response');
    final session = Session(
      token: login.token,
      user: login.user,
      tenant: login.tenant,
      expiresAt: DateTime.now().toUtc().add(Duration(seconds: login.expiresIn)),
    );
    await _ref.read(secureStoreProvider).saveSession(session);
    _ref.read(tokenHolderProvider).token = session.token;
    state = AuthState(AuthStatus.signedIn, session: session);
    unawaited(_ref.read(syncControllerProvider.notifier).syncNow());
  }

  /// Pending offline actions are kept (owner-scoped) so nothing is lost on logout.
  Future<void> logout({String? message}) async {
    await _ref.read(secureStoreProvider).clear();
    _ref.read(tokenHolderProvider).token = null;
    state = AuthState(AuthStatus.signedOut, message: message);
  }

  void sessionExpired() {
    if (state.status != AuthStatus.signedIn) return;
    unawaited(logout(message: 'Your session expired. Please sign in again.'));
  }
}
