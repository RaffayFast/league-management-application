import 'json.dart';

class Venue {
  const Venue({required this.name, this.lat, this.lng});
  final String name;
  final double? lat;
  final double? lng;

  factory Venue.fromJson(Json j) =>
      Venue(name: asString(j['name']), lat: asDoubleOrNull(j['lat']), lng: asDoubleOrNull(j['lng']));
}

class StaffMember {
  const StaffMember({required this.name, required this.role});
  final String name;
  final String role;

  factory StaffMember.fromJson(Json j) => StaffMember(name: asString(j['name']), role: asString(j['role']));
}

class SeasonStat {
  const SeasonStat({required this.season, required this.played, required this.won, required this.drawn, required this.lost});
  final String season;
  final int played, won, drawn, lost;

  factory SeasonStat.fromJson(Json j) => SeasonStat(
        season: asString(j['season']),
        played: asInt(j['played']),
        won: asInt(j['won']),
        drawn: asInt(j['drawn']),
        lost: asInt(j['lost']),
      );
}

class ClubRosterEntry {
  const ClubRosterEntry({
    required this.playerId,
    required this.name,
    required this.position,
    required this.role,
    this.squadId,
    this.parentSquadId,
  });

  final String playerId;
  final String name;
  final String position;
  final String role;
  final String? squadId;
  final String? parentSquadId;

  bool get onLoan => parentSquadId != null;

  factory ClubRosterEntry.fromJson(Json j) => ClubRosterEntry(
        playerId: asString(j['player_id']),
        name: asString(j['name']),
        position: asString(j['position']),
        role: asString(j['role']),
        squadId: asStringOrNull(j['squad_id']),
        parentSquadId: asStringOrNull(j['parent_squad_id']),
      );
}

/// B6 club profile.
class Club {
  const Club({
    required this.clubId,
    required this.tenantId,
    required this.name,
    this.homeVenue,
    required this.social,
    required this.staff,
    required this.roster,
    required this.seasons,
  });

  final String clubId;
  final String tenantId;
  final String name;
  final Venue? homeVenue;
  final Map<String, String> social;
  final List<StaffMember> staff;
  final List<ClubRosterEntry> roster;
  final List<SeasonStat> seasons;

  factory Club.fromJson(Json j) => Club(
        clubId: asString(j['club_id']),
        tenantId: asString(j['tenant_id']),
        name: asString(j['name'], asString(j['club_id'])),
        homeVenue: j['home_venue'] is Map ? Venue.fromJson(asMap(j['home_venue'])) : null,
        social: asMap(j['social']).map((k, v) => MapEntry(k, asString(v))),
        staff: mapList(j['staff'], StaffMember.fromJson),
        roster: mapList(j['roster'], ClubRosterEntry.fromJson),
        seasons: mapList(j['seasons'], SeasonStat.fromJson),
      );
}

class SquadPlayer {
  const SquadPlayer({
    required this.playerId,
    required this.name,
    required this.position,
    required this.role,
    this.parentSquadId,
  });

  final String playerId;
  final String name;
  final String position;
  final String role;
  final String? parentSquadId;

  bool get onLoan => parentSquadId != null;

  factory SquadPlayer.fromJson(Json j) => SquadPlayer(
        playerId: asString(j['player_id']),
        name: asString(j['name']),
        position: asString(j['position']),
        role: asString(j['role']),
        parentSquadId: asStringOrNull(j['parent_squad_id']),
      );
}

class Squad {
  const Squad({required this.squadId, required this.clubId, required this.name, required this.players});

  final String squadId;
  final String clubId;
  final String name;
  final List<SquadPlayer> players;

  factory Squad.fromJson(Json j) => Squad(
        squadId: asString(j['squad_id']),
        clubId: asString(j['club_id']),
        name: asString(j['name'], asString(j['squad_id'])),
        players: mapList(j['players'], SquadPlayer.fromJson),
      );
}

class TransferWindow {
  const TransferWindow({required this.open, required this.close});
  final String open; // YYYY-MM-DD
  final String close;

  bool contains(String date) => open.compareTo(date) <= 0 && date.compareTo(close) <= 0;

  factory TransferWindow.fromJson(Json j) => TransferWindow(open: asString(j['open']), close: asString(j['close']));
}

/// B7 league roster.
class RosterResponse {
  const RosterResponse({
    required this.leagueId,
    required this.sportId,
    required this.transferWindow,
    required this.maxSquadSize,
    required this.requiredPositions,
    required this.squads,
  });

  final String leagueId;
  final String sportId;
  final TransferWindow transferWindow;
  final int maxSquadSize;
  final Map<String, int> requiredPositions;
  final List<Squad> squads;

  Squad? squad(String? id) {
    for (final s in squads) {
      if (s.squadId == id) return s;
    }
    return null;
  }

  factory RosterResponse.fromJson(Json j) => RosterResponse(
        leagueId: asString(j['league_id']),
        sportId: asString(j['sport_id']),
        transferWindow: TransferWindow.fromJson(asMap(j['transfer_window'])),
        maxSquadSize: asInt(j['max_squad_size']),
        requiredPositions: asMap(j['required_positions']).map((k, v) => MapEntry(k, asInt(v))),
        squads: mapList(j['squads'], Squad.fromJson),
      );
}

enum TransferType { transfer, loan, release }

/// A9 transfer request. Every field of the contract is always sent.
class TransferRequest {
  const TransferRequest({
    required this.requestId,
    required this.leagueId,
    required this.playerId,
    required this.type,
    required this.fromSquadId,
    this.toSquadId,
    required this.effectiveDate,
    this.loanEndDate,
    required this.reason,
    required this.requestedBy,
  });

  final String requestId;
  final String leagueId;
  final String playerId;
  final TransferType type;
  final String fromSquadId;
  final String? toSquadId;
  final String effectiveDate;
  final String? loanEndDate;
  final String reason;
  final String requestedBy;

  Json toJson() => {
        'request_id': requestId,
        'league_id': leagueId,
        'player_id': playerId,
        'type': type.name,
        'from_squad_id': fromSquadId,
        'to_squad_id': type == TransferType.release ? null : toSquadId,
        'effective_date': effectiveDate,
        'loan_end_date': type == TransferType.loan ? loanEndDate : null,
        'reason': reason,
        'requested_by': requestedBy,
      };
}

class Registration {
  const Registration({
    required this.playerId,
    required this.leagueId,
    this.squadId,
    this.parentSquadId,
    required this.registrationType,
    this.startDate,
    this.loanEndDate,
    required this.role,
  });

  final String playerId;
  final String leagueId;
  final String? squadId;
  final String? parentSquadId;
  final String registrationType;
  final String? startDate;
  final String? loanEndDate;
  final String role;

  factory Registration.fromJson(Json j) => Registration(
        playerId: asString(j['player_id']),
        leagueId: asString(j['league_id']),
        squadId: asStringOrNull(j['squad_id']),
        parentSquadId: asStringOrNull(j['parent_squad_id']),
        registrationType: asString(j['registration_type']),
        startDate: asStringOrNull(j['start_date']),
        loanEndDate: asStringOrNull(j['loan_end_date']),
        role: asString(j['role']),
      );
}

class AuditEntry {
  const AuditEntry({
    required this.auditId,
    required this.action,
    required this.playerId,
    required this.leagueId,
    this.fromSquadId,
    this.toSquadId,
    required this.effectiveDate,
    required this.state,
    required this.who,
    required this.when,
    required this.why,
  });

  final String auditId;
  final String action;
  final String playerId;
  final String leagueId;
  final String? fromSquadId;
  final String? toSquadId;
  final String effectiveDate;
  final String state;
  final String who;
  final String when;
  final String why;

  factory AuditEntry.fromJson(Json j) => AuditEntry(
        auditId: asString(j['audit_id']),
        action: asString(j['action']),
        playerId: asString(j['player_id']),
        leagueId: asString(j['league_id']),
        fromSquadId: asStringOrNull(j['from_squad_id']),
        toSquadId: asStringOrNull(j['to_squad_id']),
        effectiveDate: asString(j['effective_date']),
        state: asString(j['state']),
        who: asString(j['who']),
        when: asString(j['when']),
        why: asString(j['why']),
      );
}

/// A9 transfer response.
class TransferResponse {
  const TransferResponse({
    required this.requestId,
    required this.status,
    required this.state,
    this.blockingMatchId,
    this.registration,
    this.auditEntry,
  });

  final String requestId;
  final String status;
  final String state;
  final String? blockingMatchId;
  final Registration? registration;
  final AuditEntry? auditEntry;

  bool get isDeferred => state == 'deferred_until_match_end';

  factory TransferResponse.fromJson(Json j) => TransferResponse(
        requestId: asString(j['request_id']),
        status: asString(j['status']),
        state: asString(j['state']),
        blockingMatchId: asStringOrNull(j['blocking_match_id']),
        registration: j['registration'] is Map ? Registration.fromJson(asMap(j['registration'])) : null,
        auditEntry: j['audit_entry'] is Map ? AuditEntry.fromJson(asMap(j['audit_entry'])) : null,
      );
}

/// A9 roster history.
class RosterHistory {
  const RosterHistory({
    required this.playerId,
    required this.asOf,
    required this.leagueId,
    this.currentSquadId,
    this.parentSquadId,
    required this.history,
  });

  final String playerId;
  final String asOf;
  final String leagueId;
  final String? currentSquadId;
  final String? parentSquadId;
  final List<AuditEntry> history;

  factory RosterHistory.fromJson(Json j) => RosterHistory(
        playerId: asString(j['player_id']),
        asOf: asString(j['as_of']),
        leagueId: asString(j['league_id']),
        currentSquadId: asStringOrNull(j['current_squad_id']),
        parentSquadId: asStringOrNull(j['parent_squad_id']),
        history: mapList(j['history'], AuditEntry.fromJson),
      );
}
