import 'package:finflick/indicators.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixture generated from pipeline/market.py (compute_technicals / _ema) on
/// 26 Sep 2026 — the client must agree with the server to the rounding shown.
const closes = [100.4, 101.0463, 101.9215, 103.3176, 103.8368, 102.9855, 102.0705, 101.1704, 100.0504, 99.9994, 101.1833, 102.1963, 102.9622, 103.7303, 103.317, 101.8236, 100.8417, 100.3495, 100.0139, 100.8062, 102.3896, 103.1875, 103.3258, 103.249, 102.13, 100.5543, 100.0853, 100.3504, 100.7788, 102.0285, 103.4201, 103.4852, 102.8074, 102.1107, 100.8398, 99.7755, 100.1573, 101.1424, 101.9457, 103.0676, 103.7425, 102.8955, 101.6553, 100.8814, 100.0445, 99.8334, 101.0167, 102.3186, 102.9152, 103.3987, 103.1694, 101.679, 100.4388, 100.1551, 100.0847, 100.6761, 102.2499, 103.276, 103.1706, 102.8456];

void main() {
  test('SMA 20 / 50 match the pipeline and are null before the window fills', () {
    final s20 = sma(closes, 20), s50 = sma(closes, 50);
    expect(s20.last, closeTo(101.82235, 1e-5));
    expect(s50.last, closeTo(101.810038, 1e-5));
    expect(s20[18], isNull);
    expect(s20[19], isNotNull);
  });

  test('EMA 12 / 26 use the first-value seed like market._ema', () {
    expect(ema(closes, 12).last, closeTo(102.049907, 1e-5));
    expect(ema(closes, 26).last, closeTo(101.846125, 1e-5));
    expect(ema(closes, 12).first, closes.first);
  });

  test('Wilder RSI-14 equals the pipeline value', () {
    final r = rsi(closes);
    expect(r.last, closeTo(55.420338, 1e-5));
    expect(r[13], isNull);
    expect(r[14], isNotNull);
    expect(rsi([1, 2, 3, 4, 5]).every((v) => v == null), isTrue);
    expect(rsi(List.generate(20, (i) => 100.0 + i)).last, 100); // no losses
  });

  test('MACD line / signal / histogram match', () {
    final m = macd(closes);
    expect(m.line.last, closeTo(0.203782, 1e-5));
    expect(m.signal.last, closeTo(0.02864, 1e-5));
    expect(m.hist.last, closeTo(0.18, 0.005)); // pipeline rounds to 2 dp
  });

  test('Bollinger bands sit symmetrically around the SMA', () {
    final b = bollinger(closes);
    final i = closes.length - 1;
    expect(b.mid[i], closeTo(sma(closes, 20)[i]!, 1e-9));
    expect(b.upper[i]! - b.mid[i]!, closeTo(b.mid[i]! - b.lower[i]!, 1e-9));
    expect(b.upper[i]!, greaterThan(b.lower[i]!));
    expect(b.upper[18], isNull);
  });

  test('VWAP is cumulative typical price weighted by volume', () {
    final v = vwap([11, 12], [9, 10], [10, 11], [100, 300]);
    expect(v[0], 10);
    expect(v[1], closeTo((10 * 100 + 11 * 300) / 400, 1e-9));
    expect(vwap([1], [1], [1], [0])[0], isNull);
  });
}
