import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leaguehub/core/models/league_models.dart';
import 'package:leaguehub/core/theme/app_theme.dart';
import 'package:leaguehub/core/widgets/badges.dart';
import 'package:leaguehub/features/fixtures/widgets/fixture_card.dart';

Widget _wrap(Widget child) => MaterialApp(theme: buildAppTheme(), home: Scaffold(body: child));

void main() {
  testWidgets('qualification badges always carry text, not just colour', (tester) async {
    await tester.pumpWidget(_wrap(const Column(children: [
      QualificationBadge(status: QualificationStatus.clinched),
      QualificationBadge(status: QualificationStatus.eliminated),
      QualificationBadge(status: QualificationStatus.stillPossible),
    ])));
    expect(find.text('Clinched'), findsOneWidget);
    expect(find.text('Eliminated'), findsOneWidget);
    expect(find.text('Still possible'), findsOneWidget);
  });

  testWidgets('fixture card fits a 360dp phone and shows the live score', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const f = Fixture(
      matchId: 'demo-m2',
      leagueId: 'league-alpha-1',
      homeTeamId: 'club-alpha-1',
      awayTeamId: 'club-alpha-2',
      homeName: 'Alpha FC with a very long sponsored club name',
      awayName: 'Beta United',
      statusRaw: 'in_progress',
      homeScore: 1,
      awayScore: 0,
    );
    await tester.pumpWidget(_wrap(const Padding(padding: EdgeInsets.all(16), child: FixtureCard(fixture: f))));
    expect(tester.takeException(), isNull); // no RenderFlex overflow
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('Time to be confirmed'), findsOneWidget);
  });

  test('tenant colour parsing', () {
    expect(parseHexColor('#0B5FFF'), const Color(0xFF0B5FFF));
    expect(parseHexColor('nope'), isNull);
    expect(parseHexColor(null), isNull);
  });
}
