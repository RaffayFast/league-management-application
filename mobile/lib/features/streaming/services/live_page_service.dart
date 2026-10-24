import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/json.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/providers.dart';
import '../../cart/models/merch_offer.dart';

/// Data the backend renders into a Guest Web Player page.
class LivePageInfo {
  const LivePageInfo(
      {required this.playbackUrl,
      required this.offer,
      required this.chatRoomId});

  /// Backend playback URL (`MATCH_PLAYBACK_URL_TEMPLATE` for matches); null when the page has none.
  final String? playbackUrl;
  final MerchOffer? offer;
  final String? chatRoomId;
}

/// Reads the page data of the Guest Web Player routes, which need no account.
///
/// The match playback URL is only published there: `GET /web/matches/{id}/live` renders
/// `MATCH_PLAYBACK_URL_TEMPLATE` into `<script id="guest-boot" type="application/json">`, together
/// with the pinned merchandise offer. Reading it keeps the app on the server's configured URL
/// instead of a copy of the template.
class LivePageService {
  LivePageService(this._api);

  final ApiClient _api;

  static final _boot = RegExp(
    r'<script[^>]*id="guest-boot"[^>]*>(.*?)</script>',
    dotAll: true,
    caseSensitive: false,
  );

  Future<LivePageInfo> match(String matchId) => _load(
      '/web/matches/${Uri.encodeComponent(matchId)}/live', 'match $matchId');

  Future<LivePageInfo> costream(String sessionId) => _load(
      '/web/costream/${Uri.encodeComponent(sessionId)}',
      'co-stream $sessionId');

  Future<LivePageInfo> _load(String path, String what) async {
    final html = await _api.getText(path);
    return parseBoot(html, what);
  }

  /// Parses the boot JSON of a guest page. Throws [ApiException] (malformed) when it is missing.
  static LivePageInfo parseBoot(String html, String what) {
    final match = _boot.firstMatch(html);
    if (match == null) {
      throw ApiException.malformed('The $what page has no player data');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(match.group(1)!.trim());
    } on FormatException {
      throw ApiException.malformed('The $what page data is not valid JSON');
    }
    if (decoded is! Map) {
      throw ApiException.malformed('The $what page data is not an object');
    }
    final j = asMap(decoded);
    return LivePageInfo(
      playbackUrl: asStringOrNull(j['playback_url']),
      offer: MerchOffer.tryParse(j['offer']),
      chatRoomId: asStringOrNull(j['chat_room_id']),
    );
  }
}

final livePageServiceProvider =
    Provider((ref) => LivePageService(ref.watch(apiClientProvider)));

final liveMatchPageProvider =
    FutureProvider.autoDispose.family<LivePageInfo, String>(
  (ref, matchId) => ref.watch(livePageServiceProvider).match(matchId),
);

final liveCostreamPageProvider =
    FutureProvider.autoDispose.family<LivePageInfo, String>(
  (ref, sessionId) => ref.watch(livePageServiceProvider).costream(sessionId),
);
