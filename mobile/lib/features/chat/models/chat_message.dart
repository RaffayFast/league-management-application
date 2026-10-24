import '../../../core/models/json.dart';

/// How the server's moderation treated a message that is shown in the room.
enum ModerationStatus {
  /// Broadcast unchanged.
  approved,

  /// Broadcast with profanity replaced by `***` (`flagged: true`, reason `profanity_leetspeak`).
  masked,
}

/// One message the server accepted and broadcast to the room (`POST /api/v1/chat` 201, the
/// `history` and `chat` events of `GET /api/v1/chat/{room}/stream`).
///
/// [text] is always the server's moderated text; the app never shows its own copy as broadcast.
class ChatMessage {
  const ChatMessage({
    required this.messageId,
    required this.roomId,
    required this.sender,
    required this.text,
    this.sequence,
    this.sentAt,
    this.flagged = false,
    this.reason,
  });

  final String messageId;
  final String roomId;

  /// Account id of the author (the backend's JWT `sub`).
  final String sender;
  final String text;

  /// Increases by one per room; used for ordering.
  final int? sequence;
  final DateTime? sentAt;
  final bool flagged;

  /// Moderation reason code, e.g. `profanity_leetspeak`; null when nothing was changed.
  final String? reason;

  ModerationStatus get moderation =>
      flagged ? ModerationStatus.masked : ModerationStatus.approved;

  /// Parses one message; returns null instead of throwing when required fields are missing.
  static ChatMessage? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final j = asMap(raw);
    final id = asStringOrNull(j['message_id']);
    final text = asStringOrNull(j['text']);
    if (id == null || id.isEmpty || text == null) return null;
    final sentAt = asStringOrNull(j['sent_at']);
    return ChatMessage(
      messageId: id,
      roomId: asString(j['chat_room_id']),
      sender: asString(j['sender'], 'unknown'),
      text: text,
      sequence: asIntOrNull(j['sequence']),
      sentAt: sentAt == null ? null : DateTime.tryParse(sentAt),
      flagged: asBool(j['flagged']),
      reason: asStringOrNull(j['reason']),
    );
  }

  /// Parses a `{"chat_room_id", "messages": [...]}` envelope, skipping malformed entries.
  /// Returns the messages and how many entries were skipped.
  static (List<ChatMessage>, int) parseHistory(dynamic raw) {
    final list = asList(asMap(raw)['messages']);
    final out = <ChatMessage>[];
    var skipped = 0;
    for (final item in list) {
      final m = tryParse(item);
      if (m == null) {
        skipped++;
      } else {
        out.add(m);
      }
    }
    return (out, skipped);
  }
}

enum OutgoingState {
  /// Request in flight; the text has not passed moderation yet.
  sending,

  /// The request may or may not have reached the server (timeout, connection lost, 5xx).
  unconfirmed,
}

/// A message the viewer typed that the server has not accepted yet. Shown apart from the room's
/// messages and never styled as broadcast.
class OutgoingChatMessage {
  const OutgoingChatMessage(
      {required this.messageId,
      required this.text,
      required this.state,
      this.error});

  final String messageId;
  final String text;
  final OutgoingState state;
  final String? error;

  OutgoingChatMessage copyWith({OutgoingState? state, String? error}) =>
      OutgoingChatMessage(
          messageId: messageId,
          text: text,
          state: state ?? this.state,
          error: error);
}
