import 'package:finflick/alerts.dart';
import 'package:finflick/models.dart';
import 'package:finflick/screens/alerts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Tick _tick(double price, double pct) => Tick.fromJson({
      'symbol': 'TCS',
      'kind': 'equity',
      'name': 'TCS',
      'price': price,
      'change_pct': pct,
      'currency': 'INR',
    });

PriceAlert _a(int id, String kind, {double? t, bool active = true, DateTime? fired}) => PriceAlert(
    id: id, symbol: 'TCS', kind: kind, threshold: t, active: active, createdAt: DateTime(2026, 9, 20), lastFiredAt: fired);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('alertLabel matches the pipeline title wording for all five kinds', () {
    expect(alertLabel('above', 4100), 'above ₹4,100.00');
    expect(alertLabel('below', 3999.5), 'below ₹3,999.50');
    expect(alertLabel('move', 2.5), 'moves 2.5% in a day');
    expect(alertLabel('move', 3), 'moves 3% in a day');
    expect(alertLabel('hi52', null), 'new 52-week high');
    expect(alertLabel('lo52', null), 'new 52-week low');
  });

  test('validateThreshold', () {
    expect(validateThreshold('above', ''), isNotNull);
    expect(validateThreshold('above', 'abc'), isNotNull);
    expect(validateThreshold('above', '0'), isNotNull);
    expect(validateThreshold('below', '-5'), isNotNull);
    expect(validateThreshold('move', '80'), contains('50%'));
    expect(validateThreshold('move', '3'), isNull);
    expect(validateThreshold('above', '4,100'), isNull);
    expect(validateThreshold('hi52', ''), isNull);
  });

  test('alreadyCrossed warns only when the rule is true right now', () {
    expect(alreadyCrossed('above', 100, _tick(105, 1)), contains('already above'));
    expect(alreadyCrossed('above', 110, _tick(105, 1)), isNull);
    expect(alreadyCrossed('below', 110, _tick(105, 1)), contains('already below'));
    expect(alreadyCrossed('move', 2, _tick(105, -2.5)), contains('already'));
    expect(alreadyCrossed('move', 3, _tick(105, -2.5)), isNull);
    expect(alreadyCrossed('hi52', null, _tick(105, 1)), isNull);
    expect(alreadyCrossed('above', 100, null), isNull);
  });

  testWidgets('AlertSheet: five pills, ADD disabled until valid, add + delete through the seams',
      (tester) async {
    final added = <(String, double?)>[];
    final deleted = <int>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AlertSheet('TCS',
                tick: _tick(4000, 0.5),
                initial: [_a(7, 'move', t: 3)],
                onAdd: (k, t) async => added.add((k, t)),
                onDelete: (id) async => deleted.add(id)))));
    await tester.pump();
    for (final l in ['ABOVE', 'BELOW', 'DAY MOVE %', '52W HIGH', '52W LOW']) {
      expect(find.text(l), findsOneWidget);
    }
    expect(find.textContaining('every 15 min'), findsOneWidget);
    // prefilled with the live price → ABOVE 4000 is not yet crossed, ADD is live
    expect(find.text('ADD'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '3900');
    await tester.pump();
    expect(find.textContaining('already above'), findsOneWidget);
    await tester.tap(find.text('ADD'));
    await tester.pump();
    expect(added, [('above', 3900.0)]);

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    await tester.tap(find.text('ADD'));
    await tester.pump();
    expect(added.length, 1); // disabled: nothing added

    // existing alert row with ×
    expect(find.text('moves 3% in a day'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(deleted, [7]);
    expect(find.text('moves 3% in a day'), findsNothing);
  });

  testWidgets('AlertsScreen lists armed and fired alerts and the history table', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: AlertsScreen(initialAlerts: [
      _a(1, 'above', t: 4100),
      _a(2, 'below', t: 3800, active: false, fired: DateTime.utc(2026, 9, 26, 6, 2)),
    ], initialFires: [
      (at: DateTime.utc(2026, 9, 26, 6, 2), symbol: 'TCS', kind: 'below', threshold: 3800, price: 3790.5),
    ])));
    await tester.pump();
    expect(find.text('armed'), findsOneWidget);
    expect(find.text('re-arm'), findsOneWidget);
    expect(find.textContaining('fired 11:32'), findsOneWidget);
    expect(find.text('HISTORY'), findsOneWidget);
    expect(find.text('3,790.50'), findsOneWidget);
  });

  testWidgets('AlertsScreen empty state', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AlertsScreen(initialAlerts: [], initialFires: [])));
    await tester.pump();
    expect(find.textContaining('tap the bell'), findsOneWidget);
  });
}
