import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../core/deeplink/deep_link_service.dart';
import '../../../core/network/api_client.dart';
import '../../../core/providers.dart';
import '../models/qr_payload.dart';

/// A QR value that parsed but cannot be opened.
class QrOpenFailure implements Exception {
  const QrOpenFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Opens QR payloads through the app's single [DeepLinkService].
///
/// Short links are resolved by the server: `GET /q/{code}` answers 302 with the entity's current
/// Guest Web Player route, which [DeepLinkService] maps to the app screen. The printed host
/// (`PUBLIC_BASE_URL`, often `localhost`) is ignored. The request goes to the server configured
/// in Settings, the one this device can reach.
class QrScannerService {
  QrScannerService(this._api, this._links);

  final ApiClient _api;
  final DeepLinkService _links;

  /// `mobile_scanner` has camera implementations for Android, iOS, macOS and web, but not Windows.
  bool get cameraSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Opens [payload] and returns the app route. Throws [QrOpenFailure] or ApiException.
  Future<String> open(QrPayload payload,
      {LinkNavigation how = LinkNavigation.replace}) async {
    switch (payload.kind) {
      case QrPayloadKind.invalid:
        throw QrOpenFailure(
            payload.problem ?? 'This is not a LeagueHub QR code.');
      case QrPayloadKind.deepLink:
      case QrPayloadKind.webRoute:
        final route = _links.open(payload.link!, how: how);
        if (route == null) {
          throw const QrOpenFailure(
              'This link does not open a LeagueHub screen.');
        }
        return route;
      case QrPayloadKind.shortLink:
        final location = await _api
            .redirectLocation('/q/${Uri.encodeComponent(payload.shortCode!)}');
        final route = _links.open(location, how: how);
        if (route == null) {
          throw QrOpenFailure(
              'The code leads to $location, which the app cannot open.');
        }
        return route;
    }
  }
}

final qrScannerServiceProvider = Provider(
  (ref) => QrScannerService(
      ref.watch(apiClientProvider), ref.watch(deepLinkServiceProvider)),
);
