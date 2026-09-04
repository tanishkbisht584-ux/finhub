import 'package:finswipe/analysis.dart';
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

  test('snapshotStats: six tiles, P/E carries forward P/E as sub', () {
    final tiles = snapshotStats(meta);
    expect([for (final t in tiles) t.label],
        ['Mkt cap', 'P/E', 'P/B', 'ROE', 'Div yield', 'Debt/Equity']);
    expect(tiles[0].value, '₹8.33L Cr');
    expect(tiles[1].value, '16.72');
    expect(tiles[1].sub, 'fwd 14.17');
    expect(tiles[3].value, '47.7%');
    expect(snapshotStats(const {}), isEmpty);
    expect(snapshotStats(const {'f': {'pe': 20.0}}).single.label, 'P/E');
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

  test('needsAnalysisRequest fires only when both strips are absent', () {
    expect(needsAnalysisRequest(const {}), isTrue);
    expect(needsAnalysisRequest(const {'f': null, 't': null}), isTrue);
    expect(needsAnalysisRequest(const {'f': {'pe': 10.0}}), isFalse);
    expect(needsAnalysisRequest(const {'t': {'rsi14': 50.0}}), isFalse);
  });
}
