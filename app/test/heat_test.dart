import 'package:finswipe/heat.dart';
import 'package:finswipe/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('null and near-zero are neutral grey', () {
    expect(heatColor(null), border);
    expect(heatColor(0), border);
    expect(heatColor(0.05), border);
    expect(heatColor(-0.09), border);
  });

  test('sign picks green or red', () {
    expect(heatColor(1.0).r, green.r);
    expect(heatColor(-1.0).r, red.r);
  });

  test('alpha steps up monotonically across buckets', () {
    final alphas = [0.3, 0.8, 2.0, 5.0].map((p) => heatColor(p).a).toList();
    expect(alphas, [0.10, 0.18, 0.28, 0.40].map((a) => closeTo(a, 0.01)));
    for (var i = 1; i < alphas.length; i++) {
      expect(alphas[i], greaterThan(alphas[i - 1]));
    }
  });

  test('scale rescales the thresholds', () {
    // 2% is the top bucket at scale 3 but the bottom bucket at scale 30.
    expect(heatColor(2.0).a, closeTo(0.28, 0.01));
    expect(heatColor(2.0, scale: 30).a, closeTo(0.10, 0.01));
    expect(heatColor(40.0, scale: 30).a, closeTo(0.40, 0.01));
  });

  test('deltaHeat: missing or zero prev is grey, else pct change', () {
    expect(deltaHeat(10, null), border);
    expect(deltaHeat(null, 10), border);
    expect(deltaHeat(10, 0), border);
    expect(deltaHeat(108, 100, scale: 20).r, green.r); // +8%
    expect(deltaHeat(108, 100, scale: 20).a, closeTo(0.18, 0.01));
    expect(deltaHeat(90, 100, scale: 20).r, red.r);
    expect(deltaHeat(100, 100), border);
  });

  test('deltaHeat points mode compares raw difference', () {
    // OPM 16.1 -> 16.4 is +0.3 points, not +1.9%.
    expect(deltaHeat(16.4, 16.1, points: true).a, closeTo(0.10, 0.01));
    expect(deltaHeat(16.4, 16.1).a, closeTo(0.28, 0.01));
  });

  test('legend has nine swatches, red to green', () {
    final s = heatSwatches();
    expect(s.length, 9);
    expect(s[0].r, red.r);
    expect(s[4], border);
    expect(s[8].r, green.r);
    expect(s[8].a, closeTo(0.40, 0.01));
  });
}
