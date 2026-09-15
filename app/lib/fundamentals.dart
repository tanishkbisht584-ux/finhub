import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

/// The `fundamentals` table (migration 016) grouped for the stock page:
/// one row per (kind, period), data jsonb shaped by pipeline/fundamentals.py.
class FundamentalsData {
  const FundamentalsData(
      this.annual, this.quarter, this.shareholding, this.summary, this.docs,
      {this.summaryAt, this.hasDocsRow = false});

  final Map<String, Map<String, dynamic>> annual; // 'FY2026' -> data, oldest first
  final Map<String, Map<String, dynamic>> quarter; // '2026-06' -> data
  final Map<String, Map<String, dynamic>> shareholding;
  final Map<String, dynamic> summary; // cagr/pros/cons/roce/book_value
  final Map<String, dynamic> docs;
  final DateTime? summaryAt; // summary row's updated_at: when the deep pass last ran
  final bool hasDocsRow; // an NSE pass ran at all (the row may be empty)

  bool get isEmpty =>
      annual.isEmpty && quarter.isEmpty && shareholding.isEmpty && summary.isEmpty;

  factory FundamentalsData.fromRows(List<dynamic> rows) {
    final byKind = <String, Map<String, Map<String, dynamic>>>{};
    DateTime? summaryAt;
    for (final r in rows) {
      final m = Map<String, dynamic>.from(r as Map);
      final data = m['data'] is Map
          ? Map<String, dynamic>.from(m['data'] as Map)
          : <String, dynamic>{};
      byKind.putIfAbsent('${m['kind']}', () => {})['${m['period']}'] = data;
      if (m['kind'] == 'summary') {
        summaryAt = DateTime.tryParse('${m['updated_at'] ?? ''}');
      }
    }
    Map<String, Map<String, dynamic>> sorted(String kind) {
      final m = byKind[kind] ?? const {};
      // 'FY2016' and '2025-09' both order correctly as plain strings.
      return {for (final k in m.keys.toList()..sort()) k: m[k]!};
    }

    return FundamentalsData(sorted('annual'), sorted('quarter'),
        sorted('shareholding'), byKind['summary']?['latest'] ?? const {},
        byKind['docs']?['latest'] ?? const {},
        summaryAt: summaryAt, hasDocsRow: byKind.containsKey('docs'));
  }
}

/// Should the page ask the pipeline for a deep pass? Not only when nothing
/// exists: a stock whose statements stop short of the latest filing, whose
/// NSE pieces (docs row) never ran, or whose summary is older than the
/// pipeline's own 7-day freshness gate gets refilled within minutes of being
/// opened (deep_new, 5-min group) instead of waiting its turn in the daily
/// warm. Every section on every stock fills the same way.
bool needsDeepRefresh(FundamentalsData d, {DateTime? now}) {
  now ??= DateTime.now();
  if (d.summary.isEmpty || !d.hasDocsRow || d.quarter.isEmpty) return true;
  final newest = DateTime.tryParse('${d.quarter.keys.last}-01');
  if (newest == null || now.difference(newest).inDays > 270) return true;
  final at = d.summaryAt;
  return at == null || now.difference(at).inDays > 7;
}

/// One select per symbol — a few KB. Errors surface as empty data; the page
/// keeps polling while the pipeline backfills (same rhythm as meta.f/t).
Future<FundamentalsData> loadFundamentals(String symbol) async {
  try {
    final rows = await Supabase.instance.client
        .from('fundamentals')
        .select('kind,period,data,updated_at')
        .eq('symbol', symbol);
    return FundamentalsData.fromRows(rows);
  } catch (_) {
    return FundamentalsData.fromRows(const []);
  }
}

/// 'FY2024' -> 'FY24' · '2026-06' -> 'Jun 26' · anything else unchanged.
String periodLabel(String p) {
  if (p.startsWith('FY') && p.length == 6) return 'FY${p.substring(4)}';
  final d = DateTime.tryParse('$p-01');
  if (d == null) return p;
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${m[d.month - 1]} ${d.year % 100}';
}

/// P/E over time for the chart overlay: price(t) / TTM-EPS(t), where TTM EPS
/// is a step function over quarter-end dates (sum of the 4 newest quarterly
/// eps ending on/before t). Null until 4 quarters exist or when TTM <= 0 —
/// the overlay simply starts where coverage starts.
List<double?> peSeries(List<double> closes, List<DateTime> times,
    Map<String, Map<String, dynamic>> quarters) {
  final pts = <(DateTime, double)>[];
  for (final p in quarters.keys.toList()..sort()) {
    final eps = quarters[p]!['eps'];
    final d = DateTime.tryParse('$p-01');
    if (eps is num && d != null) {
      pts.add((DateTime(d.year, d.month + 1, 0), eps.toDouble())); // month end
    }
  }
  final n = closes.length < times.length ? closes.length : times.length;
  return [
    for (var i = 0; i < n; i++)
      () {
        final have = [for (final (end, eps) in pts) if (!end.isAfter(times[i])) eps];
        if (have.length < 4) return null;
        final ttm = have.skip(have.length - 4).reduce((a, b) => a + b);
        return ttm > 0 ? closes[i] / ttm : null;
      }()
  ];
}

enum CellFmt { cr, pct, num2, days }

String fmtCell(num? v, CellFmt f) {
  if (v == null) return '—';
  switch (f) {
    case CellFmt.cr:
    case CellFmt.days:
      return fmtNum(v.toDouble(), decimals: 0);
    case CellFmt.pct:
      final s = v.toDouble() == v.roundToDouble()
          ? '${v.round()}'
          : v.toDouble().toStringAsFixed(1);
      return '$s%';
    case CellFmt.num2:
      return v.toDouble().toStringAsFixed(2);
  }
}
