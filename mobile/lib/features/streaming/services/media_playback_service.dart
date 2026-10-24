import 'dart:async';
import 'dart:io' show Platform;

import 'package:chewie/chewie.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/app_theme.dart';
import '../models/stream_source.dart';

/// Platform-neutral HLS playback. Screens only see this interface, never a platform controller.
abstract class PlaybackEngine {
  /// Short name shown in diagnostics, e.g. "video_player + chewie".
  String get engineName;

  ValueListenable<PlaybackSnapshot> get state;

  /// Opens [uri]. A second call replaces the first; a superseded open never reports state.
  Future<void> open(Uri uri, {required bool live});

  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);

  /// The video surface with the engine's own controls (play/pause, seek, fullscreen).
  Widget buildView(BuildContext context);

  Future<void> dispose();
}

/// Picks the playback engine for this platform.
///
/// - Android (and iOS): `video_player` + `chewie`. ExoPlayer plays HLS natively.
/// - Windows: `media_kit` (libmpv). `video_player` has no Windows implementation, so it would
///   compile and then never play; libmpv plays HLS, including live playlists.
class MediaPlaybackService {
  MediaPlaybackService();

  static bool _windowsReady = false;
  static Object? _windowsInitError;

  /// Called once from main() before runApp. Loads libmpv on Windows. A failure is recorded and
  /// shown by every player instead of crashing the app.
  static void initializeForPlatform() {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      MediaKit.ensureInitialized();
      _windowsReady = true;
    } on Object catch (e) {
      _windowsInitError = e;
      debugPrint('media_kit failed to initialise: $e');
    }
  }

  bool get _useVideoPlayer => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  bool get _useMediaKit => !kIsWeb && Platform.isWindows;

  /// Null when this device can play HLS, otherwise the reason in plain words.
  String? get unsupportedReason {
    if (_useVideoPlayer) return null;
    if (_useMediaKit) {
      if (_windowsReady) return null;
      return 'The Windows video engine (libmpv) could not be loaded: ${_windowsInitError ?? 'not initialised'}.';
    }
    return 'Live video is available in the Android and Windows apps.';
  }

  String get engineName =>
      _useMediaKit ? 'media_kit (libmpv)' : 'video_player + chewie';

  PlaybackEngine createEngine() {
    final reason = unsupportedReason;
    if (reason != null) throw UnsupportedError(reason);
    return _useMediaKit
        ? MediaKitPlaybackEngine()
        : VideoPlayerPlaybackEngine();
  }
}

final mediaPlaybackServiceProvider =
    Provider<MediaPlaybackService>((ref) => MediaPlaybackService());

/// Android / iOS engine: ExoPlayer / AVPlayer through `video_player`, controls from `chewie`.
class VideoPlayerPlaybackEngine implements PlaybackEngine {
  final _state = ValueNotifier<PlaybackSnapshot>(const PlaybackSnapshot());
  VideoPlayerController? _video;
  ChewieController? _chewie;
  int _generation = 0;
  bool _disposed = false;

  @override
  String get engineName => 'video_player + chewie';

  @override
  ValueListenable<PlaybackSnapshot> get state => _state;

  bool _current(int generation) => !_disposed && generation == _generation;

  @override
  Future<void> open(Uri uri, {required bool live}) async {
    if (_disposed) return;
    final generation = ++_generation;
    await _release();
    if (!_current(generation)) return;
    _state.value = const PlaybackSnapshot(phase: PlaybackPhase.opening);

    final video =
        VideoPlayerController.networkUrl(uri, formatHint: VideoFormat.hls);
    String? failure;
    try {
      await video.initialize();
    } on PlatformException catch (e) {
      failure = e.message ?? e.code;
    } on Exception catch (e) {
      failure = e.toString();
    }
    if (!_current(generation)) {
      // Superseded or disposed while connecting: this controller was never shown.
      await video.dispose();
      return;
    }
    if (failure != null) {
      await video.dispose();
      if (_current(generation)) {
        _state.value =
            PlaybackSnapshot(phase: PlaybackPhase.error, error: failure);
      }
      return;
    }

    _video = video;
    video.addListener(_sync);
    _chewie = ChewieController(
      videoPlayerController: video,
      autoPlay: true,
      isLive: live,
      allowFullScreen: true,
      allowMuting: true,
      allowPlaybackSpeedChanging: !live,
      showOptions: !live,
      materialProgressColors: ChewieProgressColors(
        playedColor: AppColors.lime,
        handleColor: AppColors.lime,
        bufferedColor: Colors.white38,
        backgroundColor: Colors.white24,
      ),
      // The LeagueHub player draws its own error state over the video.
      errorBuilder: (context, message) => const SizedBox.shrink(),
    );
    _sync();
  }

  void _sync() {
    final video = _video;
    if (video == null || _disposed) return;
    final v = video.value;
    if (v.hasError) {
      _state.value = PlaybackSnapshot(
          phase: PlaybackPhase.error, error: v.errorDescription);
      return;
    }
    _state.value = PlaybackSnapshot(
      phase: v.isCompleted ? PlaybackPhase.ended : PlaybackPhase.ready,
      playing: v.isPlaying,
      buffering: v.isBuffering,
      aspectRatio: v.isInitialized && v.aspectRatio > 0 ? v.aspectRatio : null,
    );
  }

  Future<void> _release() async {
    final chewie = _chewie;
    final video = _video;
    _chewie = null;
    _video = null;
    video?.removeListener(_sync);
    chewie?.dispose(); // does not dispose the VideoPlayerController
    await video?.dispose();
  }

  @override
  Future<void> play() async => _video?.play();

  @override
  Future<void> pause() async => _video?.pause();

  @override
  Future<void> seekTo(Duration position) async => _video?.seekTo(position);

  @override
  Widget buildView(BuildContext context) {
    final chewie = _chewie;
    if (chewie == null) return const SizedBox.shrink();
    return Chewie(controller: chewie);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    await _release();
    _state.dispose();
  }
}

/// Windows engine: libmpv through `media_kit`, controls from `media_kit_video`.
class MediaKitPlaybackEngine implements PlaybackEngine {
  MediaKitPlaybackEngine() {
    _player = Player();
    _controller = VideoController(_player);
    _subs = [
      _player.stream.width.listen((_) => _syncVideoSize()),
      _player.stream.height.listen((_) => _syncVideoSize()),
      _player.stream.playing.listen(
          (playing) => _update(_state.value.copyWith(playing: playing))),
      _player.stream.buffering.listen(
          (buffering) => _update(_state.value.copyWith(buffering: buffering))),
      // Playback position moving forward also proves the stream plays (covers streams whose
      // video size arrives late). Equal snapshots are not re-published, so this is cheap.
      _player.stream.position.listen((position) {
        if (position > Duration.zero &&
            _state.value.phase == PlaybackPhase.opening) {
          _update(_state.value.copyWith(phase: PlaybackPhase.ready));
        }
      }),
      _player.stream.completed.listen((completed) {
        if (completed && _state.value.phase != PlaybackPhase.idle) {
          _update(_state.value
              .copyWith(phase: PlaybackPhase.ended, playing: false));
        }
      }),
      _player.stream.error.listen((message) {
        if (_state.value.phase == PlaybackPhase.idle) return;
        _update(PlaybackSnapshot(phase: PlaybackPhase.error, error: message));
      }),
    ];
  }

  late final Player _player;
  late final VideoController _controller;
  late final List<StreamSubscription<Object?>> _subs;
  final _state = ValueNotifier<PlaybackSnapshot>(const PlaybackSnapshot());
  bool _disposed = false;

  @override
  String get engineName => 'media_kit (libmpv)';

  @override
  ValueListenable<PlaybackSnapshot> get state => _state;

  void _update(PlaybackSnapshot next) {
    if (!_disposed) _state.value = next;
  }

  void _syncVideoSize() {
    final w = _player.state.width;
    final h = _player.state.height;
    if (w == null || h == null || w <= 0 || h <= 0) return;
    final current = _state.value;
    // The first decoded frame size means the stream is really playing, not just requested.
    final phase = current.phase == PlaybackPhase.opening
        ? PlaybackPhase.ready
        : current.phase;
    _update(current.copyWith(phase: phase, aspectRatio: w / h));
  }

  @override
  Future<void> open(Uri uri, {required bool live}) async {
    if (_disposed) return;
    _update(const PlaybackSnapshot(phase: PlaybackPhase.opening));
    await _player.open(Media(uri.toString()), play: true);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seekTo(Duration position) => _player.seek(position);

  @override
  Widget buildView(BuildContext context) =>
      Video(controller: _controller, fit: BoxFit.contain);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    await _player.dispose();
    _state.dispose();
  }
}
