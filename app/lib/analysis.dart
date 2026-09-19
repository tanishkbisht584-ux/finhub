import 'models.dart';

/// Renders `quotes.meta.f` / `meta.t` (pipeline/market.py) into the stock
/// page's tiles and labelled tables. Pure functions so the sections are
/// testable without pumping StockScreen (which talks to Supabase in initState).
///
/// Tone is -1 / 0 / +1 (red / ink / green) so this file stays Flutter-free.

/// One bordered tile: label · value · optional sub line.
typedef Stat = ({String label, String value, String? sub, int tone});

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

Map<String, dynamic>? _sub(Map<String, dynamic> meta, String k) =>
    (meta[k] as Map?)?.cast<String, dynamic>();

String _n2(double v) => fmtNum(v, indian: false, decimals: 2);
String _pct1(double v) => '${fmtNum(v, indian: false, decimals: 1)}%';
String _signed(double v, {int decimals = 1}) =>
    '${v > 0 ? '+' : v < 0 ? '−' : ''}${v.abs().toStringAsFixed(decimals)}%';

/// SNAPSHOT tiles: the six headline ratios.
/// KEY STATS tiles. With [sectorPe] (screener_metrics.sector_pe) the P/E
/// tile carries MC's verdict ("below sector 22.8") and a tone; [ath] /
/// [athPct] (Stock Analysis) add the all-time-high tile.
List<Stat> snapshotStats(Map<String, dynamic> meta,
    {double? sectorPe, double? ath, double? athPct}) {
  final f = _sub(meta, 'f');
  if (f == null || f.isEmpty) return const [];
  double? n(String k) => (f[k] as num?)?.toDouble();
  final out = <Stat>[];
  void add(String label, double? v, String Function(double) fmt,
      {String? sub, int tone = 0}) {
    if (v != null) out.add((label: label, value: fmt(v), sub: sub, tone: tone));
  }

  add('Mkt cap', n('mcap'), fmtCrore);
  final pe = n('pe');
  final peSubs = [
    if (n('fwd_pe') != null) 'fwd ${_n2(n('fwd_pe')!)}',
    if (pe != null && sectorPe != null && sectorPe > 0)
      '${pe < sectorPe ? 'below' : 'above'} sector ${_n2(sectorPe)}',
  ];
  add('P/E', pe, _n2,
      sub: peSubs.isEmpty ? null : peSubs.join(' · '),
      tone: pe == null || sectorPe == null || sectorPe <= 0
          ? 0
          : pe < sectorPe
              ? 1
              : -1);
  add('EPS', n('eps'), (v) => '₹${_n2(v)}', sub: 'TTM');
  add('P/B', n('pb'), _n2);
  final roe = n('roe');
  add('ROE', roe, _pct1,
      sub: roe == null ? null : roe >= 15 ? 'strong' : roe < 8 ? 'weak' : null,
      tone: roe == null ? 0 : roe >= 15 ? 1 : roe < 8 ? -1 : 0);
  add('Div yield', n('div_yield'), _pct1);
  add('Debt/Equity', n('de'), _n2,
      tone: n('de') == null ? 0 : n('de')! > 2 ? -1 : 0);
  add('Beta', n('beta'), _n2,
      sub: n('beta') == null ? null : n('beta')! > 1 ? 'swings more than market' : 'calmer than market');
  if (ath != null) {
    add('All-time high', ath, (v) => '₹${fmtNum(v)}',
        sub: athPct == null ? null : '${_signed(athPct)} from high',
        tone: athPct == null ? 0 : athPct >= -5 ? 1 : athPct <= -30 ? -1 : 0);
  }
  return out;
}

/// RETURNS 3×3 (MC's absolute-returns block) from the Stock Analysis
/// columns; a missing column is a null cell, not a dropped one.
List<(String, double?)> returnsGrid(Map<String, dynamic> r) => [
      for (final (k, l) in const [
        ('ret_1w', '1W'), ('ret_1m', '1M'), ('ret_3m', '3M'),
        ('ret_6m', '6M'), ('ret_ytd', 'YTD'), ('ret_1y', '1Y'),
        ('ret_3y', '3Y'), ('ret_5y', '5Y'), ('ath_pct', 'vs ATH'),
      ])
        (l, (r[k] as num?)?.toDouble()),
    ];

/// ANALYSTS tiles (MC's rating circle): consensus word + count, target +
/// upside. Empty when Stock Analysis carries no street view for the symbol.
List<Stat> streetStats(Map<String, dynamic> r) {
  final sa = (r['sa'] as Map?)?.cast<String, dynamic>() ?? const {};
  final rating = sa['analystRatings'] as String?;
  final count = (sa['analystCount'] as num?)?.toInt();
  final target = (sa['priceTarget'] as num?)?.toDouble();
  final up = (sa['priceTargetChange'] as num?)?.toDouble();
  final out = <Stat>[];
  if (rating != null && rating.isNotEmpty) {
    final w = rating.toLowerCase();
    out.add((
      label: 'Consensus',
      value: rating.toUpperCase(),
      sub: count == null ? null : '$count analysts',
      tone: w.contains('buy') ? 1 : w.contains('sell') ? -1 : 0,
    ));
  }
  if (target != null) {
    out.add((
      label: 'Target',
      value: '₹${fmtNum(target, decimals: 0)}',
      sub: up == null ? null : '${_signed(up)} to target',
      tone: up == null ? 0 : up > 0 ? 1 : -1,
    ));
  }
  return out;
}

/// TECHNICALS tiles: trend, RSI, MACD — the three one-word reads.
List<Stat> techStats(Map<String, dynamic> meta) {
  final t = _sub(meta, 't');
  if (t == null || t.isEmpty) return const [];
  double? n(String k) => (t[k] as num?)?.toDouble();
  final out = <Stat>[];
  final trend = t['trend'] as String?;
  final above = t['above200'] as bool?;
  if (trend != null) {
    out.add((
      label: 'Trend',
      value: trend.toUpperCase(),
      sub: above == null ? null : (above ? 'above 200-DMA' : 'below 200-DMA'),
      tone: trend == 'up' ? 1 : trend == 'down' ? -1 : 0,
    ));
  }
  final rsi = n('rsi14');
  if (rsi != null) {
    out.add((
      label: 'RSI-14',
      value: '${rsi.round()}',
      sub: rsiZone(rsi),
      tone: rsi >= 70 ? -1 : rsi <= 30 ? 1 : 0,
    ));
  }
  final macd = n('macd_hist');
  if (macd != null) {
    out.add((
      label: 'MACD',
      value: macdWord(macd),
      sub: 'hist ${macd > 0 ? '+' : ''}${_n2(macd)}',
      tone: macd > 0 ? 1 : macd < 0 ? -1 : 0,
    ));
  }
  return out;
}

String rsiZone(double rsi) =>
    rsi >= 70 ? 'overbought' : rsi <= 30 ? 'oversold' : 'neutral';
String macdWord(double h) => h > 0 ? 'bullish' : h < 0 ? 'bearish' : 'flat';

/// Median of each numeric screener column across [peers], self excluded, so
/// the SECTOR column reads "the rest of the sector".
Map<String, double> sectorMedians(List<Map<String, dynamic>> peers, {String? self}) {
  const keys = ['pe', 'pb', 'roe', 'roce', 'de', 'div_yield', 'promoter_pct', 'mcap_cr', 'opm'];
  final out = <String, double>{};
  for (final k in keys) {
    final vals = [
      for (final p in peers)
        if (p['symbol'] != self && p[k] is num) (p[k] as num).toDouble()
    ]..sort();
    if (vals.isEmpty) continue;
    final mid = vals.length ~/ 2;
    out[k] = vals.length.isOdd ? vals[mid] : (vals[mid - 1] + vals[mid]) / 2;
  }
  return out;
}

/// above/below/in-line word + tone. [good] says which side is the good one
/// (+1 higher is better, -1 lower is better, 0 valuation — no verdict).
(String, int) _cmp(double v, double? med, int good) {
  if (med == null || med == 0) return ('', 0);
  final d = (v - med) / med.abs();
  if (d.abs() < 0.1) return ('in line', 0);
  if (good == 0) return (d > 0 ? 'premium' : 'discount', 0);
  final above = d > 0;
  final word = good > 0 ? (above ? 'above peers' : 'below peers')
                        : (above ? 'heavier' : 'lighter');
  return (word, (above ? 1 : -1) * good);
}

/// FUNDAMENTALS table: every meta.f ratio, ROCE/book value from the summary
/// row, sector medians from [sectorMedians]. Nothing the pipeline computed is
/// dropped — the tiles above repeat six of these on purpose.
List<KvRow> fundamentalRows(Map<String, dynamic> meta,
    {Map<String, double> medians = const {}, Map<String, dynamic> summary = const {}}) {
  final f = _sub(meta, 'f');
  if (f == null || f.isEmpty) return const [];
  double? n(String k) => (f[k] as num?)?.toDouble();
  double? med(String k) => medians[k];
  String medS(String k, String Function(double) fmt) =>
      med(k) == null ? '—' : fmt(med(k)!);
  final out = <KvRow>[];
  void row(String metric, String value, String third, String read, int tone) =>
      out.add((metric: metric, value: value, third: third, read: read, tone: tone));

  final pe = n('pe'), fpe = n('fwd_pe');
  if (pe != null) {
    final (w, _) = _cmp(pe, med('pe'), 0);
    row('P/E', _n2(pe), medS('pe', _n2),
        [if (w.isNotEmpty) w, if (fpe != null) 'fwd ${_n2(fpe)}'].join(' · '), 0);
  }
  final pb = n('pb');
  if (pb != null) {
    final (w, _) = _cmp(pb, med('pb'), 0);
    row('P/B', _n2(pb), medS('pb', _n2), w, 0);
  }
  final mcap = n('mcap');
  if (mcap != null) {
    final m = med('mcap_cr');
    row('Mkt cap', fmtCrore(mcap), m == null ? '—' : fmtCrore(m * 1e7),
        m == null || m == 0 ? '' : '${fmtNum(mcap / 1e7 / m, indian: false, decimals: 1)}× median', 0);
  }
  final eps = n('eps');
  if (eps != null) row('EPS (TTM)', '₹${_n2(eps)}', '—', 'trailing 4 quarters', 0);
  final dy = n('div_yield');
  if (dy != null) {
    final (w, tone) = _cmp(dy, med('div_yield'), 1);
    row('Div yield', _pct1(dy), medS('div_yield', _pct1), w, tone);
  }
  final roe = n('roe');
  if (roe != null) {
    final (w, tone) = _cmp(roe, med('roe'), 1);
    row('ROE', _pct1(roe), medS('roe', _pct1), w, tone);
  }
  final roce = (summary['roce'] as num?)?.toDouble();
  if (roce != null) {
    final (w, tone) = _cmp(roce, med('roce'), 1);
    row('ROCE', _pct1(roce), medS('roce', _pct1), w, tone);
  }
  final de = n('de');
  if (de != null) {
    final (w, tone) = _cmp(de, med('de'), -1);
    row('Debt/Equity', _n2(de), medS('de', _n2), w, tone);
  }
  final margin = n('margin');
  if (margin != null) row('Net margin', _pct1(margin), '—', 'of revenue', 0);
  final rg = n('rev_growth');
  if (rg != null) row('Rev growth', _signed(rg), '—', 'YoY', rg > 0 ? 1 : rg < 0 ? -1 : 0);
  final eg = n('earn_growth');
  if (eg != null) row('Earn growth', _signed(eg), '—', 'YoY', eg > 0 ? 1 : eg < 0 ? -1 : 0);
  final pr = n('promoter_pct'), inst = n('inst_pct');
  if (pr != null || inst != null) {
    row('Promoter', pr == null ? '—' : _pct1(pr), medS('promoter_pct', _pct1),
        inst == null ? '' : 'institutions ${_pct1(inst)}', 0);
  }
  final target = n('target');
  final rec = (f['rec'] as String?)?.replaceAll('_', ' ');
  if (target != null || (rec != null && rec != 'none')) {
    final close = (_sub(meta, 't')?['close'] as num?)?.toDouble();
    final up = target != null && close != null && close > 0
        ? ' · ${_signed((target - close) / close * 100)} to target'
        : '';
    final recWord = rec == null || rec == 'none' ? '' : rec.toUpperCase();
    final tone = recWord.contains('BUY') ? 1 : recWord.contains('SELL') ? -1 : 0;
    row('Analyst', target == null ? '—' : '₹${fmtNum(target, decimals: 0)}', '—',
        '$recWord$up'.trim(), tone);
  }
  final beta = n('beta');
  if (beta != null) {
    row('Beta', _n2(beta), '—',
        beta < 1 ? 'less volatile than Nifty' : 'more volatile than Nifty', 0);
  }
  final bv = (summary['book_value'] as num?)?.toDouble();
  if (bv != null) row('Book value', '₹${fmtNum(bv, decimals: 0)}', '—', 'per share', 0);
  final sector = f['sector'] as String?, industry = f['industry'] as String?;
  if (sector != null || industry != null) {
    row('Sector', sector ?? '', '', industry ?? '', 0);
  }
  return out;
}

/// TECHNICALS table: every meta.t level, each against the close. The SMA
/// levels were computed by the pipeline all along and never shown.
List<KvRow> technicalRows(Map<String, dynamic> meta) {
  final t = _sub(meta, 't');
  if (t == null || t.isEmpty) return const [];
  double? n(String k) => (t[k] as num?)?.toDouble();
  final out = <KvRow>[];
  void row(String metric, String value, String third, String read, int tone) =>
      out.add((metric: metric, value: value, third: third, read: read, tone: tone));
  String rs(double v) => '₹${fmtNum(v, decimals: 0)}';
  final close = n('close');
  if (close != null) row('Close', rs(close), '—', 'last daily close', 0);

  final sma50 = n('sma50'), sma200 = n('sma200');
  void sma(String label, double? level, double? storedVs, {String extra = ''}) {
    if (level == null) return;
    final vs = storedVs ??
        (close == null || level == 0 ? null : (close - level) / level * 100);
    final above = vs == null ? null : vs >= 0;
    row(label, rs(level), vs == null ? '—' : _signed(vs),
        [if (above != null) above ? 'above' : 'below', if (extra.isNotEmpty) extra].join(' · '),
        above == null ? 0 : above ? 1 : -1);
  }

  sma('SMA-20', n('sma20'), null);
  sma('SMA-50', sma50, n('vs50'));
  sma('SMA-200', sma200, n('vs200'),
      extra: sma50 == null || sma200 == null ? ''
          : sma50 > sma200 ? 'golden cross' : sma50 < sma200 ? 'death cross' : '');

  final hi = n('hi52'), lo = n('lo52'), pos = n('pos52');
  if (hi != null) {
    final vs = close == null || hi == 0 ? null : (close - hi) / hi * 100;
    row('52-wk high', rs(hi), vs == null ? '—' : _signed(vs),
        pos == null ? '' : 'at ${(pos * 100).round()}% of range', 0);
  }
  if (lo != null) {
    final vs = close == null || lo == 0 ? null : (close - lo) / lo * 100;
    row('52-wk low', rs(lo), vs == null ? '—' : _signed(vs), 'off the low', 0);
  }
  final rsi = n('rsi14');
  if (rsi != null) {
    row('RSI-14', '${rsi.round()}', '—', '${rsiZone(rsi)} (30–70)',
        rsi >= 70 ? -1 : rsi <= 30 ? 1 : 0);
  }
  final macd = n('macd_hist');
  if (macd != null) {
    row('MACD hist', '${macd > 0 ? '+' : ''}${_n2(macd)}', '—', macdWord(macd),
        macd > 0 ? 1 : macd < 0 ? -1 : 0);
  }
  final vr = n('vol_ratio');
  if (vr != null) {
    row('Volume', '${_n2(vr)}×', '—',
        'vs 20-day avg · ${vr >= 1.5 ? 'active' : vr <= 0.6 ? 'quiet' : 'normal'}', 0);
  }
  final beta = (_sub(meta, 'f')?['beta'] as num?)?.toDouble();
  if (beta != null) row('Beta', _n2(beta), '—', 'vs Nifty 50', 0);
  return out;
}

/// RETURNS table: the symbol's own screener_metrics row, Stock Analysis
/// (S&P Global) columns only (pipeline/stockanalysis.py, migration 019) —
/// returns ladder, records, risk, street view, fair values, calendar, facts.
/// Rows whose value is missing are skipped; an empty row yields [].
List<KvRow> saRows(Map<String, dynamic> r) {
  if (r.isEmpty) return const [];
  final sa = (r['sa'] as Map?)?.cast<String, dynamic>() ?? const {};
  double? n(String k) => (r[k] as num?)?.toDouble();
  double? s(String k) => (sa[k] as num?)?.toDouble();
  String? sd(String k) => sa[k] == null || '${sa[k]}'.isEmpty ? null : dmy(sa[k]);
  final out = <KvRow>[];
  void row(String metric, String value, String third, String read, int tone) =>
      out.add((metric: metric, value: value, third: third, read: read, tone: tone));
  int sign(double v) => v > 0 ? 1 : v < 0 ? -1 : 0;
  String rs(double v, {int decimals = 0}) => '₹${fmtNum(v, decimals: decimals)}';

  // Returns and the all-time high moved to OVERVIEW (returnsGrid /
  // snapshotStats) in Phase 2; this table keeps the rest.
  final ath = s('allTimeHigh');
  if (ath != null && sd('allTimeHighDate') != null) {
    row('All-time high date', sd('allTimeHighDate')!, '', '', 0);
  }
  if (sd('high52Date') != null || sd('low52Date') != null) {
    row('52-wk high / low', sd('high52Date') ?? '—', sd('low52Date') ?? '—', 'dates', 0);
  }
  final sharpe = n('sharpe'), sortino = n('sortino');
  if (sharpe != null || sortino != null) {
    row('Sharpe / Sortino', sharpe == null ? '—' : _n2(sharpe),
        sortino == null ? '—' : _n2(sortino), 'risk-adjusted return',
        sharpe == null ? 0 : sharpe >= 1 ? 1 : sharpe < 0 ? -1 : 0);
  }
  final atr = n('atr');
  if (atr != null) row('ATR', rs(atr, decimals: 2), '', 'avg daily range', 0);
  final rv = n('rel_vol'), to = n('turnover_cr');
  if (rv != null || to != null) {
    row('Rel. volume', rv == null ? '—' : '${_n2(rv)}×', '',
        to == null ? '' : 'turnover ${rs(to)} Cr/day', 0);
  }
  // Street view -> ANALYSTS tiles (streetStats) in Phase 2.
  final graham = s('grahamNumber'), gu = n('graham_upside');
  if (graham != null) {
    row('Graham number', rs(graham), '', gu == null ? '' : '${_signed(gu)} upside',
        gu == null ? 0 : sign(gu));
  }
  final f = n('f_score');
  if (f != null) {
    row('Piotroski F', '${f.round()}/9', '', f >= 7 ? 'strong' : f <= 3 ? 'weak' : 'middling',
        f >= 7 ? 1 : f <= 3 ? -1 : 0);
  }
  final ps = n('ps'), spe = n('sector_pe'), ipe = n('industry_pe');
  if (ps != null) {
    row('P/S', _n2(ps), '', [if (spe != null) 'sector PE ${_n2(spe)}', if (ipe != null) 'industry PE ${_n2(ipe)}'].join(' · '), 0);
  }
  for (final (k, label, unit) in const [
    ('ev_ebitda', 'EV/EBITDA', ''), ('roic', 'ROIC', '%'), ('int_cov', 'Interest cover', '×'),
    ('fcf_yield', 'FCF yield', '%'), ('earnings_yield', 'Earnings yield', '%'),
  ]) {
    final v = n(k);
    if (v != null) row(label, '${_n2(v)}$unit', '', '', 0);
  }
  final sy = n('shares_yoy');
  if (sy != null) row('Shares YoY', _signed(sy, decimals: 2), '', sy > 1 ? 'diluting' : sy < 0 ? 'buying back' : 'stable', sy > 1 ? -1 : sy < 0 ? 1 : 0);
  final next = sd('nextEarningsDate');
  if (next != null) row('Next results', next, '', sd('lastReportDate') == null ? '' : 'last report ${sd('lastReportDate')}', 0);
  final xd = sd('exDivDate');
  if (xd != null) row('Ex-dividend', xd, '', sd('paymentDate') == null ? '' : 'pays ${sd('paymentDate')}', 0);
  final emp = s('employees'), founded = sa['founded'];
  if (emp != null || founded != null) {
    row('Company', emp == null ? '—' : '${fmtNum(emp, decimals: 0)} staff',
        founded == null ? '' : 'est. $founded', '${sa['isin'] ?? ''}', 0);
  }
  return out;
}

/// Last [n] quarters of sales and net profit (₹ Cr) for the bar chart, oldest
/// first. The `fundamentals` table is preferred (full history, already in
/// Cr); meta.f.quarters (newest-first, raw ₹) is the fallback.
({List<double?> sales, List<double?> profit, List<String> labels}) quarterSeries(
    Map<String, Map<String, dynamic>> quarters, Map<String, dynamic> meta,
    {int n = 8, String Function(String)? label}) {
  if (quarters.isNotEmpty) {
    final keys = quarters.keys.toList()..sort();
    final last = keys.length > n ? keys.sublist(keys.length - n) : keys;
    double? v(String p, String k) => (quarters[p]![k] as num?)?.toDouble();
    return (
      sales: [for (final p in last) v(p, 'sales')],
      profit: [for (final p in last) v(p, 'net_profit')],
      labels: [for (final p in last) label == null ? p : label(p)],
    );
  }
  final q = (_sub(meta, 'f')?['quarters'] as List?)?.cast<Map>().reversed.toList();
  if (q == null || q.isEmpty) return (sales: const [], profit: const [], labels: const []);
  double? cr(Map m, String k) => m[k] is num ? (m[k] as num) / 1e7 : null;
  const mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String lbl(Map m) {
    final d = DateTime.tryParse('${m['end']}');
    return d == null ? '' : '${mon[d.month - 1]} ${d.year % 100}';
  }

  return (
    sales: [for (final m in q) cr(m, 'revenue')],
    profit: [for (final m in q) cr(m, 'net_income')],
    labels: [for (final m in q) lbl(m)],
  );
}

/// True when the pipeline has produced neither strip for this symbol — the
/// signal to drop a row into analysis_requests (market.refresh_analysis_new
/// backfills it within ~5 min).
bool needsAnalysisRequest(Map<String, dynamic> meta) =>
    meta['f'] == null && meta['t'] == null;

// ---------------------------------------------------------------------------
// Phase 3 (20 Sep): INSIGHTS · VITALS · TECHNICALS · SEASONALITY — pure
// functions over data the app already holds (quotes.meta, screener_metrics,
// fundamentals summary/annual, a Yahoo monthly chart). Nothing here fetches.
// ---------------------------------------------------------------------------

/// One scored dimension: label, points earned, points possible, one-line read.
typedef ScorePart = ({String label, int points, int max, String read});

/// FinSwipe score: 0–100, normalised over the dimensions we can actually
/// measure for this stock (a missing dimension shrinks the denominator rather
/// than dragging the score). Transparent on purpose — the section prints
/// every part. Weights: strength 30 · growth 25 · valuation 25 · trend 20.
typedef ScoreCard = ({int score, String verdict, List<ScorePart> parts});

ScoreCard? finScore(Map<String, dynamic> meta,
    {Map<String, dynamic> sa = const {}, Map<String, dynamic> summary = const {}}) {
  final f = _sub(meta, 'f') ?? const {};
  final t = _sub(meta, 't') ?? const {};
  double? fn(String k) => (f[k] as num?)?.toDouble();
  double? sn(String k) => (sa[k] as num?)?.toDouble();
  final parts = <ScorePart>[];

  // Financial strength: Piotroski (0–9 → 0–20) + leverage (0–10).
  final fs = sn('f_score'), de = fn('de'), roe = fn('roe');
  if (fs != null || roe != null) {
    final base = fs != null ? (fs / 9 * 20).round() : roe! >= 15 ? 14 : roe >= 8 ? 8 : 0;
    final lev = de == null ? 5 : de < 1 ? 10 : de < 2 ? 5 : 0;
    parts.add((
      label: 'Financial strength',
      points: base + lev,
      max: 30,
      read: [
        if (fs != null) 'Piotroski ${fs.round()}/9',
        if (de != null) 'D/E ${_n2(de)}',
        if (fs == null && roe != null) 'ROE ${_pct1(roe)}',
      ].join(' · '),
    ));
  }
  // Growth: 3-year profit CAGR, else the quarterly earnings growth Yahoo gives.
  final cagr = (summary['cagr'] as Map?)?.cast<String, dynamic>();
  final profit3 = ((cagr?['profit'] as Map?)?['y3'] as num?)?.toDouble();
  final g = profit3 ?? fn('earn_growth');
  if (g != null) {
    parts.add((
      label: 'Growth',
      points: g >= 20 ? 25 : g >= 10 ? 15 : g >= 0 ? 8 : 0,
      max: 25,
      read: profit3 != null ? 'profit ${_signed(g)} CAGR 3y' : 'earnings ${_signed(g)} YoY',
    ));
  }
  // Valuation: P/E against the sector's.
  final pe = fn('pe'), spe = sn('sector_pe');
  if (pe != null && spe != null && spe > 0) {
    final r = pe / spe;
    parts.add((
      label: 'Valuation',
      points: r <= 0.8 ? 25 : r <= 1 ? 18 : r <= 1.3 ? 10 : 3,
      max: 25,
      read: 'P/E ${_n2(pe)} vs sector ${_n2(spe)}',
    ));
  }
  // Trend: the MA-stack read the pipeline already computes.
  final trend = t['trend'] as String?;
  if (trend != null) {
    parts.add((
      label: 'Trend',
      points: trend == 'up' ? 20 : trend == 'mixed' ? 10 : 0,
      max: 20,
      read: '$trend · ${t['above200'] == true ? 'above' : 'below'} 200-DMA',
    ));
  }
  if (parts.isEmpty) return null;
  final max = parts.fold(0, (a, p) => a + p.max);
  final pts = parts.fold(0, (a, p) => a + p.points);
  final score = (pts / max * 100).round();
  String grade(String label, List<String> words) {
    final p = parts.where((x) => x.label == label).firstOrNull;
    if (p == null) return '';
    final r = p.points / p.max;
    return r >= 0.75 ? words[0] : r >= 0.4 ? words[1] : words[2];
  }

  final verdict = [
    grade('Financial strength', ['Strong financials', 'Fair financials', 'Weak financials']),
    grade('Growth', ['high growth', 'moderate growth', 'low growth']),
    grade('Valuation', ['attractive valuation', 'reasonable valuation', 'expensive valuation']),
    grade('Trend', ['uptrend', 'sideways', 'downtrend']),
  ].where((s) => s.isNotEmpty).join(', ');
  return (score: score, verdict: verdict, parts: parts);
}

/// SWOT: strengths / weaknesses from the pipeline's pros / cons plus a few
/// rule reads; opportunities and threats from the street, the tape and the
/// chart. Each list is short sentences ready to print.
typedef Swot = ({List<String> s, List<String> w, List<String> o, List<String> t});

Swot swot(Map<String, dynamic> meta,
    {Map<String, dynamic> sa = const {}, Map<String, dynamic> summary = const {}}) {
  final f = _sub(meta, 'f') ?? const {};
  final t = _sub(meta, 't') ?? const {};
  final saj = (sa['sa'] as Map?)?.cast<String, dynamic>() ?? const {};
  double? fn(String k) => (f[k] as num?)?.toDouble();
  double? tn(String k) => (t[k] as num?)?.toDouble();
  double? sn(String k) => (sa[k] as num?)?.toDouble();
  final s = [for (final p in (summary['pros'] as List? ?? const [])) '$p'];
  final w = [for (final c in (summary['cons'] as List? ?? const [])) '$c'];
  final o = <String>[], th = <String>[];
  final de = fn('de');
  if (de != null && de < 0.15 && !s.any((x) => x.toLowerCase().contains('debt'))) {
    s.add('Company is almost debt-free');
  }
  final roe = fn('roe');
  if (roe != null && roe >= 20 && !s.any((x) => x.contains('ROE'))) {
    s.add('ROE of ${_pct1(roe)} is well above the 15% bar');
  }
  final up = (saj['priceTargetChange'] as num?)?.toDouble();
  final target = (saj['priceTarget'] as num?)?.toDouble();
  if (up != null && up >= 15 && target != null) {
    o.add('Street target ₹${fmtNum(target, decimals: 0)} is ${_signed(up)} away');
  }
  final ath = sn('ath_pct'), fs = sn('f_score');
  if (ath != null && ath <= -30 && fs != null && fs >= 6) {
    o.add('${_signed(ath)} from its all-time high with Piotroski ${fs.round()}/9');
  }
  final pe = fn('pe'), spe = sn('sector_pe');
  if (pe != null && spe != null && spe > 0 && pe <= spe * 0.8) {
    o.add('P/E ${_n2(pe)} is a discount to the sector\'s ${_n2(spe)}');
  }
  final rsi = tn('rsi14');
  if (rsi != null && rsi >= 70) th.add('RSI ${rsi.round()} — overbought');
  if (t['above200'] == false) th.add('Trading below its 200-day average');
  if (de != null && de > 2) th.add('Debt/Equity ${_n2(de)} — heavily leveraged');
  final promo = fn('promoter_pct');
  if (promo != null && promo < 40) th.add('Promoter holding only ${_pct1(promo)}');
  final dil = sn('shares_yoy');
  if (dil != null && dil > 5) th.add('Share count up ${_signed(dil)} in a year — dilution');
  return (s: s, w: w, o: o, t: th);
}

/// ESSENTIALS: ten yes/no checks (MC's "% pass"); null = not measurable here.
List<(String, bool?)> essentials(Map<String, dynamic> meta,
    {Map<String, dynamic> sa = const {}, Map<String, dynamic> summary = const {}}) {
  final f = _sub(meta, 'f') ?? const {};
  final t = _sub(meta, 't') ?? const {};
  double? fn(String k) => (f[k] as num?)?.toDouble();
  double? sn(String k) => (sa[k] as num?)?.toDouble();
  final cagr = (summary['cagr'] as Map?)?.cast<String, dynamic>();
  double? c3(String k) => ((cagr?[k] as Map?)?['y3'] as num?)?.toDouble();
  bool? gt(double? v, double bar) => v == null ? null : v > bar;
  bool? lt(double? v, double bar) => v == null ? null : v < bar;
  final pe = fn('pe'), spe = sn('sector_pe');
  return [
    ('ROE above 15%', gt(fn('roe'), 15)),
    ('ROCE above 15%', gt(fn('roce') ?? (summary['roce'] as num?)?.toDouble(), 15)),
    ('Debt/Equity below 1', lt(fn('de'), 1)),
    ('Profit growing >10% a year (3y)', gt(c3('profit'), 10)),
    ('Sales growing >10% a year (3y)', gt(c3('sales'), 10)),
    ('Promoters hold over 50%', gt(fn('promoter_pct'), 50)),
    ('P/E below the sector\'s', pe == null || spe == null || spe <= 0 ? null : pe < spe),
    ('Piotroski 6 or better', gt(sn('f_score'), 5.5)),
    ('Above its 200-day average', t['above200'] as bool?),
    ('Pays a dividend', gt(fn('div_yield'), 0)),
  ];
}

/// DuPont from the latest annual row (₹ Cr): ROE = margin × turnover ×
/// leverage. Any missing input leaves that factor (and the product) null.
typedef DuPont = ({double? npm, double? at, double? em, double? roe});

DuPont dupont(Map<String, dynamic> annual) {
  double? n(String k) => (annual[k] as num?)?.toDouble();
  final sales = n('sales'), np = n('net_profit'), ta = n('total_assets');
  final eq = n('equity_cap') != null || n('reserves') != null
      ? (n('equity_cap') ?? 0) + (n('reserves') ?? 0)
      : null;
  final npm = sales != null && sales != 0 && np != null ? np / sales * 100 : null;
  final at = sales != null && ta != null && ta != 0 ? sales / ta : null;
  final em = ta != null && eq != null && eq != 0 ? ta / eq : null;
  final roe = npm != null && at != null && em != null ? npm * at * em : null;
  return (npm: npm, at: at, em: em, roe: roe);
}

/// Pivot levels from one bar's high / low / close — classic, Fibonacci and
/// Camarilla, the three MC shows. Checked against MC's TCS card (18 Sep 2026):
/// H 2177.30 L 2101.20 C 2105 → P 2127.83, R1 2154.47, S3 2002.27.
Map<String, Map<String, double>> pivots(double h, double l, double c) {
  final p = (h + l + c) / 3, r = h - l;
  return {
    'Classic': {
      'R3': h + 2 * (p - l), 'R2': p + r, 'R1': 2 * p - l, 'P': p,
      'S1': 2 * p - h, 'S2': p - r, 'S3': l - 2 * (h - p),
    },
    'Fibonacci': {
      'R3': p + r, 'R2': p + 0.618 * r, 'R1': p + 0.382 * r, 'P': p,
      'S1': p - 0.382 * r, 'S2': p - 0.618 * r, 'S3': p - r,
    },
    'Camarilla': {
      'R3': c + r * 1.1 / 4, 'R2': c + r * 1.1 / 6, 'R1': c + r * 1.1 / 12, 'P': p,
      'S1': c - r * 1.1 / 12, 'S2': c - r * 1.1 / 6, 'S3': c - r * 1.1 / 4,
    },
  };
}

/// Moving-average reads: close vs each average the pipeline stores, plus the
/// 50/200 crossover. (label, bullish?) — null level = not stored.
typedef MaRead = ({List<(String, bool)> above, String? crossover, int bull, int bear});

MaRead maSignals(Map<String, dynamic> meta) {
  final t = _sub(meta, 't') ?? const {};
  double? n(String k) => (t[k] as num?)?.toDouble();
  final close = n('close');
  final above = <(String, bool)>[
    for (final k in const ['sma20', 'sma50', 'sma200'])
      if (close != null && n(k) != null) ('${k.substring(3)}-DMA', close > n(k)!),
  ];
  final s50 = n('sma50'), s200 = n('sma200');
  final cross = s50 == null || s200 == null
      ? null
      : s50 > s200
          ? 'Golden cross · 50-DMA above 200-DMA'
          : 'Death cross · 50-DMA below 200-DMA';
  final bull = above.where((a) => a.$2).length + (s50 != null && s200 != null && s50 > s200 ? 1 : 0);
  final bear = above.length - above.where((a) => a.$2).length + (s50 != null && s200 != null && s50 <= s200 ? 1 : 0);
  return (above: above, crossover: cross, bull: bull, bear: bear);
}

/// Seasonality from a monthly chart (Yahoo range=max&interval=1mo): month
/// return = close / previous month's close − 1, keyed year → month (1–12).
/// Years newest first; the month labels are shared by the table and callout.
typedef Seasonality = ({
  Map<int, Map<int, double>> table, // year -> month -> %
  List<int> years, // newest first
  List<double?> avg, // 12 entries, average % per month over the years
  List<double?> posPct, // 12 entries, % of years the month was positive
});

Seasonality? seasonality(List<double> closes, List<DateTime> times) {
  if (closes.length < 13 || closes.length != times.length) return null;
  final table = <int, Map<int, double>>{};
  for (var i = 1; i < closes.length; i++) {
    final prev = closes[i - 1];
    if (prev == 0) continue;
    final d = times[i];
    (table[d.year] ??= {})[d.month] = (closes[i] / prev - 1) * 100;
  }
  final years = table.keys.toList()..sort((a, b) => b - a);
  final avg = <double?>[], pos = <double?>[];
  for (var m = 1; m <= 12; m++) {
    final vals = [for (final y in years) if (table[y]![m] != null) table[y]![m]!];
    avg.add(vals.isEmpty ? null : vals.reduce((a, b) => a + b) / vals.length);
    pos.add(vals.isEmpty ? null : vals.where((v) => v > 0).length / vals.length * 100);
  }
  return (table: table, years: years, avg: avg, posPct: pos);
}

const monthAbbr = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// The callout for one month: "11 of 18 years negative in September", best,
/// worst, average up / down / overall.
typedef MonthStats = ({int years, int negative, (int, double)? best, (int, double)? worst,
  double? avgPos, double? avgNeg, double? avg});

MonthStats monthStats(Seasonality s, int month) {
  final vals = <(int, double)>[
    for (final y in s.years) if (s.table[y]![month] != null) (y, s.table[y]![month]!)
  ];
  if (vals.isEmpty) {
    return (years: 0, negative: 0, best: null, worst: null, avgPos: null, avgNeg: null, avg: null);
  }
  final pos = vals.where((v) => v.$2 > 0).toList(), neg = vals.where((v) => v.$2 <= 0).toList();
  double mean(List<(int, double)> l) => l.fold(0.0, (a, v) => a + v.$2) / l.length;
  return (
    years: vals.length,
    negative: neg.length,
    best: vals.reduce((a, b) => a.$2 >= b.$2 ? a : b),
    worst: vals.reduce((a, b) => a.$2 <= b.$2 ? a : b),
    avgPos: pos.isEmpty ? null : mean(pos),
    avgNeg: neg.isEmpty ? null : mean(neg),
    avg: mean(vals),
  );
}

/// DELIVERY & VOLUME (MC's block) from screener_metrics.tape — today,
/// yesterday, 1-week and 1-month averages of volume vs delivered quantity.
typedef DeliveryRow = ({String label, double vol, double deliv, double pct});

List<DeliveryRow> deliveryRows(Map<String, dynamic>? tape) {
  final d = [
    for (final e in (tape?['d'] as List? ?? const []))
      if (e is Map && e['vol'] is num && e['deliv_qty'] is num)
        (vol: (e['vol'] as num).toDouble(), deliv: (e['deliv_qty'] as num).toDouble())
  ];
  if (d.isEmpty) return const [];
  DeliveryRow avg(String label, Iterable<({double vol, double deliv})> xs) {
    final l = xs.toList();
    final v = l.fold(0.0, (a, x) => a + x.vol) / l.length;
    final q = l.fold(0.0, (a, x) => a + x.deliv) / l.length;
    return (label: label, vol: v, deliv: q, pct: v == 0 ? 0 : q / v * 100);
  }

  return [
    avg('Today', d.take(1)),
    if (d.length > 1) avg('Yesterday', d.skip(1).take(1)),
    if (d.length > 2) avg('1 week avg', d.take(5)),
    if (d.length > 5) avg('1 month avg', d.take(22)),
  ];
}
