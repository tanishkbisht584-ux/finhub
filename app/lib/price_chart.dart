import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'charts.dart' show sparkAxisWidth;
import 'drawings.dart';
import 'indicators.dart';
import 'models.dart';
import 'theme.dart';

/// The stock page's chart (Phase D, 26 Sep 2026): one hand-painted component
/// with one x-mapping and one price scale for every layer — line or candles,
/// SMA / EMA / Bollinger / VWAP overlays, pivot lines, dividend markers, and
/// stacked panes for volume, RSI and MACD. Drag pans, pinch zooms, hold shows
/// a crosshair readout, double-tap resets. No chart package.

/// Aligned bar series. Everything the painter needs, nothing it does not.
typedef Bars = ({
  List<double> o,
  List<double> h,
  List<double> l,
  List<double> c,
  List<double> v,
  List<DateTime> t
});

Bars barsOf(Quote q) => (
      o: q.opens.length == q.closes.length ? q.opens : q.closes,
      h: q.highs.length == q.closes.length ? q.highs : q.closes,
      l: q.lows.length == q.closes.length ? q.lows : q.closes,
      c: q.closes,
      v: q.volumes.length == q.closes.length ? q.volumes : List.filled(q.closes.length, 0.0),
      t: q.times,
    );

Bars sliceBars(Bars b, int from) => (
      o: b.o.sublist(from),
      h: b.h.sublist(from),
      l: b.l.sublist(from),
      c: b.c.sublist(from),
      v: b.v.sublist(from),
      t: b.t.sublist(from),
    );

enum ChartLayer { candle, sma20, sma50, sma200, ema21, bb, vwap, vol, rsi, macd, pivots, div }

const chartLayerLabel = {
  ChartLayer.candle: 'CANDLE',
  ChartLayer.sma20: 'SMA 20',
  ChartLayer.sma50: 'SMA 50',
  ChartLayer.sma200: 'SMA 200',
  ChartLayer.ema21: 'EMA 21',
  ChartLayer.bb: 'BOLLINGER',
  ChartLayer.vwap: 'VWAP',
  ChartLayer.vol: 'VOL',
  ChartLayer.rsi: 'RSI',
  ChartLayer.macd: 'MACD',
  ChartLayer.pivots: 'PIVOTS',
  ChartLayer.div: 'DIV',
};

/// Visible window [first, last] (inclusive bar indexes). Pure, so the gesture
/// maths is testable: [dxBars] > 0 drags the chart right (shows older bars).
({int first, int last}) panWindow(int first, int last, int n, double dxBars) {
  final width = last - first;
  var f = (first - dxBars).round();
  f = f.clamp(0, math.max(0, n - 1 - width));
  return (first: f, last: f + width);
}

/// Zoom the window by [scale] (>1 = fewer bars) around [focus] (0..1 across
/// the visible width). Never fewer than [minBars] nor more than n.
({int first, int last}) zoomWindow(int first, int last, int n, double scale, double focus,
    {int minBars = 10}) {
  final width = last - first + 1;
  final int target = (width / scale).round().clamp(math.min(minBars, n), n);
  final anchor = first + focus * (width - 1);
  var f = (anchor - focus * (target - 1)).round();
  final int f0 = f.clamp(0, math.max(0, n - target));
  return (first: f0, last: math.min(n - 1, f0 + target - 1));
}

class PriceChart extends StatefulWidget {
  const PriceChart(this.bars,
      {super.key,
      this.layers = const {ChartLayer.vol},
      this.baseline,
      this.pivots = const [],
      this.dividendDates = const [],
      this.secondary,
      this.intraday = false,
      this.height = 220,
      this.drawings = const [],
      this.tool,
      this.onDrawingsChanged,
      this.onTextPrompt});
  final Bars bars;

  /// 035: user drawings anchored in (time, price); [tool] armed = taps place
  /// anchors (long-press-drag moves the nearest one, ERASE removes what was
  /// tapped); null = the chart pans/zooms/crosshairs as before.
  final List<Drawing> drawings;
  final DrawKind? tool;
  final void Function(List<Drawing>)? onDrawingsChanged;
  final Future<String?> Function()? onTextPrompt;
  final Set<ChartLayer> layers;
  final double? baseline; // previous close (intraday)
  final List<(String, double)> pivots;
  final List<DateTime> dividendDates;

  /// Own-scale amber line (the P/E overlay), aligned with the bars.
  final List<double?>? secondary;
  final bool intraday;
  final double height;

  @override
  State<PriceChart> createState() => _PriceChartState();
}

/// The last paint's mapping, shared with the gesture layer so a tap turns
/// into (time, price) with the very scale that is on screen.
class _ChartMap {
  int first = 0;
  double slot = 1, lo = 0, span = 1, priceH = 1, width = 1;
  List<DateTime> t = const [];

  double xOfIndex(int i) => slot * (i - first + 0.5);
  double yOf(double v) => priceH - (v - lo) / span * (priceH - 8) - 4;
  double priceAt(double y) => lo + (priceH - 4 - y) / (priceH - 8) * span;

  /// x for a timestamp: nearest bar, extrapolated by slot outside the series.
  double xOf(DateTime time) {
    if (t.isEmpty) return 0;
    var lo_ = 0, hi_ = t.length - 1;
    while (lo_ < hi_) {
      final mid = (lo_ + hi_) ~/ 2;
      if (t[mid].isBefore(time)) {
        lo_ = mid + 1;
      } else {
        hi_ = mid;
      }
    }
    if (lo_ == t.length - 1 && time.isAfter(t.last) && t.length > 1) {
      final step = t.last.difference(t[t.length - 2]).inSeconds;
      if (step > 0) return xOfIndex(t.length - 1) + slot * (time.difference(t.last).inSeconds / step);
    }
    return xOfIndex(lo_);
  }

  Offset toPx(DateTime time, double price) => Offset(xOf(time), yOf(price));
}

class _PriceChartState extends State<PriceChart> {
  int? _first, _last; // null = whole series
  int? _cross;
  int _startFirst = 0, _startLast = 0;
  double _startScale = 1;
  final _map = _ChartMap();
  final List<(DateTime, double)> _pending = [];   // anchors of the drawing in progress
  int? _dragIdx, _dragAnchor;

  (DateTime, double)? _anchorAt(Offset p, BoxConstraints c) {
    if (widget.bars.t.length != _n) return null;
    final i = _indexAt(p.dx, c);
    return (widget.bars.t[i], _map.priceAt(p.dy));
  }

  Future<void> _placeAnchor(Offset p, BoxConstraints c) async {
    final tool = widget.tool;
    if (tool == null) return;
    if (tool == DrawKind.erase) {
      final hit = hitTest(widget.drawings, _map.toPx, p, right: _map.width);
      if (hit != null) {
        widget.onDrawingsChanged?.call([for (var k = 0; k < widget.drawings.length; k++) if (k != hit) widget.drawings[k]]);
      }
      return;
    }
    final a = _anchorAt(p, c);
    if (a == null) return;
    _pending.add(a);
    if (_pending.length < anchorsFor(tool)) {
      setState(() {});
      return;
    }
    String? text;
    if (tool == DrawKind.text) {
      text = await widget.onTextPrompt?.call();
      if (text == null || text.trim().isEmpty) {
        setState(_pending.clear);
        return;
      }
    }
    final d = Drawing(tool, List.of(_pending), text: text);
    _pending.clear();
    widget.onDrawingsChanged?.call([...widget.drawings, d]);
  }

  int get _n => widget.bars.c.length;
  int get _f => _first ?? 0;
  int get _l => _last ?? math.max(0, _n - 1);

  @override
  void didUpdateWidget(PriceChart old) {
    super.didUpdateWidget(old);
    if (old.bars.c.length != widget.bars.c.length || (old.bars.t.isNotEmpty && widget.bars.t.isNotEmpty && old.bars.t.first != widget.bars.t.first)) {
      _first = _last = _cross = null;
    }
  }

  double _plotWidth(BoxConstraints c) => c.maxWidth - sparkAxisWidth;

  int _indexAt(double dx, BoxConstraints c) {
    final w = _plotWidth(c);
    final count = _l - _f + 1;
    final i = (dx / w * count).floor() + _f;
    return i.clamp(_f, _l);
  }

  @override
  Widget build(BuildContext context) {
    if (_n < 2) return SizedBox(height: widget.height);
    return LayoutBuilder(builder: (context, c) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (d) {
          _startFirst = _f;
          _startLast = _l;
          _startScale = 1;
        },
        onScaleUpdate: (d) {
          final w = _plotWidth(c);
          if (d.pointerCount > 1 && (d.scale - _startScale).abs() > 0.02) {
            final z = zoomWindow(_startFirst, _startLast, _n, d.scale, (d.localFocalPoint.dx / w).clamp(0, 1));
            setState(() {
              _first = z.first;
              _last = z.last;
            });
          } else if (d.pointerCount == 1) {
            final count = _l - _f + 1;
            final dxBars = d.focalPointDelta.dx / w * count;
            final p = panWindow(_f, _l, _n, dxBars);
            setState(() {
              _first = p.first;
              _last = p.last;
            });
          }
        },
        onTapUp: widget.tool == null ? null : (d) => _placeAnchor(d.localPosition, c),
        onLongPressStart: (d) {
          if (widget.tool != null && widget.tool != DrawKind.erase && widget.drawings.isNotEmpty) {
            final hit = hitTest(widget.drawings, _map.toPx, d.localPosition, right: _map.width);
            if (hit != null) {
              setState(() {
                _dragIdx = hit;
                _dragAnchor = nearestAnchor(widget.drawings[hit], _map.toPx, d.localPosition);
              });
              return;
            }
          }
          setState(() => _cross = _indexAt(d.localPosition.dx, c));
        },
        onLongPressMoveUpdate: (d) {
          if (_dragIdx != null) {
            final a = _anchorAt(d.localPosition, c);
            if (a == null) return;
            final ds = List.of(widget.drawings);
            ds[_dragIdx!] = ds[_dragIdx!].withAnchor(_dragAnchor!, a);
            widget.onDrawingsChanged?.call(ds);
            return;
          }
          setState(() => _cross = _indexAt(d.localPosition.dx, c));
        },
        onLongPressEnd: (_) => setState(() {
          _cross = null;
          _dragIdx = _dragAnchor = null;
        }),
        onDoubleTap: () => setState(() {
          _first = _last = null;
          _cross = null;
          _pending.clear();
        }),
        child: CustomPaint(
          size: Size(c.maxWidth, widget.height),
          painter: _PricePainter(
            bars: widget.bars,
            first: _f,
            last: _l,
            cross: _cross,
            layers: widget.layers,
            baseline: widget.baseline,
            pivots: widget.pivots,
            dividendDates: widget.dividendDates,
            secondary: widget.secondary,
            intraday: widget.intraday,
            drawings: widget.drawings,
            pending: _pending,
            map: _map,
          ),
        ),
      );
    });
  }
}

class _PricePainter extends CustomPainter {
  _PricePainter(
      {required this.bars,
      required this.first,
      required this.last,
      required this.cross,
      required this.layers,
      required this.baseline,
      required this.pivots,
      required this.dividendDates,
      required this.secondary,
      required this.intraday,
      this.drawings = const [],
      this.pending = const [],
      this.map});
  final Bars bars;
  final int first, last;
  final int? cross;
  final Set<ChartLayer> layers;
  final double? baseline;
  final List<(String, double)> pivots;
  final List<DateTime> dividendDates;
  final List<double?>? secondary;
  final bool intraday;
  final List<Drawing> drawings;
  final List<(DateTime, double)> pending;
  final _ChartMap? map;

  static const paneH = 44.0;
  static const gap = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.c.length;
    if (n < 2 || last <= first) return;
    final w = size.width - sparkAxisWidth;
    final count = last - first + 1;
    final slot = w / count;
    double xOf(int i) => slot * (i - first + 0.5);

    // ---- overlays over the FULL series (SMA200 needs history) ----
    final ov = <ChartLayer, List<double?>>{};
    if (layers.contains(ChartLayer.sma20)) ov[ChartLayer.sma20] = sma(bars.c, 20);
    if (layers.contains(ChartLayer.sma50)) ov[ChartLayer.sma50] = sma(bars.c, 50);
    if (layers.contains(ChartLayer.sma200)) ov[ChartLayer.sma200] = sma(bars.c, 200);
    if (layers.contains(ChartLayer.ema21)) ov[ChartLayer.ema21] = ema(bars.c, 21);
    if (layers.contains(ChartLayer.vwap) && intraday) {
      ov[ChartLayer.vwap] = vwap(bars.h, bars.l, bars.c, bars.v);
    }
    final bb = layers.contains(ChartLayer.bb) ? bollinger(bars.c) : null;
    final panes = [
      if (layers.contains(ChartLayer.vol)) ChartLayer.vol,
      if (layers.contains(ChartLayer.rsi)) ChartLayer.rsi,
      if (layers.contains(ChartLayer.macd)) ChartLayer.macd,
    ];
    final priceH = size.height - panes.length * (paneH + gap);

    // ---- price scale over the visible window + visible overlay points ----
    var lo = double.infinity, hi = -double.infinity;
    for (var i = first; i <= last; i++) {
      lo = math.min(lo, layers.contains(ChartLayer.candle) ? bars.l[i] : bars.c[i]);
      hi = math.max(hi, layers.contains(ChartLayer.candle) ? bars.h[i] : bars.c[i]);
    }
    for (final s in ov.values) {
      for (var i = first; i <= last; i++) {
        final v = s[i];
        if (v != null) {
          lo = math.min(lo, v);
          hi = math.max(hi, v);
        }
      }
    }
    if (bb != null) {
      for (var i = first; i <= last; i++) {
        if (bb.upper[i] != null) hi = math.max(hi, bb.upper[i]!);
        if (bb.lower[i] != null) lo = math.min(lo, bb.lower[i]!);
      }
    }
    if (baseline != null) {
      lo = math.min(lo, baseline!);
      hi = math.max(hi, baseline!);
    }
    if (layers.contains(ChartLayer.pivots)) {
      for (final p in pivots) {
        lo = math.min(lo, p.$2);
        hi = math.max(hi, p.$2);
      }
    }
    final span = hi - lo == 0 ? 1.0 : hi - lo;
    double yOf(double v) => priceH - (v - lo) / span * (priceH - 8) - 4;
    map
      ?..first = first
      ..slot = slot
      ..lo = lo
      ..span = span
      ..priceH = priceH
      ..width = w
      ..t = bars.t.length == n ? bars.t : const [];
    final up = bars.c[last] >= (baseline ?? bars.c[first]);
    final tone = up ? green : red;

    // ---- price layer ----
    if (layers.contains(ChartLayer.candle)) {
      final body = (slot * 0.6).clamp(1.0, 8.0);
      for (var i = first; i <= last; i++) {
        final x = xOf(i);
        final bull = bars.c[i] >= bars.o[i];
        final p = Paint()
          ..color = bull ? green : red
          ..strokeWidth = 1;
        canvas.drawLine(Offset(x, yOf(bars.h[i])), Offset(x, yOf(bars.l[i])), p);
        final top = yOf(bull ? bars.c[i] : bars.o[i]), bot = yOf(bull ? bars.o[i] : bars.c[i]);
        canvas.drawRect(Rect.fromLTRB(x - body / 2, top, x + body / 2, bot - top < 1 ? top + 1 : bot),
            p..style = PaintingStyle.fill);
      }
    } else {
      final path = Path();
      for (var i = first; i <= last; i++) {
        final x = xOf(i), y = yOf(bars.c[i]);
        i == first ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      final area = Path.from(path)
        ..lineTo(xOf(last), priceH)
        ..lineTo(xOf(first), priceH)
        ..close();
      canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [tone.withValues(alpha: 0.22), tone.withValues(alpha: 0)])
                .createShader(Rect.fromLTWH(0, 0, w, priceH)));
      canvas.drawPath(
          path,
          Paint()
            ..color = tone
            ..strokeWidth = 1.6
            ..style = PaintingStyle.stroke);
    }

    // ---- overlays ----
    const ovColor = {
      ChartLayer.sma20: Color(0xFF6FA8DC),
      ChartLayer.sma50: amber,
      ChartLayer.sma200: Color(0xFFB07CC6),
      ChartLayer.ema21: Color(0xFFE28C5A),
      ChartLayer.vwap: Color(0xFF9BE7C4),
    };
    void line(List<double?> s, Color color, {double width = 1, bool dashed = false}) {
      final path = Path();
      var pen = false;
      for (var i = first; i <= last; i++) {
        final v = s[i];
        if (v == null) {
          pen = false;
          continue;
        }
        final x = xOf(i), y = yOf(v);
        pen ? path.lineTo(x, y) : path.moveTo(x, y);
        pen = true;
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..strokeWidth = width
            ..style = PaintingStyle.stroke);
    }

    for (final e in ov.entries) {
      line(e.value, ovColor[e.key]!);
    }
    if (bb != null) {
      line(bb.upper, inkDim.withValues(alpha: 0.7));
      line(bb.lower, inkDim.withValues(alpha: 0.7));
      final band = Path();
      var pen = false;
      for (var i = first; i <= last; i++) {
        if (bb.upper[i] == null) continue;
        final x = xOf(i);
        pen ? band.lineTo(x, yOf(bb.upper[i]!)) : band.moveTo(x, yOf(bb.upper[i]!));
        pen = true;
      }
      for (var i = last; i >= first; i--) {
        if (bb.lower[i] == null) continue;
        band.lineTo(xOf(i), yOf(bb.lower[i]!));
      }
      canvas.drawPath(band, Paint()..color = inkDim.withValues(alpha: 0.08));
    }

    // ---- dotted reference lines: previous close, pivots ----
    void dotted(double y, Color c, [String? label]) {
      final p = Paint()
        ..color = c
        ..strokeWidth = 1;
      for (var x = 0.0; x < w; x += 6) {
        canvas.drawLine(Offset(x, y), Offset(x + 3, y), p);
      }
      if (label != null) _text(canvas, label, Offset(2, y - 11), c, 8);
    }

    if (baseline != null) dotted(yOf(baseline!), inkDim);
    if (layers.contains(ChartLayer.pivots)) {
      for (final p in pivots) {
        dotted(yOf(p.$2), amber.withValues(alpha: 0.7), p.$1);
      }
    }

    // ---- dividend markers ----
    if (layers.contains(ChartLayer.div) && dividendDates.isNotEmpty && bars.t.length == n) {
      for (final d in dividendDates) {
        var idx = -1;
        for (var i = first; i <= last; i++) {
          if (!bars.t[i].isBefore(d)) {
            idx = i;
            break;
          }
        }
        if (idx < 0) continue;
        final x = xOf(idx);
        canvas.drawCircle(Offset(x, priceH - 6), 3, Paint()..color = amber);
        _text(canvas, 'D', Offset(x - 2.5, priceH - 18), amber, 8);
      }
    }

    // ---- 035: user drawings, in (time, price) space ----
    if (map != null && bars.t.length == n && (drawings.isNotEmpty || pending.isNotEmpty)) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, w, priceH));
      for (final d in drawings) {
        _drawing(canvas, d, map!, w);
      }
      for (final p in pending) {
        canvas.drawCircle(map!.toPx(p.$1, p.$2), 4, Paint()..color = amber);
      }
      canvas.restore();
    }

    // ---- secondary (P/E) on its own scale ----
    final sec = secondary;
    if (sec != null && sec.length == n) {
      var slo = double.infinity, shi = -double.infinity;
      for (var i = first; i <= last; i++) {
        final v = sec[i];
        if (v != null) {
          slo = math.min(slo, v);
          shi = math.max(shi, v);
        }
      }
      if (slo.isFinite) {
        final sspan = shi - slo == 0 ? 1.0 : shi - slo;
        final path = Path();
        var pen = false;
        for (var i = first; i <= last; i++) {
          final v = sec[i];
          if (v == null) {
            pen = false;
            continue;
          }
          final y = priceH - (v - slo) / sspan * (priceH - 8) - 4;
          pen ? path.lineTo(xOf(i), y) : path.moveTo(xOf(i), y);
          pen = true;
        }
        canvas.drawPath(
            path,
            Paint()
              ..color = amber
              ..strokeWidth = 1
              ..style = PaintingStyle.stroke);
      }
    }

    // ---- axis: hi / lo / last ----
    _text(canvas, _fmt(hi), Offset(w + 6, 0), inkDim, 9);
    _text(canvas, _fmt(lo), Offset(w + 6, priceH - 12), inkDim, 9);
    final lastY = (yOf(bars.c[last]) - 6).clamp(12, priceH - 24);
    _text(canvas, _fmt(bars.c[last]), Offset(w + 6, lastY.toDouble()), tone, 9);

    // ---- panes ----
    var top = priceH + gap;
    for (final pane in panes) {
      final rect = Rect.fromLTWH(0, top, w, paneH);
      canvas.drawLine(Offset(0, top), Offset(w, top), Paint()..color = border);
      switch (pane) {
        case ChartLayer.vol:
          var vmax = 0.0;
          for (var i = first; i <= last; i++) {
            vmax = math.max(vmax, bars.v[i]);
          }
          if (vmax > 0) {
            final bw = (slot * 0.7).clamp(1.0, 10.0);
            for (var i = first; i <= last; i++) {
              final hgt = bars.v[i] / vmax * (paneH - 4);
              final bull = bars.c[i] >= bars.o[i];
              canvas.drawRect(
                  Rect.fromLTWH(xOf(i) - bw / 2, rect.bottom - hgt, bw, hgt),
                  Paint()..color = (bull ? green : red).withValues(alpha: 0.55));
            }
          }
          _text(canvas, 'VOL', Offset(2, top + 2), inkDim, 8);
          _text(canvas, _fmtVol(bars.v[last]), Offset(w + 6, top + 2), inkDim, 8);
        case ChartLayer.rsi:
          final r = rsi(bars.c);
          double y(double v) => rect.bottom - v / 100 * (paneH - 4) - 2;
          for (final rail in const [30.0, 70.0]) {
            final p = Paint()
              ..color = inkDim.withValues(alpha: 0.5)
              ..strokeWidth = 0.5;
            for (var x = 0.0; x < w; x += 6) {
              canvas.drawLine(Offset(x, y(rail)), Offset(x + 3, y(rail)), p);
            }
          }
          final path = Path();
          var pen = false;
          for (var i = first; i <= last; i++) {
            final v = r[i];
            if (v == null) {
              pen = false;
              continue;
            }
            pen ? path.lineTo(xOf(i), y(v)) : path.moveTo(xOf(i), y(v));
            pen = true;
          }
          canvas.drawPath(
              path,
              Paint()
                ..color = const Color(0xFF6FA8DC)
                ..strokeWidth = 1
                ..style = PaintingStyle.stroke);
          _text(canvas, 'RSI 14', Offset(2, top + 2), inkDim, 8);
          if (r[last] != null) {
            _text(canvas, r[last]!.toStringAsFixed(0), Offset(w + 6, top + 2),
                r[last]! >= 70 ? red : r[last]! <= 30 ? green : inkDim, 8);
          }
        case ChartLayer.macd:
          final m = macd(bars.c);
          var mlo = 0.0, mhi = 0.0;
          for (var i = first; i <= last; i++) {
            for (final v in [m.line[i], m.signal[i], m.hist[i]]) {
              if (v != null) {
                mlo = math.min(mlo, v);
                mhi = math.max(mhi, v);
              }
            }
          }
          final mspan = mhi - mlo == 0 ? 1.0 : mhi - mlo;
          double y(double v) => rect.bottom - (v - mlo) / mspan * (paneH - 4) - 2;
          final bw = (slot * 0.6).clamp(1.0, 8.0);
          for (var i = first; i <= last; i++) {
            final v = m.hist[i];
            if (v == null) continue;
            final y0 = y(0), y1 = y(v);
            canvas.drawRect(
                Rect.fromLTRB(xOf(i) - bw / 2, math.min(y0, y1), xOf(i) + bw / 2, math.max(y0, y1)),
                Paint()..color = (v >= 0 ? green : red).withValues(alpha: 0.5));
          }
          void mline(List<double?> s, Color c) {
            final path = Path();
            var pen = false;
            for (var i = first; i <= last; i++) {
              final v = s[i];
              if (v == null) {
                pen = false;
                continue;
              }
              pen ? path.lineTo(xOf(i), y(v)) : path.moveTo(xOf(i), y(v));
              pen = true;
            }
            canvas.drawPath(
                path,
                Paint()
                  ..color = c
                  ..strokeWidth = 1
                  ..style = PaintingStyle.stroke);
          }

          mline(m.line, const Color(0xFF6FA8DC));
          mline(m.signal, amber);
          _text(canvas, 'MACD 12·26·9', Offset(2, top + 2), inkDim, 8);
        default:
          break;
      }
      top += paneH + gap;
    }

    // ---- crosshair + readout ----
    final ci = cross;
    if (ci != null && ci >= first && ci <= last) {
      final x = xOf(ci);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height),
          Paint()
            ..color = ink.withValues(alpha: 0.6)
            ..strokeWidth = 0.8);
      final y = yOf(bars.c[ci]);
      canvas.drawCircle(Offset(x, y), 3, Paint()..color = ink);
      final lines = <String>[
        if (bars.t.length == n) _when(bars.t[ci], intraday),
        layers.contains(ChartLayer.candle)
            ? 'O ${_fmt(bars.o[ci])}  H ${_fmt(bars.h[ci])}  L ${_fmt(bars.l[ci])}  C ${_fmt(bars.c[ci])}'
            : 'Close ${_fmt(bars.c[ci])}',
        if (bars.v[ci] > 0) 'Vol ${_fmtVol(bars.v[ci])}',
        for (final e in ov.entries)
          if (e.value[ci] != null) '${chartLayerLabel[e.key]} ${_fmt(e.value[ci]!)}',
        if (bb != null && bb.upper[ci] != null) 'BB ${_fmt(bb.lower[ci]!)} – ${_fmt(bb.upper[ci]!)}',
      ];
      const pad = 6.0;
      final tps = [
        for (final l in lines)
          TextPainter(text: TextSpan(text: l, style: mono.copyWith(fontSize: 9, color: ink)), textDirection: TextDirection.ltr)
            ..layout()
      ];
      final bw = math.min(w, tps.map((t) => t.width).reduce(math.max) + pad * 2);
      final bh = tps.fold(0.0, (s, t) => s + t.height) + pad * 2;
      final bx = x + 8 + bw > w ? x - 8 - bw : x + 8;
      final box = Rect.fromLTWH(bx.clamp(0.0, math.max(0.0, w - bw)), 2, bw, bh);
      canvas.drawRect(box, Paint()..color = surface.withValues(alpha: 0.95));
      canvas.drawRect(
          box,
          Paint()
            ..color = border
            ..style = PaintingStyle.stroke);
      var ty = box.top + pad;
      for (final t in tps) {
        t.paint(canvas, Offset(box.left + pad, ty));
        ty += t.height;
      }
    }
  }

  void _drawing(Canvas canvas, Drawing d, _ChartMap m, double w) {
    final px = [for (final p in d.pts) m.toPx(p.$1, p.$2)];
    final stroke = Paint()
      ..color = amber
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    switch (d.kind) {
      case DrawKind.trend:
        canvas.drawLine(px[0], extendTrend(px[0], px[1], w), stroke);
        canvas.drawCircle(px[0], 3, Paint()..color = amber);
        canvas.drawCircle(px[1], 3, Paint()..color = amber);
      case DrawKind.hline:
        canvas.drawLine(Offset(0, px[0].dy), Offset(w, px[0].dy), stroke);
        _text(canvas, _fmt(d.pts[0].$2), Offset(4, px[0].dy - 12), amber, 9);
      case DrawKind.fib:
        final x0 = math.min(px[0].dx, px[1].dx);
        for (final (r, price) in fibLevels(d.pts[0].$2, d.pts[1].$2)) {
          final y = m.yOf(price);
          var x = x0;
          while (x < w) {
            canvas.drawLine(Offset(x, y), Offset(math.min(x + 4, w), y), stroke);
            x += 8;
          }
          _text(canvas, '${(r * 100).toStringAsFixed(1)}% ${_fmt(price)}', Offset(x0 + 2, y - 11), amber, 8);
        }
      case DrawKind.rect:
        final r = Rect.fromPoints(px[0], px[1]);
        canvas.drawRect(r, Paint()..color = amber.withValues(alpha: 0.12));
        canvas.drawRect(r, stroke);
      case DrawKind.text:
        canvas.drawCircle(px[0], 2.5, Paint()..color = amber);
        _text(canvas, d.text ?? '', px[0] + const Offset(6, -6), amber, 10);
      case DrawKind.erase:
        break;
    }
  }

  static String _fmt(double v) => v >= 1000 ? fmtNum(v, decimals: 0) : v.toStringAsFixed(2);
  static String _fmtVol(double v) => v >= 1e7
      ? '${(v / 1e7).toStringAsFixed(1)} Cr'
      : v >= 1e5
          ? '${(v / 1e5).toStringAsFixed(1)} L'
          : fmtNum(v, decimals: 0);
  static String _when(DateTime t, bool intraday) {
    final ist = t.toUtc().add(const Duration(hours: 5, minutes: 30));
    final d = dmy(ist.toIso8601String());
    return intraday ? '$d ${ist.hour.toString().padLeft(2, '0')}:${ist.minute.toString().padLeft(2, '0')}' : d;
  }

  static void _text(Canvas c, String s, Offset at, Color color, double size) {
    final tp = TextPainter(
        text: TextSpan(text: s, style: mono.copyWith(fontSize: size, color: color)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(c, at);
  }

  @override
  bool shouldRepaint(_PricePainter o) =>
      o.bars != bars ||
      o.first != first ||
      o.last != last ||
      o.cross != cross ||
      o.layers != layers ||
      o.baseline != baseline ||
      o.secondary != secondary ||
      o.drawings != drawings ||
      o.pending.length != pending.length;
}
