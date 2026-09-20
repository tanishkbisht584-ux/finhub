import 'package:finflick/analysis.dart';
import 'package:finflick/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _meta = {
  'f': {
    'pe': 16.72, 'fwd_pe': 14.17, 'pb': 7.6, 'mcap': 8328837070848,
    'eps': 137.66, 'div_yield': 2.8, 'roe': 47.7, 'de': 0.1, 'margin': 18.1,
    'rev_growth': 13.9, 'earn_growth': 4.6, 'target': 2460.05, 'rec': 'strong_buy',
    'promoter_pct': 71.8, 'inst_pct': 17.7, 'beta': 0.16,
    'sector': 'Technology', 'industry': 'IT Services',
    'quarters': [
      {'end': '2026-06-30', 'revenue': 722750000000, 'net_income': 133490000000},
      {'end': '2026-03-31', 'revenue': 700000000000, 'net_income': 120000000000},
    ],
  },
  'f_at': '2026-08-23T16:35:00+00:00',
  't': {
    'close': 2302.0, 'rsi14': 78.0, 'vs50': 2.1, 'vs200': -1.3, 'trend': 'mixed',
    'above200': false, 'hi52': 4592.25, 'lo52': 2205.0, 'pos52': 0.05,
    'vol_ratio': 1.9, 'macd_hist': -30.86, 'sma20': 2310.0, 'sma50': 2254.6,
    'sma200': 2332.3,
  },
};

Map<String, KvRow> _byMetric(List<KvRow> rows) => {for (final r in rows) r.metric: r};

void main() {
  final meta = Map<String, dynamic>.from(_meta);

  test('snapshotStats: headline tiles, P/E carries forward P/E as sub', () {
    final tiles = snapshotStats(meta);
    expect(tiles[0].value, '₹8.33L Cr');
    expect(tiles[1].value, '16.72');
    expect(tiles[1].sub, 'fwd 14.17');
    expect(tiles[4].value, '47.7%');
    expect(snapshotStats(const {}), isEmpty);
    expect(snapshotStats(const {'f': {'pe': 20.0}}).single.label, 'P/E');
  });

  test('snapshotStats verdicts: P/E vs sector, ROE, beta, all-time high', () {
    expect([for (final t in snapshotStats(meta)) t.label],
        ['Mkt cap', 'P/E', 'EPS', 'P/B', 'ROE', 'Div yield', 'Debt/Equity', 'Beta']);
    expect(snapshotStats(meta).firstWhere((t) => t.label == 'EPS').value, '₹137.66');
    expect(snapshotStats(meta).firstWhere((t) => t.label == 'Beta').sub, 'calmer than market · 5y monthly');
    expect(snapshotStats(meta, ttmDivYield: 5.23).firstWhere((t) => t.label == 'Div yield').value, '5.2%');
    expect(snapshotStats(meta, ttmDivYield: 5.23).firstWhere((t) => t.label == 'Div yield').sub, 'last 12 months');
    final tr = technicalRows(meta, hi52: 3350, lo52: 1976.8);
    expect(tr.firstWhere((r) => r.metric == '52-wk high').value, '₹3,350');
    expect(tr.firstWhere((r) => r.metric == '52-wk low').value, '₹1,977');
    final tiles = snapshotStats(meta, sectorPe: 22.76, ath: 4592.25, athPct: -54.2);
    final by = {for (final t in tiles) t.label: t};
    expect(by['P/E']!.sub, 'fwd 14.17 · below sector 22.76');
    expect(by['P/E']!.tone, 1);
    expect(by['ROE']!.sub, 'strong'); // 47.7%
    expect(by['ROE']!.tone, 1);
    expect(by['All-time high']!.value, '₹4,592.25');
    expect(by['All-time high']!.sub, '−54.2% from high');
    expect(by['All-time high']!.tone, -1);
    // above-sector P/E reads red; no sector P/E = no verdict, no tone
    expect(snapshotStats(meta, sectorPe: 10).firstWhere((t) => t.label == 'P/E').tone, -1);
    expect(snapshotStats(meta).firstWhere((t) => t.label == 'P/E').sub, 'fwd 14.17');
  });

  test('returnsGrid: nine cells in MC order, missing columns stay as null cells', () {
    final g = returnsGrid(const {'ret_1w': -4.35, 'ret_1y': -33.74, 'ath_pct': -54.2});
    expect([for (final c in g) c.$1],
        ['1W', '1M', '3M', '6M', 'YTD', '1Y', '3Y', '5Y', 'vs ATH']);
    expect(g[0].$2, -4.35);
    expect(g[1].$2, isNull);
    expect(g[8].$2, -54.2);
  });

  test('streetStats: consensus word + count, target + upside; empty without street', () {
    final s = streetStats(const {
      'sa': {'analystRatings': 'Strong Buy', 'analystCount': 26, 'priceTarget': 1676, 'priceTargetChange': 33.28}
    });
    expect([for (final t in s) t.label], ['Consensus', 'Target']);
    expect(s[0].value, 'STRONG BUY');
    expect(s[0].sub, '26 analysts');
    expect(s[0].tone, 1);
    expect(s[1].value, '₹1,676');
    expect(s[1].sub, '+33.3% to target');
    expect(streetStats(const {}), isEmpty);
    expect(streetStats(const {'sa': {'analystRatings': 'Sell'}}).single.tone, -1);
  });

  test('deliveryRows: today / yesterday / 1-week / 1-month averages', () {
    final d = [
      for (var i = 0; i < 22; i++)
        {'date': '2026-09-${18 - i}', 'vol': 100.0 * (i + 1), 'deliv_qty': 50.0 * (i + 1)}
    ];
    final rows = deliveryRows({'asof': '2026-09-18', 'd': d});
    expect([for (final r in rows) r.label], ['Today', 'Yesterday', '1 week avg', '1 month avg']);
    expect(rows[0].vol, 100); // newest first in the tape
    expect(rows[1].vol, 200);
    expect(rows[2].vol, 300); // mean of 100..500
    expect(rows[3].vol, 1150); // mean of 100..2200
    expect(rows[3].pct, 50);
    expect(deliveryRows(null), isEmpty);
    // BSE join: combined sums per date, bse reads the BSE tape alone, a date BSE lacks stays NSE-only
    final nse = {'d': [{'date': '2026-09-18', 'vol': 100.0, 'deliv_qty': 50.0}, {'date': '2026-09-17', 'vol': 80.0, 'deliv_qty': 40.0}]};
    final bse = {'d': [{'date': '2026-09-18', 'vol': 20.0, 'deliv_qty': 15.0}]};
    final comb = deliveryRows(nse, bse: bse, mode: 'combined');
    expect((comb[0].vol, comb[0].deliv), (120.0, 65.0));
    expect((comb[1].vol, comb[1].deliv), (80.0, 40.0));
    expect(deliveryRows(nse, bse: bse, mode: 'bse').single.vol, 20.0);
    expect(deliveryRows(nse, bse: bse, mode: 'nse')[0].vol, 100.0);
    expect(deliveryRows({'d': [{'date': 'x', 'vol': 10, 'deliv_qty': 4}]}).single.pct, 40);
  });

  test('earningsRows: latest quarter with YoY and QoQ against the right bases', () {
    final e = earningsRows({
      '2025-06': {'sales': 62000, 'net_profit': 12000, 'eps': 33.0},
      '2026-03': {'sales': 70698, 'op_profit': 18000, 'net_profit': 13784, 'eps': 38.1},
      '2026-06': {'sales': 72275, 'op_profit': 18217, 'net_profit': 13420, 'eps': 37.1},
    })!;
    expect((e.period, e.prevPeriod, e.yearAgo), ('2026-06', '2026-03', '2025-06'));
    final by = {for (final l in e.lines) l.label: l};
    expect(by.keys, ['Revenue', 'Operating profit', 'Net profit', 'EPS']);
    expect(by['Revenue']!.yoy!.toStringAsFixed(2), '16.57');
    expect(by['Revenue']!.qoq!.toStringAsFixed(2), '2.23');
    expect(by['Operating profit']!.yoy, isNull); // no op_profit a year ago and nothing to derive it from
    final derived = earningsRows({
      '2025-06': {'sales': 100, 'pbt': 20, 'interest': 1, 'depreciation': 4, 'other_income': 5},
      '2026-06': {'sales': 110, 'op_profit': 24},
    })!;
    expect(derived.lines.firstWhere((l) => l.label == 'Operating profit').yoy!.toStringAsFixed(1), '20.0');
    expect(by['Net profit']!.qoq!.toStringAsFixed(2), '-2.64');
    expect(by['EPS']!.money, isFalse);
    expect(earningsRows(const {}), isNull);
    expect(earningsRows({'2026-06': {'sales': 1}})!.lines.single.qoq, isNull);
  });

  test('infoRows: facts from meta + sa, website kept, blanks dropped', () {
    final rows = infoRows(meta, const {
      'industry': 'IT Services', 'sa': {'isin': 'INE467B01029', 'founded': 1968, 'employees': 601546,
        'website': 'https://www.tcs.com', 'nextEarningsDate': '2026-10-09', 'lastReportDate': ''}
    });
    expect([for (final r in rows) r.$1],
        ['Sector', 'Industry', 'ISIN', 'Founded', 'Employees', 'Website', 'Next results']);
    expect(rows.firstWhere((r) => r.$1 == 'Employees').$2, '6,01,546');
    expect(rows.firstWhere((r) => r.$1 == 'Next results').$2, '9 Oct');
    expect(infoRows(const {}, const {}), isEmpty);
  });

  test('hitsMisses and estimateLabel (Phase 6)', () {
    final hm = hitsMisses(const [
      {'surprise': 2.5}, {'surprise': 1.1}, {'surprise': -0.5}, {'surprise': -14.5}, {'x': 1}
    ]);
    expect((hm.beats, hm.misses, hm.inline), (1, 1, 2));
    expect(estimateLabel(const {'period': '0q', 'end': '2026-09-30'}), 'Q Sep 26');
    expect(estimateLabel(const {'period': '+1y', 'end': '2028-03-31'}), 'FY28');
    expect(estimateLabel(const {'period': '0y'}), '0y');
  });

  test('withScreenerTech synthesises meta.t from screener columns only when absent', () {
    final m = withScreenerTech(const {'f': {'pe': 1}}, const {'ma50': 2300.0, 'ma200': 2550.0, 'rsi': 32.0, 'hi52': 3350.0, 'lo52': 1976.8, 'trend': 'bearish'}, 2105.0);
    final t = m['t'] as Map;
    expect(t['sma50'], 2300.0);
    expect(t['trend'], 'down');
    expect(t['above200'], isFalse);
    expect((t['pos52'] as double).toStringAsFixed(3), '0.093');
    expect(t['src'], 'screener');
    expect(withScreenerTech(meta, const {'ma50': 1.0}, 2105.0)['t'], same(meta['t'])); // existing t untouched
    expect(withScreenerTech(const {}, const {}, 2105.0).containsKey('t'), isFalse);
    expect(withScreenerTech(const {}, const {'ma50': 1.0}, null).containsKey('t'), isFalse);
  });

  test('altmanZ from the annual row: TCS-like inputs land in the safe zone', () {
    final z = altmanZ({'total_assets': 182372, 'sales': 267021, 'reserves': 106878, 'equity_cap': 362,
      'pbt': 65487, 'interest': 1227, 'wc_days': 102}, 761607)!;
    expect(z, greaterThan(8)); // MC prints 8.58 on its own inputs
    expect(altmanZ({'total_assets': 100}, 10), isNull);
    expect(altmanZ({'total_assets': 100, 'sales': 50, 'reserves': 120, 'equity_cap': 5, 'pbt': 1, 'wc_days': 10}, 10), isNull); // TL ≤ 0
    expect(snapshotStats(const {'f': {'pe': 10.0}}, roeFallback: 21.5).firstWhere((t) => t.label == 'ROE').value, '21.5%');
  });

  test('techStats: trend / RSI / MACD tiles with tone', () {
    final tiles = techStats(meta);
    expect([for (final t in tiles) t.label], ['Trend', 'RSI-14', 'MACD']);
    expect(tiles[0].value, 'MIXED');
    expect(tiles[0].sub, 'below 200-DMA');
    expect(tiles[1].value, '78');
    expect(tiles[1].sub, 'overbought');
    expect(tiles[1].tone, -1);
    expect(tiles[2].value, 'bearish');
    expect(tiles[2].sub, 'hist -30.86');
    expect(techStats(const {}), isEmpty);
  });

  test('sectorMedians: per-column median, self excluded, nulls skipped', () {
    final peers = [
      {'symbol': 'SELF', 'pe': 100.0, 'roe': 1.0},
      {'symbol': 'A', 'pe': 10.0, 'roe': 12.0},
      {'symbol': 'B', 'pe': 20.0, 'roe': null},
      {'symbol': 'C', 'pe': 30.0, 'roe': 18.0, 'de': 0.5},
    ];
    final m = sectorMedians(peers, self: 'SELF');
    expect(m['pe'], 20.0);
    expect(m['roe'], 15.0);
    expect(m['de'], 0.5);
    expect(m.containsKey('pb'), isFalse);
    expect(sectorMedians(const []), isEmpty);
  });

  test('fundamentalRows: every ratio, sector column, reads and tones', () {
    final rows = _byMetric(fundamentalRows(meta,
        medians: {'pe': 25.0, 'roe': 15.0, 'de': 0.5, 'div_yield': 1.0, 'mcap_cr': 100000.0},
        summary: {'roce': 60.0, 'book_value': 290.5}));
    expect(rows.keys, containsAll([
      'P/E', 'P/B', 'Mkt cap', 'EPS (TTM)', 'Div yield', 'ROE', 'ROCE',
      'Debt/Equity', 'Net margin', 'Rev growth', 'Earn growth', 'Promoter',
      'Analyst', 'Beta', 'Book value', 'Sector',
    ]));
    expect(rows['P/E']!.value, '16.72');
    expect(rows['P/E']!.third, '25.00');
    expect(rows['P/E']!.read, 'discount · fwd 14.17');
    expect(rows['P/E']!.tone, 0); // valuation: no verdict
    expect(rows['ROE']!.read, 'above peers');
    expect(rows['ROE']!.tone, 1);
    expect(rows['Debt/Equity']!.read, 'lighter');
    expect(rows['Debt/Equity']!.tone, 1);
    expect(rows['ROCE']!.value, '60.0%');
    expect(rows['ROCE']!.third, '—'); // no median given
    expect(rows['Mkt cap']!.value, '₹8.33L Cr');
    expect(rows['Mkt cap']!.read, '8.3× median');
    expect(rows['Rev growth']!.value, '+13.9%');
    expect(rows['Rev growth']!.tone, 1);
    expect(rows['Promoter']!.read, 'institutions 17.7%');
    expect(rows['Analyst']!.value, '₹2,460');
    expect(rows['Analyst']!.read, 'STRONG BUY · +6.9% to target');
    expect(rows['Analyst']!.tone, 1);
    expect(rows['Beta']!.read, 'less volatile than Nifty');
    expect(rows['Book value']!.value, '₹291');
    expect(rows['Sector']!.value, 'Technology');
    expect(rows['Sector']!.read, 'IT Services');
  });

  test('fundamentalRows without medians still lists every metric', () {
    final rows = _byMetric(fundamentalRows(meta));
    expect(rows['P/E']!.third, '—');
    expect(rows['P/E']!.read, 'fwd 14.17');
    expect(rows['ROE']!.read, '');
    expect(rows.containsKey('ROCE'), isFalse);
    expect(fundamentalRows(const {}), isEmpty);
    expect(fundamentalRows(const {'f': {'pe': 20.0}}).single.metric, 'P/E');
  });

  test('technicalRows: SMA levels vs close, cross, 52-wk, zones', () {
    final rows = _byMetric(technicalRows(meta));
    expect([for (final r in technicalRows(meta)) r.metric], [
      'Close', 'SMA-20', 'SMA-50', 'SMA-200', '52-wk high', '52-wk low',
      'RSI-14', 'MACD hist', 'Volume', 'Beta',
    ]);
    expect(rows['Close']!.value, '₹2,302');
    expect(rows['SMA-20']!.value, '₹2,310');
    expect(rows['SMA-20']!.third, '−0.3%'); // computed from close
    expect(rows['SMA-20']!.read, 'below');
    expect(rows['SMA-50']!.third, '+2.1%'); // stored vs50 wins
    expect(rows['SMA-50']!.tone, 1);
    expect(rows['SMA-200']!.read, 'below · death cross');
    expect(rows['52-wk high']!.third, '−49.9%');
    expect(rows['52-wk high']!.read, 'at 5% of range');
    expect(rows['52-wk low']!.third, '+4.4%');
    expect(rows['RSI-14']!.read, 'overbought (30–70)');
    expect(rows['MACD hist']!.value, '-30.86');
    expect(rows['MACD hist']!.read, 'bearish');
    expect(rows['Volume']!.value, '1.90×');
    expect(rows['Volume']!.read, 'vs 20-day avg · active');
    expect(rows['Beta']!.value, '0.16');
    expect(technicalRows(const {}), isEmpty);
    expect(technicalRows(const {'t': {'rsi14': 25.0}}).single.read, 'oversold (30–70)');
  });

  test('quarterSeries prefers the fundamentals table, falls back to meta', () {
    final fromTable = quarterSeries({
      '2025-12': {'sales': 100, 'net_profit': 10},
      '2026-03': {'sales': 110},
      '2025-09': {'sales': 90, 'net_profit': 9},
    }, meta, n: 2, label: (p) => p.substring(5));
    expect(fromTable.sales, [100, 110]);
    expect(fromTable.profit, [10, null]);
    expect(fromTable.labels, ['12', '03']);

    final fromMeta = quarterSeries(const {}, meta);
    expect(fromMeta.labels, ['Mar 26', 'Jun 26']); // oldest first
    expect(fromMeta.sales, [70000.0, 72275.0]); // ₹ -> Cr
    expect(fromMeta.profit, [12000.0, 13349.0]);

    expect(quarterSeries(const {}, const {}).sales, isEmpty);
  });

  test('fmtCrore and fmtDay', () {
    expect(fmtCrore(722750000000), '₹72,275 Cr');
    expect(fmtCrore(8328837070848), '₹8.33L Cr');
    expect(fmtDay('2026-08-23T16:35:00+00:00'), '23 Aug');
    expect(fmtDay(null), '');
  });

  test('saRows: Stock Analysis columns -> RETURNS table, blanks skipped', () {
    expect(saRows(const {}), isEmpty);
    final rows = saRows(const {
      'ret_1w': -4.88, 'ret_1y': -8.68, 'ret_5y': null, 'ath_pct': -21.98,
      'sharpe': -0.5, 'sortino': -0.42, 'atr': 21.16, 'rel_vol': 0.82, 'turnover_cr': 1103.8,
      'graham_upside': -20.6, 'f_score': 3, 'ps': 1.51, 'sector_pe': 13.32,
      'ev_ebitda': 10.74, 'roic': 8.07, 'shares_yoy': 0.0,
      'sa': {
        'allTimeHigh': 1611.8, 'allTimeHighDate': '2026-01-05',
        'high52Date': '2026-01-05', 'low52Date': '2026-07-24',
        'analystRatings': 'Strong Buy', 'analystCount': 26, 'priceTarget': 1676,
        'priceTargetChange': 33.28, 'grahamNumber': 998.5,
        'nextEarningsDate': '2026-10-23', 'lastReportDate': '2026-06-30',
        'employees': 404501, 'founded': 1957, 'isin': 'INE002A01018',
      },
      'sa_price_date': '2026-09-11',
    });
    final metrics = [for (final r in rows) r.metric];
    // Phase 2: returns, the all-time high and the street moved to OVERVIEW
    // (returnsGrid / snapshotStats / streetStats); the table keeps the rest.
    expect(metrics, [
      'All-time high date', '52-wk high / low', 'Sharpe / Sortino', 'ATR',
      'Rel. volume', 'Graham number', 'Piotroski F', 'P/S', 'EV/EBITDA', 'ROIC',
      'Shares YoY', 'Next results', 'Company',
    ]);
    final by = {for (final r in rows) r.metric: r};
    expect(by['All-time high date']!.value, '5 Jan');
    expect(by['Piotroski F']!.value, '3/9');
    expect(by['Piotroski F']!.tone, -1);
    expect(by['P/S']!.read, 'sector PE 13.32');
    expect(by['Company']!.third, 'est. 1957');
    expect(by['Company']!.read, 'INE002A01018');
  });

  test('needsAnalysisRequest fires only when both strips are absent', () {
    expect(needsAnalysisRequest(const {}), isTrue);
    expect(needsAnalysisRequest(const {'f': null, 't': null}), isTrue);
    expect(needsAnalysisRequest(const {'f': {'pe': 10.0}}), isFalse);
    expect(needsAnalysisRequest(const {'t': {'rsi14': 50.0}}), isFalse);
  });

  // ---------- Phase 3 ----------

  test('finScore: four parts, normalised, verdict words track the parts', () {
    final card = finScore(meta, sa: const {'f_score': 8, 'sector_pe': 22.76}, summary: const {
      'cagr': {'profit': {'y3': 12.0}}
    })!;
    expect([for (final p in card.parts) p.label],
        ['Financial strength', 'Growth', 'Valuation', 'Trend']);
    // strength: 8/9*20 = 18 + D/E 0.1 -> 10 = 28; growth 12% -> 15; P/E 16.72 is 0.73× the
    // sector's 22.76 -> 25; trend mixed -> 10 => 78/100
    expect([for (final p in card.parts) p.points], [28, 15, 25, 10]);
    expect(card.score, 78);
    expect(card.verdict, 'Strong financials, moderate growth, attractive valuation, sideways');
    // No sector P/E and no CAGR: valuation drops out, growth falls back to earn_growth (4.6 -> 8)
    final thin = finScore(meta)!;
    expect([for (final p in thin.parts) p.label], ['Financial strength', 'Growth', 'Trend']);
    expect(thin.parts[0].points, 24); // ROE 47.7 -> 14, D/E -> 10
    expect(thin.parts[1].read, 'earnings +4.6% YoY');
    expect(finScore(const {}), isNull);
  });

  test('swot: pros/cons pass through, rules add the rest', () {
    final s = swot(meta,
        sa: const {'ath_pct': -54.2, 'f_score': 7, 'sector_pe': 40.0, 'shares_yoy': 6.1,
          'sa': {'priceTarget': 2460, 'priceTargetChange': 33.3}},
        summary: const {'pros': ['Company has a good return on equity'], 'cons': ['Stock is trading at 7.6× book']});
    expect(s.s.first, 'Company has a good return on equity');
    expect(s.s, contains('Company is almost debt-free')); // D/E 0.1
    expect(s.w, ['Stock is trading at 7.6× book']);
    expect(s.o, [
      'Street target ₹2,460 is +33.3% away',
      '−54.2% from its all-time high with Piotroski 7/9',
      'P/E 16.72 is a discount to the sector\'s 40.00',
    ]);
    expect(s.t, [
      'RSI 78 — overbought',
      'Trading below its 200-day average',
      'Share count up +6.1% in a year — dilution',
    ]);
  });

  test('essentials: ten checks, unmeasurable ones are null', () {
    final e = essentials(meta, sa: const {'f_score': 7, 'sector_pe': 22.76});
    expect(e.length, 10);
    final by = {for (final x in e) x.$1: x.$2};
    expect(by['ROE above 15%'], isTrue);
    expect(by['Debt/Equity below 1'], isTrue);
    expect(by['Profit growing >10% a year (3y)'], isNull); // no summary
    expect(by['ROCE above 15%'], isNull);
    expect(by['P/E below the sector\'s'], isTrue);
    expect(by['Piotroski 6 or better'], isTrue);
    expect(by['Above its 200-day average'], isFalse);
    expect(by['Pays a dividend'], isTrue);
  });

  test('dupont: ROE = margin × turnover × leverage from an annual row', () {
    final d = dupont(const {'sales': 255324, 'net_profit': 48553, 'total_assets': 150000,
      'equity_cap': 362, 'reserves': 94394});
    expect(d.npm!.toStringAsFixed(2), '19.02');
    expect(d.at!.toStringAsFixed(2), '1.70');
    expect(d.em!.toStringAsFixed(2), '1.58');
    expect(d.roe!.toStringAsFixed(1), '51.2');
    expect(dupont(const {'sales': 100}).roe, isNull);
  });

  test('pivots: classic levels match MC\'s TCS card for 18 Sep 2026', () {
    final p = pivots(2177.30, 2101.20, 2105.00);
    final c = p['Classic']!;
    expect(c['P']!.toStringAsFixed(2), '2127.83');
    expect(c['R1']!.toStringAsFixed(2), '2154.47');
    expect(c['R2']!.toStringAsFixed(2), '2203.93');
    expect(c['R3']!.toStringAsFixed(2), '2230.57');
    expect(c['S1']!.toStringAsFixed(2), '2078.37');
    expect(c['S2']!.toStringAsFixed(2), '2051.73');
    expect(c['S3']!.toStringAsFixed(2), '2002.27');
    expect(p['Fibonacci']!['R1']!, closeTo(2127.83 + 0.382 * 76.1, 0.01));
    expect(p['Camarilla']!['S3']!, closeTo(2105 - 76.1 * 1.1 / 4, 0.01));
  });

  test('maSignals: above/below each stored average and the 50/200 cross', () {
    final m = maSignals(meta); // close 2302 vs 2310 / 2254.6 / 2332.3, sma50 < sma200
    expect(m.above, [('20-DMA', false), ('50-DMA', true), ('200-DMA', false)]);
    expect(m.crossover, startsWith('Death cross'));
    expect((m.bull, m.bear), (1, 3));
    expect(maSignals(const {}).above, isEmpty);
  });

  test('seasonality: month-on-month table, averages, up-% and the month callout', () {
    // 25 monthly closes: Jan 2024 .. Jan 2026, +1% every month except Septembers (−3%)
    final closes = <double>[100];
    final times = <DateTime>[DateTime(2024, 1, 1)];
    for (var i = 1; i < 25; i++) {
      final d = DateTime(2024 + (i ~/ 12), i % 12 + 1, 1);
      times.add(d);
      closes.add(closes.last * (d.month == 9 ? 0.97 : 1.01));
    }
    final s = seasonality(closes, times)!;
    expect(s.years, [2026, 2025, 2024]);
    expect(s.table[2024]![9]!, closeTo(-3.0, 1e-9));
    expect(s.table[2024]![2]!, closeTo(1.0, 1e-9));
    expect(s.table[2024]!.containsKey(1), isFalse); // first close has no prior month
    expect(s.avg[8]!, closeTo(-3.0, 1e-9)); // September column
    expect(s.posPct[8], 0);
    expect(s.posPct[1], 100);
    // a second bar for the running month (Yahoo's max/1mo tail) is ignored
    final dup = seasonality([...closes, closes.last], [...times, DateTime(2026, 1, 18)])!;
    expect(dup.table[2026]![1], closeTo(s.table[2026]![1]!, 1e-9));
    final sep = monthStats(s, 9);
    expect((sep.years, sep.negative), (2, 2));
    expect(sep.worst!.$2, closeTo(-3.0, 1e-9));
    expect(sep.avgPos, isNull);
    expect(seasonality(closes.take(5).toList(), times.take(5).toList()), isNull);
  });
}
