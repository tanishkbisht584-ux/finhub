import 'package:flutter/material.dart';

import 'theme.dart';

/// Hand-painted charts. No chart package: each shape here is a few dozen
/// lines against a dependency, and the ledger only ever needs these four.

/// One polyline, no chart package: the spec asks for a "light line chart" and
/// a painter is 20 lines against a dependency.
class Sparkline extends StatelessWidget {
  const Sparkline(this.values, this.color, {super.key, this.secondary});
  final List<double> values;
  final Color color;

  /// Optional overlay (the P/E line): aligned with [values], nulls break the
  /// line, normalized on its own scale, drawn thin in amber.
  final List<double?>? secondary;

  @override
  Widget build(BuildContext context) => CustomPaint(
      size: Size.infinite, painter: _SparkPainter(values, color, secondary));
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color, [this.secondary]);
  final List<double> values;
  final Color color;
  final List<double?>? secondary;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo) == 0 ? 1.0 : hi - lo;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final y = size.height - (values[i] - lo) / span * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color);
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
      final x = i / (values.length - 1) * size.width;
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
      old.values != values || old.color != color || old.secondary != secondary;
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
