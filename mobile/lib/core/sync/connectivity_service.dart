import 'package:connectivity_plus/connectivity_plus.dart';

/// Network-interface availability. Server reachability is tracked separately
/// from real API results (ApiClient.onReachability).
class ConnectivityService {
  ConnectivityService([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _hasNetwork(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  Future<bool> isOnline() async =>
      _hasNetwork(await _connectivity.checkConnectivity());

  Stream<bool> watch() =>
      _connectivity.onConnectivityChanged.map(_hasNetwork).distinct();
}
