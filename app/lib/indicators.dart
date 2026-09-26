import 'dart:math' as math;

/// Client-side indicator math (Phase D, 26 Sep 2026), mirroring
/// pipeline/market.py compute_technicals so the header tiles and the chart
/// panes never disagree: SMA over the last n, EMA seeded on the first value,
/// Wilder RSI-14 seeded on the first 15 closes, MACD 12/26/9. Every series is
/// aligned with the input (null where the window is not full yet).

List<double?> sma(List<double> c, int n) {
  final out = List<double?>.filled(c.length, null);
  var sum = 0.0;
  for (var i = 0; i < c.length; i++) {
    sum += c[i];
    if (i >= n) sum -= c[i - n];
    if (i >= n - 1) out[i] = sum / n;
  }
  return out;
}

/// Same seed as market._ema: the first close, then k = 2/(n+1).
List<double?> ema(List<double> c, int n) {
  if (c.isEmpty) return const [];
  final k = 2 / (n + 1);
  final out = List<double?>.filled(c.length, null);
  var e = c[0];
  out[0] = e;
  for (var i = 1; i < c.length; i++) {
    e = c[i] * k + e * (1 - k);
    out[i] = e;
  }
  return out;
}

/// Wilder RSI: first average over closes[0..14], then smoothed. Value at i
/// covers closes[0..i]; null before 15 closes.
List<double?> rsi(List<double> c, [int n = 14]) {
  final out = List<double?>.filled(c.length, null);
  if (c.length < n + 1) return out;
  var g = 0.0, l = 0.0;
  for (var i = 1; i <= n; i++) {
    final d = c[i] - c[i - 1];
    g += math.max(d, 0);
    l += math.max(-d, 0);
  }
  var ag = g / n, al = l / n;
  double val() => al == 0 ? 100 : 100 - 100 / (1 + ag / al);
  out[n] = val();
  for (var i = n + 1; i < c.length; i++) {
    final d = c[i] - c[i - 1];
    ag = (ag * (n - 1) + math.max(d, 0)) / n;
    al = (al * (n - 1) + math.max(-d, 0)) / n;
    out[i] = val();
  }
  return out;
}

typedef Macd = ({List<double?> line, List<double?> signal, List<double?> hist});

Macd macd(List<double> c, {int fast = 12, int slow = 26, int sig = 9}) {
  if (c.isEmpty) return (line: const [], signal: const [], hist: const []);
  final f = ema(c, fast), s = ema(c, slow);
  final line = [for (var i = 0; i < c.length; i++) f[i]! - s[i]!];
  final signal = ema(line, sig);
  return (
    line: line,
    signal: signal,
    hist: [for (var i = 0; i < c.length; i++) line[i] - signal[i]!],
  );
}

typedef Bands = ({List<double?> mid, List<double?> upper, List<double?> lower});

/// Bollinger: SMA(n) ± k·σ (population σ over the window).
Bands bollinger(List<double> c, {int n = 20, double k = 2}) {
  final mid = sma(c, n);
  final up = List<double?>.filled(c.length, null), lo = List<double?>.filled(c.length, null);
  for (var i = n - 1; i < c.length; i++) {
    final m = mid[i]!;
    var ss = 0.0;
    for (var j = i - n + 1; j <= i; j++) {
      ss += (c[j] - m) * (c[j] - m);
    }
    final sd = math.sqrt(ss / n);
    up[i] = m + k * sd;
    lo[i] = m - k * sd;
  }
  return (mid: mid, upper: up, lower: lo);
}

/// Intraday VWAP, cumulative from the first bar (typical price × volume).
List<double?> vwap(List<double> h, List<double> l, List<double> c, List<double> v) {
  final n = [h.length, l.length, c.length, v.length].reduce(math.min);
  final out = List<double?>.filled(c.length, null);
  var pv = 0.0, vol = 0.0;
  for (var i = 0; i < n; i++) {
    pv += (h[i] + l[i] + c[i]) / 3 * v[i];
    vol += v[i];
    out[i] = vol == 0 ? null : pv / vol;
  }
  return out;
}
