import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/network/sse.dart';
import '../../../core/network/sse_connection.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/widgets/status_banner.dart';
import '../models/chat_message.dart';
import '../models/moderation_result.dart';
import '../services/live_chat_service.dart';

/// Feedback shown above the chat input.
class ChatNotice {
  const ChatNotice(this.tone, this.message, {this.requiresAuth = false});
  final StatusTone tone;
  final String message;

  /// The action needs an account: the panel offers the progressive sign-in sheet.
  final bool requiresAuth;
}

enum SendResult {
  /// Broadcast (possibly masked).
  sent,

  /// Moderation dropped it; the text stays in the input so it can be edited.
  rejected,

  /// The author must sign in first; the text stays in the input.
  needsAuth,

  /// Unknown outcome; kept in the outgoing list with Retry.
  unconfirmed,

  /// Rejected before or by validation; the text stays in the input.
  invalid,
}

class LiveChatState {
  const LiveChatState({
    this.messages = const [],
    this.outgoing = const [],
    this.connection = RealtimeStatus.connecting,
    this.connectionError,
    this.notice,
    this.restriction = SenderRestriction.none,
    this.skippedEvents = 0,
  });

  /// Broadcast messages, ordered by the room sequence, unique by message id.
  final List<ChatMessage> messages;

  /// The viewer's own messages that the server has not confirmed.
  final List<OutgoingChatMessage> outgoing;
  final RealtimeStatus connection;
  final String? connectionError;
  final ChatNotice? notice;
  final SenderRestriction restriction;

  /// Malformed events ignored so far (shown in diagnostics, never crashes the room).
  final int skippedEvents;

  LiveChatState copyWith({
    List<ChatMessage>? messages,
    List<OutgoingChatMessage>? outgoing,
    RealtimeStatus? connection,
    String? connectionError,
    bool clearConnectionError = false,
    ChatNotice? notice,
    bool clearNotice = false,
    SenderRestriction? restriction,
    int? skippedEvents,
  }) =>
      LiveChatState(
        messages: messages ?? this.messages,
        outgoing: outgoing ?? this.outgoing,
        connection: connection ?? this.connection,
        connectionError: clearConnectionError
            ? null
            : (connectionError ?? this.connectionError),
        notice: clearNotice ? null : (notice ?? this.notice),
        restriction: restriction ?? this.restriction,
        skippedEvents: skippedEvents ?? this.skippedEvents,
      );
}

/// One chat room: realtime subscription, moderated posting and the viewer's pending messages.
///
/// Auto-disposed with the screen; disposing closes the SSE connection.
class LiveChatController extends StateNotifier<LiveChatState> {
  LiveChatController(this._service, this.roomId)
      : super(const LiveChatState()) {
    if (!LiveChatService.isValidRoom(roomId)) {
      state = state.copyWith(
          connection: RealtimeStatus.failed,
          connectionError: 'This chat room id is not valid.');
      return;
    }
    _connection = _service.subscribe(roomId,
        onEvent: _onEvent, onStatus: _onStatus)
      ..start();
  }

  final LiveChatService _service;
  final String roomId;
  SseConnection? _connection;

  static const maxLength = 500;

  void reconnect() => _connection?.reconnectNow();

  void dismissNotice() => state = state.copyWith(clearNotice: true);

  // ------------------------------------------------------------------ realtime

  void _onStatus(RealtimeStatus status, Object? error) {
    if (!mounted) return;
    state = state.copyWith(
      connection: status,
      connectionError: error == null ? null : friendlyError(error),
      clearConnectionError: error == null,
    );
  }

  void _onEvent(SseEvent event) {
    if (!mounted) return;
    switch (event.event) {
      case 'history':
        final decoded = _decode(event.data);
        if (decoded == null) return;
        final (messages, skipped) = ChatMessage.parseHistory(decoded);
        _replaceAll(messages, skipped);
      case 'chat':
        final decoded = _decode(event.data);
        final message = decoded == null ? null : ChatMessage.tryParse(decoded);
        if (message == null) {
          state = state.copyWith(skippedEvents: state.skippedEvents + 1);
          return;
        }
        _upsert([message]);
      case 'reset':
        state = state.copyWith(
            messages: const [],
            outgoing: const [],
            restriction: SenderRestriction.none,
            clearNotice: true);
      default:
      // Unknown event types are ignored so a newer server cannot break older apps.
    }
  }

  Object? _decode(String data) {
    try {
      return jsonDecode(data);
    } on FormatException {
      state = state.copyWith(skippedEvents: state.skippedEvents + 1);
      return null;
    }
  }

  void _replaceAll(List<ChatMessage> messages, int skipped) {
    final byId = <String, ChatMessage>{
      for (final m in messages) m.messageId: m
    };
    state = state.copyWith(
      messages: _sorted(byId.values),
      outgoing:
          state.outgoing.where((o) => !byId.containsKey(o.messageId)).toList(),
      skippedEvents: state.skippedEvents + skipped,
    );
  }

  /// Adds or replaces by message id, so a reconnect's `history` and the post response never
  /// duplicate a message.
  void _upsert(List<ChatMessage> incoming) {
    final byId = <String, ChatMessage>{
      for (final m in state.messages) m.messageId: m
    };
    for (final m in incoming) {
      byId[m.messageId] = m;
    }
    final ids = incoming.map((m) => m.messageId).toSet();
    state = state.copyWith(
      messages: _sorted(byId.values),
      outgoing:
          state.outgoing.where((o) => !ids.contains(o.messageId)).toList(),
    );
  }

  static List<ChatMessage> _sorted(Iterable<ChatMessage> messages) {
    final list = messages.toList();
    list.sort((a, b) {
      final sa = a.sequence;
      final sb = b.sequence;
      if (sa != null && sb != null) return sa.compareTo(sb);
      final ta = a.sentAt;
      final tb = b.sentAt;
      if (ta != null && tb != null) return ta.compareTo(tb);
      return 0;
    });
    // The server keeps the latest 200 per room; the app keeps the same window.
    return list.length > 200 ? list.sublist(list.length - 200) : list;
  }

  // ------------------------------------------------------------------ posting

  /// Sends [rawText] for moderation. [signedIn] is the member session state; guests are asked to
  /// sign in before any request is made.
  Future<SendResult> send(String rawText, {required bool signedIn}) async {
    final text = rawText.trim();
    if (text.isEmpty) return SendResult.invalid;
    if (text.length > maxLength) {
      state = state.copyWith(
          notice: const ChatNotice(
              StatusTone.error, 'Messages can be at most 500 characters.'));
      return SendResult.invalid;
    }
    if (!signedIn) {
      state = state.copyWith(
          notice: const ChatNotice(
              StatusTone.info, 'Sign in or create an account to chat.',
              requiresAuth: true));
      return SendResult.needsAuth;
    }
    final messageId = LiveChatService.newMessageId();
    state = state.copyWith(
      outgoing: [
        ...state.outgoing,
        OutgoingChatMessage(
            messageId: messageId, text: text, state: OutgoingState.sending)
      ],
      clearNotice: true,
    );
    return _post(messageId, text);
  }

  Future<SendResult> _post(String messageId, String text) async {
    try {
      final outcome =
          await _service.post(roomId: roomId, text: text, messageId: messageId);
      if (!mounted) return SendResult.sent;
      return _applyOutcome(messageId, outcome);
    } on ApiException catch (e) {
      if (!mounted) return SendResult.unconfirmed;
      return _applyFailure(messageId, e);
    }
  }

  SendResult _applyOutcome(String messageId, ModerationOutcome outcome) {
    final feedback = outcome.feedback;
    final restriction = outcome.restriction;
    switch (outcome.verdict) {
      case ModerationVerdict.approved:
      case ModerationVerdict.masked:
        _upsert([outcome.message!]);
        state = state.copyWith(
          notice: feedback == null
              ? null
              : ChatNotice(StatusTone.warning, feedback),
          clearNotice: feedback == null,
          // The server just broadcast it, so the author is not blocked (masked: kicked from now on).
          restriction: restriction,
        );
        return SendResult.sent;
      case ModerationVerdict.dropped:
        state = state.copyWith(
          outgoing: _without(messageId),
          notice: ChatNotice(
              StatusTone.error, feedback ?? 'Not sent: blocked by moderation.'),
          restriction: restriction,
        );
        return SendResult.rejected;
    }
  }

  SendResult _applyFailure(String messageId, ApiException e) {
    final uncertain = e.isConnectivity || e.kind == ApiErrorKind.server;
    if (uncertain) {
      state = state.copyWith(outgoing: [
        for (final o in state.outgoing)
          if (o.messageId == messageId)
            o.copyWith(
              state: OutgoingState.unconfirmed,
              error:
                  'Not confirmed: ${friendlyError(e)} It may still appear; Retry checks the room first.',
            )
          else
            o,
      ]);
      return SendResult.unconfirmed;
    }
    final needsAuth = e.code == 'GUEST_WRITE_FORBIDDEN' ||
        e.code == 'UNAUTHENTICATED' ||
        e.statusCode == 401;
    state = state.copyWith(
      outgoing: _without(messageId),
      notice: ChatNotice(
        needsAuth ? StatusTone.info : StatusTone.error,
        needsAuth
            ? 'Your session has ended. Sign in to keep chatting.'
            : friendlyError(e),
        requiresAuth: needsAuth,
      ),
    );
    return needsAuth ? SendResult.needsAuth : SendResult.invalid;
  }

  List<OutgoingChatMessage> _without(String messageId) =>
      state.outgoing.where((o) => o.messageId != messageId).toList();

  /// Retries an unconfirmed message without risking a duplicate: the room is checked first, and
  /// the message is only re-sent (same id) when the server does not have it.
  Future<SendResult> retry(String messageId) async {
    final pending =
        state.outgoing.where((o) => o.messageId == messageId).firstOrNull;
    if (pending == null || pending.state != OutgoingState.unconfirmed) {
      return SendResult.invalid;
    }
    if (state.messages.any((m) => m.messageId == messageId)) {
      state = state.copyWith(outgoing: _without(messageId));
      return SendResult.sent;
    }
    state = state.copyWith(outgoing: [
      for (final o in state.outgoing)
        if (o.messageId == messageId)
          o.copyWith(state: OutgoingState.sending)
        else
          o,
    ]);
    try {
      final (history, _) = await _service.history(roomId);
      if (!mounted) return SendResult.invalid;
      final found = history.where((m) => m.messageId == messageId).firstOrNull;
      if (found != null) {
        _upsert([found]);
        return SendResult.sent;
      }
    } on ApiException catch (e) {
      if (!mounted) return SendResult.invalid;
      return _applyFailure(messageId, e); // still uncertain; nothing re-sent
    }
    return _post(messageId, pending.text);
  }

  void discard(String messageId) =>
      state = state.copyWith(outgoing: _without(messageId));

  @override
  void dispose() {
    unawaited(_connection?.close());
    super.dispose();
  }
}

/// One controller per room id, alive while a screen shows that room.
final liveChatControllerProvider = StateNotifierProvider.autoDispose
    .family<LiveChatController, LiveChatState, String>((ref, roomId) {
  final controller =
      LiveChatController(ref.watch(liveChatServiceProvider), roomId);
  ref.listen<bool>(syncControllerProvider.select((s) => s.hasNetwork),
      (previous, hasNetwork) {
    if (hasNetwork && previous == false) controller.reconnect();
  });
  return controller;
});
