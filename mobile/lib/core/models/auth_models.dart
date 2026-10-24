import 'json.dart';

enum UserRole {
  superAdmin,
  leagueOrganizer,
  clubManager,
  player,
  viewer,
  unknown
}

UserRole parseRole(String raw) => switch (raw) {
      'super_admin' => UserRole.superAdmin,
      'league_organizer' => UserRole.leagueOrganizer,
      'club_manager' => UserRole.clubManager,
      'player' => UserRole.player,
      'viewer' => UserRole.viewer,
      _ => UserRole.unknown,
    };

String roleLabel(UserRole role) => switch (role) {
      UserRole.superAdmin => 'Super-Admin',
      UserRole.leagueOrganizer => 'League Organizer',
      UserRole.clubManager => 'Club Manager',
      UserRole.player => 'Player',
      UserRole.viewer => 'Viewer',
      UserRole.unknown => 'Member',
    };

/// B1 user object.
class AppUser {
  const AppUser({
    required this.userId,
    required this.email,
    required this.name,
    required this.roleRaw,
    this.tenantId,
    this.clubId,
    this.leagueId,
    this.playerId,
  });

  final String userId;
  final String email;
  final String name;
  final String roleRaw;
  final String? tenantId;
  final String? clubId;
  final String? leagueId;
  final String? playerId;

  UserRole get role => parseRole(roleRaw);

  factory AppUser.fromJson(Json j) => AppUser(
        userId: asString(j['user_id']),
        email: asString(j['email']),
        name: asString(j['name']),
        roleRaw: asString(j['role']),
        tenantId: asStringOrNull(j['tenant_id']),
        clubId: asStringOrNull(j['club_id']),
        leagueId: asStringOrNull(j['league_id']),
        playerId: asStringOrNull(j['player_id']),
      );

  Json toJson() => {
        'user_id': userId,
        'email': email,
        'name': name,
        'role': roleRaw,
        'tenant_id': tenantId,
        'club_id': clubId,
        'league_id': leagueId,
        'player_id': playerId,
      };
}

class Tenant {
  const Tenant(
      {required this.tenantId,
      required this.name,
      this.logoUrl,
      this.primaryColor});

  final String tenantId;
  final String name;
  final String? logoUrl;
  final String? primaryColor;

  factory Tenant.fromJson(Json j) => Tenant(
        tenantId: asString(j['tenant_id']),
        name: asString(j['name']),
        logoUrl: asStringOrNull(j['logo_url']),
        primaryColor: asStringOrNull(j['primary_color']),
      );

  Json toJson() => {
        'tenant_id': tenantId,
        'name': name,
        'logo_url': logoUrl,
        'primary_color': primaryColor,
      };
}

/// B1 login response.
class LoginResponse {
  const LoginResponse({
    required this.token,
    required this.tokenType,
    required this.expiresIn,
    required this.user,
    this.tenant,
  });

  final String token;
  final String tokenType;
  final int expiresIn;
  final AppUser user;
  final Tenant? tenant;

  factory LoginResponse.fromJson(Json j) {
    final token = asString(j['token']);
    if (token.isEmpty || j['user'] is! Map) {
      throw MalformedResponse('login response is missing token or user');
    }
    return LoginResponse(
      token: token,
      tokenType: asString(j['token_type'], 'Bearer'),
      expiresIn: asInt(j['expires_in'], 3600),
      user: AppUser.fromJson(asMap(j['user'])),
      tenant: j['tenant'] is Map ? Tenant.fromJson(asMap(j['tenant'])) : null,
    );
  }
}

/// A persisted, authenticated session. The password is never stored.
class Session {
  const Session(
      {required this.token,
      required this.user,
      this.tenant,
      required this.expiresAt});

  final String token;
  final AppUser user;
  final Tenant? tenant;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  Session copyWith({AppUser? user, Tenant? tenant}) => Session(
      token: token,
      user: user ?? this.user,
      tenant: tenant ?? this.tenant,
      expiresAt: expiresAt);

  Json toJson() => {
        'token': token,
        'user': user.toJson(),
        'tenant': tenant?.toJson(),
        'expires_at': expiresAt.toIso8601String(),
      };

  factory Session.fromJson(Json j) => Session(
        token: asString(j['token']),
        user: AppUser.fromJson(asMap(j['user'])),
        tenant: j['tenant'] is Map ? Tenant.fromJson(asMap(j['tenant'])) : null,
        expiresAt: DateTime.tryParse(asString(j['expires_at']))?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}
