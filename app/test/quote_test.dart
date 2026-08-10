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
  });

  test('Company parses a companies row', () {
    final c = Company.fromJson({'id': 7, 'name': 'Reliance Industries', 'nse_symbol': 'RELIANCE'});
    expect(c.id, 7);
    expect(c.nseSymbol, 'RELIANCE');
  });
}
