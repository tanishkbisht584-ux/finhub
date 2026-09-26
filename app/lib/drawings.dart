// Chart drawings (free-parity P3, 26 Sep 2026): trendline, horizontal level,
// fib retracement, box and note, anchored in (time, price) so pan, zoom and
// a range change keep them where they were drawn. Pure geometry here; the
// painter in price_chart.dart draws them, the stock page owns the list and
// persists it (SharedPreferences mirror + user_drawings on the account).
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum DrawKind { trend, hline, fib, rect, text, erase }

const drawKindLabel = {
  DrawKind.trend: 'TREND',
  DrawKind.hline: 'LEVEL',
  DrawKind.fib: 'FIB',
  DrawKind.rect: 'BOX',
  DrawKind.text: 'NOTE',
  DrawKind.erase: 'ERASE',
};

/// Anchors a kind needs before it is complete.
int anchorsFor(DrawKind k) => switch (k) {
      DrawKind.trend || DrawKind.fib || DrawKind.rect => 2,
      DrawKind.hline || DrawKind.text => 1,
      DrawKind.erase => 0,
    };

class Drawing {
  const Drawing(this.kind, this.pts, {this.text});
  final DrawKind kind;
  final List<(DateTime, double)> pts;
  final String? text;

  Drawing withAnchor(int i, (DateTime, double) p) =>
      Drawing(kind, [for (var k = 0; k < pts.length; k++) k == i ? p : pts[k]], text: text);

  Map<String, dynamic> toJson() => {
        'k': kind.name,
        'a': [
          for (final p in pts) [p.$1.toUtc().millisecondsSinceEpoch ~/ 1000, p.$2]
        ],
        if (text != null) 't': text,
      };

  static Drawing? fromJson(Map<String, dynamic> j) {
    final kind = DrawKind.values.where((k) => k.name == j['k']).firstOrNull;
    if (kind == null || kind == DrawKind.erase) return null;
    final pts = <(DateTime, double)>[];
    for (final a in (j['a'] as List? ?? const [])) {
      if (a is List && a.length == 2 && a[0] is num && a[1] is num) {
        pts.add((DateTime.fromMillisecondsSinceEpoch((a[0] as num).toInt() * 1000, isUtc: true), (a[1] as num).toDouble()));
      }
    }
    if (pts.length < anchorsFor(kind)) return null;
    return Drawing(kind, pts, text: j['t'] as String?);
  }
}

String encodeDrawings(List<Drawing> ds) => jsonEncode([for (final d in ds) d.toJson()]);

List<Drawing> decodeDrawings(String s) {
  try {
    return [
      for (final j in (jsonDecode(s) as List))
        if (j is Map) Drawing.fromJson(Map<String, dynamic>.from(j))
    ].whereType<Drawing>().toList();
  } catch (_) {
    return const [];
  }
}

const fibRatios = [0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0];

/// Retracement levels between two prices: 0 at [a], 1 at [b].
List<(double, double)> fibLevels(double a, double b) => [for (final r in fibRatios) (r, a + (b - a) * r)];

double _segDist(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// Index of the drawing under [tap] (pixels), given the chart's mapping, or
/// null. Trendlines extend to the right edge ([right]) like the painter draws them.
int? hitTest(List<Drawing> ds, Offset Function(DateTime, double) toPx, Offset tap,
    {double tol = 14, double right = double.infinity}) {
  double? best;
  int? at;
  for (var i = 0; i < ds.length; i++) {
    final d = ds[i];
    final px = [for (final p in d.pts) toPx(p.$1, p.$2)];
    double dist;
    switch (d.kind) {
      case DrawKind.trend:
        final a = px[0], b = px[1];
        final ext = _extend(a, b, right);
        dist = _segDist(tap, a, ext);
      case DrawKind.hline:
        dist = (tap.dy - px[0].dy).abs();
      case DrawKind.fib:
        dist = double.infinity;
        for (final (_, price) in fibLevels(d.pts[0].$2, d.pts[1].$2)) {
          dist = math.min(dist, (tap.dy - toPx(d.pts[0].$1, price).dy).abs());
        }
        if (tap.dx < math.min(px[0].dx, px[1].dx) - tol) dist = double.infinity;
      case DrawKind.rect:
        final r = Rect.fromPoints(px[0], px[1]);
        dist = r.inflate(tol).contains(tap) ? 0 : double.infinity;
      case DrawKind.text:
        dist = (tap - px[0]).distance;
      case DrawKind.erase:
        dist = double.infinity;
    }
    if (dist <= tol && (best == null || dist < best)) {
      best = dist;
      at = i;
    }
  }
  return at;
}

/// Nearest anchor of drawing [i] to [tap].
int nearestAnchor(Drawing d, Offset Function(DateTime, double) toPx, Offset tap) {
  var best = 0;
  var bd = double.infinity;
  for (var k = 0; k < d.pts.length; k++) {
    final dist = (toPx(d.pts[k].$1, d.pts[k].$2) - tap).distance;
    if (dist < bd) {
      bd = dist;
      best = k;
    }
  }
  return best;
}

Offset _extend(Offset a, Offset b, double right) {
  if (right == double.infinity || b.dx == a.dx) return b;
  final slope = (b.dy - a.dy) / (b.dx - a.dx);
  final x = b.dx >= a.dx ? right : a.dx;
  return b.dx >= a.dx ? Offset(x, a.dy + slope * (x - a.dx)) : b;
}

Offset extendTrend(Offset a, Offset b, double right) => _extend(a, b, right);

// ---------- persistence: prefs mirror + account row (newest wins) ----------

String _prefsKey(String symbol) => 'drawings_v1:$symbol';

Future<List<Drawing>> loadDrawings(String symbol) async {
  List<Drawing> local = const [];
  DateTime? localAt;
  try {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey(symbol));
    if (raw != null) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      local = decodeDrawings(jsonEncode(j['items']));
      localAt = DateTime.tryParse('${j['at']}');
    }
  } catch (_) {}
  try {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid != null) {
      final row = await Supabase.instance.client
          .from('user_drawings')
          .select('items,updated_at')
          .match({'user_id': uid, 'symbol': symbol}).maybeSingle();
      if (row != null) {
        final cloudAt = DateTime.tryParse('${row['updated_at']}');
        if (localAt == null || (cloudAt != null && cloudAt.isAfter(localAt))) {
          return decodeDrawings(jsonEncode(row['items']));
        }
      }
    }
  } catch (_) {}
  return local;
}

Future<void> saveDrawings(String symbol, List<Drawing> items) async {
  final now = DateTime.now().toUtc();
  final json = [for (final d in items) d.toJson()];
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey(symbol), jsonEncode({'at': now.toIso8601String(), 'items': json}));
  } catch (_) {}
  try {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    await Supabase.instance.client.from('user_drawings').upsert(
        {'user_id': uid, 'symbol': symbol, 'items': json, 'updated_at': now.toIso8601String()},
        onConflict: 'user_id,symbol');
  } catch (_) {}
}
