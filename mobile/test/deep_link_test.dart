import 'package:flutter_test/flutter_test.dart';
import 'package:leaguehub/core/deeplink/deep_link_service.dart';

void main() {
  test('match and co-stream links open the public live screens (Day 2 spec 6.3)', () {
    expect(routeForDeepLink(Uri.parse('nascon://entity/match-m1')), '/live/match/match-m1');
    expect(routeForDeepLink(Uri.parse('nascon://stream/cs-session-101')), '/live/costream/cs-session-101');
  });

  test('player and club links open their profiles', () {
    expect(routeForDeepLink(Uri.parse('nascon://entity/player-alpha-1')), '/player/player-alpha-1');
    expect(routeForDeepLink(Uri.parse('nascon://entity/club-alpha-1')), '/club/club-alpha-1');
  });

  test('foreign or malformed links are ignored', () {
    expect(routeForDeepLink(Uri.parse('https://example.com/entity/match-m1')), isNull);
    expect(routeForDeepLink(Uri.parse('nascon://entity')), isNull);
    expect(routeForDeepLink(Uri.parse('nascon://other/x')), isNull);
  });
}
