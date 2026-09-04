import 'package:flutter/material.dart';

import 'theme.dart';

/// Tint for heat cells and heat-table cells. Five buckets so a +0.5% and a
/// +2.4% sector stop looking identical: grey inside ±0.1, then alpha steps at
/// 0.5 / 1.5 / 3 (× [scale]/3). Sign picks green or red — still "red/green
/// only for direction", the direction is just growth instead of a tick.
Color heatColor(double? pct, {double scale = 3}) {
  if (pct == null || pct.isNaN || pct.abs() < 0.1) return border;
  final k = scale / 3;
  final a = pct.abs();
  final alpha = a < 0.5 * k
      ? 0.10
      : a < 1.5 * k
          ? 0.18
          : a < 3 * k
              ? 0.28
              : 0.40;
  return (pct > 0 ? green : red).withValues(alpha: alpha);
}

/// Cell tint by change vs the previous period. [points] compares raw
/// differences (OPM %, days) instead of percent change.
Color deltaHeat(num? cur, num? prev, {double scale = 3, bool points = false}) {
  if (cur == null || prev == null) return border;
  if (points) return heatColor((cur - prev).toDouble(), scale: scale);
  if (prev == 0) return border;
  return heatColor((cur - prev) / prev.abs() * 100, scale: scale);
}

/// Nine swatches, most-negative → most-positive, for a legend strip.
List<Color> heatSwatches({double scale = 3}) => [
      for (final p in [-4.0, -2.0, -1.0, -0.3, 0.0, 0.3, 1.0, 2.0, 4.0])
        heatColor(p * scale / 3, scale: scale)
    ];
