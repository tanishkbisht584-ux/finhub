import 'package:flutter/material.dart';

import 'heat.dart';
import 'theme.dart';

/// The ledger kit: one section header, one row, one tile, one heat cell, one
/// scale bar. Stock page and Markets tab used to each carry private copies
/// with different paddings; this is the single rhythm (10px rows, 84px value
/// column, 8px tile gaps).

String hhmmIst(DateTime t) {
  final ist = t.toUtc().add(const Duration(hours: 5, minutes: 30));
  return '${ist.hour.toString().padLeft(2, '0')}:${ist.minute.toString().padLeft(2, '0')}';
}

/// monoLabel title, optional NSE stamp / action on the right, divider, rows,
/// optional mono-10 footnote.
class LedgerSection extends StatelessWidget {
  const LedgerSection(this.title,
      {super.key,
      this.children = const [],
      this.stamp,
      this.action,
      this.footnote,
      this.stampPrefix = 'NSE'});
  final String title;
  final List<Widget> children;
  final DateTime? stamp;
  final Widget? action;
  final String? footnote;
  final String stampPrefix;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: Text(title.toUpperCase(), style: monoLabel)),
            if (stamp != null)
              Text('$stampPrefix · ${hhmmIst(stamp!)}',
                  style: mono.copyWith(fontSize: 10)),
            if (action != null) action!,
          ]),
          const SizedBox(height: 6),
          const Divider(height: 1),
          const SizedBox(height: 4),
          ...children,
          if (footnote != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(footnote!, style: mono.copyWith(fontSize: 10)),
            ),
        ],
      );
}

/// 3px proportional bar: [f] 0..1 of the width, ink-alpha unless coloured.
Widget miniBar(double f, {Color? color, Color? track}) => SizedBox(
      height: 3,
      child: Stack(children: [
        ColoredBox(color: track ?? border, child: const SizedBox.expand()),
        FractionallySizedBox(
            widthFactor: f.isNaN ? 0 : f.clamp(0, 1),
            child: ColoredBox(
                color: color ?? ink.withValues(alpha: 0.25),
                child: const SizedBox.expand())),
      ]),
    );

/// lead (86px symbol, optional) · main serif + mono sub · trail in a fixed
/// 84px right-aligned column so every list shares one right edge. [bar] draws
/// a proportional bar under the main text.
class LedgerRow extends StatelessWidget {
  const LedgerRow(
      {super.key,
      this.lead,
      required this.main,
      this.trail,
      this.sub,
      this.trailColor,
      this.bar,
      this.barColor,
      this.barTrack,
      this.onTap});
  final String? lead, trail, sub;
  final String main;
  final Color? trailColor, barColor, barTrack;
  final double? bar;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: border))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (lead != null)
          SizedBox(
              width: 86,
              child: Text(lead!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(fontSize: 12, color: ink))),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(main,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: serif.copyWith(fontSize: 13)),
                if (sub != null && sub!.isNotEmpty)
                  Text(sub!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: mono.copyWith(fontSize: 10)),
                if (bar != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 5, right: 12),
                    child: miniBar(bar!, color: barColor, track: barTrack),
                  ),
              ]),
        ),
        if (trail != null) ...[
          const SizedBox(width: 8),
          SizedBox(
              width: 84,
              child: Text(trail!,
                  textAlign: TextAlign.end,
                  style: mono.copyWith(
                      fontSize: 12, color: trailColor ?? ink))),
        ],
      ]),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// Bordered KPI tile: mono-10 label, mono-15 value, optional mono-10 sub.
class StatTile extends StatelessWidget {
  const StatTile(this.label, this.value, {super.key, this.sub, this.color});
  final String label, value;
  final String? sub;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(border: Border.all(color: border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono.copyWith(fontSize: 10)),
          const SizedBox(height: 2),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono.copyWith(fontSize: 15, color: color ?? ink)),
          if (sub != null)
            Text(sub!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(fontSize: 10)),
        ]),
      );
}

/// Rows of equal-width tiles with 8px gaps; the last row is padded so tiles
/// never stretch. No GridView, no aspect-ratio guessing.
class StatGrid extends StatelessWidget {
  const StatGrid(this.tiles, {super.key, this.columns = 3});
  final List<Widget> tiles;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < tiles.length; i += columns) {
      final chunk = tiles.sublist(i, (i + columns).clamp(0, tiles.length));
      rows.add(IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var j = 0; j < columns; j++) ...[
            if (j > 0) const SizedBox(width: 8),
            Expanded(child: j < chunk.length ? chunk[j] : const SizedBox()),
          ],
        ]),
      ));
      if (i + columns < tiles.length) rows.add(const SizedBox(height: 8));
    }
    return Column(children: rows);
  }
}

/// Heat cell: tinted by [pct] through [heatColor]; label / pct / optional sub
/// or breadth bar. Tap for the detail sheet.
class HeatCell extends StatelessWidget {
  const HeatCell(this.label, this.pct,
      {super.key,
      this.sub,
      this.onTap,
      this.bar,
      this.barColor,
      this.barTrack,
      this.scale = 3,
      this.height = 56,
      this.pctText});
  final String label;
  final double? pct;
  final String? sub;
  final VoidCallback? onTap;
  final double? bar;
  final Color? barColor, barTrack;
  final double scale, height;

  /// Formatted pct; defaults to a signed two-decimal percent.
  final String? pctText;

  @override
  Widget build(BuildContext context) {
    final c = pct == null ? inkDim : (pct! >= 0 ? green : red);
    final neutral = pct == null || pct!.abs() < 0.1;
    // Min height, not fixed: platform line heights vary and a fixed 56 clipped
    // the sub line. StatGrid stretches rows to the tallest cell anyway.
    final cell = Container(
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
          color: heatColor(pct, scale: scale),
          border: Border.all(
              color: neutral ? border : c.withValues(alpha: 0.45))),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(fontSize: 10, color: ink)),
            const SizedBox(height: 4),
            Text(
                pctText ??
                    (pct == null
                        ? '—'
                        : '${pct! > 0 ? '+' : ''}${pct!.toStringAsFixed(2)}%'),
                style: mono.copyWith(
                    fontSize: 13, color: neutral ? inkDim : c)),
            if (bar != null) ...[
              const SizedBox(height: 5),
              miniBar(bar!, color: barColor, track: barTrack),
            ] else if (sub != null)
              Text(sub!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(fontSize: 9)),
          ]),
    );
    return onTap == null ? cell : InkWell(onTap: onTap, child: cell);
  }
}

/// Horizontal 0..1 track with tinted zones, tick marks with labels, and an
/// ink marker at the clamped [value]. RSI, fear/greed, PCR, 52-week range.
class ScaleBar extends StatelessWidget {
  const ScaleBar(this.value,
      {super.key,
      this.min = 0,
      this.max = 100,
      this.zones = const [],
      this.marks = const [],
      this.height = 6});
  final double value, min, max, height;
  final List<(double lo, double hi, Color color)> zones;
  final List<(double value, String label)> marks;

  double _f(double v) => max == min ? 0 : ((v - min) / (max - min)).clamp(0, 1);

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height + (marks.isEmpty ? 10 : 22),
        child: LayoutBuilder(builder: (_, c) {
          final w = c.maxWidth;
          return Stack(clipBehavior: Clip.none, children: [
            Positioned(
                top: 4, left: 0, right: 0, height: height,
                child: const ColoredBox(color: border)),
            for (final z in zones)
              Positioned(
                  top: 4,
                  left: _f(z.$1) * w,
                  width: (_f(z.$2) - _f(z.$1)).clamp(0, 1) * w,
                  height: height,
                  child: ColoredBox(color: z.$3.withValues(alpha: 0.25))),
            for (final m in marks) ...[
              Positioned(
                  top: 1,
                  left: _f(m.$1) * w,
                  width: 1,
                  height: height + 6,
                  child: const ColoredBox(color: inkDim)),
              Positioned(
                  top: height + 8,
                  left: _f(m.$1) * w - 20,
                  width: 40,
                  child: Text(m.$2,
                      textAlign: TextAlign.center,
                      style: mono.copyWith(fontSize: 9))),
            ],
            Positioned(
                top: 0,
                left: _f(value) * w - 1,
                width: 2,
                height: height + 8,
                child: const ColoredBox(color: ink)),
          ]);
        }),
      );
}

/// Long lists start at [initial] rows; "show all N" expands in place.
class Collapsible extends StatefulWidget {
  const Collapsible(this.rows, {super.key, this.initial = 6});
  final List<Widget> rows;
  final int initial;

  @override
  State<Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<Collapsible> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final rows =
        _all ? widget.rows : widget.rows.take(widget.initial).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ...rows,
      if (!_all && widget.rows.length > widget.initial)
        TextButton(
            onPressed: () => setState(() => _all = true),
            child: Text('show all ${widget.rows.length}',
                style: mono.copyWith(fontSize: 12, color: green))),
    ]);
  }
}
