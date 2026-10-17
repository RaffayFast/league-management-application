import 'json.dart';
import 'league_models.dart';

/// A7 TeamScore.
class TeamScore {
  const TeamScore({
    this.teamId,
    required this.score,
    this.wickets,
    this.balls,
    this.overs,
    required this.fairPlay,
  });

  final String? teamId;
  final int score;
  final int? wickets;
  final int? balls;
  final String? overs;
  final int fairPlay;

  factory TeamScore.fromJson(Json j) => TeamScore(
        teamId: asStringOrNull(j['team_id']),
        score: asInt(j['score']),
        wickets: asIntOrNull(j['wickets']),
        balls: asIntOrNull(j['balls']),
        overs: asStringOrNull(j['overs']),
        fairPlay: asInt(j['fair_play']),
      );

  /// "142/3 (18.2)" for innings sports, plain score otherwise.
  String get display {
    if (wickets != null) {
      return overs != null ? '$score/$wickets ($overs)' : '$score/$wickets';
    }
    return '$score';
  }
}

/// A7 event entry.
class MatchEvent {
  const MatchEvent({
    required this.sequence,
    required this.eventId,
    required this.type,
    required this.payload,
    required this.signature,
    required this.compensated,
    this.compensatedBy,
  });

  final int sequence;
  final String eventId;
  final String type;
  final Json payload;
  final String signature;
  final bool compensated;
  final String? compensatedBy;

  String? get teamId => asStringOrNull(payload['team_id']);
  String? get eventType => asStringOrNull(payload['event_type']);
  String? get compensates => asStringOrNull(payload['compensates']);

  /// score / discipline / tiebreak_winner can be corrected (A6 compensation).
  bool get isCompensatable =>
      !compensated && (type == 'score' || type == 'discipline' || type == 'tiebreak_winner');

  factory MatchEvent.fromJson(Json j) => MatchEvent(
        sequence: asInt(j['sequence']),
        eventId: asString(j['event_id']),
        type: asString(j['type']),
        payload: asMap(j['payload']),
        signature: asString(j['signature']),
        compensated: asBool(j['compensated']),
        compensatedBy: asStringOrNull(j['compensated_by']),
      );
}

class PinnedProduct {
  const PinnedProduct({
    required this.productId,
    required this.name,
    required this.variantId,
    required this.priceMinor,
    required this.currency,
  });

  final String productId;
  final String name;
  final String variantId;
  final int priceMinor;
  final String currency;

  factory PinnedProduct.fromJson(Json j) => PinnedProduct(
        productId: asString(j['product_id']),
        name: asString(j['name']),
        variantId: asString(j['variant_id']),
        priceMinor: asInt(j['price_minor']),
        currency: asString(j['currency'], 'PKR'),
      );
}

/// A7 Score object, extended by B4 with names and the pinned product.
class ScoreObject {
  const ScoreObject({
    required this.matchId,
    this.sportId,
    this.leagueId,
    required this.statusRaw,
    required this.outcome,
    this.winnerTeamId,
    this.tiebreakWinnerTeamId,
    required this.home,
    required this.away,
    required this.version,
    required this.events,
    this.homeName,
    this.awayName,
    this.pinnedProduct,
  });

  final String matchId;
  final String? sportId;
  final String? leagueId;
  final String statusRaw;
  final String outcome;
  final String? winnerTeamId;
  final String? tiebreakWinnerTeamId;
  final TeamScore home;
  final TeamScore away;
  final int version;
  final List<MatchEvent> events;
  final String? homeName;
  final String? awayName;
  final PinnedProduct? pinnedProduct;

  MatchStatus get status => parseMatchStatus(statusRaw);
  String get homeLabel => homeName ?? home.teamId ?? 'Home';
  String get awayLabel => awayName ?? away.teamId ?? 'Away';

  String teamName(String? teamId) {
    if (teamId == null) return 'Unknown team';
    if (teamId == home.teamId) return homeLabel;
    if (teamId == away.teamId) return awayLabel;
    return teamId;
  }

  factory ScoreObject.fromJson(Json j) {
    if (j['match_id'] is! String) throw MalformedResponse('score object without match_id');
    return ScoreObject(
      matchId: asString(j['match_id']),
      sportId: asStringOrNull(j['sport_id']),
      leagueId: asStringOrNull(j['league_id']),
      statusRaw: asString(j['status'], 'upcoming'),
      outcome: asString(j['outcome'], 'pending'),
      winnerTeamId: asStringOrNull(j['winner_team_id']),
      tiebreakWinnerTeamId: asStringOrNull(j['tiebreak_winner_team_id']),
      home: TeamScore.fromJson(asMap(j['home'])),
      away: TeamScore.fromJson(asMap(j['away'])),
      version: asInt(j['version']),
      events: mapList(j['events'], MatchEvent.fromJson),
      homeName: asStringOrNull(j['home_name']),
      awayName: asStringOrNull(j['away_name']),
      pinnedProduct: j['pinned_product'] is Map ? PinnedProduct.fromJson(asMap(j['pinned_product'])) : null,
    );
  }
}

/// One entry of a sport's `scoring_events` map. Its meaning depends on the
/// sport's scoring_model, never on the event name.
class ScoringEventDef {
  const ScoringEventDef({required this.key, required this.config});

  final String key;
  final Json config;

  String get label => key
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');

  String describe(String scoringModel) {
    switch (scoringModel) {
      case 'innings':
        final parts = <String>['${asInt(config['runs'])} run${asInt(config['runs']) == 1 ? '' : 's'}'];
        if (asBool(config['wicket'])) parts.add('wicket');
        if (!asBool(config['legal_ball'], true)) parts.add('extra ball');
        return parts.join(' · ');
      case 'round':
        final r = asInt(config['rounds'], 1);
        return '$r round${r == 1 ? '' : 's'}';
      default:
        final p = asInt(config['points'], 1);
        return '$p point${p == 1 ? '' : 's'}';
    }
  }
}

/// B5 sport configuration.
class SportConfig {
  const SportConfig({
    required this.sportId,
    required this.name,
    required this.scoringModel,
    required this.periods,
    required this.scoringEvents,
    required this.drawAllowed,
  });

  final String sportId;
  final String name;
  final String scoringModel;
  final Json periods;
  final List<ScoringEventDef> scoringEvents;
  final bool drawAllowed;

  factory SportConfig.fromJson(Json j) => SportConfig(
        sportId: asString(j['sport_id']),
        name: asString(j['name'], asString(j['sport_id'])),
        scoringModel: asString(j['scoring_model'], 'event'),
        periods: asMap(j['periods']),
        scoringEvents: asMap(j['scoring_events'])
            .entries
            .map((e) => ScoringEventDef(key: e.key, config: asMap(e.value)))
            .toList(),
        drawAllowed: asBool(j['draw_allowed'], true),
      );
}

/// A6 response.
class EventAck {
  const EventAck({
    required this.eventId,
    required this.matchId,
    required this.type,
    required this.sequence,
    required this.matchVersion,
    required this.signature,
  });

  final String eventId;
  final String matchId;
  final String type;
  final int sequence;
  final int matchVersion;
  final String signature;

  factory EventAck.fromJson(Json j) => EventAck(
        eventId: asString(j['event_id']),
        matchId: asString(j['match_id']),
        type: asString(j['type']),
        sequence: asInt(j['sequence']),
        matchVersion: asInt(j['match_version']),
        signature: asString(j['signature']),
      );
}
