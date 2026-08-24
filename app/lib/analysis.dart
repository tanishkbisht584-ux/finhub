import 'models.dart';

/// Renders `quotes.meta.f` / `meta.t` (pipeline/market.py) into label/value
/// lines for the stock page. Pure functions so the strips are testable without
/// pumping StockScreen (which talks to Supabase in initState).

/// ₹ raw value -> "₹832,884 Cr" / "₹8.33L Cr". Company-scale money only.
String fmtCrore(num v) {
  final cr = v / 1e7;
  if (cr >= 1e5) return '₹${fmtNum(cr / 1e5, indian: false, decimals: 2)}L Cr';
  return '₹${fmtNum(cr.toDouble(), decimals: 0)} Cr';
}

String fmtDay(Object? iso) {
  final d = DateTime.tryParse('$iso');
  if (d == null) return '';
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${m[d.month - 1]}';
}

List<(String, String)> fundamentalLines(Map<String, dynamic> meta) {
  final f = (meta['f'] as Map?)?.cast<String, dynamic>();
  if (f == null || f.isEmpty) return const [];
  double? n(String k) => (f[k] as num?)?.toDouble();
  final out = <(String, String)>[];
  void add(String label, String? v) {
    if (v != null && v.isNotEmpty) out.add((label, v));
  }

  final pe = n('pe'), fpe = n('fwd_pe');
  add('P/E', pe == null ? null
      : fmtNum(pe, indian: false) + (fpe != null ? ' · fwd ${fmtNum(fpe, indian: false)}' : ''));
  add('P/B', n('pb') == null ? null : fmtNum(n('pb')!, indian: false));
  add('Mkt cap', n('mcap') == null ? null : fmtCrore(n('mcap')!));
  add('EPS (TTM)', n('eps') == null ? null : '₹${fmtNum(n('eps')!, indian: false)}');
  add('Div yield', n('div_yield') == null ? null : '${fmtNum(n('div_yield')!, indian: false)}%');
  add('ROE', n('roe') == null ? null : '${fmtNum(n('roe')!, indian: false)}%');
  add('Debt/Equity', n('de') == null ? null : fmtNum(n('de')!, indian: false, decimals: 2));
  add('Net margin', n('margin') == null ? null : '${fmtNum(n('margin')!, indian: false)}%');
  final rg = n('rev_growth'), eg = n('earn_growth');
  add('Growth (YoY)', rg == null && eg == null ? null
      : [
          if (rg != null) 'rev ${fmtPct(rg, decimals: 1)}',
          if (eg != null) 'earnings ${fmtPct(eg, decimals: 1)}',
        ].join(' · '));
  final pr = n('promoter_pct'), inst = n('inst_pct');
  add('Holding', pr == null && inst == null ? null
      : [
          if (pr != null) 'promoter ${fmtNum(pr, indian: false)}%',
          if (inst != null) 'inst ${fmtNum(inst, indian: false)}%',
        ].join(' · '));
  final target = n('target');
  final rec = (f['rec'] as String?)?.replaceAll('_', ' ');
  add('Analyst', target == null && rec == null ? null
      : [
          if (target != null) 'target ₹${fmtNum(target, decimals: 0)}',
          if (rec != null && rec != 'none') rec.toUpperCase(),
        ].join(' · '));
  final q = (f['quarters'] as List?)?.cast<Map>();
  if (q != null && q.isNotEmpty) {
    final last = q.first;
    final rev = (last['revenue'] as num?), pat = (last['net_income'] as num?);
    if (rev != null || pat != null) {
      add('Last quarter', [
        if (rev != null) 'rev ${fmtCrore(rev)}',
        if (pat != null) 'PAT ${fmtCrore(pat)}',
      ].join(' · '));
    }
  }
  add('Beta', n('beta') == null ? null : fmtNum(n('beta')!, indian: false, decimals: 2));
  final sector = f['sector'] as String?, industry = f['industry'] as String?;
  add('Sector', [sector, industry].whereType<String>().join(' · '));
  return out;
}

List<(String, String)> technicalLines(Map<String, dynamic> meta) {
  final t = (meta['t'] as Map?)?.cast<String, dynamic>();
  if (t == null || t.isEmpty) return const [];
  double? n(String k) => (t[k] as num?)?.toDouble();
  final out = <(String, String)>[];
  void add(String label, String? v) {
    if (v != null && v.isNotEmpty) out.add((label, v));
  }

  final rsi = n('rsi14');
  add('RSI-14', rsi == null ? null
      : '${fmtNum(rsi, indian: false, decimals: 0)} · ${rsi >= 70 ? 'overbought' : rsi <= 30 ? 'oversold' : 'neutral'}');
  final vs50 = n('vs50'), vs200 = n('vs200');
  add('vs moving avgs', vs50 == null && vs200 == null ? null
      : [
          if (vs50 != null) '50-DMA ${fmtPct(vs50, decimals: 1)}',
          if (vs200 != null) '200-DMA ${fmtPct(vs200, decimals: 1)}',
        ].join(' · '));
  final trend = t['trend'] as String?;
  final above = t['above200'] as bool?;
  add('Trend', trend == null ? null
      : trend.toUpperCase() + (above == null ? '' : above ? ' · above 200-DMA' : ' · below 200-DMA'));
  final hi = n('hi52'), lo = n('lo52'), pos = n('pos52');
  add('52-wk range', hi == null || lo == null ? null
      : '₹${fmtNum(lo, decimals: 0)} – ₹${fmtNum(hi, decimals: 0)}'
        '${pos == null ? '' : ' · at ${(pos * 100).round()}%'}');
  final vr = n('vol_ratio');
  add('Volume', vr == null ? null : '${fmtNum(vr, indian: false)}× 20-day avg');
  final macd = n('macd_hist');
  add('MACD', macd == null ? null : macd > 0 ? 'bullish' : macd < 0 ? 'bearish' : 'flat');
  return out;
}

/// True when the pipeline has produced neither strip for this symbol — the
/// signal to drop a row into analysis_requests (market.refresh_analysis_new
/// backfills it within ~5 min).
bool needsAnalysisRequest(Map<String, dynamic> meta) =>
    meta['f'] == null && meta['t'] == null;
