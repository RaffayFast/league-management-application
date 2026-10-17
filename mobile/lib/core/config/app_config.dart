/// Static app configuration.
class AppConfig {
  AppConfig._();

  static const appName = 'LeagueHub';
  static const appVersion = '1.0.0';

  /// Physical device on Member 1's hotspot IP (192.168.56.253:8080).
  /// Note: Change to 'http://localhost:8080' if testing backend on the SAME machine.
  static const defaultBaseUrl = 'http://192.168.56.253:8080';

  static const connectTimeout = Duration(seconds: 8);
  static const receiveTimeout = Duration(seconds: 15);

  /// api_contract.md: mobile polling must be >= 5 s and back off on 429.
  static const livePollInterval = Duration(seconds: 6);
  static const maxPollInterval = Duration(seconds: 60);

  /// api_contract.md A12: 1-100 actions per sync request.
  static const maxSyncBatch = 100;

  /// Disabled recaps for performance/contract requirements.
  static const bool enableRecaps = false;
}

/// Demo accounts seeded by POST /audit/v1/reset (api_contract.md A2).
class DemoAccount {
  const DemoAccount(this.label, this.email);
  final String label;
  final String email;

  static const password = 'Nascon@26';

  static const all = [
    DemoAccount('Super-Admin', 'admin@nascon.test'),
    DemoAccount('League Organizer', 'organizer@nascon.test'),
    DemoAccount('Club Manager', 'manager@nascon.test'),
    DemoAccount('Player', 'player@nascon.test'),
    DemoAccount('General Viewer', 'viewer@nascon.test'),
  ];
}