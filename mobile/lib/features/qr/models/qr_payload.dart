import '../../../core/deeplink/deep_link_service.dart';

enum QrPayloadKind {
  /// `nascon://entity/<id>` or `nascon://stream/<session_id>`.
  deepLink,

  /// A printed short link `http(s)://<host>/q/<code>` (or a relative `/q/<code>`, or a bare code).
  /// The server decides the destination at scan time with a 302.
  shortLink,

  /// A Guest Web Player page link such as `/web/matches/<id>/live`.
  webRoute,

  invalid,
}

/// A scanned or typed QR value, normalised once.
class QrPayload {
  const QrPayload._(this.raw, this.kind,
      {this.link, this.shortCode, this.problem});

  final String raw;
  final QrPayloadKind kind;

  /// The link to open for [QrPayloadKind.deepLink] and [QrPayloadKind.webRoute].
  final String? link;

  /// The code for [QrPayloadKind.shortLink].
  final String? shortCode;

  /// Why the value cannot be opened, for [QrPayloadKind.invalid].
  final String? problem;

  bool get isValid => kind != QrPayloadKind.invalid;

  static final _code = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$');

  /// The single normalisation step for camera detections and typed values.
  static QrPayload parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return QrPayload._(raw, QrPayloadKind.invalid,
          problem: 'Nothing to open.');
    }
    final uri = Uri.tryParse(text);
    if (uri == null) return _notOurs(raw);

    if (uri.scheme == 'nascon') {
      return routeForDeepLink(uri) == null
          ? QrPayload._(raw, QrPayloadKind.invalid,
              problem:
                  'This nascon:// link does not point to a match, stream, player or club.')
          : QrPayload._(raw, QrPayloadKind.deepLink, link: text);
    }
    if (uri.hasScheme && uri.scheme != 'http' && uri.scheme != 'https') {
      return _notOurs(raw);
    }

    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length == 2 &&
        segments.first == 'q' &&
        _code.hasMatch(segments[1])) {
      return QrPayload._(raw, QrPayloadKind.shortLink, shortCode: segments[1]);
    }
    if (segments.isNotEmpty && segments.first == 'web') {
      return routeForWebPath(text) == null
          ? QrPayload._(raw, QrPayloadKind.invalid,
              problem: 'The app has no screen for this page.')
          : QrPayload._(raw, QrPayloadKind.webRoute, link: text);
    }
    // A short code typed by hand, e.g. "m1-live" (server codes always contain a hyphen).
    if (!uri.hasScheme &&
        !text.contains('/') &&
        text.contains('-') &&
        _code.hasMatch(text)) {
      return QrPayload._(raw, QrPayloadKind.shortLink, shortCode: text);
    }
    return _notOurs(raw);
  }

  static QrPayload _notOurs(String raw) =>
      QrPayload._(raw, QrPayloadKind.invalid,
          problem: 'This is not a LeagueHub QR code.');
}
