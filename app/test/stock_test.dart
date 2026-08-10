import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/screens/stock.dart';

void main() {
  testWidgets('Sparkline paints without error for flat and normal series',
      (tester) async {
    for (final series in [<double>[100, 100, 100], <double>[95, 103, 99, 110]]) {
      await tester.pumpWidget(MaterialApp(
          home: SizedBox(width: 200, height: 64,
              child: Sparkline(series, const Color(0xFF3ECF8E)))));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Sparkline with a single point renders empty, no crash',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: SizedBox(width: 200, height: 64,
            child: Sparkline(const [100], Color(0xFF3ECF8E)))));
    expect(tester.takeException(), isNull);
  });
}
