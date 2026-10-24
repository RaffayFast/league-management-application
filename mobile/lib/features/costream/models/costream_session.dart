import '../../../core/models/json.dart';

/// The four contract layouts (api_contract.md C5).
enum CostreamLayout {
  solo('solo', 1),
  grid2('grid_2', 2),
  grid4('grid_4', 4),
  spotlight('spotlight', 4);

  const CostreamLayout(this.wire, this.capacity);

  /// Value used by the API.
  final String wire;

  /// Participants the layout can show (services/costream_service.py LAYOUT_CAPACITY).
  final int capacity;

  static CostreamLayout? parse(String? raw) {
    for (final l in values) {
      if (l.wire == raw) return l;
    }
    return null;
  }

  String get label => switch (this) {
        CostreamLayout.solo => 'Solo',
        CostreamLayout.grid2 => 'Side by side',
        CostreamLayout.grid4 => 'Four-way grid',
        CostreamLayout.spotlight => 'Spotlight',
      };
}

/// Public co-stream view: `GET /api/v1/live/costream/{session_id}`.
///
/// The backend publishes one composite stream per session. Participant feeds are publish-only
/// (reading `costream/<session>/<player>` is refused), so there are no per-participant URLs here.
class CostreamSession {
  const CostreamSession({
    required this.sessionId,
    required this.status,
    required this.activeHost,
    required this.participants,
    required this.layout,
    required this.layoutRaw,
    required this.participantCount,
    required this.compositePlaybackUrl,
    required this.chatRoomId,
  });

  final String sessionId;

  /// `active` or `terminated`.
  final String status;
  final String? activeHost;

  /// Active participants in the server's order (the composite tiles follow this order).
  final List<String> participants;

  /// Null when the server sent a layout this app does not know.
  final CostreamLayout? layout;
  final String layoutRaw;
  final int participantCount;
  final String? compositePlaybackUrl;

  /// The single shared room for every host and viewer (`chat-<session_id>`).
  final String chatRoomId;

  bool get isActive => status == 'active';

  static CostreamSession fromJson(Json j) {
    final id = asStringOrNull(j['session_id']);
    if (id == null || id.isEmpty) {
      throw MalformedResponse('Co-stream view has no session_id');
    }
    final participants =
        asList(j['active_participants']).whereType<String>().toList();
    final layoutRaw = asString(j['layout']);
    return CostreamSession(
      sessionId: id,
      status: asString(j['status'], 'unknown'),
      activeHost: asStringOrNull(j['active_host']),
      participants: participants,
      layout: CostreamLayout.parse(layoutRaw),
      layoutRaw: layoutRaw,
      participantCount: asInt(j['participant_count'], participants.length),
      compositePlaybackUrl: asStringOrNull(j['composite_playback_url']),
      chatRoomId: asString(j['chat_room_id'], 'chat-$id'),
    );
  }
}

/// A host change observed between two server snapshots. The app never decides a handoff itself.
class HostHandoff {
  const HostHandoff({required this.from, required this.to, required this.at});
  final String from;
  final String? to;
  final DateTime at;
}
