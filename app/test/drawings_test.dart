// 035: chart drawings — JSON round trip, fib levels, hit-testing on a linear mapping.
import 'dart:ui';

import 'package:finflick/drawings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 1);
  final t1 = DateTime.utc(2026, 9, 20);
  // 10 px per day, 2 px per rupee, y grows downward from 1000 at price 0
  Offset toPx(DateTime t, double p) => Offset(t.difference(t0).inDays * 10.0, 1000 - p * 2);

  test('JSON round trip keeps kind, anchors (second precision) and text', () {
    final ds = [
      Drawing(DrawKind.trend, [(t0, 100), (t1, 120)]),
      Drawing(DrawKind.text, [(t1, 110)], text: 'breakout?'),
    ];
    final back = decodeDrawings(encodeDrawings(ds));
    expect(back.length, 2);
    expect(back[0].kind, DrawKind.trend);
    expect(back[0].pts[1], (t1, 120.0));
    expect(back[1].text, 'breakout?');
    expect(decodeDrawings('garbage'), isEmpty);
    expect(decodeDrawings('[{"k":"erase","a":[[1,2]]},{"k":"hline","a":[]}]'), isEmpty);
  });

  test('fibLevels spans a..b at the standard ratios', () {
    final f = fibLevels(100, 200);
    expect(f.first, (0.0, 100.0));
    expect(f.last, (1.0, 200.0));
    expect(f[3], (0.5, 150.0));
    expect(f.length, 7);
  });

  test('hitTest picks the nearest drawing within tolerance, misses otherwise', () {
    final ds = [
      Drawing(DrawKind.hline, [(t0, 100)]),                 // y = 800
      Drawing(DrawKind.trend, [(t0, 100), (t1, 120)]),      // from (0,800) to (190,760)
      Drawing(DrawKind.rect, [(t0, 50), (t1, 60)]),         // y 900..880, x 0..190
      Drawing(DrawKind.fib, [(t0, 200), (t1, 300)]),        // levels y 600..400
    ];
    expect(hitTest(ds, toPx, const Offset(300, 803)), 0);       // near the level, far along x
    expect(hitTest(ds, toPx, const Offset(95, 780)), 1);        // on the trendline midpoint
    expect(hitTest(ds, toPx, const Offset(100, 890)), 2);       // inside the box
    expect(hitTest(ds, toPx, const Offset(100, 500)), 3);       // the 0.5 fib level (y = 500)
    expect(hitTest(ds, toPx, const Offset(100, 700)), isNull);
    expect(nearestAnchor(ds[1], toPx, const Offset(180, 770)), 1);
  });

  test('withAnchor moves one anchor only', () {
    final d = Drawing(DrawKind.trend, [(t0, 100), (t1, 120)]);
    final m = d.withAnchor(1, (t1, 130));
    expect(m.pts[0], (t0, 100.0));
    expect(m.pts[1], (t1, 130.0));
    expect(anchorsFor(DrawKind.fib), 2);
    expect(anchorsFor(DrawKind.text), 1);
  });
}
