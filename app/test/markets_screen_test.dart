import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show homeTabLabels, marketsTab;
import 'package:finswipe/screens/markets.dart';
import 'package:finswipe/ticks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Tick _t(String sym, String kind, String name, double price, double? pct,
        {String cur = 'INR', List<double> closes = const [], Map? meta}) =>
    Tick.fromJson({
      'symbol': sym, 'kind': kind, 'name': name, 'price': price,
      'change_pct': pct, 'currency': cur, 'closes': closes, 'meta': meta,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });

final _data = MarketsData(ticks: [
  _t('^NSEI', 'index', 'NIFTY 50', 24252, 0.08, closes: [24000, 24252]),
  _t('USDINR=X', 'fx', 'USD/INR', 95.71, -0.06, closes: [95.8, 95.71]),
  _t('bitcoin', 'crypto', 'Bitcoin', 7395017, -0.19),
  _t('GC=F', 'commodity', 'Gold (USD/oz)', 4624.1, 2.39, cur: 'USD'),
  _t('GOLD_INR_10G', 'commodity', 'Gold (₹/10g)', 142290, 2.39,
      meta: {'derived': true, 'label': 'intl spot × USD/INR, ex-duty'}),
], watchlist: const []);

Widget _app(MarketsData d) => MaterialApp(home: Scaffold(body: MarketsBody(d)));

void main() {
  testWidgets('Markets body renders every section with formatted numbers',
      (tester) async {
    await tester.pumpWidget(_app(_data));
    for (final h in ['INDICES', 'YOUR WATCHLIST', 'CURRENCIES', 'CRYPTO', 'COMMODITIES']) {
      expect(find.text(h), findsOneWidget, reason: h);
    }
    expect(find.text('NIFTY 50'), findsOneWidget);
    expect(find.text('₹24,252'), findsOneWidget);
    expect(find.text('▲0.08%'), findsOneWidget);
    expect(find.text('₹73,95,017'), findsOneWidget);
    expect(find.text('\$4,624.10'), findsOneWidget);
    expect(find.text('intl spot × USD/INR, ex-duty'), findsOneWidget);
    expect(find.textContaining('Nothing followed yet'), findsOneWidget);
    // The footer sits below the test viewport; the list is lazy.
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pump();
    expect(find.textContaining('as of'), findsOneWidget);
    expect(find.textContaining('stale'), findsNothing);
  });

  testWidgets('watchlist rows show the live % from ticks and tolerate a gap',
      (tester) async {
    ticks.value = {
      'TCS': _t('TCS', 'equity', 'TCS', 2302, 0.17),
    };
    final d = MarketsData(ticks: _data.ticks, watchlist: [
      Company.fromJson({'id': 1, 'name': 'Tata Consultancy', 'nse_symbol': 'TCS'}),
      Company.fromJson({'id': 2, 'name': 'Infosys', 'nse_symbol': 'INFY'}),
    ]);
    await tester.pumpWidget(_app(d));
    expect(find.text('\$TCS'), findsOneWidget);
    expect(find.text('▲0.17%'), findsOneWidget);
    expect(find.text('\$INFY'), findsOneWidget);
    expect(find.text('—'), findsOneWidget); // no quote yet, row still there
    ticks.value = {};
  });

  testWidgets('empty data explains itself instead of a blank screen',
      (tester) async {
    await tester.pumpWidget(_app(const MarketsData(ticks: [], watchlist: [])));
    expect(find.textContaining('No market data yet'), findsOneWidget);
  });

  test('Markets is the second tab', () {
    expect(homeTabLabels, ['News', 'Markets', 'Ask', 'Profile']);
    expect(homeTabLabels[marketsTab], 'Markets');
  });
}
