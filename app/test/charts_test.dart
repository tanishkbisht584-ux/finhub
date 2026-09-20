import 'package:finswipe/charts.dart';
import 'package:finswipe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _box(Widget w) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 300, height: 120, child: w)));

void main() {
  for (final (name, values) in [
    ('empty', <double?>[]),
    ('single', <double?>[5]),
    ('normal', <double?>[1, 3, 2, 4]),
    ('negative', <double?>[-2, 1, -1, 3]),
    ('with nulls', <double?>[1, null, 2, null]),
    ('all nulls', <double?>[null, null]),
  ]) {
    testWidgets('BarChart paints $name', (tester) async {
      await tester.pumpWidget(_box(BarChart(values,
          secondary: values, labels: [for (final _ in values) 'q'])));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Sparkline with fill, baseline and axis paints; Candles paint',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: SizedBox(
            width: 300,
            height: 140,
            child: Sparkline([2124.9, 2130.0, 2105.0], Color(0xFFE5484D),
                fill: true, baseline: 2190.0, axis: true))));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const MaterialApp(
        home: SizedBox(
            width: 300,
            height: 140,
            child: Candles([2175.0, 2110.0], [2175.0, 2112.0], [2116.7, 2104.0],
                [2124.9, 2105.0],
                baseline: 2190.0, axis: true))));
    expect(tester.takeException(), isNull);
    // fewer than two bars: nothing drawn, nothing thrown
    await tester.pumpWidget(const MaterialApp(
        home: SizedBox(
            width: 300, height: 140, child: Candles([1], [1], [1], [1]))));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Donut and Radar paint; Radar needs three spokes', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Center(
            child: Donut([(0.7177, Color(0xFFE8E6E3), 'Promoters 71.8%'), (0.0906, Color(0xFF9BA09C), 'FIIs 9.1%')],
                center: 'Jun 26'))));
    expect(tester.takeException(), isNull);
    expect(find.text('Jun 26'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(
        home: Center(
            child: Radar([('TCS', 761607.0), ('INFY', 426683.0), ('HCLTECH', 339018.0), ('WIPRO', null)],
                highlight: 0))));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const MaterialApp(home: Center(child: Radar([('A', 1.0), ('B', 2.0)]))));
    expect(tester.takeException(), isNull);
  });

  testWidgets('StackedBar skips zero segments and lists the rest',
      (tester) async {
    await tester.pumpWidget(_box(const StackedBar([
      (0.5, green, 'Promoters 50%'),
      (0.0, red, 'Govt 0%'),
      (0.5, amber, 'Public 50%'),
    ])));
    expect(find.text('Promoters 50%'), findsOneWidget);
    expect(find.text('Govt 0%'), findsNothing);
    expect(find.text('Public 50%'), findsOneWidget);
  });

  testWidgets('StackedBar with nothing live renders nothing', (tester) async {
    await tester.pumpWidget(_box(const StackedBar([(0, green, 'x')])));
    expect(find.text('x'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('LabeledLine renders one label per column and the values',
      (tester) async {
    await tester.pumpWidget(_box(const LabeledLine(
        [6.4, 6.6, 6.8], ['2Y', '5Y', '10Y'], ink,
        valueLabels: ['6.4%', '6.6%', '6.8%'])));
    expect(find.text('2Y'), findsOneWidget);
    expect(find.text('10Y'), findsOneWidget);
    expect(find.text('6.8%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (name, values) in [
    ('empty', <double>[]),
    ('flat', <double>[7, 7, 7]),
  ]) {
    testWidgets('LabeledLine paints $name', (tester) async {
      await tester.pumpWidget(
          _box(LabeledLine(values, [for (final _ in values) 'l'], ink)));
      expect(tester.takeException(), isNull);
    });
  }

  for (final (a, b) in [(10.0, 5.0), (0.0, 0.0), (3.0, 9.0)]) {
    testWidgets('PairedBar $a vs $b paints', (tester) async {
      await tester.pumpWidget(_box(PairedBar(a, b)));
      expect(tester.takeException(), isNull);
      expect(find.byType(FractionallySizedBox), findsNWidgets(2));
    });
  }
}
