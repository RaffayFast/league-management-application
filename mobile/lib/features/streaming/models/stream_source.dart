/// What a [StreamSource] plays.
enum StreamKind {
  /// A match broadcast (`.../live/<stream_key>/index.m3u8`).
  match,

  /// The server-side composite of a co-stream (`.../costream/<session_id>/index.m3u8`).
  costreamComposite,
}

/// A playable source as the backend described it.
///
/// [playbackUrl] is kept exactly as the server sent it. `MediaUrlResolver` turns it into a URL this
/// device can reach just before playback, so the model never stores a device-specific address.
class StreamSource {
  const StreamSource({
    required this.kind,
    required this.ownerId,
    required this.playbackUrl,
    this.hostId,
    this.title,
    this.live = true,
  });

  /// A match broadcast. [playbackUrl] comes from the Guest Web Player page data for the match.
  const StreamSource.match(
      {required String matchId, required String? playbackUrl, String? title})
      : this(
            kind: StreamKind.match,
            ownerId: matchId,
            playbackUrl: playbackUrl,
            title: title);

  /// The composite broadcast of a co-stream session (`composite_playback_url`).
  const StreamSource.costream(
      {required String sessionId,
      required String? playbackUrl,
      String? hostId,
      String? title})
      : this(
          kind: StreamKind.costreamComposite,
          ownerId: sessionId,
          playbackUrl: playbackUrl,
          hostId: hostId,
          title: title,
        );

  final StreamKind kind;

  /// Match id or co-stream session id.
  final String ownerId;

  /// URL from the backend; null when the backend has none to offer.
  final String? playbackUrl;

  /// Active host of a co-stream, for labels only. A host change does not change the composite URL,
  /// so it never forces the player to reopen.
  final String? hostId;

  final String? title;

  /// Live sources hide the seek bar and reconnect after the stream ends.
  final bool live;

  /// Two sources with the same identity are the same feed; the player only reopens when it changes.
  String get identity => '${kind.name}|$ownerId|${playbackUrl ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is StreamSource &&
      other.identity == identity &&
      other.hostId == hostId &&
      other.title == title;

  @override
  int get hashCode => Object.hash(identity, hostId, title);
}

enum PlaybackPhase {
  /// Nothing opened yet.
  idle,

  /// Connecting to the stream and reading the playlist.
  opening,

  /// Frames are available; [PlaybackSnapshot.playing] and [PlaybackSnapshot.buffering] refine it.
  ready,

  /// The stream ended (for a live source: the broadcaster stopped or the server restarted it).
  ended,

  error,
}

/// What a playback engine reports. Position is deliberately left out: the engines' own controls
/// draw progress, and leaving it out keeps screens from rebuilding several times a second.
class PlaybackSnapshot {
  const PlaybackSnapshot({
    this.phase = PlaybackPhase.idle,
    this.playing = false,
    this.buffering = false,
    this.aspectRatio,
    this.error,
  });

  final PlaybackPhase phase;
  final bool playing;
  final bool buffering;

  /// Width / height of the video once known.
  final double? aspectRatio;

  /// The engine's own error text (technical; the player widget explains it in plain words).
  final String? error;

  PlaybackSnapshot copyWith(
          {PlaybackPhase? phase,
          bool? playing,
          bool? buffering,
          double? aspectRatio,
          String? error}) =>
      PlaybackSnapshot(
        phase: phase ?? this.phase,
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        aspectRatio: aspectRatio ?? this.aspectRatio,
        error: error ?? this.error,
      );

  @override
  bool operator ==(Object other) =>
      other is PlaybackSnapshot &&
      other.phase == phase &&
      other.playing == playing &&
      other.buffering == buffering &&
      other.aspectRatio == aspectRatio &&
      other.error == error;

  @override
  int get hashCode =>
      Object.hash(phase, playing, buffering, aspectRatio, error);
}
