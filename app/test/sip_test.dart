// P4: SIP arithmetic against the numbers every AMC calculator prints.
import 'package:finflick/sip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('₹10,000 a month at 12% for 10 years ≈ ₹23.2 L', () {
    final v = sipFuture(10000, 12, 120);
    expect(v, closeTo(2323391, 2000));
  });

  test('lumpsum ₹1 L at 10% for 5 years ≈ ₹1.645 L (monthly compounding)', () {
    expect(lumpsumFuture(100000, 10, 5), closeTo(164531, 300));
  });

  test('goal inverts the SIP', () {
    final need = sipForTarget(2323391, 12, 120);
    expect(need, closeTo(10000, 20));
  });

  test('step-up beats flat and invests more', () {
    final flat = sipFuture(10000, 12, 120);
    final up = stepUpSip(10000, 12, 120, 10);
    expect(up, greaterThan(flat));
    expect(investedIn(10000, 120, 10), greaterThan(1200000));
    expect(stepUpSip(10000, 12, 120, 0), closeTo(flat, 1));
    expect(investedIn(10000, 24, 0), 240000);
  });

  test('edge cases: zero rate and zero months', () {
    expect(sipFuture(500, 0, 12), 6000);
    expect(sipFuture(500, 12, 0), 0);
    expect(sipForTarget(1000, 12, 0), 0);
  });
}
