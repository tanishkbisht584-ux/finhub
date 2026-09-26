import 'screens/screens.dart' show ScreenFilter, metricDefs;

/// Typed screens (Phase C, 26 Sep 2026): `ROCE > 20 AND Debt to equity < 0.5`
/// → the same `ScreenFilter` list the pills build, so one PostgREST query
/// serves both. AND-only on purpose: PostgREST cannot express OR across
/// columns or `pe < sector_pe` without an RPC — both are refused with a
/// message rather than silently misread.
/// ponytail: `>` and `<` are served as ≥ / ≤ (PostgREST gte/lte) — the
/// difference at exactly 15.0 is not worth two more operators.

typedef ParsedQuery = ({List<ScreenFilter> filters, String? error});

/// phrase → column. Built once from metricDefs labels + the ways people
/// actually type them (Screener.in / MC wording).
final Map<String, String> metricAliases = _build();

Map<String, String> _build() {
  final m = <String, String>{};
  for (final d in metricDefs) {
    m[d.col] = d.col;
    m[_norm(d.label)] = d.col;
  }
  const extra = {
    'pe': ['p/e', 'pe ratio', 'price to earnings', 'price earnings'],
    'pb': ['p/b', 'pb ratio', 'price to book', 'price book'],
    'ps': ['p/s', 'price to sales', 'ps ratio'],
    'mcap_cr': ['market cap', 'mcap', 'market capitalisation', 'market capitalization', 'mcap cr', 'market cap cr'],
    'div_yield': ['dividend yield', 'div yield', 'yield', 'dividend'],
    'roe': ['return on equity'],
    'roce': ['return on capital employed', 'return on capital'],
    'roic': ['return on invested capital'],
    'de': ['debt to equity', 'debt/equity', 'd/e', 'debt equity', 'debt eq', 'debt'],
    'opm': ['operating margin', 'op margin', 'operating profit margin'],
    'sales_cagr_3y': ['sales growth 3y', 'sales cagr 3y', 'sales 3y', 'revenue growth 3y', 'sales growth 3 years', 'sales growth'],
    'profit_cagr_3y': ['profit growth 3y', 'profit cagr 3y', 'profit 3y', 'profit growth 3 years', 'profit growth'],
    'sales_cagr_5y': ['sales growth 5y', 'sales cagr 5y', 'sales 5y', 'sales growth 5 years'],
    'profit_cagr_5y': ['profit growth 5y', 'profit cagr 5y', 'profit 5y', 'profit growth 5 years'],
    'promoter_pct': ['promoter holding', 'promoter', 'promoters', 'promoter %'],
    'ret_1w': ['return 1w', '1w return', '1 week return', 'ret 1w', 'week return'],
    'ret_1m': ['return 1m', '1m return', '1 month return', 'ret 1m', 'month return'],
    'ret_3m': ['return 3m', '3m return', '3 month return', 'ret 3m'],
    'ret_6m': ['return 6m', '6m return', '6 month return', 'ret 6m'],
    'ret_ytd': ['ytd', 'return ytd', 'ytd return'],
    'ret_1y': ['return 1y', '1y return', '1 year return', 'ret 1y', 'year return'],
    'ret_3y': ['return 3y', '3y return', '3 year return', 'ret 3y'],
    'ret_5y': ['return 5y', '5y return', '5 year return', 'ret 5y'],
    'ath_pct': ['from ath', 'ath', 'below ath', 'ath pct', 'from all time high'],
    'turnover_cr': ['turnover', 'daily turnover', 'turnover cr'],
    'avg_vol': ['avg volume', 'average volume', 'volume', 'avg vol'],
    'rel_vol': ['relative volume', 'rel volume', 'rel vol', 'rvol'],
    'sharpe': ['sharpe ratio'],
    'sortino': ['sortino ratio'],
    'atr': ['average true range', 'atr %'],
    'graham_upside': ['graham', 'graham upside', 'graham number upside'],
    'f_score': ['f score', 'piotroski', 'piotroski score', 'fscore'],
    'earnings_yield': ['earnings yield', 'e/p'],
    'fcf_yield': ['fcf yield', 'free cash flow yield'],
    'int_cov': ['interest coverage', 'interest cover', 'int cov', 'icr'],
    'ev_ebitda': ['ev/ebitda', 'ev to ebitda', 'ev ebitda'],
    'sector_pe': ['sector pe', 'sector p/e'],
    'industry_pe': ['industry pe', 'industry p/e'],
    'shares_yoy': ['shares yoy', 'dilution', 'share count growth', 'equity dilution'],
    'rsi': ['rsi 14', 'rsi14', 'relative strength'],
    'altman_z': ['altman z', 'altman', 'z score', 'altman z score', 'z-score'],
    'beta_5y': ['beta', 'beta 5y', '5y beta'],
  };
  final known = {for (final d in metricDefs) d.col};
  for (final e in extra.entries) {
    if (!known.contains(e.key)) continue;
    for (final a in e.value) {
      m[_norm(a)] = e.key;
    }
  }
  return m;
}

String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[_\-]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// The column for a typed metric name, or null.
String? resolveMetric(String text) {
  var t = _norm(text);
  if (metricAliases[t] != null) return metricAliases[t];
  t = t.replaceAll(RegExp(r'\s*(ratio|%|percent|pct)$'), '').trim();
  if (metricAliases[t] != null) return metricAliases[t];
  // "roe ratio", "the pe" … strip filler words
  t = t.replaceAll(RegExp(r'^(the|a|its)\s+'), '').trim();
  return metricAliases[t];
}

final _clause = RegExp(r'^(.*?)\s*(>=|<=|=<|=>|>|<|=|≥|≤|==)\s*(-?[\d,]*\.?\d+)\s*(%|cr|crore|crores|k|x|times)?\s*$',
    caseSensitive: false);

/// Parse `metric op number [unit] AND …`. Errors name the offending clause.
ParsedQuery parseScreenQuery(String text) {
  final src = text.trim();
  if (src.isEmpty) return (filters: const [], error: null);
  if (RegExp(r'\bor\b|\|\|', caseSensitive: false).hasMatch(src)) {
    return (filters: const [], error: 'OR is not supported yet — every rule must hold (AND)');
  }
  final clauses = src
      .split(RegExp(r'\s+and\s+|\s*&&\s*|\s*[;\n]\s*|\s*,\s*(?=[A-Za-z])', caseSensitive: false))
      .map((c) => c.trim())
      .where((c) => c.isNotEmpty)
      .toList();
  final out = <ScreenFilter>[];
  for (final c in clauses) {
    final m = _clause.firstMatch(c);
    if (m == null) {
      if (RegExp(r'[<>=≥≤]').hasMatch(c) && RegExp(r'[<>=≥≤]\s*[A-Za-z_]').hasMatch(c)) {
        return (filters: const [], error: 'comparing two metrics ("$c") is not supported yet — compare with a number');
      }
      return (filters: const [], error: 'could not read "$c" — write it as METRIC > NUMBER, e.g. ROCE > 20');
    }
    final col = resolveMetric(m[1]!);
    if (col == null) {
      return (filters: const [], error: 'unknown metric "${m[1]!.trim()}" — try PE, ROE, ROCE, market cap, debt to equity, sales growth 3y…');
    }
    var value = double.tryParse(m[3]!.replaceAll(',', ''));
    if (value == null) return (filters: const [], error: 'not a number in "$c"');
    final unit = (m[4] ?? '').toLowerCase();
    if (unit == 'k') value *= 1000;
    final op = m[2]!;
    if (op == '=' || op == '==') {
      out.add((metric: col, gte: true, value: value));
      out.add((metric: col, gte: false, value: value));
    } else {
      final gte = op == '>' || op == '>=' || op == '=>' || op == '≥';
      out.add((metric: col, gte: gte, value: value));
    }
  }
  return (filters: out, error: null);
}

/// Filters → the text the bar shows (pill edits regenerate it).
String screenQueryText(List<ScreenFilter> filters) {
  String label(String col) {
    for (final d in metricDefs) {
      if (d.col == col) return d.label;
    }
    return col;
  }

  String num(double v) => v == v.roundToDouble() ? v.round().toString() : v.toString();
  return [for (final f in filters) '${label(f.metric)} ${f.gte ? '>=' : '<='} ${num(f.value)}'].join(' AND ');
}

const screenQueryExamples = [
  'ROCE > 20 AND Debt to equity < 0.5',
  'PE < 15 AND ROE > 15 AND market cap > 500',
  'dividend yield > 3 AND promoter > 50',
  'RSI < 30 AND Altman Z > 3',
  'sales growth 3y > 15 AND profit growth 3y > 15 AND PE < 25',
];
