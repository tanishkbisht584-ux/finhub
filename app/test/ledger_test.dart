import 'package:finswipe/ledger.dart';
import 'package:finswipe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _page(Widget w) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 360, child: SingleChildScrollView(child: w))));

void main() {
  testWidgets('LedgerRow trails share one right edge regardless of length',
      (tester) async {
    await tester.pumpWidget(_page(const Column(children: [
      LedgerRow(lead: 'A', main: 'short', trail: '1%'),
      LedgerRow(lead: 'B', main: 'long', trail: '+₹12,345 Cr'),
    ])));
    final r1 = tester.getRect(find.text('1%'));
    final r2 = tester.getRect(find.text('+₹12,345 Cr'));
    expect(r1.right, r2.right);
    expect(r1.width, 84);
    expect(r2.width, 84);
  });

  testWidgets('LedgerRow without lead has no 86px gutter', (tester) async {
    await tester.pumpWidget(_page(const LedgerRow(main: 'no lead', trail: 'x')));
    final main = tester.getRect(find.text('no lead'));
    // Row starts at the page edge (Scaffold body has no padding here).
    expect(main.left, lessThan(10));
  });

  testWidgets('LedgerRow bar and tap', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(_page(LedgerRow(
        main: 'bar row', trail: '42', bar: 0.42, onTap: () => tapped++)));
    expect(find.byType(FractionallySizedBox), findsOneWidget);
    await tester.tap(find.text('bar row'));
    expect(tapped, 1);
  });

  testWidgets('StatGrid of 5 tiles lays out 2 rows of 3', (tester) async {
    await tester.pumpWidget(_page(StatGrid([
      for (var i = 0; i < 5; i++) StatTile('l$i', 'v$i'),
    ])));
    expect(find.byType(StatTile), findsNWidgets(5));
    final r0 = tester.getRect(find.text('v0'));
    final r2 = tester.getRect(find.text('v2'));
    final r3 = tester.getRect(find.text('v3'));
    expect(r0.top, r2.top);
    expect(r3.top, greaterThan(r0.bottom));
    // Column 4 lands under column 1.
    expect(r3.left, r0.left);
  });

  testWidgets('ScaleBar clamps out-of-range values and draws marks',
      (tester) async {
    await tester.pumpWidget(_page(const Column(children: [
      ScaleBar(150, marks: [(30, '30'), (70, '70')], zones: [(0, 30, green)]),
      ScaleBar(-5, min: 0, max: 0),
    ])));
    expect(tester.takeException(), isNull);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('70'), findsOneWidget);
  });

  testWidgets('HeatCell shows dash for null and sub or bar', (tester) async {
    await tester.pumpWidget(_page(const Row(children: [
      Expanded(child: HeatCell('IT', null, sub: 'lvl')),
      Expanded(child: HeatCell('Bank', 1.234, bar: 0.6)),
      Expanded(child: HeatCell('Auto', -0.5, pctText: '−0.5 bp')),
      Expanded(child: HeatCell('Oil', -2.3)),
    ])));
    expect(find.text('—'), findsOneWidget);
    expect(find.text('lvl'), findsOneWidget);
    expect(find.text('+1.23%'), findsOneWidget);
    expect(find.text('−0.5 bp'), findsOneWidget);
    expect(find.text('−2.30%'), findsOneWidget);
  });

  testWidgets('Collapsible shows initial rows then all', (tester) async {
    await tester.pumpWidget(_page(Collapsible(
        [for (var i = 0; i < 8; i++) Text('row$i')], initial: 3)));
    expect(find.text('row2'), findsOneWidget);
    expect(find.text('row3'), findsNothing);
    await tester.tap(find.text('show all 8'));
    await tester.pump();
    expect(find.text('row7'), findsOneWidget);
    expect(find.text('show all 8'), findsNothing);
  });

  testWidgets('LedgerSection header, stamp, action, footnote', (tester) async {
    await tester.pumpWidget(_page(LedgerSection('flows',
        stamp: DateTime.utc(2026, 9, 4, 10, 0),
        action: const Text('ACT'),
        footnote: 'note',
        children: const [Text('child')])));
    expect(find.text('FLOWS'), findsOneWidget);
    expect(find.text('NSE · 15:30'), findsOneWidget);
    expect(find.text('ACT'), findsOneWidget);
    expect(find.text('note'), findsOneWidget);
    expect(find.text('child'), findsOneWidget);
  });
}
