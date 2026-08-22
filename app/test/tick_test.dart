import 'package:finswipe/models.dart';
import 'package:finswipe/ticks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Tick parses a quotes row, tolerating nulls', () {
    final t = Tick.fromJson({
      'symbol': 'TCS', 'kind': 'equity', 'name': 'TCS', 'price': 2302,
      'prev_close': 2298, 'change_pct': 0.17, 'currency': 'INR',
      'as_of': '2026-08-21T10:00:00+00:00', 'updated_at': null,
      'closes': [2313.2, null, 2302.0], 'meta': null,
    });
    expect(t.price, 2302.0);
    expect(t.changePct, 0.17);
    expect(t.up, isTrue);
    expect(t.closes, [2313.2, 2302.0]);
    expect(t.updatedAt, isNull);
    expect(t.meta, isEmpty);
    final bare = Tick.fromJson({'symbol': 'X', 'price': 1});
    expect(bare.changePct, isNull);
    expect(bare.up, isTrue); // unknown reads as flat, never red
  });

  test('fmtPct carries direction in the glyph', () {
    expect(fmtPct(1.234), '▲1.23%');
    expect(fmtPct(-0.8), '▼0.80%');
    expect(fmtPct(-0.8, decimals: 1), '▼0.8%');
    expect(fmtPct(null), '');
  });

  test('fmtNum groups Indian style and scales decimals', () {
    expect(fmtNum(142290), '1,42,290');
    expect(fmtNum(7395017), '73,95,017');
    expect(fmtNum(24252.0), '24,252');
    expect(fmtNum(2302.5), '2,302.50');
    expect(fmtNum(95.71), '95.71');
    expect(fmtNum(0.6018), '0.6018');
    expect(fmtNum(-1500.0), '-1,500.00');
    expect(fmtNum(4624.1, indian: false), '4,624.10');
    expect(fmtNum(1234567, indian: false), '1,234,567');
    expect(fmtMoney(142290, 'INR'), '₹1,42,290');
    expect(fmtMoney(4624.1, 'USD'), '\$4,624.10');
  });

  test('mergeTicks keeps earlier symbols and overwrites the same one', () {
    ticks.value = {};
    mergeTicks([Tick.fromJson({'symbol': 'A', 'price': 1})]);
    mergeTicks([
      Tick.fromJson({'symbol': 'B', 'price': 2}),
      Tick.fromJson({'symbol': 'A', 'price': 3}),
    ]);
    expect(ticks.value.keys.toSet(), {'A', 'B'});
    expect(ticks.value['A']!.price, 3);
    ticks.value = {};
  });
}
