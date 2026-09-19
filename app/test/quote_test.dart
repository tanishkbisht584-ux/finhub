import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/models.dart';

// The exact envelope Yahoo's keyless chart endpoint returns:
// GET query1.finance.yahoo.com/v8/finance/chart/RELIANCE.NS?range=1mo&interval=1d
Map<String, dynamic> yahoo({List<double?> closes = const [100.0, 101.5]}) => {
      'chart': {
        'result': [
          {
            'meta': {
              'regularMarketPrice': 101.5,
              'chartPreviousClose': 99.0,
              'fiftyTwoWeekHigh': 120.0,
              'fiftyTwoWeekLow': 80.0,
            },
            'indicators': {
              'quote': [
                {'close': closes}
              ]
            },
          }
        ]
      }
    };

void main() {
  test('Quote parses the Yahoo chart envelope', () {
    final q = Quote.fromChartJson(yahoo());
    expect(q.price, 101.5);
    expect(q.prevClose, 99.0);
    expect(q.high52, 120.0);
    expect(q.low52, 80.0);
    expect(q.closes, [100.0, 101.5]);
  });

  test('Quote drops the nulls Yahoo pads holidays with', () {
    final q = Quote.fromChartJson(yahoo(closes: [100.0, null, 101.5]));
    expect(q.closes, [100.0, 101.5]);
    // no OHLC in the envelope: every bar is a doji on its close, day fields empty
    expect(q.opens, [100.0, 101.5]);
    expect(q.highs, q.closes);
    expect(q.open, 100.0); // first bar's open stands in for regularMarketOpen
    expect(q.dayHigh, isNull);
    expect(q.volume, isNull);
    expect(q.asOf, isNull);
  });

  test('Quote reads the day and OHLC (Phase 2 intraday envelope)', () {
    final j = <String, dynamic>{
      'chart': {
        'result': [
          {
            'meta': <String, dynamic>{
              'regularMarketPrice': 2105.0,
              'chartPreviousClose': 2200.8, // 5-day-ago close on a 5d range
              'previousClose': 2190.0, // yesterday: the header's reference
              'fiftyTwoWeekHigh': 3350.0,
              'fiftyTwoWeekLow': 1976.8,
              'regularMarketDayHigh': 2177.3,
              'regularMarketDayLow': 2101.2,
              'regularMarketVolume': 6875428,
              'regularMarketTime': 1789724699,
            },
            'timestamp': [1789703100, 1789703400, 1789703700],
            'indicators': {
              'quote': [
                <String, dynamic>{
                  'close': [2124.9, null, 2105.0],
                  'open': [2175.0, null, 2110.0],
                  'high': [2175.0, null, 2112.0],
                  'low': [2116.7, null, 2104.0],
                }
              ]
            },
          }
        ]
      }
    };
    final q = Quote.fromChartJson(j);
    expect(q.prevClose, 2190.0);
    expect(q.dayHigh, 2177.3);
    expect(q.dayLow, 2101.2);
    expect(q.volume, 6875428);
    expect(q.open, 2175.0);
    expect(q.asOf!.isUtc, isTrue);
    expect(q.asOf!.millisecondsSinceEpoch, 1789724699000);
    expect(q.opens, [2175.0, 2110.0]); // null bar dropped from every series
    expect(q.highs, [2175.0, 2112.0]);
    expect(q.lows, [2116.7, 2104.0]);
    expect(q.closes, [2124.9, 2105.0]);
  });

  test('Quote reads dividend and split events, newest first', () {
    final j = yahoo();
    (j['chart']['result'][0] as Map<String, dynamic>)['events'] = {
      'dividends': {
        '1768535100': {'amount': 57.0, 'date': 1768535100},
        '1779680700': {'amount': 31.0, 'date': 1779680700},
      },
      'splits': {
        '1527738300': {'date': 1527738300, 'numerator': 2.0, 'denominator': 1.0, 'splitRatio': '2:1'}
      },
    };
    final q = Quote.fromChartJson(j);
    expect([for (final d in q.dividends) d.amount], [31.0, 57.0]);
    expect(q.dividends.first.date.isUtc, isTrue);
    expect(q.splits.single.ratio, '2:1');
    expect(Quote.fromChartJson(yahoo()).dividends, isEmpty);
  });

  test('Company parses a companies row', () {
    final c = Company.fromJson({'id': 7, 'name': 'Reliance Industries', 'nse_symbol': 'RELIANCE'});
    expect(c.id, 7);
    expect(c.nseSymbol, 'RELIANCE');
  });
}
