import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Result of resolving a backend playback URL for this device.
class MediaUrlResolution {
  const MediaUrlResolution._(this.uri, this.problem,
      {this.rewrittenFrom, this.loopbackOnAndroid = false});

  const MediaUrlResolution.ok(Uri uri,
      {String? rewrittenFrom, bool loopbackOnAndroid = false})
      : this._(uri, null,
            rewrittenFrom: rewrittenFrom, loopbackOnAndroid: loopbackOnAndroid);

  const MediaUrlResolution.unavailable(String problem) : this._(null, problem);

  /// The URL to hand to the player; null when the source cannot be played.
  final Uri? uri;

  /// Why there is nothing to play, in words a viewer understands.
  final String? problem;

  /// The backend's original host when it was swapped for the configured server host.
  final String? rewrittenFrom;

  /// True when both the server and the media URL point at `localhost` on Android. That only works
  /// with `adb reverse`; the player uses it to explain a failure.
  final bool loopbackOnAndroid;

  bool get playable => uri != null;
}

/// The one place where backend playback URLs become URLs this device can reach.
///
/// The backend advertises HLS URLs built from its `MEDIA_HLS_BASE_URL`, which defaults to
/// `http://localhost:8888`. `localhost` is only correct on the machine running the stack. On the
/// Android emulator the host machine is `10.0.2.2`, and on a phone it is the laptop's LAN address.
/// The app already knows how it reaches the backend from the server address in Settings
/// ([apiBaseUrl]). So a loopback media host is replaced with that host, keeping the media scheme,
/// port and path. Media URLs that already name a real host are used unchanged.
class MediaUrlResolver {
  MediaUrlResolver(this.apiBaseUrl, {bool? isAndroid})
      : _isAndroid = isAndroid ?? (!kIsWeb && Platform.isAndroid);

  final String apiBaseUrl;
  final bool _isAndroid;

  static bool isLoopbackHost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' ||
        h == '::1' ||
        h == '0.0.0.0' ||
        h.startsWith('127.');
  }

  MediaUrlResolution resolve(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) {
      return const MediaUrlResolution.unavailable(
          'The server has not published a video address for this stream.');
    }
    final api = Uri.tryParse(apiBaseUrl.trim());
    var media = Uri.tryParse(text);
    if (media == null) {
      return const MediaUrlResolution.unavailable(
          'The server sent a video address the app cannot read.');
    }

    // Relative paths are served by the backend origin.
    if (!media.hasScheme) {
      if (api == null ||
          !api.hasScheme ||
          api.host.isEmpty ||
          !text.startsWith('/')) {
        return const MediaUrlResolution.unavailable(
            'The server sent a video address the app cannot read.');
      }
      media = api.resolveUri(media);
    }
    if ((media.scheme != 'http' && media.scheme != 'https') ||
        media.host.isEmpty) {
      return const MediaUrlResolution.unavailable(
          'The video address is not an http(s) stream.');
    }
    if (!media.path.toLowerCase().endsWith('.m3u8')) {
      return const MediaUrlResolution.unavailable(
          'The video address is not an HLS playlist (.m3u8).');
    }

    final apiHost = api?.host ?? '';
    if (isLoopbackHost(media.host) &&
        apiHost.isNotEmpty &&
        !isLoopbackHost(apiHost)) {
      return MediaUrlResolution.ok(media.replace(host: apiHost),
          rewrittenFrom: media.host);
    }
    return MediaUrlResolution.ok(
      media,
      loopbackOnAndroid: _isAndroid && isLoopbackHost(media.host),
    );
  }
}
