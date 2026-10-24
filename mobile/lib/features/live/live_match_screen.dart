import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/state_views.dart';
import '../cart/widgets/guest_cart_widgets.dart';
import '../chat/widgets/live_chat_panel.dart';
import '../streaming/models/stream_source.dart';
import '../streaming/services/live_page_service.dart';
import '../streaming/widgets/leaguehub_video_player.dart';

/// Public live match screen opened by nascon://entity/match-* (no account needed).
///
/// - Score: GET /api/v1/live/matches/{id}, refreshed every 5 s (app polling rule, api_contract.md §0).
/// - Video: the backend's playback URL from the Guest Web Player page data.
/// - Chat: room `chat-<match_id>` over the SSE stream; posting asks guests to sign in in place.
/// - Merchandise: the pinned offer goes into the guest cart.
class LiveMatchScreen extends ConsumerStatefulWidget {
  const LiveMatchScreen({super.key, required this.matchId});
  final String matchId;

  @override
  ConsumerState<LiveMatchScreen> createState() => _LiveMatchScreenState();
}

class _LiveMatchScreenState extends ConsumerState<LiveMatchScreen> {
  Map<String, dynamic>? _snapshot;
  Object? _error;
  Timer? _timer;

  String get _room => 'chat-${widget.matchId}';

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await ref
          .read(apiClientProvider)
          .get('/api/v1/live/matches/${widget.matchId}', auth: false);
      if (!mounted) return;
      setState(() {
        _snapshot = Map<String, dynamic>.from(data as Map);
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  static const _statusLabels = {
    'upcoming': 'Upcoming',
    'in_progress': 'LIVE',
    'completed': 'Full time'
  };

  @override
  Widget build(BuildContext context) {
    final snap = _snapshot;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live match'),
        actions: [
          IconButton(
              tooltip: 'Scan a QR code',
              onPressed: () => context.push('/scan'),
              icon: const Icon(Icons.qr_code_scanner)),
          const GuestCartButton(),
        ],
      ),
      body: Semantics(
        label: 'live-match-screen ${widget.matchId}',
        child: snap == null
            ? (_error == null
                ? const Center(child: CircularProgressIndicator())
                : ErrorView(error: _error!, onRetry: _load))
            : LayoutBuilder(
                builder: (context, c) => c.maxWidth >= 960
                    ? _wide(context, snap)
                    : _narrow(context, snap)),
      ),
    );
  }

  Widget _wide(BuildContext context, Map<String, dynamic> snap) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: ListView(children: _mainColumn(context, snap)),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(flex: 2, child: LiveChatPanel(roomId: _room)),
        ],
      ),
    );
  }

  Widget _narrow(BuildContext context, Map<String, dynamic> snap) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        ..._mainColumn(context, snap),
        const SizedBox(height: AppSpacing.lg),
        SizedBox(height: 460, child: LiveChatPanel(roomId: _room)),
      ],
    );
  }

  List<Widget> _mainColumn(BuildContext context, Map<String, dynamic> snap) {
    final page = ref.watch(liveMatchPageProvider(widget.matchId));
    final home = Map<String, dynamic>.from(snap['home'] as Map);
    final away = Map<String, dynamic>.from(snap['away'] as Map);
    final title = '${home['name']} vs ${away['name']}';
    return [
      page.when(
        skipLoadingOnRefresh: true,
        loading: () => const AspectRatio(
          aspectRatio: 16 / 9,
          child: DecoratedBox(
            decoration: BoxDecoration(
                color: AppColors.navy,
                borderRadius:
                    BorderRadius.all(Radius.circular(AppSpacing.radius))),
            child:
                Center(child: CircularProgressIndicator(color: AppColors.lime)),
          ),
        ),
        error: (e, _) => AspectRatio(
          aspectRatio: 16 / 9,
          child: Card(
            margin: EdgeInsets.zero,
            child: ErrorView(
                error: e,
                onRetry: () =>
                    ref.invalidate(liveMatchPageProvider(widget.matchId))),
          ),
        ),
        data: (info) => LeagueHubVideoPlayer(
          key: ValueKey('match-player-${widget.matchId}'),
          source: StreamSource.match(
              matchId: widget.matchId,
              playbackUrl: info.playbackUrl,
              title: title),
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      _ScoreCard(snap: snap, statusLabels: _statusLabels),
      if (page.valueOrNull?.offer case final offer?) ...[
        const SizedBox(height: AppSpacing.md),
        MerchOfferCard(offer: offer),
      ],
    ];
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.snap, required this.statusLabels});
  final Map<String, dynamic> snap;
  final Map<String, String> statusLabels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final home = Map<String, dynamic>.from(snap['home'] as Map);
    final away = Map<String, dynamic>.from(snap['away'] as Map);
    final status = '${snap['status']}';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
          color: AppColors.navy,
          borderRadius: BorderRadius.circular(AppSpacing.radius)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${home['name']}  vs  ${away['name']}',
              style: theme.textTheme.titleLarge
                  ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.md),
          Semantics(
            liveRegion: true,
            label: 'live-score-banner',
            child: Text('${home['score']} - ${away['score']}',
                style: theme.textTheme.displaySmall?.copyWith(
                    color: AppColors.lime, fontWeight: FontWeight.w900)),
          ),
          const SizedBox(height: AppSpacing.sm),
          Chip(
            label: Text(statusLabels[status] ?? status),
            backgroundColor:
                status == 'in_progress' ? AppColors.live : AppColors.navySoft,
            labelStyle: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
              'Match ${snap['match_id'] ?? ''} · the score refreshes every few seconds',
              style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ],
      ),
    );
  }
}
