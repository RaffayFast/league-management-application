import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leaguehub/core/models/auth_models.dart';
import 'package:leaguehub/core/models/club_models.dart';
import 'package:leaguehub/core/network/api_exception.dart';
import 'package:leaguehub/core/network/error_messages.dart';
import 'package:leaguehub/core/util/formatters.dart';
import 'package:leaguehub/core/util/ids.dart';
import 'package:leaguehub/core/util/validators.dart';
import 'package:leaguehub/features/auth/permissions.dart';
import 'package:leaguehub/features/settings/server_settings_screen.dart';

AppUser _user(String role, {String? league, String? club, String? player}) => AppUser(
      userId: 'u',
      email: 'u@nascon.test',
      name: 'U',
      roleRaw: role,
      tenantId: 'tenant-alpha',
      leagueId: league,
      clubId: club,
      playerId: player,
    );

void main() {
  group('currency', () {
    test('minor units format with grouping and two decimals', () {
      expect(formatMoney(450000), 'PKR 4,500.00');
      expect(formatMoney(810000), 'PKR 8,100.00');
      expect(formatMoney(5), 'PKR 0.05');
      expect(formatMoney(123456789), 'PKR 1,234,567.89');
      expect(formatMoney(-90000), '-PKR 900.00');
    });

    test('quantity clamps to 1..10 and to stock', () {
      expect(clampQuantity(5, 1), 1);
      expect(clampQuantity(0, 5), 1);
      expect(clampQuantity(15, 50), 10);
      expect(clampQuantity(3, 0), 0);
    });
  });

  group('timestamps and ids', () {
    test('utcTimestamp uses the contract format', () {
      expect(utcTimestamp(DateTime.utc(2026, 10, 17, 11, 0, 5)), '2026-10-17T11:00:05Z');
      expect(isoDate(DateTime(2026, 1, 2)), '2026-01-02');
    });

    test('generated ids satisfy the contract id rule', () {
      for (final prefix in ['dev', 'act', 'evt', 'tr', 'ord']) {
        final id = newId(prefix);
        expect(isValidContractId(id), isTrue, reason: id);
        expect(id.length, lessThanOrEqualTo(64));
      }
    });
  });

  group('forms', () {
    test('login validation', () {
      expect(validateEmail(''), isNotNull);
      expect(validateEmail('not-an-email'), isNotNull);
      expect(validateEmail('viewer@nascon.test'), isNull);
      expect(validatePassword(''), isNotNull);
      expect(validatePassword('Nascon@26'), isNull);
    });

    test('server url validation', () {
      expect(validateServerUrl(''), isNotNull);
      expect(validateServerUrl('192.168.1.5:8080'), isNotNull);
      expect(validateServerUrl('http://10.0.2.2:8080'), isNull);
    });

    const window = TransferWindow(open: '2026-10-01', close: '2026-12-31');

    test('loan dates: end must follow start; window enforced', () {
      final errors = validateTransferForm(
        type: TransferType.loan,
        playerId: 'p1',
        fromSquadId: 'sq-a',
        toSquadId: 'sq-b',
        effectiveDate: '2027-01-05',
        loanEndDate: '2027-01-01',
        reason: 'dev',
        window: window,
      );
      expect(errors, hasLength(2));
      expect(errors.join(' '), contains('transfer window'));
      expect(errors.join(' '), contains('end after'));
    });

    test('transfer to same squad and missing reason are caught', () {
      final errors = validateTransferForm(
        type: TransferType.transfer,
        playerId: 'p1',
        fromSquadId: 'sq-a',
        toSquadId: 'sq-a',
        effectiveDate: '2026-10-10',
        loanEndDate: null,
        reason: ' ',
        window: window,
      );
      expect(errors, hasLength(2));
    });

    test('release needs no destination', () {
      final errors = validateTransferForm(
        type: TransferType.release,
        playerId: 'p1',
        fromSquadId: 'sq-a',
        toSquadId: null,
        effectiveDate: '2026-10-10',
        loanEndDate: null,
        reason: 'released',
        window: window,
      );
      expect(errors, isEmpty);
    });
  });

  group('roles', () {
    test('only own-league organizers and admins can score', () {
      expect(Permissions.canScore(_user('league_organizer', league: 'league-alpha-1'), 'league-alpha-1'), isTrue);
      expect(Permissions.canScore(_user('league_organizer', league: 'league-alpha-1'), 'league-alpha-2'), isFalse);
      expect(Permissions.canScore(_user('super_admin'), 'anything'), isTrue);
      expect(Permissions.canScore(_user('viewer'), 'league-alpha-1'), isFalse);
      expect(Permissions.canScore(_user('club_manager', club: 'c'), 'league-alpha-1'), isFalse);
    });

    test('roster management is limited to managers and admins', () {
      expect(Permissions.canManageRoster(_user('club_manager', club: 'club-alpha-1')), isTrue);
      expect(Permissions.canManageRoster(_user('viewer')), isFalse);
      expect(Permissions.canManageClub(_user('club_manager', club: 'club-alpha-1'), 'club-alpha-2'), isFalse);
    });

    test('dashboard actions are role specific', () {
      List<String> ids(AppUser u) => dashboardActionsFor(u).map((a) => a.id).toList();
      expect(ids(_user('viewer')), isNot(contains('roster')));
      expect(ids(_user('viewer')), isNot(contains('score')));
      expect(ids(_user('league_organizer', league: 'l')).first, 'score');
      expect(ids(_user('club_manager', club: 'c')).first, 'roster');
      expect(ids(_user('player', player: 'p', club: 'c')), containsAll(['me', 'club']));
      final managerRoster = dashboardActionsFor(_user('club_manager', club: 'c')).first;
      expect(managerRoster.route, '/roster');
      expect(managerRoster.icon, Icons.groups);
    });
  });

  group('error messages', () {
    test('known codes become plain English', () {
      expect(describeErrorCode('SQUAD_FULL'), contains('maximum size'));
      expect(describeErrorCode('TRANSFER_WINDOW_CLOSED'), contains('transfer window'));
      expect(describeErrorCode('PAYMENT_DECLINED'), contains('declined'));
      expect(describeErrorCode('MIN_POSITION_VIOLATION', details: const {'position': 'gk'}), contains('"gk"'));
      expect(describeErrorCode('VALIDATION_ERROR', details: const {'fields': ['effective_date']}), contains('effective date'));
    });

    test('unknown codes fall back to the server message', () {
      final e = ApiException.fromResponse(409, {
        'error': {'code': 'SOMETHING_NEW', 'message': 'Server says no', 'details': {}},
      });
      expect(friendlyError(e), 'Server says no');
    });
  });
}
