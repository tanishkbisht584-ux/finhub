import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

/// The `fundamentals` table (migration 016) grouped for the stock page:
/// one row per (kind, period), data jsonb shaped by pipeline/fundamentals.py.
class FundamentalsData {
  const FundamentalsData(
      this.annual, this.quarter, this.shareholding, this.summary, this.docs);

  final Map<String, Map<String, dynamic>> annual; // 'FY2026' -> data, oldest first
  final Map<String, Map<String, dynamic>> quarter; // '2026-06' -> data
  final Map<String, Map<String, dynamic>> shareholding;
  final Map<String, dynamic> summary; // cagr/pros/cons/roce/book_value
  final Map<String, dynamic> docs;

  bool get isEmpty =>
      annual.isEmpty && quarter.isEmpty && shareholding.isEmpty && summary.isEmpty;

  factory FundamentalsData.fromRows(List<dynamic> rows) {
    final byKind = <String, Map<String, Map<String, dynamic>>>{};
    for (final r in rows) {
      final m = Map<String, dynamic>.from(r as Map);
      final data = m['data'] is Map
          ? Map<String, dynamic>.from(m['data'] as Map)
          : <String, dynamic>{};
      byKind.putIfAbsent('${m['kind']}', () => {})['${m['period']}'] = data;
    }
    Map<String, Map<String, dynamic>> sorted(String kind) {
      final m = byKind[kind] ?? const {};
      // 'FY2016' and '2025-09' both order correctly as plain strings.
      return {for (final k in m.keys.toList()..sort()) k: m[k]!};
    }

    return FundamentalsData(sorted('annual'), sorted('quarter'),
        sorted('shareholding'), byKind['summary']?['latest'] ?? const {},
        byKind['docs']?['latest'] ?? const {});
  }
}

/// One select per symbol — a few KB. Errors surface as empty data; the page
/// keeps polling while the pipeline backfills (same rhythm as meta.f/t).
Future<FundamentalsData> loadFundamentals(String symbol) async {
  try {
    final rows = await Supabase.instance.client
        .from('fundamentals')
        .select('kind,period,data')
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
