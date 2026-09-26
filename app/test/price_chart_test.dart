import 'package:finflick/models.dart';
import 'package:finflick/price_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Bars _bars(int n) {
  final c = List.generate(n, (i) => 100 + (i % 7) * 1.5 - (i % 3));
  return (
    o: [for (final v in c) v - 0.5],
    h: [for (final v in c) v + 1],
    l: [for (final v in c) v - 1],
    c: c,
    v: List.generate(n, (i) => 1000.0 + i * 10),
    t: List.generate(n, (i) => DateTime.utc(2026, 1, 1).add(Duration(days: i))),
  );
}

void main() {
  group('window maths', () {
    test('pan keeps the width and clamps at both ends', () {
      expect(panWindow(10, 20, 100, 5), (first: 5, last: 15));
      expect(panWindow(10, 20, 100, -5), (first: 15, last: 25));
      expect(panWindow(0, 10, 100, 5), (first: 0, last: 10));
      expect(panWindow(85, 95, 100, -50), (first: 89, last: 99));
    });

    test('zoom in halves the bars around the focus, zoom out never exceeds n', () {
      final z = zoomWindow(0, 99, 100, 2, 0.5);
      expect(z.last - z.first + 1, 50);
      expect(z.first, 25);
      final out = zoomWindow(25, 74, 100, 0.25, 0.5);
      expect((out.first, out.last), (0, 99));
      final tiny = zoomWindow(0, 99, 100, 50, 1.0);
      expect(tiny.last - tiny.first + 1, 10);
      expect(tiny.last, 99);
    });
  });

  test('barsOf falls back per series and sliceBars trims every series together', () {
    final q = Quote.fromChartJson({
      'chart': {
        'result': [
          {
            'meta': {'regularMarketPrice': 12.0, 'previousClose': 11.0},
            'timestamp': [1, 2, 3],
            'indicators': {
              'quote': [
                {
                  'close': [10.0, null, 12.0],
                  'open': [9.5, null, 11.5],
                  'high': [10.5, null, 12.5],
                  'low': [9.0, null, 11.0],
                  'volume': [100, null, null],
                }
              ]
            }
          }
        ]
      }
    });
    expect(q.volumes, [100.0, 0.0]);
    final b = barsOf(q);
    expect(b.c.length, 2);
    expect(b.v, [100.0, 0.0]);
    final s = sliceBars(b, 1);
    expect([s.o.length, s.h.length, s.l.length, s.c.length, s.v.length, s.t.length], everyElement(1));
  });

  testWidgets('every layer combination paints without error, including crosshair state', (tester) async {
    for (final layers in [
      <ChartLayer>{},
      {ChartLayer.candle, ChartLayer.vol},
      {ChartLayer.sma20, ChartLayer.sma50, ChartLayer.sma200, ChartLayer.ema21, ChartLayer.bb},
      {ChartLayer.rsi, ChartLayer.macd, ChartLayer.vol, ChartLayer.pivots, ChartLayer.div},
      ChartLayer.values.toSet(),
    ]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
                  width: 360,
                  child: PriceChart(_bars(260),
                      layers: layers,
                      baseline: 101,
                      pivots: const [('P', 101.0), ('R1', 104.0)],
                      dividendDates: [DateTime.utc(2026, 3, 1)],
                      secondary: List.generate(260, (i) => i < 30 ? null : 20 + (i % 5).toDouble()),
                      intraday: true)))));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$layers');
    }
    // hold shows the readout; double-tap resets
    await tester.longPressAt(tester.getCenter(find.byType(PriceChart)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(PriceChart));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(PriceChart));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // the double-tap recogniser's timer must expire before the tree is torn down
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a two-bar series and a one-bar series never crash', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PriceChart(_bars(2), layers: ChartLayer.values.toSet()))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PriceChart(_bars(1)))));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
