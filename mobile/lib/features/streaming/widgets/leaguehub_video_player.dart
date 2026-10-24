import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/media/media_url_resolver.dart';
import '../../../core/providers.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../models/stream_source.dart';
import '../services/media_playback_service.dart';

/// LeagueHub HLS player for Android (video_player + chewie) and Windows (media_kit).
///
/// - The backend URL goes through [MediaUrlResolver] once per source change.
/// - One engine per widget. It is reopened only when the source URL changes, so a co-stream host
///   handoff (same composite URL) never recreates it.
/// - Errors retry automatically (2 s, 4 s, 8 s). After that the viewer gets a Retry button. Only
///   one retry is ever scheduled, and the engine ignores superseded opens.
/// - Offline: nothing is opened. Playback resumes when connectivity returns.
class LeagueHubVideoPlayer extends ConsumerStatefulWidget {
  const LeagueHubVideoPlayer({
    super.key,
    required this.source,
    this.aspectRatio = 16 / 9,
    this.videoVisible,
  });

  final StreamSource source;

  /// Box aspect ratio until the stream reports its own.
  final double aspectRatio;

  /// Set to true while video frames are showing, so a parent can hide overlays (such as co-stream
  /// name tags) while the player shows a status message instead. Updated from engine events only.
  final ValueNotifier<bool>? videoVisible;

  @override
  ConsumerState<LeagueHubVideoPlayer> createState() =>
      _LeagueHubVideoPlayerState();
}

enum _View {
  unavailable,
  unsupported,
  offline,
  connecting,
  playing,
  retrying,
  failed,
  ended
}

class _LeagueHubVideoPlayerState extends ConsumerState<LeagueHubVideoPlayer> {
  static const _maxAutoRetries = 3;

  PlaybackEngine? _engine;
  MediaUrlResolution? _resolution;
  Uri? _openedUri;
  PlaybackSnapshot _snapshot = const PlaybackSnapshot();
  String? _unsupported;
  bool _offline = false;
  int _attempt = 0;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _bind(initial: true);
  }

  @override
  void didUpdateWidget(covariant LeagueHubVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.identity != widget.source.identity) _bind();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _releaseEngine();
    super.dispose();
  }

  void _releaseEngine() {
    final engine = _engine;
    _engine = null;
    _openedUri = null;
    if (engine == null) return;
    engine.state.removeListener(_onEngineState);
    unawaited(engine.dispose());
  }

  /// Resolves the current source and opens it if it differs from what is already playing.
  void _bind({bool initial = false}) {
    _retryTimer?.cancel();
    _retryTimer = null;
    final service = ref.read(mediaPlaybackServiceProvider);
    final resolution = MediaUrlResolver(ref.read(apiClientProvider).baseUrl)
        .resolve(widget.source.playbackUrl);
    _resolution = resolution;
    _unsupported = service.unsupportedReason;
    _offline = !ref.read(syncControllerProvider).hasNetwork;

    final uri = resolution.uri;
    if (uri == null || _unsupported != null || _offline) {
      // Nothing to open (or offline: opened when connectivity returns).
      if (uri == null || _unsupported != null) _releaseEngine();
      _snapshot = const PlaybackSnapshot();
      if (!initial) setState(() {});
      return;
    }
    if (_openedUri == uri && _snapshot.phase != PlaybackPhase.error) {
      return; // no duplicate initialisation
    }

    final engine =
        _engine ??= service.createEngine()..state.addListener(_onEngineState);
    _openedUri = uri;
    _attempt = 0;
    unawaited(engine.open(uri, live: widget.source.live));
    if (!initial) setState(() {});
  }

  void _retryNow() {
    _attempt = 0;
    _openedUri = null;
    _bind();
  }

  void _onEngineState() {
    final engine = _engine;
    if (engine == null || !mounted) return;
    final s = engine.state.value;
    if (s.phase == PlaybackPhase.ready) _attempt = 0;
    final interrupted = s.phase == PlaybackPhase.error ||
        (s.phase == PlaybackPhase.ended && widget.source.live);
    if (interrupted && _retryTimer == null && _attempt < _maxAutoRetries) {
      _attempt++;
      final uri = _openedUri;
      _retryTimer = Timer(Duration(seconds: 1 << _attempt), () {
        _retryTimer = null;
        if (!mounted || uri == null || _engine == null || _offline) return;
        unawaited(_engine!.open(uri, live: widget.source.live));
      });
    }
    widget.videoVisible?.value = s.phase == PlaybackPhase.ready;
    setState(() => _snapshot = s);
  }

  _View get _view {
    if (_resolution?.playable != true) return _View.unavailable;
    if (_unsupported != null) return _View.unsupported;
    if (_offline) return _View.offline;
    switch (_snapshot.phase) {
      case PlaybackPhase.idle:
      case PlaybackPhase.opening:
        return _attempt > 0 ? _View.retrying : _View.connecting;
      case PlaybackPhase.ready:
        return _View.playing;
      case PlaybackPhase.ended:
        if (!widget.source.live) return _View.ended;
        return _retryTimer != null ? _View.retrying : _View.failed;
      case PlaybackPhase.error:
        return _retryTimer != null ? _View.retrying : _View.failed;
    }
  }

  String _failureMessage() {
    final parts = <String>[
      'The stream is offline or has not started. The broadcaster may not be live yet.',
    ];
    if (_resolution?.loopbackOnAndroid == true) {
      parts.add(
          'On Android, "localhost" means the phone itself. Set the server address in Settings to '
          "your computer's address (10.0.2.2 on the emulator).");
    }
    return parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(syncControllerProvider.select((s) => s.hasNetwork),
        (previous, hasNetwork) {
      if (hasNetwork == _offline) {
        _offline = !hasNetwork;
        if (hasNetwork) {
          _retryNow();
        } else {
          setState(() {});
        }
      }
    });

    final view = _view;
    final engine = _engine;
    final title = widget.source.title ?? 'Live stream';
    final ratio = _snapshot.aspectRatio ?? widget.aspectRatio;

    return Semantics(
      label: 'Video player: $title. ${_semanticState(view)}',
      container: true,
      child: AspectRatio(
        aspectRatio: ratio.clamp(0.5, 4.0).toDouble(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The surface stays mounted while reconnecting so the engine is not rebuilt.
                if (engine != null && _openedUri != null)
                  Positioned.fill(child: engine.buildView(context)),
                if (view == _View.playing && widget.source.live)
                  const Positioned(
                      left: AppSpacing.sm,
                      top: AppSpacing.sm,
                      child: _LiveBadge()),
                if (view != _View.playing)
                  Positioned.fill(child: _overlay(context, view)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _semanticState(_View view) => switch (view) {
        _View.unavailable => 'Stream unavailable.',
        _View.unsupported => 'Playback not supported on this device.',
        _View.offline => 'Offline.',
        _View.connecting => 'Connecting.',
        _View.playing => _snapshot.playing ? 'Playing.' : 'Paused.',
        _View.retrying => 'Reconnecting.',
        _View.failed => 'Stream offline.',
        _View.ended => 'Ended.',
      };

  Widget _overlay(BuildContext context, _View view) {
    switch (view) {
      case _View.unavailable:
        return _Placeholder(
          icon: Icons.videocam_off_outlined,
          title: 'Stream unavailable',
          message:
              _resolution?.problem ?? 'There is no video for this stream yet.',
        );
      case _View.unsupported:
        return _Placeholder(
            icon: Icons.desktop_access_disabled_outlined,
            title: 'Video not supported here',
            message: _unsupported!);
      case _View.offline:
        return _Placeholder(
          icon: Icons.cloud_off_outlined,
          title: 'You are offline',
          message: 'The stream will reconnect when your connection returns.',
          actionLabel: 'Retry',
          onAction: _retryNow,
        );
      case _View.connecting:
        return const _Busy(text: 'Connecting to the stream…');
      case _View.retrying:
        return _Busy(
            text:
                'Stream interrupted. Reconnecting (attempt $_attempt of $_maxAutoRetries)…');
      case _View.ended:
        return _Placeholder(
            icon: Icons.replay,
            title: 'Playback ended',
            message: null,
            actionLabel: 'Play again',
            onAction: _retryNow);
      case _View.failed:
        return _Placeholder(
          icon: Icons.portable_wifi_off,
          title: 'Stream offline',
          message: _failureMessage(),
          detail: _snapshot.error,
          actionLabel: 'Retry',
          onAction: _retryNow,
          secondaryLabel:
              _resolution?.loopbackOnAndroid == true ? 'Server settings' : null,
          onSecondary: _resolution?.loopbackOnAndroid == true
              ? () => context.push('/settings')
              : null,
        );
      case _View.playing:
        return const SizedBox.shrink();
    }
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: AppColors.live, borderRadius: BorderRadius.circular(6)),
        child: const Text('LIVE',
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 12)),
      );
}

class _Busy extends StatelessWidget {
  const _Busy({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                        color: AppColors.lime, strokeWidth: 3)),
                const SizedBox(height: AppSpacing.md),
                Text(text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white)),
              ],
            ),
          ),
        ),
      );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.title,
    required this.message,
    this.detail,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.navy,
      child: LayoutBuilder(builder: (context, c) {
        final compact = c.maxHeight < 200;
        return Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(compact ? AppSpacing.sm : AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: AppColors.lime, size: compact ? 28 : 40),
                SizedBox(height: compact ? AppSpacing.xs : AppSpacing.sm),
                Text(title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16)),
                if (message != null && !compact) ...[
                  const SizedBox(height: AppSpacing.xs),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Text(message!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70)),
                  ),
                ],
                if (detail != null && !compact) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(detail!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
                if (onAction != null || onSecondary != null) ...[
                  SizedBox(height: compact ? AppSpacing.xs : AppSpacing.md),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      if (onAction != null)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.lime,
                            foregroundColor: AppColors.navy,
                            minimumSize: const Size(48, 44),
                          ),
                          onPressed: onAction,
                          icon: const Icon(Icons.refresh),
                          label: Text(actionLabel ?? 'Retry'),
                        ),
                      if (onSecondary != null)
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white54),
                            minimumSize: const Size(48, 44),
                          ),
                          onPressed: onSecondary,
                          child: Text(secondaryLabel!),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      }),
    );
  }
}
