import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show homeTabLabels, marketsTab;
import 'package:finswipe/screens/markets.dart';
import 'package:finswipe/screens/stock.dart';
import 'package:finswipe/ticks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Tick _t(String sym, String kind, String name, double price, double? pct,
        {String cur = 'INR', List<double> closes = const [], Map? meta,
        double? prev}) =>
    Tick.fromJson({
      'symbol': sym, 'kind': kind, 'name': name, 'price': price,
      'prev_close': prev, 'change_pct': pct, 'currency': cur, 'closes': closes,
      'meta': meta, 'updated_at': DateTime.now().toUtc().toIso8601String(),
    });

final _data = MarketsData(ticks: [
  _t('^NSEI', 'index', 'NIFTY 50', 24252, 0.08, closes: [24000, 24252]),
  _t('USDINR=X', 'fx', 'USD/INR', 95.71, -0.06, closes: [95.8, 95.71]),
  _t('bitcoin', 'crypto', 'Bitcoin', 7395017, -0.19),
  _t('GC=F', 'commodity', 'Gold (USD/oz)', 4624.1, 2.39, cur: 'USD'),
  _t('GOLD_INR_10G', 'commodity', 'Gold (₹/10g)', 142290, 2.39,
      meta: {'derived': true, 'label': 'intl spot × USD/INR, ex-duty'}),
], watchlist: const []);

final _blobs = <String, dynamic>{
  'results_calendar': [
    {'symbol': 'TCS', 'company': 'TCS Ltd', 'date': '2026-08-28', 'purpose': 'Financial Results'},
  ],
  'bulk_deals': {
    'as_on': '21-Aug-2026',
    'deals': [
      {'type': 'block', 'symbol': 'AMAGI', 'name': 'Amagi', 'side': 'BUY', 'qty': 142857,
       'price': 560.0, 'value': 80000000, 'client': 'NOTRE DAME', 'date': '21-Aug-2026'},
    ],
  },
  'insider_trades': [
    {'symbol': 'TCS', 'person': 'A Person', 'side': 'Buy', 'qty': '100', 'category': 'Promoter',
     'mode': 'Market', 'date': '20-Aug-2026'},
  ],
  'flows': {
    'fii': {'buy': 12560.91, 'sell': 13103.62, 'net': -542.71},
    'dii': {'buy': 15258.71, 'sell': 13134.57, 'net': 2124.14},
    'date': '21-Aug-2026',
    'pcr': 1.08, 'ce_oi': 2708660, 'pe_oi': 2918695, 'expiry': '25-Aug-2026',
    'underlying': 24252, 'max_oi_strike': 24200,
    'breadth': {'NIFTY 50': {'adv': 25, 'dec': 24}, 'NIFTY 500': {'adv': 217, 'dec': 276}},
  },
  'fno': {
    'oi_gainers': [{'symbol': 'RELIANCE', 'ltp': 3010.5, 'pct': 1.2, 'oi_pct': 38.2}],
    'oi_losers': [{'symbol': 'INFY', 'ltp': 1890.0, 'pct': -0.8, 'oi_pct': -12.0}],
    'gainers': [{'symbol': 'ADANIENT', 'ltp': 3300.0, 'pct': 4.5}],
    'losers': [{'symbol': 'WIPRO', 'ltp': 240.0, 'pct': -3.2}],
    'hi52': 34, 'lo52': 12,
  },
  'bonds': {
    'yields': [
      {'tenor': '10Y', 'yield': 6.82, 'prev': 6.85, 'chg_bp': -3.0, 'date': '2026-08-28'},
      {'tenor': '3Y', 'name': '6.20% GS 2029', 'yield': 6.38, 'prev': null, 'chg_bp': null,
       'date': '2026-09-03'},
    ],
  },
  'rbi_rates': {'repo': 5.25, 'sdf': 5.0, 'crr': 3.0, 'tbill_91d': 5.2599, 'asof': '2026-09-03'},
  'macro_context': {
    'asof': '2026-07-13',
    'series': {
      'NY.GDP.MKTP.KD.ZG': {'name': 'GDP growth', 'units': '%', 'value': 7.57, 'year': '2025',
        'prev': 7.1, 'prev_year': '2024'},
      'BN.CAB.XOKA.GD.ZS': {'name': 'Current account', 'units': '% of GDP', 'value': -0.42,
        'year': '2025', 'prev': -0.85, 'prev_year': '2024'},
    },
  },
  'hazards': {'quakes': [
    {'mag': 5.1, 'place': '115 km NE of Joshimath, India', 'time': '2026-09-03T08:16:36+00:00',
     'url': 'https://earthquake.usgs.gov/x', 'lat': 31.2, 'lon': 79.9},
  ]},
  'ipos': {
    'current': [
      {'symbol': 'ABCIPO', 'company': 'ABC Ltd', 'open': '01-Sep-2026', 'close': '03-Sep-2026',
       'band': '95-100', 'size': '1,200.00', 'series': 'EQ', 'status': 'Open'},
    ],
    'upcoming': [],
  },
  'market_summary': {'text': 'NIFTY +0.1%, SENSEX -0.0% · FII -2,346 cr / DII +4,977 cr · Mood: neutral (48)'},
  'fear_greed': {'score': 48, 'label': 'Neutral', 'methodology_version': 1,
    'components': {'fii': 11, 'vix': 94, 'breadth': 60, 'momentum': 25}},
  'risk_index': {'score': 44, 'label': 'Elevated', 'methodology_version': 1,
    'components': {'inr': 50, 'vix': 6, 'news': 33, 'breadth': 40, 'fii_outflow': 89}},
  'move_context': {
    'explained': [{'symbol': 'ANANTRAJ', 'chg': 7.67, 'story_id': 97588,
      'title': 'NSE Questions Anant Raj Over Sudden Surge in Trading Volume'}],
    'unexplained': [{'symbol': 'IFCI', 'chg': -3.1}],
  },
  'nse_indices': [
    {'index': 'NIFTY IT', 'group': 'SECTORAL INDICES', 'pct': -0.46,
     'last': 30532, 'pe': '28', 'advances': '3', 'declines': '7',
     'pct_30d': 1.8, 'pct_1y': -4.2, 'year_high': 37200, 'year_low': 28100},
    {'index': 'NIFTY 100', 'group': 'BROAD MARKET INDICES', 'pct': 0.02},
    for (var i = 1; i <= 7; i++)
      {'index': 'NIFTY THEME $i', 'group': 'THEMATIC INDICES', 'pct': 0.5},
  ],
};

final _phase3 = MarketsData(
  ticks: [
    ..._data.ticks,
    _t('MF:122639', 'mf', 'Parag Parikh Flexi Cap Fund', 90.8656, 0.14,
        meta: {'scheme_code': 122639, 'ret_1y': -1.2, 'category': 'Equity Scheme - Flexi Cap Fund'}),
    _t('MF:120503', 'mf', 'Axis ELSS Tax Saver Fund', 112.22, -0.02,
        meta: {'scheme_code': 120503, 'ret_1y': 8.0}),
    _t('MACRO:FEDFUNDS', 'macro', 'US Fed funds rate', 4.33, null, cur: '',
        prev: 4.58, closes: [4.58, 4.33],
        meta: {'units': '%', 'delta': -0.25, 'period': '2026-08-01'}),
  ],
  watchlist: const [],
  followedMf: {120503},
  blobs: _blobs,
  blobUpdated: {'bulk_deals': DateTime.now().toUtc()},
);

Widget _app(MarketsData d, {void Function(int, bool)? onFollow}) => MaterialApp(
    home: Scaffold(body: MarketsBody(d, onFollowMf: onFollow, onAddMf: () {})));

Future<void> _toEnd(WidgetTester tester) async {
  await tester.drag(find.byKey(const Key('marketsScroll')), const Offset(0, -6000));
  await tester.pump();
}

void main() {
  mergeMarketsTests();
  testWidgets('Markets body renders every section with formatted numbers',
      (tester) async {
    await tester.pumpWidget(_app(_data));
    // Each heading appears twice: ribbon chip + section header.
    for (final h in ['INDICES', 'WATCHLIST', 'FX', 'CRYPTO', 'COMMODITIES']) {
      expect(find.text(h), findsNWidgets(2), reason: h);
    }
    expect(find.text('MACRO'), findsNothing); // empty section = no chip either
    for (final h in ['TODAY', 'MOOD', 'MOVES', 'QUAKES', 'BONDS']) {
      expect(find.text(h), findsNothing, reason: '$h needs its blob');
    }
    expect(find.text('NIFTY 50'), findsOneWidget);
    expect(find.text('₹24,252'), findsOneWidget);
    expect(find.text('▲0.08%'), findsOneWidget);
    expect(find.text('₹73,95,017'), findsOneWidget);
    expect(find.text('\$4,624.10'), findsOneWidget);
    expect(find.text('intl spot × USD/INR, ex-duty'), findsOneWidget);
    expect(find.textContaining('Nothing followed yet'), findsOneWidget);
    await _toEnd(tester); // the footer sits below the test viewport
    expect(find.textContaining('as of'), findsOneWidget);
    expect(find.textContaining('stale'), findsNothing);
  });

  testWidgets('watchlist rows show the live % from ticks and tolerate a gap',
      (tester) async {
    ticks.value = {'TCS': _t('TCS', 'equity', 'TCS', 2302, 0.17)};
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

  testWidgets('phase 3 sections: MF (followed first, star toggles), economy, '
      'NSE lists, sector tiles', (tester) async {
    final toggles = <(int, bool)>[];
    await tester.pumpWidget(_app(_phase3, onFollow: (c, f) => toggles.add((c, f))));
    // Sectors open the tab: heatmap first, watchlist right below. (Two
    // matches per heading: ribbon chip first in the tree, header second.)
    expect(find.text('SECTORS'), findsNWidgets(2));
    // Sentiment/signal cards (today / mood / moves) come after flows, so
    // the heatmap still opens the tab.
    for (final h in ['TODAY', 'MOOD', 'MOVES']) {
      expect(find.text(h), findsNWidgets(2), reason: h);
    }
    expect(find.textContaining('Mood: neutral (48)'), findsOneWidget);
    expect(tester.getTopLeft(find.text('FLOWS').last).dy <
        tester.getTopLeft(find.text('TODAY').last).dy, isTrue);
    expect(find.text('Fear & Greed'), findsOneWidget);
    expect(find.text('Neutral'), findsOneWidget);
    expect(find.text('India VIX'), findsNWidgets(2)); // F&G and risk components
    expect(find.text('Elevated'), findsOneWidget);
    expect(find.text('ANANTRAJ'), findsOneWidget);
    expect(find.text('▲7.67%'), findsOneWidget);
    expect(find.text('No news we carry'), findsOneWidget);
    expect(find.text('IT'), findsOneWidget); // NIFTY prefix dropped
    expect(find.text('100'), findsOneWidget); // broad market renders too now
    expect(
        tester.getTopLeft(find.text('SECTORS').last).dy <
            tester.getTopLeft(find.text('WATCHLIST').last).dy,
        isTrue);
    // Everything lays out eagerly now, so the rest is visible to finders
    // without scrolling; only taps need the widget on screen.
    expect(find.text('−₹543 Cr'), findsOneWidget);       // FII net, red side
    expect(find.text('+₹2,124 Cr'), findsOneWidget);     // DII net
    expect(find.text('PCR 1.08'), findsOneWidget);
    expect(find.text('25↑ 24↓'), findsOneWidget);
    // Followed scheme (Axis) sorts above the default (Parag) despite the alphabet.
    final axis = tester.getTopLeft(find.text('Axis ELSS Tax Saver Fund'));
    final ppfas = tester.getTopLeft(find.text('Parag Parikh Flexi Cap Fund'));
    expect(axis.dy < ppfas.dy, isTrue);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.textContaining('1y ▼1.2%'), findsOneWidget);
    await tester.ensureVisible(find.byIcon(Icons.star_outline_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.star_outline_rounded).first);
    expect(toggles, [(122639, true)]);
    expect(find.text('+ Add fund'), findsOneWidget);
    expect(find.text('4.33%'), findsOneWidget);
    expect(find.text('-0.25'), findsOneWidget);
    expect(find.text('RESULTS'), findsNWidgets(2));
    expect(find.text('28 Aug'), findsOneWidget);
    expect(find.text('DEALS'), findsNWidgets(2));
    expect(find.text('BUY ₹8.0 Cr'), findsOneWidget);
    expect(find.textContaining('NSE · '), findsWidgets); // blob stamp on deals
    expect(find.text('A Person'), findsOneWidget);
  });

  testWidgets('ribbon chip tracks the scroll and taps jump to the section',
      (tester) async {
    FontWeight? chipWeight(String label) =>
        tester.widget<Text>(find.text(label).first).style?.fontWeight;
    await tester.pumpWidget(_app(_phase3));
    // Before any scroll the first section owns the ribbon.
    expect(chipWeight('SECTORS'), FontWeight.w700);
    // Scrolling to the very bottom hands the ribbon to the last section.
    await _toEnd(tester);
    await tester.pumpAndSettle();
    expect(chipWeight('INSIDER'), FontWeight.w700);
    // Tap a chip to jump back up (bring it into the ribbon's viewport first).
    await tester.ensureVisible(find.text('FLOWS').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('FLOWS').first);
    await tester.pumpAndSettle();
    expect(chipWeight('FLOWS'), FontWeight.w700);
    final header = tester.getTopLeft(find.text('FLOWS').last);
    expect(header.dy, greaterThanOrEqualTo(0));
    expect(header.dy, lessThan(600)); // inside the test viewport
  });

  testWidgets('index board groups collapse past 6 tiles and expand in place',
      (tester) async {
    await tester.pumpWidget(_app(_phase3));
    expect(find.text('SECTORAL'), findsOneWidget);
    expect(find.text('BROAD MARKET'), findsOneWidget);
    expect(find.text('THEMATIC'), findsOneWidget);
    expect(find.text('THEME 6'), findsOneWidget);
    expect(find.text('THEME 7'), findsNothing); // behind the expander
    await tester.ensureVisible(find.text('show all 7'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('show all 7'));
    await tester.pump();
    expect(find.text('THEME 7'), findsOneWidget);
  });

  testWidgets('trader coverage: F&O, bonds and IPO sections render',
      (tester) async {
    await tester.pumpWidget(_app(_phase3));
    for (final h in ['F&O', 'BONDS', 'IPO']) {
      expect(find.text(h), findsNWidgets(2), reason: h); // chip + header
    }
    // PCR moved out of FLOWS into F&O, above the OI movers.
    expect(
        tester.getTopLeft(find.text('F&O').last).dy <
            tester.getTopLeft(find.text('PCR 1.08')).dy,
        isTrue);
    expect(find.text('+38.2% OI'), findsOneWidget);
    expect(find.text('−12.0% OI'), findsOneWidget);
    expect(find.text('34↑ 12↓'), findsOneWidget);
    expect(find.text('top gainer'), findsOneWidget);
    expect(find.text('6.82%'), findsOneWidget);
    expect(find.text('−3.0 bp · 2026-08-28'), findsOneWidget);
    // 0.31.0: named benchmark G-Secs, the curve (2+ points), RBI policy box
    expect(find.text('6.20% GS 2029'), findsOneWidget);
    expect(find.byType(Sparkline), findsWidgets);
    expect(find.text('Repo rate'), findsOneWidget);
    expect(find.text('5.25%'), findsOneWidget);
    expect(find.text('91-day T-bill cut-off'), findsOneWidget);
    // World Bank rows ride the MACRO section; quakes get their own
    expect(find.text('GDP growth'), findsOneWidget);
    expect(find.text('prev 2024: 7.10'), findsOneWidget);
    expect(find.textContaining('% of GDP · prev 2024: '), findsOneWidget);
    expect(find.textContaining('0.85'), findsOneWidget);
    expect(find.text('QUAKES'), findsNWidgets(2));
    expect(find.text('M5.1'), findsOneWidget);
    expect(find.text('09-03'), findsOneWidget);
    expect(find.text('ABC Ltd'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('₹95-100 · 1,200.00 · 01-Sep-2026–03-Sep-2026'),
        findsOneWidget);
  });

  testWidgets('ribbon search filters headings and jumps on tap',
      (tester) async {
    await tester.pumpWidget(_app(_phase3));
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'cry');
    await tester.pump();
    // Chips filtered to CRYPTO; section headers are untouched.
    expect(find.text('FLOWS'), findsOneWidget); // header only, chip gone
    expect(find.text('CRYPTO'), findsNWidgets(2));
    await tester.tap(find.text('CRYPTO').first);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing); // search closes on jump
    final header = tester.getTopLeft(find.text('CRYPTO').last);
    expect(header.dy, greaterThanOrEqualTo(0));
    expect(header.dy, lessThan(600));
  });

  testWidgets('tapping a sector tile opens the full NSE row in a sheet',
      (tester) async {
    await tester.pumpWidget(_app(_phase3));
    await tester.tap(find.text('IT'));
    await tester.pumpAndSettle();
    expect(find.text('NIFTY IT'), findsOneWidget); // sheet title
    expect(find.text('P/E'), findsOneWidget);
    expect(find.text('3↑ 7↓'), findsOneWidget);
    expect(find.text('▲1.80%'), findsOneWidget);          // 30d
    expect(find.text('▼4.20%'), findsOneWidget);          // 1y
    expect(find.text('37,200 / 28,100'), findsOneWidget); // 52w
  });

  testWidgets('empty data explains itself instead of a blank screen',
      (tester) async {
    await tester.pumpWidget(_app(const MarketsData(ticks: [], watchlist: [])));
    expect(find.textContaining('No market data yet'), findsOneWidget);
  });

  test('companyEventLines picks only this symbol from the blobs', () {
    final lines = companyEventLines(_blobs, 'TCS');
    expect(lines.length, 2);
    expect(lines[0], 'Board meeting 28 Aug — Financial Results');
    expect(lines[1], startsWith('Insider buy: A Person 100'));
    expect(companyEventLines(_blobs, 'AMAGI').single, contains('Block BUY 1,42,857 @ ₹560.00'));
    expect(companyEventLines(const {}, 'TCS'), isEmpty);
  });

  test('Markets is the second tab', () {
    expect(homeTabLabels, ['News', 'Markets', 'Ask', 'Profile']);
    expect(homeTabLabels[marketsTab], 'Markets');
  });
}

// ---------- mergeMarkets: the 60s delta poll ----------

void mergeMarketsTests() {
  test('mergeMarkets overrides changed rows and keeps the rest', () {
    final prev = MarketsData(
      ticks: [_t('^NSEI', 'index', 'NIFTY 50', 24252, 0.08), _t('bitcoin', 'crypto', 'Bitcoin', 7395017, -0.19)],
      watchlist: const [],
      blobs: const {'flows': {'pcr': 1.08}, 'fno': {'hi52': 34}},
      blobUpdated: {'flows': DateTime.utc(2026, 9, 2, 9), 'fno': DateTime.utc(2026, 9, 2, 9)},
    );
    final merged = mergeMarkets(
      prev,
      [_t('^NSEI', 'index', 'NIFTY 50', 24300, 0.28)],
      {'flows': {'pcr': 1.11}},
      {'flows': DateTime.utc(2026, 9, 2, 10)},
      const [],
      const {},
    );
    expect(merged.ticks.length, 2);
    expect(merged.kind('index').single.price, 24300); // fresh row won
    expect(merged.kind('crypto').single.price, 7395017); // untouched row kept
    expect((merged.blobs['flows'] as Map)['pcr'], 1.11);
    expect((merged.blobs['fno'] as Map)['hi52'], 34);
    expect(merged.blobUpdated['flows'], DateTime.utc(2026, 9, 2, 10));
    expect(merged.blobUpdated['fno'], DateTime.utc(2026, 9, 2, 9));
  });

  test('mergeMarkets with nothing fresh keeps the previous picture', () {
    final prev = MarketsData(
        ticks: [_t('^NSEI', 'index', 'NIFTY 50', 24252, 0.08)],
        watchlist: const [],
        blobs: const {'bonds': {'yields': []}},
        blobUpdated: const {});
    final merged = mergeMarkets(prev, const [], const {}, const {}, const [], const {});
    expect(merged.ticks.single.price, 24252);
    expect(merged.blobs['bonds'], isNotNull);
  });
}
