import 'package:flutter_test/flutter_test.dart';
import 'package:leaguehub/core/models/auth_models.dart';
import 'package:leaguehub/core/models/club_models.dart';
import 'package:leaguehub/core/models/league_models.dart';
import 'package:leaguehub/core/models/match_models.dart';
import 'package:leaguehub/core/models/store_models.dart';
import 'package:leaguehub/core/models/sync_models.dart';

/// Payloads copied from api_contract.md examples.
void main() {
  test('B1 login response parses user, tenant and role', () {
    final r = LoginResponse.fromJson({
      'token': 'jwt',
      'token_type': 'Bearer',
      'expires_in': 3600,
      'user': {
        'user_id': 'user-manager',
        'email': 'manager@nascon.test',
        'name': 'Club Manager',
        'role': 'club_manager',
        'tenant_id': 'tenant-alpha',
        'club_id': 'club-alpha-1',
        'league_id': null,
        'player_id': null,
      },
      'tenant': {'tenant_id': 'tenant-alpha', 'name': 'Alpha Sports', 'logo_url': null, 'primary_color': '#0B5FFF'},
    });
    expect(r.user.role, UserRole.clubManager);
    expect(r.user.clubId, 'club-alpha-1');
    expect(r.user.leagueId, isNull);
    expect(r.tenant!.primaryColor, '#0B5FFF');
  });

  test('login response without token is malformed', () {
    expect(() => LoginResponse.fromJson({'user': {}}), throwsA(isA<Exception>()));
  });

  test('A7 score object parses teams, events and compensation flags', () {
    final s = ScoreObject.fromJson({
      'match_id': 'm1',
      'sport_id': 'football',
      'league_id': 'lg-1',
      'status': 'completed',
      'outcome': 'home_win',
      'winner_team_id': 't1',
      'tiebreak_winner_team_id': null,
      'home': {'team_id': 't1', 'score': 2, 'wickets': null, 'balls': null, 'overs': null, 'fair_play': 0},
      'away': {'team_id': 't2', 'score': 1, 'wickets': null, 'balls': null, 'overs': null, 'fair_play': -1},
      'version': 9,
      'events': [
        {
          'sequence': 3,
          'event_id': 'evt-3',
          'type': 'score',
          'payload': {'team_id': 't1', 'event_type': 'goal'},
          'signature': 'abc',
          'compensated': true,
          'compensated_by': 'evt-4',
        },
        {
          'sequence': 4,
          'event_id': 'evt-4',
          'type': 'score',
          'payload': {'team_id': 't2', 'event_type': 'goal'},
          'signature': 'def',
          'compensated': false,
          'compensated_by': null,
        },
      ],
      'home_name': 'Alpha FC',
      'pinned_product': {
        'product_id': 'prod-jersey-001',
        'name': 'Jersey',
        'variant_id': 'var-jersey-001-M',
        'price_minor': 450000,
        'currency': 'PKR',
      },
    });
    expect(s.status, MatchStatus.completed);
    expect(s.version, 9);
    expect(s.home.display, '2');
    expect(s.away.fairPlay, -1);
    expect(s.events.first.compensated, isTrue);
    expect(s.events.first.isCompensatable, isFalse);
    expect(s.events.last.isCompensatable, isTrue);
    expect(s.homeLabel, 'Alpha FC');
    expect(s.awayLabel, 't2');
    expect(s.pinnedProduct!.priceMinor, 450000);
  });

  test('innings TeamScore displays runs/wickets (overs)', () {
    final t = TeamScore.fromJson({'team_id': 'X', 'score': 142, 'wickets': 3, 'balls': 110, 'overs': '18.2', 'fair_play': 0});
    expect(t.display, '142/3 (18.2)');
  });

  test('sport config builds scoring options from scoring_events, per model', () {
    final sport = SportConfig.fromJson({
      'sport_id': 'kabaddi',
      'name': 'Kabaddi',
      'scoring_model': 'event',
      'scoring_events': {
        'raid_point': {'points': 1},
        'all_out': {'points': 2},
      },
    });
    expect(sport.scoringEvents.map((e) => e.key), ['raid_point', 'all_out']);
    expect(sport.scoringEvents.last.label, 'All Out');
    expect(sport.scoringEvents.last.describe('event'), '2 points');
    const wide = ScoringEventDef(key: 'wide', config: {'runs': 1, 'legal_ball': false, 'wicket': false});
    expect(wide.describe('innings'), '1 run · extra ball');
  });

  test('A8 standings keep server order and parse h2h', () {
    final st = StandingsResponse.fromJson({
      'league_id': 'lg-1',
      'sport_id': 'football',
      'qualification_spots': 2,
      'table': [
        {'rank': 1, 'team_id': 't1', 'played': 3, 'won': 2, 'drawn': 1, 'lost': 0, 'scored': 7, 'conceded': 2,
          'diff': 5, 'points': 7, 'fair_play': 0, 'status': 'clinched', 'resolved_by': null},
        {'rank': 2, 'team_id': 't2', 'played': 3, 'won': 0, 'drawn': 0, 'lost': 3, 'scored': 0, 'conceded': 7,
          'diff': -7, 'points': 0, 'fair_play': -2, 'status': 'eliminated', 'resolved_by': 'h2h_points'},
      ],
      'h2h': {
        't1': {'t2': {'played': 1, 'points': 3, 'scored': 2, 'conceded': 1}},
      },
    });
    expect(st.table.map((r) => r.teamId), ['t1', 't2']);
    expect(st.table.first.status, QualificationStatus.clinched);
    expect(st.table.last.status, QualificationStatus.eliminated);
    expect(st.h2h['t1']!['t2']!.points, 3);
  });

  test('B3 fixtures carry league id and nullable schedule', () {
    final f = FixturesResponse.fromJson({
      'league_id': 'league-alpha-1',
      'fixtures': [
        {'match_id': 'demo-m1', 'home_team_id': 'club-alpha-1', 'away_team_id': 'club-alpha-2', 'home_name': 'Alpha FC',
          'away_name': 'Beta United', 'status': 'in_progress', 'scheduled_at': null, 'home_score': 1, 'away_score': 0},
      ],
    });
    expect(f.fixtures.single.leagueId, 'league-alpha-1');
    expect(f.fixtures.single.status, MatchStatus.inProgress);
    expect(f.fixtures.single.scheduledAt, isNull);
  });

  test('A10 order + receipt parse', () {
    final o = OrderResponse.fromJson({
      'order_id': 'o1',
      'status': 'paid',
      'currency': 'PKR',
      'items': [
        {'variant_id': 'var-jersey-001-L', 'quantity': 2, 'unit_price_minor': 450000},
      ],
      'subtotal_minor': 900000,
      'discount_minor': 90000,
      'total_minor': 810000,
      'payment': {'authorization_id': 'auth_o1', 'capture_id': 'cap_o1', 'state': 'captured'},
      'receipt': {
        'payload': {
          'order_id': 'o1',
          'customer_id': 'cust-1',
          'items': [],
          'subtotal_minor': 900000,
          'discount_minor': 90000,
          'total_minor': 810000,
          'currency': 'PKR',
          'paid_at': '2026-10-17T11:20:05Z',
        },
        'signature': 'sig',
        'pdf_base64': 'JVBERi0=',
      },
    });
    expect(o.items.single.lineTotalMinor, 900000);
    expect(o.totalMinor, 810000);
    expect(o.receipt.payload.customerId, 'cust-1');
  });

  test('A9 transfer request always carries every contract field', () {
    const release = TransferRequest(
      requestId: 'tr-1',
      leagueId: 'lg-r1',
      playerId: 'p1',
      type: TransferType.release,
      fromSquadId: 'sq-a',
      toSquadId: 'sq-b', // must be dropped for release
      effectiveDate: '2026-10-10',
      loanEndDate: '2026-10-20', // must be dropped for non-loans
      reason: 'end of contract',
      requestedBy: 'manager@nascon.test',
    );
    final json = release.toJson();
    expect(json.keys.toSet(), {
      'request_id', 'league_id', 'player_id', 'type', 'from_squad_id', 'to_squad_id',
      'effective_date', 'loan_end_date', 'reason', 'requested_by',
    });
    expect(json['type'], 'release');
    expect(json['to_squad_id'], isNull);
    expect(json['loan_end_date'], isNull);
  });

  test('deferred transfer response is detected', () {
    final r = TransferResponse.fromJson({
      'request_id': 'rq3',
      'status': 'accepted',
      'state': 'deferred_until_match_end',
      'blocking_match_id': 'rm-1',
      'registration': null,
      'audit_entry': {'audit_id': 'aud-1', 'action': 'loan', 'player_id': 'p2', 'league_id': 'lg-r1',
        'from_squad_id': 'sq-a', 'to_squad_id': 'sq-b', 'effective_date': '2026-10-10',
        'state': 'deferred_until_match_end', 'who': 'admin', 'when': '2026-10-17T11:00:00Z', 'why': 'dev'},
    });
    expect(r.isDeferred, isTrue);
    expect(r.blockingMatchId, 'rm-1');
    expect(r.registration, isNull);
  });

  test('A12 sync response parses per-action results', () {
    final r = SyncResponse.fromJson({
      'device_id': 'dev-1',
      'results': [
        {'action_id': 'a1', 'status': 'applied', 'resolution': 'rebased_append', 'error_code': null,
          'processed_order': 1, 'server_version': 5, 'signature': 'x'},
        {'action_id': 'a2', 'status': 'rejected', 'resolution': 'server_wins', 'error_code': 'SQUAD_FULL',
          'processed_order': 2, 'server_version': null, 'signature': null},
      ],
      'summary': {'applied': 1, 'rejected': 1, 'duplicate': 0},
    });
    expect(r.results.first.isApplied, isTrue);
    expect(r.results.last.errorCode, 'SQUAD_FULL');
  });
}
