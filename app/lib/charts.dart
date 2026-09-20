import 'dart:math';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Hand-painted charts. No chart package: each shape here is a few dozen
/// lines against a dependency, and the ledger only ever needs these four.

/// One polyline, no chart package: the spec asks for a "light line chart" and
/// a painter is 20 lines against a dependency.
class Sparkline extends StatelessWidget {
  const Sparkline(this.values, this.color,
      {super.key,
      this.secondary,
      this.fill = false,
      this.baseline,
      this.axis = false});
  final List<double> values;
  final Color color;

  /// Optional overlay (the P/E line): aligned with [values], nulls break the
  /// line, normalized on its own scale, drawn thin in amber.
  final List<double?>? secondary;

  /// Phase 2 (stock chart): tinted area under the line, a dotted reference
  /// line at [baseline] (previous close) and hi / lo / last labels down the
  /// right edge like MC's price axis. [baseline] widens the scale to include it.
  final bool fill, axis;
  final double? baseline;

  @override
  Widget build(BuildContext context) => CustomPaint(
      size: Size.infinite,
      painter: _SparkPainter(values, color, secondary,
          fill: fill, baseline: baseline, axis: axis));
}

/// Width reserved for the axis labels when [Sparkline.axis] is on.
const sparkAxisWidth = 48.0;

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color, this.secondary,
      {this.fill = false, this.baseline, this.axis = false});
  final List<double> values;
  final Color color;
  final List<double?>? secondary;
  final bool fill, axis;
  final double? baseline;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final w = axis ? size.width - sparkAxisWidth : size.width;
    var lo = values.reduce((a, b) => a < b ? a : b);
    var hi = values.reduce((a, b) => a > b ? a : b);
    final b = baseline;
    if (b != null) {
      lo = lo < b ? lo : b;
      hi = hi > b ? hi : b;
    }
    final span = (hi - lo) == 0 ? 1.0 : hi - lo;
    double yOf(double v) => size.height - (v - lo) / span * size.height;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * w;
      final y = yOf(values[i]);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    if (fill) {
      final area = Path.from(path)
        ..lineTo(w, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.02)],
            ).createShader(Rect.fromLTWH(0, 0, w, size.height)));
    }
    if (b != null) {
      final y = yOf(b);
      final dash = Paint()
        ..color = inkDim
        ..strokeWidth = 1;
      for (var x = 0.0; x < w; x += 6) {
        canvas.drawLine(Offset(x, y), Offset(x + 3, y), dash);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color);
    if (axis) {
      void label(double v, double y, Color c) {
        final tp = TextPainter(
            text: TextSpan(
                text: v >= 1000 ? v.toStringAsFixed(0) : v.toStringAsFixed(2),
                style: mono.copyWith(fontSize: 9, color: c)),
            textDirection: TextDirection.ltr)
          ..layout();
        tp.paint(canvas,
            Offset(w + 6, (y - tp.height / 2).clamp(0, size.height - tp.height)));
      }

      label(hi, yOf(hi), inkDim);
      label(lo, yOf(lo), inkDim);
      label(values.last, yOf(values.last), color);
    }
    final sec = secondary;
    if (sec == null) return;
    final vals = [for (final v in sec) if (v != null) v];
    if (vals.length < 2) return;
    final slo = vals.reduce((a, b) => a < b ? a : b);
    final shi = vals.reduce((a, b) => a > b ? a : b);
    final sspan = (shi - slo) == 0 ? 1.0 : shi - slo;
    final spath = Path();
    var pen = false;
    final n = sec.length < values.length ? sec.length : values.length;
    for (var i = 0; i < n; i++) {
      final v = sec[i];
      if (v == null) {
        pen = false;
        continue;
      }
      final x = i / (values.length - 1) * w;
      final y = size.height - (v - slo) / sspan * size.height;
      pen ? spath.lineTo(x, y) : spath.moveTo(x, y);
      pen = true;
    }
    canvas.drawPath(
        spath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = amber);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values ||
      old.color != color ||
      old.secondary != secondary ||
      old.fill != fill ||
      old.baseline != baseline ||
      old.axis != axis;
}

/// OHLC candles (MC's line ⇄ candle toggle). Green when close ≥ open, red
/// below; wick = high–low. Same right-edge axis as [Sparkline] when [axis].
class Candles extends StatelessWidget {
  const Candles(this.opens, this.highs, this.lows, this.closes,
      {super.key, this.baseline, this.axis = false});
  final List<double> opens, highs, lows, closes;
  final double? baseline;
  final bool axis;

  @override
  Widget build(BuildContext context) => CustomPaint(
      size: Size.infinite,
      painter: _CandlePainter(opens, highs, lows, closes, baseline, axis));
}

class _CandlePainter extends CustomPainter {
  _CandlePainter(
      this.opens, this.highs, this.lows, this.closes, this.baseline, this.axis);
  final List<double> opens, highs, lows, closes;
  final double? baseline;
  final bool axis;

  @override
  void paint(Canvas canvas, Size size) {
    final n = [opens.length, highs.length, lows.length, closes.length]
        .reduce((a, b) => a < b ? a : b);
    if (n < 2) return;
    final w = axis ? size.width - sparkAxisWidth : size.width;
    var lo = lows.take(n).reduce((a, b) => a < b ? a : b);
    var hi = highs.take(n).reduce((a, b) => a > b ? a : b);
    final b = baseline;
    if (b != null) {
      lo = lo < b ? lo : b;
      hi = hi > b ? hi : b;
    }
    final span = (hi - lo) == 0 ? 1.0 : hi - lo;
    double yOf(double v) => size.height - (v - lo) / span * size.height;
    final slot = w / n;
    final body = (slot * 0.6).clamp(1.0, 8.0);
    for (var i = 0; i < n; i++) {
      final x = slot * (i + 0.5);
      final up = closes[i] >= opens[i];
      final paint = Paint()
        ..color = up ? green : red
        ..strokeWidth = 1;
      canvas.drawLine(Offset(x, yOf(highs[i])), Offset(x, yOf(lows[i])), paint);
      final top = yOf(up ? closes[i] : opens[i]);
      final bottom = yOf(up ? opens[i] : closes[i]);
      canvas.drawRect(
          Rect.fromLTRB(x - body / 2, top, x + body / 2,
              bottom - top < 1 ? top + 1 : bottom),
          paint..style = PaintingStyle.fill);
    }
    if (b != null) {
      final y = yOf(b);
      final dash = Paint()
        ..color = inkDim
        ..strokeWidth = 1;
      for (var x = 0.0; x < w; x += 6) {
        canvas.drawLine(Offset(x, y), Offset(x + 3, y), dash);
      }
    }
    if (axis) {
      void label(double v, double y, Color c) {
        final tp = TextPainter(
            text: TextSpan(
                text: v >= 1000 ? v.toStringAsFixed(0) : v.toStringAsFixed(2),
                style: mono.copyWith(fontSize: 9, color: c)),
            textDirection: TextDirection.ltr)
          ..layout();
        tp.paint(canvas,
            Offset(w + 6, (y - tp.height / 2).clamp(0, size.height - tp.height)));
      }

      label(hi, yOf(hi), inkDim);
      label(lo, yOf(lo), inkDim);
      label(closes[n - 1], yOf(closes[n - 1]),
          closes[n - 1] >= opens[n - 1] ? green : red);
    }
  }

  @override
  bool shouldRepaint(_CandlePainter old) =>
      old.closes != closes || old.baseline != baseline || old.axis != axis;
}

/// Vertical bars with the baseline at zero (negatives hang below). An optional
/// [secondary] series is drawn as a thinner bar inside each slot, on the same
/// scale — sales vs profit, not two unrelated units. Labels sit under slots.
class BarChart extends StatelessWidget {
  const BarChart(this.values,
      {super.key,
      this.secondary,
      this.labels,
      this.color = green,
      this.secondaryColor = amber});
  final List<double?> values;
  final List<double?>? secondary;
  final List<String>? labels;
  final Color color;
  final Color secondaryColor;

  @override
  Widget build(BuildContext context) => CustomPaint(
      size: Size.infinite,
      painter: _BarPainter(values, secondary, labels, color, secondaryColor));
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.values, this.secondary, this.labels, this.color, this.sec);
  final List<double?> values;
  final List<double?>? secondary;
  final List<String>? labels;
  final Color color, sec;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final all = [
      ...values.whereType<double>(),
      ...?secondary?.whereType<double>(),
    ];
    if (all.isEmpty) return;
    final lo = all.fold(0.0, (a, b) => a < b ? a : b);
    final hi = all.fold(0.0, (a, b) => a > b ? a : b);
    final span = (hi - lo) == 0 ? 1.0 : hi - lo;
    final labelH = labels == null ? 0.0 : 12.0;
    final plotH = size.height - labelH;
    final slot = size.width / values.length;
    double y(double v) => plotH - (v - lo) / span * plotH;
    final base = y(0);
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      final x0 = i * slot;
      if (v != null) {
        final w = slot * 0.7;
        canvas.drawRect(
            Rect.fromLTRB(x0 + (slot - w) / 2, y(v), x0 + (slot + w) / 2, base)
                .normalize(),
            Paint()..color = color.withValues(alpha: 0.55));
      }
      final s = secondary != null && i < secondary!.length ? secondary![i] : null;
      if (s != null) {
        final w = slot * 0.24;
        canvas.drawRect(
            Rect.fromLTRB(x0 + (slot - w) / 2, y(s), x0 + (slot + w) / 2, base)
                .normalize(),
            Paint()..color = sec);
      }
      final l = labels;
      if (l != null && i < l.length) {
        final tp = TextPainter(
            text: TextSpan(text: l[i], style: mono.copyWith(fontSize: 9)),
            textDirection: TextDirection.ltr)
          ..layout();
        tp.paint(canvas, Offset(x0 + (slot - tp.width) / 2, plotH + 2));
      }
    }
    canvas.drawLine(Offset(0, base), Offset(size.width, base),
        Paint()..color = border);
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.values != values || old.secondary != secondary || old.labels != labels;
}

extension on Rect {
  Rect normalize() =>
      Rect.fromLTRB(left, top < bottom ? top : bottom, right, top < bottom ? bottom : top);
}

/// One 100% horizontal bar plus its legend. Segments with a zero share are
/// skipped so the legend never lists a sliver.
class StackedBar extends StatelessWidget {
  const StackedBar(this.segments, {super.key, this.height = 8});
  final List<(double fraction, Color color, String label)> segments;
  final double height;

  @override
  Widget build(BuildContext context) {
    final live = [for (final s in segments) if (s.$1 > 0) s];
    if (live.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: height,
        child: Row(children: [
          for (final s in live)
            Expanded(
                flex: (s.$1 * 1000).round().clamp(1, 1000),
                child: ColoredBox(color: s.$2)),
        ]),
      ),
      const SizedBox(height: 6),
      Wrap(spacing: 14, runSpacing: 4, children: [
        for (final s in live)
          Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 8, height: 8, child: ColoredBox(color: s.$2)),
            const SizedBox(width: 5),
            Text(s.$3, style: mono.copyWith(fontSize: 10)),
          ]),
      ]),
    ]);
  }
}

/// A line whose points sit at column centres, with a label under each column —
/// so the label row lines up with the vertices by construction (the bond
/// curve's labels used to drift from its points).
class LabeledLine extends StatelessWidget {
  const LabeledLine(this.values, this.labels, this.color,
      {super.key, this.height = 56, this.valueLabels});
  final List<double> values;
  final List<String> labels;
  final Color color;
  final double height;

  /// Optional second row (the values themselves), drawn in ink above [labels].
  final List<String>? valueLabels;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
            height: height,
            child: CustomPaint(painter: _CentredLinePainter(values, color))),
        const SizedBox(height: 6),
        if (valueLabels != null)
          Row(children: [
            for (final v in valueLabels!)
              Expanded(
                  child: Text(v,
                      textAlign: TextAlign.center,
                      style: mono.copyWith(fontSize: 11, color: ink))),
          ]),
        Row(children: [
          for (final l in labels)
            Expanded(
                child: Text(l,
                    textAlign: TextAlign.center,
                    style: mono.copyWith(fontSize: 10))),
        ]),
      ]);
}

class _CentredLinePainter extends CustomPainter {
  _CentredLinePainter(this.values, this.color);
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo) == 0 ? 1.0 : hi - lo;
    const pad = 4.0;
    final path = Path();
    final pts = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final x = (i + 0.5) / values.length * size.width;
      final y = pad + (size.height - 2 * pad) * (1 - (values[i] - lo) / span);
      pts.add(Offset(x, y));
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color);
    final dot = Paint()..color = color;
    for (final p in pts) {
      canvas.drawCircle(p, 2.5, dot);
    }
  }

  @override
  bool shouldRepaint(_CentredLinePainter old) =>
      old.values != values || old.color != color;
}

/// Two horizontal bars normalised to the larger — buy vs sell.
class PairedBar extends StatelessWidget {
  const PairedBar(this.a, this.b,
      {super.key, this.colorA = green, this.colorB = red, this.height = 6});
  final double a, b;
  final Color colorA, colorB;
  final double height;

  @override
  Widget build(BuildContext context) {
    final max = a > b ? a : b;
    Widget bar(double v, Color c) => SizedBox(
          height: height,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
                widthFactor: max <= 0 ? 0 : (v / max).clamp(0, 1),
                child: ColoredBox(color: c.withValues(alpha: 0.7))),
          ),
        );
    return Column(children: [
      bar(a, colorA),
      const SizedBox(height: 3),
      bar(b, colorB),
    ]);
  }
}

/// Donut (MC's shareholding pie): segments as fractions of 1, a hole with
/// [center] text. Legend is the caller's (StackedBar's legend row fits).
class Donut extends StatelessWidget {
  const Donut(this.segments, {super.key, this.center, this.size = 132});
  final List<(double fraction, Color color, String label)> segments;
  final String? center;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _DonutPainter(segments),
          child: Center(
            child: Text(center ?? '',
                textAlign: TextAlign.center,
                style: mono.copyWith(fontSize: 11, color: inkDim)),
          ),
        ),
      );
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.segments);
  final List<(double, Color, String)> segments;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: Offset(size.width / 2, size.height / 2), radius: r - 9);
    var start = -1.5707963; // 12 o'clock
    final total = segments.fold(0.0, (a, s) => a + (s.$1 > 0 ? s.$1 : 0));
    if (total <= 0) return;
    for (final s in segments) {
      if (s.$1 <= 0) continue;
      final sweep = s.$1 / total * 6.2831853;
      canvas.drawArc(
          rect,
          start,
          sweep - 0.02,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 18
            ..color = s.$2);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.segments != segments;
}

/// Radar (MC's peer chart): one spoke per [points] entry, length = value /
/// max, labels at the rim, [highlight] index drawn in green (self).
class Radar extends StatelessWidget {
  const Radar(this.points, {super.key, this.highlight, this.size = 220});
  final List<(String label, double? value)> points;
  final int? highlight;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _RadarPainter(points, highlight)));
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.points, this.highlight);
  final List<(String, double?)> points;
  final int? highlight;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 3) return;
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2 - 26;
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = border;
    for (final f in const [0.33, 0.66, 1.0]) {
      canvas.drawCircle(c, r * f, grid);
    }
    final vals = [for (final p in points) if (p.$2 != null && p.$2! > 0) p.$2!];
    final max = vals.isEmpty ? 1.0 : vals.reduce((a, b) => a > b ? a : b);
    final n = points.length;
    final poly = Path();
    var pen = false;
    for (var i = 0; i < n; i++) {
      final a = -1.5707963 + i * 6.2831853 / n;
      final tip = Offset(c.dx + r * cos(a), c.dy + r * sin(a));
      canvas.drawLine(c, tip, grid);
      final v = points[i].$2;
      final f = v == null || v <= 0 ? 0.0 : (v / max).clamp(0.0, 1.0);
      final p = Offset(c.dx + r * f * cos(a), c.dy + r * f * sin(a));
      pen ? poly.lineTo(p.dx, p.dy) : poly.moveTo(p.dx, p.dy);
      pen = true;
      canvas.drawCircle(
          p, i == highlight ? 4 : 2.5, Paint()..color = i == highlight ? green : amber);
      final tp = TextPainter(
          text: TextSpan(
              text: points[i].$1,
              style: mono.copyWith(fontSize: 9, color: i == highlight ? green : inkDim)),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…')
        ..layout(maxWidth: 70);
      final lx = c.dx + (r + 10) * cos(a), ly = c.dy + (r + 10) * sin(a);
      tp.paint(
          canvas,
          Offset(
              (lx - (cos(a) < -0.1 ? tp.width : cos(a) > 0.1 ? 0 : tp.width / 2))
                  .clamp(0, size.width - tp.width),
              (ly - tp.height / 2).clamp(0, size.height - tp.height)));
    }
    poly.close();
    canvas.drawPath(poly, Paint()..color = amber.withValues(alpha: 0.18));
    canvas.drawPath(
        poly,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = amber);
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.points != points || old.highlight != highlight;
}
