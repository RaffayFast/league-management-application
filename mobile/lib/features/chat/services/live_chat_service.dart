import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/sse.dart';
import '../../../core/network/sse_connection.dart';
import '../../../core/providers.dart';
import '../../../core/util/ids.dart';
import '../models/chat_message.dart';
import '../models/moderation_result.dart';

/// Chat transport on the shared [ApiClient] (api_contract.md C10).
///
/// - History: `GET /api/v1/chat/{room}` (public).
/// - Realtime: `GET /api/v1/chat/{room}/stream` (public SSE). It sends `history` first, then one
///   `chat` event per approved message, and `reset` after a server reset. The backend has no
///   WebSocket route, so SSE is the only realtime transport.
/// - Post: `POST /api/v1/chat` (member token). The server moderates synchronously: 201 means
///   broadcast (possibly masked), 200 `dropped` means not broadcast. Guest tokens get 403.
/// - Probe: `POST /audit/v1/moderation/test`, the diagnostic batch check. It is not a broadcast route.
class LiveChatService {
  LiveChatService(this._api);

  final ApiClient _api;

  static final _roomPattern = RegExp(r'^chat-[A-Za-z0-9_.:-]{1,59}$');

  static bool isValidRoom(String roomId) => _roomPattern.hasMatch(roomId);

  /// A client id lets the app recognise its own message when the stream delivers it.
  static String newMessageId() => newId('m');

  Future<(List<ChatMessage>, int)> history(String roomId) async {
    final data = await _api.get('/api/v1/chat/${Uri.encodeComponent(roomId)}',
        auth: false);
    return ChatMessage.parseHistory(data);
  }

  SseConnection subscribe(
    String roomId, {
    required void Function(SseEvent event) onEvent,
    required void Function(RealtimeStatus status, Object? error) onStatus,
  }) =>
      SseConnection(
        api: _api,
        path: '/api/v1/chat/${Uri.encodeComponent(roomId)}/stream',
        onEvent: onEvent,
        onStatus: onStatus,
      );

  /// Throws ApiException for 4xx/5xx and connectivity failures.
  Future<ModerationOutcome> post(
      {required String roomId,
      required String text,
      required String messageId}) async {
    final response = await _api.send(
      'POST',
      '/api/v1/chat',
      body: {'chat_room_id': roomId, 'text': text, 'message_id': messageId},
    );
    return ModerationOutcome.fromPostResponse(
        response.statusCode, response.data);
  }

  /// Runs the diagnostic moderation probe for [roomId] with synthetic senders.
  ///
  /// The probe records kick/mute decisions for the senders in that room, so callers must use a
  /// throwaway room and senders, never a real room or account.
  Future<ModerationProbeResult> probe(
      {required String roomId,
      required List<(String sender, String text)> messages}) async {
    final response = await _api.send(
      'POST',
      '/audit/v1/moderation/test',
      auth: false,
      body: {
        'chat_room_id': roomId,
        'incoming_messages': [
          for (var i = 0; i < messages.length; i++)
            {
              'message_id': 'probe-$i',
              'sender': messages[i].$1,
              'text': messages[i].$2
            },
        ],
        'check_dlq': true,
        'simulate_failed_notifications': 0,
      },
    );
    return parseOrThrow(
        response.data, ModerationProbeResult.fromJson, 'moderation probe');
  }
}

final liveChatServiceProvider =
    Provider((ref) => LiveChatService(ref.watch(apiClientProvider)));
