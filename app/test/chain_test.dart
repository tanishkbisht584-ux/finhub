// 034: full F&O chain — the pure helpers and the section widget on a fixture.
import 'package:finflick/screens/stock_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _data = <String, dynamic>{
  'asof': '2026-09-25',
  'u': 2104.98,
  'lot': 225,
  'pcr': 1.23,
  'exp': [
    {
      'e': '2026-09-29',
      'fut': [2095.0, 2191.5, 6930000, 120000, 6930],
      'pcr': 1.23,
      's': [
        [2000.0, 10.0, 100, 5, 10, 12.0, 800, -3, 10],
        [2100.0, 10.0, 300, 5, 10, 12.0, 600, -3, 10],
        [2200.0, 10.0, 900, 5, 10, 12.0, 200, -3, 10],
      ],
    },
    {
      'e': '2026-10-27',
      'fut': [2106.9, 2202.7, 500, -20, 10],
      'pcr': null,
      's': [
        [2100.0, 40.0, 50, 100, 10, null, 0, 0, 0],
      ],
    },
  ],
};

void main() {
  test('chainStats: PCR, max OI strikes near the money, max pain', () {
    final s = strikesOf((_data['exp'] as List)[0] as Map<String, dynamic>);
    final st = chainStats(s, 2104.98);
    expect(st.pcr, closeTo(1600 / 1300, 1e-9));
    expect(st.maxCe, 2200);
    expect(st.maxPe, 2000);
    expect(st.maxPain, 2100);
    expect(chainStats(const [], null).pcr, isNull);
  });

  test('atmWindow keeps ±each strikes around the money', () {
    final s = [for (var k = 1000; k <= 3000; k += 100) <num?>[k, null, 1, 0, 0, null, 1, 0, 0]];
    final w = atmWindow(s, 2050, 3);
    expect(w.map((r) => r[0]).toList(), [1800, 1900, 2000, 2100, 2200, 2300]);
    expect(atmWindow(s, null, 3).length, s.length);
  });

  testWidgets('ChainSection: expiry pills switch the ladder, SHOW ALL toggles', (t) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ChainSection(_data)))));
    expect(find.text('29 Sep'), findsOneWidget);
    expect(find.text('27 Oct'), findsOneWidget);
    expect(find.text('2,200'), findsWidgets); // a strike on the nearest expiry
    expect(find.textContaining('Max pain'), findsOneWidget);
    await t.tap(find.text('27 Oct'));
    await t.pumpAndSettle();
    expect(find.text('2,200'), findsNothing); // only the 2,100 strike lives on the later expiry
    expect(find.text('2,100'), findsWidgets);
  });

  testWidgets('actionsTable renders kind labels and details', (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: actionsTable([
      {'ex': '2026-09-30', 'symbol': 'TCS', 'kind': 'bonus', 'detail': '1:1'},
      {'ex': '2026-09-21', 'symbol': 'BDL', 'kind': 'dividend', 'detail': '₹0.4'},
    ]))));
    expect(find.text('BONUS'), findsOneWidget);
    expect(find.text('₹0.4'), findsOneWidget);
    expect(find.text('TCS'), findsOneWidget);
  });
}
