// 035: PriceChart paints drawings and places anchors from taps when a tool is armed.
import 'package:finflick/drawings.dart';
import 'package:finflick/price_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Bars _bars(int n) {
  final t0 = DateTime.utc(2026, 1, 1);
  final c = [for (var i = 0; i < n; i++) 100.0 + (i % 7) - 3];
  return (
    o: c,
    h: [for (final x in c) x + 1],
    l: [for (final x in c) x - 1],
    c: c,
    v: List.filled(n, 1000.0),
    t: [for (var i = 0; i < n; i++) t0.add(Duration(days: i))],
  );
}

void main() {
  testWidgets('paints every drawing kind without throwing', (t) async {
    final b = _bars(60);
    final ds = [
      Drawing(DrawKind.trend, [(b.t[5], 98), (b.t[40], 104)]),
      Drawing(DrawKind.hline, [(b.t[0], 101)]),
      Drawing(DrawKind.fib, [(b.t[10], 97), (b.t[30], 103)]),
      Drawing(DrawKind.rect, [(b.t[20], 99), (b.t[35], 102)]),
      Drawing(DrawKind.text, [(b.t[50], 100)], text: 'note'),
    ];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 360, height: 240, child: PriceChart(b, drawings: ds)))));
    expect(tester(t), isNotNull);
  });

  testWidgets('two taps with TREND armed produce one trendline', (t) async {
    final b = _bars(60);
    List<Drawing>? got;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 360,
                height: 240,
                child: PriceChart(b, tool: DrawKind.trend, onDrawingsChanged: (d) => got = d)))));
    // the chart also listens for double-taps, so a single tap is delivered
    // only after the double-tap window (300 ms) has passed
    await t.tapAt(const Offset(60, 80));
    await t.pump(const Duration(milliseconds: 400));
    expect(got, isNull); // one anchor pending
    await t.tapAt(const Offset(200, 120));
    await t.pump(const Duration(milliseconds: 400));
    expect(got, isNotNull);
    expect(got!.single.kind, DrawKind.trend);
    expect(got!.single.pts.length, 2);
    expect(got!.single.pts[1].$1.isAfter(got!.single.pts[0].$1), isTrue);
  });

  testWidgets('ERASE tap removes the drawing under the finger', (t) async {
    final b = _bars(60);
    final ds = [Drawing(DrawKind.hline, [(b.t[0], 100)])];
    List<Drawing>? got;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 360,
                height: 240,
                child: PriceChart(b, drawings: ds, tool: DrawKind.erase, onDrawingsChanged: (d) => got = d)))));
    await t.pump();
    // the level sits mid-scale (closes 97..103, level 100): tap along it
    final box = t.getRect(find.byType(PriceChart));
    await t.tapAt(Offset(box.left + 100, box.top + box.height * 0.42));
    await t.pump(const Duration(milliseconds: 400));
    expect(got, isNotNull);
    expect(got, isEmpty);
  });
}

WidgetTester tester(WidgetTester t) => t;
