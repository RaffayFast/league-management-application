import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/auth_controller.dart';
import '../network/error_messages.dart';
import '../providers.dart';
import 'pending_action.dart';
import 'sync_service.dart';

/// App-wide connection + queue state shown by the persistent status chip.
class SyncState {
  const SyncState({
    this.hasNetwork = true,
    this.serverReachable = true,
    this.syncing = false,
    this.pending = 0,
    this.rejected = 0,
    this.lastSyncAt,
    this.lastMessage,
    this.lastReport,
  });

  final bool hasNetwork;
  final bool serverReachable;
  final bool syncing;
  final int pending;
  final int rejected;
  final DateTime? lastSyncAt;
  final String? lastMessage;
  final SyncReport? lastReport;

  bool get online => hasNetwork && serverReachable;

  SyncState copyWith({
    bool? hasNetwork,
    bool? serverReachable,
    bool? syncing,
    int? pending,
    int? rejected,
    DateTime? lastSyncAt,
    String? lastMessage,
    SyncReport? lastReport,
  }) =>
      SyncState(
        hasNetwork: hasNetwork ?? this.hasNetwork,
        serverReachable: serverReachable ?? this.serverReachable,
        syncing: syncing ?? this.syncing,
        pending: pending ?? this.pending,
        rejected: rejected ?? this.rejected,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        lastMessage: lastMessage ?? this.lastMessage,
        lastReport: lastReport ?? this.lastReport,
      );
}

final syncControllerProvider = StateNotifierProvider<SyncController, SyncState>(
    (ref) => SyncController(ref));

class SyncController extends StateNotifier<SyncState> {
  SyncController(this._ref) : super(const SyncState()) {
    _init();
  }

  final Ref _ref;
  StreamSubscription<bool>? _sub;

  Future<void> _init() async {
    final connectivity = _ref.read(connectivityServiceProvider);
    final online = await connectivity.isOnline();
    if (!mounted) return;
    state = state.copyWith(hasNetwork: online);
    await refreshCounts();
    _sub = connectivity.watch().listen((hasNetwork) {
      final regained = hasNetwork && !state.hasNetwork;
      // A fresh interface gets a fresh chance; real requests will confirm reachability.
      state = state.copyWith(
          hasNetwork: hasNetwork,
          serverReachable: hasNetwork ? true : state.serverReachable);
      if (regained) {
        _ref.read(refreshTickProvider.notifier).state++;
        unawaited(syncNow());
      }
    });
  }

  void setServerReachable(bool reachable) {
    if (!mounted || reachable == state.serverReachable) return;
    final regained = reachable && !state.serverReachable;
    state = state.copyWith(serverReachable: reachable);
    if (regained && state.pending > 0) unawaited(syncNow());
  }

  Future<void> refreshCounts() async {
    final queue = _ref.read(actionQueueProvider);
    final pending = await queue.count();
    final rejected = await queue.count(state: PendingState.rejected);
    if (mounted) state = state.copyWith(pending: pending, rejected: rejected);
  }

  Future<void> enqueue(PendingAction action) async {
    await _ref.read(actionQueueProvider).enqueue(action);
    await refreshCounts();
  }

  /// Sends the signed-in user's pending actions. Safe to call repeatedly: a
  /// second call while one is running is ignored.
  Future<SyncReport?> syncNow() async {
    final session = _ref.read(authControllerProvider).session;
    if (state.syncing || session == null || !state.hasNetwork) return null;
    state = state.copyWith(syncing: true);
    SyncReport? report;
    String message;
    try {
      report = await _ref
          .read(syncServiceProvider)
          .syncPending(owner: session.user.userId);
      if (report.transportError != null) {
        message = 'Sync paused: ${friendlyError(report.transportError!)}';
      } else if (report.isEmpty) {
        message = 'Nothing to sync.';
      } else {
        message =
            'Synced: ${report.applied} applied, ${report.duplicate} already on server, '
            '${report.rejected} rejected.';
      }
    } catch (e) {
      message = 'Sync failed: ${friendlyError(e)}';
    }
    if (!mounted) return report;
    state = state.copyWith(
      syncing: false,
      lastSyncAt: DateTime.now().toUtc(),
      lastMessage: message,
      lastReport: report,
    );
    await refreshCounts();
    if (report != null && report.outcomes.isNotEmpty) {
      _ref.read(refreshTickProvider.notifier).state++;
    }
    return report;
  }

  Future<void> retry(String actionId) async {
    await _ref.read(actionQueueProvider).requeue(actionId);
    await refreshCounts();
    await syncNow();
  }

  Future<void> discard(String actionId) async {
    await _ref.read(actionQueueProvider).remove(actionId);
    await refreshCounts();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
