import 'models.dart';

/// Renders `quotes.meta.f` / `meta.t` (pipeline/market.py) into the stock
/// page's tiles and labelled tables. Pure functions so the sections are
/// testable without pumping StockScreen (which talks to Supabase in initState).
///
/// Tone is -1 / 0 / +1 (red / ink / green) so this file stays Flutter-free.

/// One row of a labelled table: metric · value · third column · read.
typedef KvRow = ({String metric, String value, String third, String read, int tone});

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
List<Stat> snapshotStats(Map<String, dynamic> meta) {
  final f = _sub(meta, 'f');
  if (f == null || f.isEmpty) return const [];
  double? n(String k) => (f[k] as num?)?.toDouble();
  final out = <Stat>[];
  void add(String label, double? v, String Function(double) fmt, {String? sub}) {
    if (v != null) out.add((label: label, value: fmt(v), sub: sub, tone: 0));
  }

  add('Mkt cap', n('mcap'), fmtCrore);
  add('P/E', n('pe'), _n2,
      sub: n('fwd_pe') == null ? null : 'fwd ${_n2(n('fwd_pe')!)}');
  add('P/B', n('pb'), _n2);
  add('ROE', n('roe'), _pct1);
  add('Div yield', n('div_yield'), _pct1);
  add('Debt/Equity', n('de'), _n2);
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
