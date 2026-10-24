import '../../../core/models/json.dart';
import '../../../core/network/api_exception.dart';
import 'chat_message.dart';

enum ModerationVerdict {
  approved,
  masked,

  /// Not broadcast (`200 {"status":"dropped","reason"}`).
  dropped,
}

/// What moderation means for the author's next messages in this room.
///
/// The live pipeline (services/moderation_service.py `moderate_live`) kicks the sender of a
/// profane message and mutes the sender of a flood or rate-limit violation. After that every post
/// in the room is dropped with `sender_blocked`.
enum SenderRestriction { none, muted, kicked, blocked }

/// The server's decision for one message sent with `POST /api/v1/chat`.
///
/// Built only from the server response. The app has no profanity rules of its own.
class ModerationOutcome {
  const ModerationOutcome._(this.verdict, this.reason, this.message);

  final ModerationVerdict verdict;
  final String? reason;

  /// The broadcast message (approved or masked); null when dropped.
  final ChatMessage? message;

  /// 201 = broadcast message, 200 = dropped. Anything else is not a moderation decision.
  factory ModerationOutcome.fromPostResponse(int status, dynamic body) {
    final j = asMap(body);
    if (status == 200 && j['status'] == 'dropped') {
      return ModerationOutcome._(
          ModerationVerdict.dropped, asStringOrNull(j['reason']), null);
    }
    if (status == 201) {
      final message = ChatMessage.tryParse(body);
      if (message == null) {
        throw ApiException.malformed(
            'The chat server sent an unreadable message');
      }
      return ModerationOutcome._(
        message.flagged ? ModerationVerdict.masked : ModerationVerdict.approved,
        message.reason,
        message,
      );
    }
    throw ApiException.malformed('Unexpected chat response ($status)');
  }

  SenderRestriction get restriction => switch ((verdict, reason)) {
        (ModerationVerdict.masked, _) => SenderRestriction.kicked,
        (ModerationVerdict.dropped, 'flood_character_repeat') =>
          SenderRestriction.muted,
        (ModerationVerdict.dropped, 'rate_limit_exceeded') =>
          SenderRestriction.muted,
        (ModerationVerdict.dropped, 'sender_blocked') =>
          SenderRestriction.blocked,
        _ => SenderRestriction.none,
      };

  /// Feedback for the author, or null when the message went out unchanged.
  String? get feedback => switch ((verdict, reason)) {
        (ModerationVerdict.approved, _) => null,
        (ModerationVerdict.masked, _) =>
          'Your message was posted with some words masked (***). Moderation has also removed you from '
              'posting in this chat.',
        (ModerationVerdict.dropped, 'flood_character_repeat') =>
          'Not sent: repeated characters such as "aaaa" or "!!!" count as flooding. You are now muted in this chat.',
        (ModerationVerdict.dropped, 'rate_limit_exceeded') =>
          'Not sent: more than 3 messages in 2 seconds is too fast. You are now muted in this chat.',
        (ModerationVerdict.dropped, 'sender_blocked') =>
          'Not sent: moderation has muted or removed you in this chat, so your messages are not broadcast.',
        (ModerationVerdict.dropped, _) =>
          'Not sent: moderation blocked this message${reason == null ? '' : ' ($reason)'}.',
      };
}

/// One judged message from the moderation probe.
class ProbeFilteredMessage {
  const ProbeFilteredMessage(
      {required this.messageId,
      required this.sender,
      required this.text,
      required this.flagged,
      this.reason});

  final String messageId;
  final String sender;
  final String text;
  final bool flagged;
  final String? reason;

  static ProbeFilteredMessage fromJson(Json j) => ProbeFilteredMessage(
        messageId: asString(j['message_id']),
        sender: asString(j['sender']),
        text: asString(j['text']),
        flagged: asBool(j['flagged']),
        reason: asStringOrNull(j['reason']),
      );
}

/// Response of the diagnostic `POST /audit/v1/moderation/test` (api_contract.md C6).
///
/// The probe judges a batch of messages and reports kick/mute decisions and the notification
/// dead-letter queue. It does not broadcast anything; live chat goes through `POST /api/v1/chat`.
class ModerationProbeResult {
  const ModerationProbeResult({
    required this.roomId,
    required this.filtered,
    required this.kickedUsers,
    required this.mutedUsers,
    required this.dlqDepth,
    required this.undeliveredEvents,
    required this.signature,
  });

  final String roomId;

  /// Messages that would be broadcast (masked where needed). Floods are absent: they are never broadcast.
  final List<ProbeFilteredMessage> filtered;
  final List<String> kickedUsers;
  final List<String> mutedUsers;
  final int dlqDepth;
  final int undeliveredEvents;

  /// Server signature over the result. Shown as received; the app never computes one.
  final String signature;

  int get flaggedCount => filtered.where((m) => m.flagged).length;

  static ModerationProbeResult fromJson(Json j) {
    final dlq = asMap(j['dlq_status']);
    return ModerationProbeResult(
      roomId: asString(j['chat_room_id']),
      filtered: mapList(j['filtered_messages'], ProbeFilteredMessage.fromJson),
      kickedUsers: asList(j['kicked_users']).whereType<String>().toList(),
      mutedUsers: asList(j['muted_users']).whereType<String>().toList(),
      dlqDepth: asInt(dlq['queue_depth']),
      undeliveredEvents: asList(dlq['undelivered_events']).length,
      signature: asString(j['signature']),
    );
  }
}
