import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/state_views.dart';
import '../../core/widgets/status_banner.dart';
import '../cart/widgets/guest_cart_widgets.dart';
import '../chat/widgets/live_chat_panel.dart';
import '../costream/controllers/costream_controller.dart';
import '../costream/models/costream_session.dart';
import '../costream/widgets/costream_grid.dart';
import '../streaming/models/stream_source.dart';
import '../streaming/services/live_page_service.dart';
import '../streaming/widgets/leaguehub_video_player.dart';

/// Public co-stream screen opened by nascon://stream/<session_id> (no account needed to watch).
///
/// - Session: GET /api/v1/live/costream/{id}, followed by [CostreamController] (404 = not started).
/// - Video: the session's `composite_playback_url` in the [CoStreamGrid] layout. A host handoff
///   keeps the same composite URL, so the player is not recreated; only labels move.
/// - Chat: the one shared room `chat-<session_id>` (FR-3.3), realtime over SSE.
class LiveCostreamScreen extends ConsumerWidget {
  const LiveCostreamScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(costreamControllerProvider(sessionId));
    final controller = ref.read(costreamControllerProvider(sessionId).notifier);
    // The backend names the room; before the session exists it is chat-<session_id> as well.
    final room = state.session?.chatRoomId ?? 'chat-$sessionId';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Co-stream'),
        actions: [
          IconButton(
              tooltip: 'Scan a QR code',
              onPressed: () => context.push('/scan'),
              icon: const Icon(Icons.qr_code_scanner)),
          const GuestCartButton(),
        ],
      ),
      body: Semantics(
        label: 'live-costream-screen $sessionId',
        child: LayoutBuilder(builder: (context, c) {
          final main = _MainColumn(
              sessionId: sessionId, state: state, onRetry: controller.refresh);
          if (c.maxWidth >= 1000) {
            return Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: ListView(children: [main])),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                      flex: 2,
                      child:
                          LiveChatPanel(roomId: room, title: 'Co-stream chat')),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              main,
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                  height: 460,
                  child: LiveChatPanel(roomId: room, title: 'Co-stream chat')),
            ],
          );
        }),
      ),
    );
  }
}

class _MainColumn extends ConsumerStatefulWidget {
  const _MainColumn(
      {required this.sessionId, required this.state, required this.onRetry});
  final String sessionId;
  final CostreamState state;
  final Future<void> Function() onRetry;

  @override
  ConsumerState<_MainColumn> createState() => _MainColumnState();
}

class _MainColumnState extends ConsumerState<_MainColumn> {
  /// True while the composite shows video; the grid hides name tags otherwise.
  final _videoVisible = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _videoVisible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final state = widget.state;
    final onRetry = widget.onRetry;
    final session = state.session;
    final offer =
        ref.watch(liveCostreamPageProvider(sessionId)).valueOrNull?.offer;
    final handoff = state.lastHandoff;
    final recentHandoff = handoff != null &&
        DateTime.now().difference(handoff.at) < const Duration(seconds: 20);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(sessionId: sessionId, state: state, onRetry: onRetry),
        const SizedBox(height: AppSpacing.md),
        if (state.error != null && session != null) ...[
          StatusBanner(
            tone: StatusTone.offline,
            dense: true,
            message: 'Showing the last known session: ${state.error}',
            actionLabel: 'Retry now',
            onAction: onRetry,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (recentHandoff) ...[
          StatusBanner(
            tone: StatusTone.info,
            dense: true,
            icon: Icons.swap_horiz,
            message: handoff.to == null
                ? '${handoff.from} left; the session has no host now.'
                : 'Host handed over from ${handoff.from} to ${handoff.to}. The broadcast may pause briefly while '
                    'the server rebuilds the composite.',
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (session == null)
          _NoSession(
              waiting: state.waiting, error: state.error, onRetry: onRetry)
        else if (!session.isActive)
          const SizedBox(
            height: 220,
            child: MessageView(
                icon: Icons.stop_circle_outlined,
                title: 'This co-stream has ended',
                message: 'The hosts have stopped broadcasting.'),
          )
        else
          CoStreamGrid(
            layout: session.layout ?? CostreamLayout.grid4,
            participants: session.participants,
            activeHost: session.activeHost,
            tileLabelsVisible: _videoVisible,
            composite: LeagueHubVideoPlayer(
              key: ValueKey('composite-$sessionId'),
              videoVisible: _videoVisible,
              source: StreamSource.costream(
                sessionId: sessionId,
                playbackUrl: session.compositePlaybackUrl,
                title: 'Co-stream $sessionId',
              ),
            ),
          ),
        if (session != null && session.isActive) ...[
          const SizedBox(height: AppSpacing.md),
          _ParticipantList(session: session),
        ],
        if (offer != null) ...[
          const SizedBox(height: AppSpacing.md),
          MerchOfferCard(offer: offer),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(
      {required this.sessionId, required this.state, required this.onRetry});
  final String sessionId;
  final CostreamState state;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = state.session;
    final layout = s?.layout?.label ?? s?.layoutRaw;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
          color: AppColors.navy,
          borderRadius: BorderRadius.circular(AppSpacing.radius)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(sessionId,
                    style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              ConnectionPill(
                  status: state.connection, onRetry: onRetry, onDark: true),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            liveRegion: true,
            child: Text(
              s == null
                  ? (state.waiting
                      ? 'Waiting for the hosts to go live'
                      : 'Connecting…')
                  : 'Host: ${s.activeHost ?? '—'} · ${s.participantCount} on stream${layout == null || layout.isEmpty ? '' : ' · $layout'}',
              style: const TextStyle(
                  color: AppColors.lime, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _ParticipantList extends StatelessWidget {
  const _ParticipantList({required this.session});
  final CostreamSession session;

  @override
  Widget build(BuildContext context) {
    final capacity = session.layout?.capacity ?? 4;
    final spotlight = session.layout == CostreamLayout.spotlight;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (var i = 0; i < session.participants.length; i++)
          Builder(builder: (context) {
            final p = session.participants[i];
            final host = p == session.activeHost;
            final inFrame = spotlight ? host : i < capacity;
            return Chip(
              key: ValueKey('participant-$p'),
              avatar: Icon(
                  host
                      ? Icons.star_rounded
                      : (inFrame
                          ? Icons.videocam_outlined
                          : Icons.videocam_off_outlined),
                  size: 18,
                  color: host ? AppColors.limeDeep : AppColors.navySoft),
              label: Text(
                  '$p${host ? ' · host' : ''}${inFrame ? '' : ' · off frame'}'),
            );
          }),
      ],
    );
  }
}

class _NoSession extends StatelessWidget {
  const _NoSession(
      {required this.waiting, required this.error, required this.onRetry});
  final bool waiting;
  final String? error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(
            color: AppColors.navy,
            borderRadius: BorderRadius.circular(AppSpacing.radius)),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(waiting ? Icons.hourglass_top : Icons.portable_wifi_off,
                    color: AppColors.lime, size: 40),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  waiting
                      ? 'The hosts have not started this co-stream yet'
                      : (error ?? 'Connecting to the co-stream…'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600),
                ),
                if (waiting) ...[
                  const SizedBox(height: AppSpacing.xs),
                  const Text(
                      'This page refreshes on its own. Chat is already open.',
                      style: TextStyle(color: Colors.white70)),
                ],
                if (!waiting && error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.lime,
                        foregroundColor: AppColors.navy),
                    onPressed: onRetry,
                    child: const Text('Retry'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
