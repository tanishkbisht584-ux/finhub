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
    ],
  },
  'f_at': '2026-08-23T16:35:00+00:00',
  't': {
    'close': 2302.0, 'rsi14': 78.0, 'vs50': 2.1, 'vs200': -1.3, 'trend': 'mixed',
    'above200': false, 'hi52': 4592.25, 'lo52': 2205.0, 'pos52': 0.05,
    'vol_ratio': 1.9, 'macd_hist': -30.86, 'sma20': 2310.0,
  },
};

Map<String, String> _asMap(List<(String, String)> lines) =>
    {for (final (k, v) in lines) k: v};

void main() {
  test('fundamentalLines formats every ratio the meta carries', () {
    final m = _asMap(fundamentalLines(Map<String, dynamic>.from(_meta)));
    expect(m['P/E'], '16.72 · fwd 14.17');
    expect(m['P/B'], '7.60');
    expect(m['Mkt cap'], '₹8.33L Cr');
    expect(m['EPS (TTM)'], '₹137.66');
    expect(m['Div yield'], '2.80%');
    expect(m['ROE'], '47.70%');
    expect(m['Debt/Equity'], '0.10');
    expect(m['Growth (YoY)'], 'rev ▲13.9% · earnings ▲4.6%');
    expect(m['Holding'], 'promoter 71.80% · inst 17.70%');
    expect(m['Analyst'], 'target ₹2,460 · STRONG BUY');
    expect(m['Last quarter'], 'rev ₹72,275 Cr · PAT ₹13,349 Cr');
    expect(m['Sector'], 'Technology · IT Services');
  });

  test('technicalLines tags RSI and trend honestly', () {
    final m = _asMap(technicalLines(Map<String, dynamic>.from(_meta)));
    expect(m['RSI-14'], '78 · overbought');
    expect(m['vs moving avgs'], '50-DMA ▲2.1% · 200-DMA ▼1.3%');
    expect(m['Trend'], 'MIXED · below 200-DMA');
    expect(m['52-wk range'], '₹2,205 – ₹4,592 · at 5%');
    expect(m['Volume'], '1.90× 20-day avg');
    expect(m['MACD'], 'bearish');
  });

  test('missing meta yields empty strips, partial meta skips lines', () {
    expect(fundamentalLines(const {}), isEmpty);
    expect(technicalLines(const {}), isEmpty);
    final partial = _asMap(fundamentalLines(const {'f': {'pe': 20.0}}));
    expect(partial, {'P/E': '20.00'});
    final rsiOnly = _asMap(technicalLines(const {'t': {'rsi14': 25.0}}));
    expect(rsiOnly['RSI-14'], '25 · oversold');
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
