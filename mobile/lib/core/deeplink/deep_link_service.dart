import 'package:flutter/services.dart';

/// Maps nascon:// links (Day 2 spec 6.3) to app routes.
///
/// - nascon://stream/<session_id>  -> the public co-stream screen
/// - nascon://entity/<id>          -> match-* opens the public live match screen; player-* and club-* open
///                                    their profiles. The id families come from Day 2 FR-4.1.
/// The /live/* routes need no account, so a deep link never stops on the login screen.
String? routeForDeepLink(Uri uri) {
  if (uri.scheme != 'nascon') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;
  final id = Uri.encodeComponent(segments.first);
  switch (uri.host) {
    case 'stream':
      return '/live/costream/$id';
    case 'entity':
      if (id.startsWith('player-')) return '/player/$id';
      if (id.startsWith('club-')) return '/club/$id';
      if (id.startsWith('cs-')) return '/live/costream/$id';
      return '/live/match/$id';
    default:
      return null;
  }
}

/// Maps a Guest Web Player route to the app screen for the same entity.
///
/// These are the routes `GET /q/{code}` redirects to (services/qr_resolver.py), and the page links a
/// viewer may paste: `/web/matches/<id>/live|preview|vod|notice`, `/web/players/<id>`,
/// `/web/clubs/<id>` and `/web/costream/<id>`. Accepts a path or a full http(s) URL on any host.
String? routeForWebPath(String pathOrUrl) {
  final uri = Uri.tryParse(pathOrUrl.trim());
  if (uri == null) return null;
  if (uri.hasScheme && uri.scheme != 'http' && uri.scheme != 'https') {
    return null;
  }
  final s = uri.pathSegments.where((e) => e.isNotEmpty).toList();
  if (s.length < 3 || s.first != 'web') return null;
  final id = Uri.encodeComponent(s[2]);
  switch (s[1]) {
    case 'matches':
      return '/live/match/$id';
    case 'costream':
      return '/live/costream/$id';
    case 'players':
      return '/player/$id';
    case 'clubs':
      return '/club/$id';
    default:
      return null;
  }
}

/// The single link-to-route mapping used by platform deep links, QR scans and pasted links.
String? routeForLink(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null) return null;
  if (uri.scheme == 'nascon') return routeForDeepLink(uri);
  return routeForWebPath(link);
}

/// How a resolved route is opened.
enum LinkNavigation {
  /// Replace the whole stack (platform deep links).
  go,

  /// Open on top of the current screen.
  push,

  /// Replace the current screen, e.g. the QR scanner with the scanned destination.
  replace,
}

/// Listens to MainActivity's "leaguehub/deeplinks" channel and opens each link through [_navigate].
///
/// [open] is the same entry point for in-app sources (QR scanner, pasted links), so there is one
/// router for every kind of link.
class DeepLinkService {
  DeepLinkService(this._navigate);

  final void Function(String route, LinkNavigation how) _navigate;
  static const _channel = MethodChannel('leaguehub/deeplinks');
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLink' && call.arguments is String) {
        open(call.arguments as String);
      }
    });
    try {
      final initial = await _channel.invokeMethod<String>('getInitialLink');
      if (initial != null) open(initial);
    } on MissingPluginException {
      // Not on Android (desktop, web, widget tests): there are no platform deep links.
    } on PlatformException {
      // Channel unavailable this launch; links arriving later still use onLink.
    }
  }

  /// Opens a `nascon://` link or a Guest Web Player link. Returns the app route, or null when the
  /// link is not a LeagueHub link (nothing is opened then).
  String? open(String link, {LinkNavigation how = LinkNavigation.go}) {
    final route = routeForLink(link);
    if (route != null) _navigate(route, how);
    return route;
  }
}
