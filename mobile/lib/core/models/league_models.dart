import 'json.dart';

/// B2 league summary.
class League {
  const League(
      {required this.leagueId,
      required this.name,
      required this.sportId,
      this.tenantId});

  final String leagueId;
  final String name;
  final String sportId;
  final String? tenantId;

  factory League.fromJson(Json j) => League(
        leagueId: asString(j['league_id']),
        name: asString(j['name'], asString(j['league_id'])),
        sportId: asString(j['sport_id']),
        tenantId: asStringOrNull(j['tenant_id']),
      );
}

/// Match status values from the Score object (A7). Unknown values from a future
/// backend (postponed, abandoned, cancelled) are preserved and shown verbatim.
enum MatchStatus {
  upcoming,
  inProgress,
  completed,
  postponed,
  abandoned,
  cancelled,
  other
}

MatchStatus parseMatchStatus(String raw) => switch (raw) {
      'upcoming' || 'scheduled' => MatchStatus.upcoming,
      'in_progress' || 'live' => MatchStatus.inProgress,
      'completed' => MatchStatus.completed,
      'postponed' => MatchStatus.postponed,
      'abandoned' => MatchStatus.abandoned,
      'cancelled' || 'canceled' => MatchStatus.cancelled,
      _ => MatchStatus.other,
    };

String matchStatusLabel(MatchStatus s, [String raw = '']) => switch (s) {
      MatchStatus.upcoming => 'Upcoming',
      MatchStatus.inProgress => 'Live',
      MatchStatus.completed => 'Full time',
      MatchStatus.postponed => 'Postponed',
      MatchStatus.abandoned => 'Abandoned',
      MatchStatus.cancelled => 'Cancelled',
      MatchStatus.other => raw.isEmpty ? 'Unknown' : raw.replaceAll('_', ' '),
    };

/// B3 fixture row.
class Fixture {
  const Fixture({
    required this.matchId,
    required this.leagueId,
    this.homeTeamId,
    this.awayTeamId,
    this.homeName,
    this.awayName,
    required this.statusRaw,
    this.scheduledAt,
    required this.homeScore,
    required this.awayScore,
  });

  final String matchId;
  final String leagueId;
  final String? homeTeamId;
  final String? awayTeamId;
  final String? homeName;
  final String? awayName;
  final String statusRaw;
  final DateTime? scheduledAt;
  final int homeScore;
  final int awayScore;

  MatchStatus get status => parseMatchStatus(statusRaw);
  String get homeLabel => homeName ?? homeTeamId ?? 'TBD';
  String get awayLabel => awayName ?? awayTeamId ?? 'TBD';

  factory Fixture.fromJson(Json j, String leagueId) => Fixture(
        matchId: asString(j['match_id']),
        leagueId: leagueId,
        homeTeamId: asStringOrNull(j['home_team_id']),
        awayTeamId: asStringOrNull(j['away_team_id']),
        homeName: asStringOrNull(j['home_name']),
        awayName: asStringOrNull(j['away_name']),
        statusRaw: asString(j['status'], 'upcoming'),
        scheduledAt: DateTime.tryParse(asString(j['scheduled_at']))?.toUtc(),
        homeScore: asInt(j['home_score']),
        awayScore: asInt(j['away_score']),
      );
}

class FixturesResponse {
  const FixturesResponse({required this.leagueId, required this.fixtures});
  final String leagueId;
  final List<Fixture> fixtures;

  factory FixturesResponse.fromJson(Json j) {
    final id = asString(j['league_id']);
    return FixturesResponse(
        leagueId: id,
        fixtures: mapList(j['fixtures'], (f) => Fixture.fromJson(f, id)));
  }
}

enum QualificationStatus { clinched, eliminated, stillPossible, unknown }

QualificationStatus parseQualification(String raw) => switch (raw) {
      'clinched' => QualificationStatus.clinched,
      'eliminated' => QualificationStatus.eliminated,
      'still_possible' => QualificationStatus.stillPossible,
      _ => QualificationStatus.unknown,
    };

/// A8 standings row.
class StandingRow {
  const StandingRow({
    required this.rank,
    required this.teamId,
    required this.played,
    required this.won,
    required this.drawn,
    required this.lost,
    required this.scored,
    required this.conceded,
    required this.diff,
    required this.points,
    required this.fairPlay,
    required this.statusRaw,
    this.resolvedBy,
  });

  final int rank;
  final String teamId;
  final int played, won, drawn, lost, scored, conceded, diff, points, fairPlay;
  final String statusRaw;
  final String? resolvedBy;

  QualificationStatus get status => parseQualification(statusRaw);

  factory StandingRow.fromJson(Json j) => StandingRow(
        rank: asInt(j['rank']),
        teamId: asString(j['team_id']),
        played: asInt(j['played']),
        won: asInt(j['won']),
        drawn: asInt(j['drawn']),
        lost: asInt(j['lost']),
        scored: asInt(j['scored']),
        conceded: asInt(j['conceded']),
        diff: asInt(j['diff']),
        points: asInt(j['points']),
        fairPlay: asInt(j['fair_play']),
        statusRaw: asString(j['status']),
        resolvedBy: asStringOrNull(j['resolved_by']),
      );
}

class H2hEntry {
  const H2hEntry(
      {required this.played,
      required this.points,
      required this.scored,
      required this.conceded});
  final int played, points, scored, conceded;

  factory H2hEntry.fromJson(Json j) => H2hEntry(
        played: asInt(j['played']),
        points: asInt(j['points']),
        scored: asInt(j['scored']),
        conceded: asInt(j['conceded']),
      );
}

/// A8 Standings object, ordered by the server.
class StandingsResponse {
  const StandingsResponse({
    required this.leagueId,
    required this.sportId,
    required this.qualificationSpots,
    required this.table,
    required this.h2h,
  });

  final String leagueId;
  final String sportId;
  final int qualificationSpots;
  final List<StandingRow> table;
  final Map<String, Map<String, H2hEntry>> h2h;

  factory StandingsResponse.fromJson(Json j) {
    final h2h = <String, Map<String, H2hEntry>>{};
    asMap(j['h2h']).forEach((team, opps) {
      h2h[team] = asMap(opps)
          .map((opp, e) => MapEntry(opp, H2hEntry.fromJson(asMap(e))));
    });
    return StandingsResponse(
      leagueId: asString(j['league_id']),
      sportId: asString(j['sport_id']),
      qualificationSpots: asInt(j['qualification_spots']),
      table: mapList(j['table'], StandingRow.fromJson),
      h2h: h2h,
    );
  }
}
