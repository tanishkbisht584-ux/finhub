import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show homeTabLabels, marketsTab;
import 'package:finswipe/screens/markets.dart';
import 'package:finswipe/screens/stock.dart';
import 'package:finswipe/ticks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Tick _t(String sym, String kind, String name, double price, double? pct,
        {String cur = 'INR',
        List<double> closes = const [],
        Map? meta,
        double? prev}) =>
    Tick.fromJson({
      'symbol': sym,
      'kind': kind,
      'name': name,
      'price': price,
      'prev_close': prev,
      'change_pct': pct,
      'currency': cur,
      'closes': closes,
      'meta': meta,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });

final _data = MarketsData(ticks: [
  _t('^NSEI', 'index', 'NIFTY 50', 24252, 0.08, closes: [24000, 24252]),
  _t('USDINR=X', 'fx', 'USD/INR', 95.71, -0.06, closes: [95.8, 95.71]),
  _t('bitcoin', 'crypto', 'Bitcoin', 7395017, -0.19,
      prev: 7409093, meta: {'usd': 88000, 'vol_24h': 4005655243996}),
  _t('GC=F', 'commodity', 'Gold (USD/oz)', 4624.1, 2.39, cur: 'USD'),
  _t('GOLD_INR_10G', 'commodity', 'Gold (₹/10g)', 142290, 2.39,
      meta: {'derived': true, 'label': 'intl spot × USD/INR, ex-duty'}),
], watchlist: const []);

final _blobs = <String, dynamic>{
  'results_calendar': [
    {
      'symbol': 'TCS',
      'company': 'TCS Ltd',
      'date': '2026-08-28',
      'purpose': 'Financial Results'
    },
  ],
  'bulk_deals': {
    'as_on': '21-Aug-2026',
    'deals': [
      {
        'type': 'block',
        'symbol': 'AMAGI',
        'name': 'Amagi',
        'side': 'BUY',
        'qty': 142857,
        'price': 560.0,
        'value': 80000000,
        'client': 'NOTRE DAME',
        'date': '21-Aug-2026'
      },
    ],
  },
  'insider_trades': [
    {
      'symbol': 'TCS',
      'person': 'A Person',
      'side': 'Buy',
      'qty': '100',
      'category': 'Promoter',
      'mode': 'Market',
      'date': '20-Aug-2026'
    },
  ],
  'flows': {
    'fii': {'buy': 12560.91, 'sell': 13103.62, 'net': -542.71},
    'dii': {'buy': 15258.71, 'sell': 13134.57, 'net': 2124.14},
    'date': '21-Aug-2026',
    'pcr': 1.08,
    'ce_oi': 2708660,
    'pe_oi': 2918695,
    'expiry': '25-Aug-2026',
    'underlying': 24252,
    'max_oi_strike': 24200,
    'breadth': {
      'NIFTY 50': {'adv': 25, 'dec': 24},
      'NIFTY 500': {'adv': 217, 'dec': 276}
    },
  },
  'trends': {
    'asof': '2026-09-18',
    'bullish': [
      {
        'symbol': 'RELIANCE',
        'name': 'Reliance',
        'price': 1226.4,
        'chg': 1.41,
        'trend': 'bullish',
        'prev': null,
        'since': '2026-09-01',
        'since_price': 1100.0,
        'perf': 11.49
      }
    ],
    'turning_bullish': [],
    'bearish': [],
    'turning_bearish': [
      {
        'symbol': 'INFY',
        'name': 'Infosys',
        'price': 1890.0,
        'chg': -0.8,
        'trend': 'bearish',
        'prev': 'bullish',
        'since': '2026-09-17',
        'since_price': 1950.0,
        'perf': -3.08
      }
    ],
  },
  'fno': {
    'oi_gainers': [
      {'symbol': 'RELIANCE', 'ltp': 3010.5, 'pct': 1.2, 'oi_pct': 38.2}
    ],
    'oi_losers': [
      {'symbol': 'INFY', 'ltp': 1890.0, 'pct': -0.8, 'oi_pct': -12.0}
    ],
    'gainers': [
      {'symbol': 'ADANIENT', 'ltp': 3300.0, 'pct': 4.5}
    ],
    'losers': [
      {'symbol': 'WIPRO', 'ltp': 240.0, 'pct': -3.2}
    ],
    'hi52': 34,
    'lo52': 12,
  },
  'bonds': {
    'yields': [
      {
        'tenor': '10Y',
        'yield': 6.82,
        'prev': 6.85,
        'chg_bp': -3.0,
        'date': '2026-08-28'
      },
      {
        'tenor': '3Y',
        'name': '6.20% GS 2029',
        'yield': 6.38,
        'prev': null,
        'chg_bp': null,
        'date': '2026-09-03'
      },
    ],
  },
  'rbi_rates': {
    'repo': 5.25,
    'sdf': 5.0,
    'crr': 3.0,
    'tbill_91d': 5.2599,
    'asof': '2026-09-03'
  },
  'macro_context': {
    'asof': '2026-07-13',
    'series': {
      'NY.GDP.MKTP.KD.ZG': {
        'name': 'GDP growth',
        'units': '%',
        'value': 7.57,
        'year': '2025',
        'prev': 7.1,
        'prev_year': '2024'
      },
      'BN.CAB.XOKA.GD.ZS': {
        'name': 'Current account',
        'units': '% of GDP',
        'value': -0.42,
        'year': '2025',
        'prev': -0.85,
        'prev_year': '2024'
      },
    },
  },
  'hazards': {
    'quakes': [
      {
        'mag': 5.1,
        'place': '115 km NE of Joshimath, India',
        'time': '2026-09-03T08:16:36+00:00',
        'url': 'https://earthquake.usgs.gov/x',
        'lat': 31.2,
        'lon': 79.9
      },
    ]
  },
  'ipos': {
    'current': [
      {
        'symbol': 'ABCIPO',
        'company': 'ABC Ltd',
        'open': '01-Sep-2026',
        'close': '03-Sep-2026',
        'band': '95-100',
        'size': '1,200.00',
        'series': 'EQ',
        'status': 'Open'
      },
    ],
    'upcoming': [],
  },
  'market_summary': {
    'text':
        'NIFTY +0.1%, SENSEX -0.0% · FII -2,346 cr / DII +4,977 cr · Mood: neutral (48)'
  },
  'fear_greed': {
    'score': 48,
    'label': 'Neutral',
    'methodology_version': 2,
    'components': {
      'fii': 11,
      'vix': 94,
      'breadth': 60,
      'momentum': 25,
      'pcr': 50,
      'fii_pos': 71,
      'nifty_gold': 57,
    }
  },
  'correlation': {
    'assets': ['NIFTY', 'Gold', 'USD/INR'],
    'matrix': [
      [1.0, 0.62, -0.41],
      [0.62, 1.0, -0.18],
      [-0.41, -0.18, 1.0],
    ],
    'window_d': 21,
  },
  'freight': {
    'indices': [
      {
        'name': 'SCFI',
        'value': 3590.02,
        'prev': 3509.5,
        'pct': 2.29,
        'date': '2026-09-04'
      },
    ],
    'asof': '2026-09-04',
  },
  'risk_index': {
    'score': 44,
    'label': 'Elevated',
    'methodology_version': 1,
    'components': {
      'inr': 50,
      'vix': 6,
      'news': 33,
      'breadth': 40,
      'fii_outflow': 89
    }
  },
  'move_context': {
    'explained': [
      {
        'symbol': 'ANANTRAJ',
        'chg': 7.67,
        'ltp': 610.0,
        'story_id': 97588,
        'title': 'NSE Questions Anant Raj Over Sudden Surge in Trading Volume',
        'impact': 6,
        'source': 'Mint Markets',
        'at': '2026-08-21T10:00:00+05:30',
      },
      {
        'symbol': 'IFCI',
        'chg': -3.1,
        'ltp': 42.5,
        'reason': 'Bagging of orders worth Rs 120 crore from NHAI',
        'source': 'NSE filing',
        'at': '2026-08-21T15:10:00+05:30',
        'url': 'https://nsearchives.nseindia.com/x.pdf',
      },
    ],
    'unexplained': [],
    'unexplained_n': 3,
  },
  'predictions': {
    'markets': [
      {
        'q': 'Will the Fed cut 25 bps in September?',
        'slug': 'fed-sep',
        'label': 'Yes',
        'pct': 1,
        'end': '2026-09-16'
      },
    ],
  },
  // Context layer (0.33.0)
  'calendar': {
    'asof': '2026-09-05',
    'events': [
      {
        'date': '2026-09-11',
        'name': 'US CPI',
        'region': 'US',
        'time': '08:30 ET'
      },
      {
        'date': '2026-10-07',
        'name': 'RBI MPC decision',
        'region': 'IN',
        'time': '10:00 IST'
      },
    ]
  },
  'participant_oi': {
    'date': '2026-09-04',
    'rows': {
      'FII': {
        'fut_idx_long': 33502,
        'fut_idx_short': 268604,
        'net_fut_idx': -235102,
        'total_long': 5470310,
        'total_short': 4814011,
        'prev_net_fut_idx': -200000
      },
      'DII': {
        'net_fut_idx': 11369,
        'total_long': 1,
        'total_short': 2,
        'prev_net_fut_idx': null
      },
    }
  },
  'shipping': {
    'asof': '2026-08-30',
    'chokepoints': [
      {
        'name': 'Hormuz',
        'date': '2026-08-30',
        'n_total': 6,
        'n_tanker': 2,
        'avg7': 4.3,
        'avg30': 4.9,
        'pct': -12.5
      }
    ],
    'ports': [
      {
        'name': 'JNPT',
        'date': '2026-08-28',
        'portcalls': 18,
        'import': 74605,
        'export': 141222
      }
    ]
  },
  'monsoon': {
    'asof': '2026-09-05',
    'country': {'dep_pct': -13, 'actual_mm': 629.7, 'normal_mm': 727.9},
    'regions': [
      {'name': 'South Peninsula', 'dep_pct': -26}
    ],
    'worst': [
      {'name': 'Rayalaseema', 'dep_pct': -46}
    ],
    'best': []
  },
  'cb_rates': {
    'asof': '2026-09-04',
    'rates': {
      'US': {'name': 'Fed funds', 'rate': 3.625, 'asof': '2026-09-01'},
      'XM': {'name': 'ECB deposit', 'rate': 2.25, 'asof': '2026-09-01'},
    }
  },
  'nse_indices': [
    {
      'index': 'NIFTY IT',
      'group': 'SECTORAL INDICES',
      'pct': -0.46,
      'last': 30532,
      'pe': '28',
      'advances': '3',
      'declines': '7',
      'pct_30d': 1.8,
      'pct_1y': -4.2,
      'year_high': 37200,
      'year_low': 28100
    },
    {'index': 'NIFTY 100', 'group': 'BROAD MARKET INDICES', 'pct': 0.02},
    for (var i = 1; i <= 7; i++)
      {'index': 'NIFTY THEME $i', 'group': 'THEMATIC INDICES', 'pct': 0.5},
  ],
};

final _phase3 = MarketsData(
  ticks: [
    ..._data.ticks,
    _t('^GSPC', 'index', 'S&P 500', 7716.03, -0.41,
        cur: '', closes: [7700, 7716], meta: {'global': true}),
    _t('ADR:INFY', 'index', 'Infosys ADR (NYSE)', 11.75, -2.77,
        cur: 'USD', meta: {'global': true, 'adr': true}),
    _t('US:NVDA', 'index', 'Nvidia', 222.25, 1.33,
        cur: 'USD',
        prev: 219.34,
        closes: [200, 222.25],
        meta: {
          'global': true,
          'us': true,
          'idx': ['DOW', 'NASDAQ'],
          'trend': 'VERY BULLISH',
          'hi52': 224.0,
          'lo52': 86.6
        }),
    _t('US:CAT', 'index', 'Caterpillar', 808.99, -1.30,
        cur: 'USD',
        prev: 819.64,
        closes: [790, 808.99],
        meta: {
          'global': true,
          'us': true,
          'idx': ['DOW'],
          'trend': 'NEUTRAL',
          'hi52': 900.0,
          'lo52': 600.0
        }),
    _t('MF:122639', 'mf', 'Parag Parikh Flexi Cap Fund', 90.8656, 0.14, meta: {
      'scheme_code': 122639,
      'ret_1y': -1.2,
      'category': 'Equity Scheme - Flexi Cap Fund'
    }),
    _t('MF:120503', 'mf', 'Axis ELSS Tax Saver Fund', 112.22, -0.02,
        meta: {'scheme_code': 120503, 'ret_1y': 8.0}),
    _t('MACRO:FEDFUNDS', 'macro', 'US Fed funds rate', 4.33, null,
        cur: '',
        prev: 4.58,
        closes: [4.58, 4.33],
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
  await tester.drag(
      find.byKey(const Key('marketsScroll')), const Offset(0, -30000));
  await tester.pump();
}

/// Tap a region pill (INDIA · MF · … · US) below the pinned heatmap.
Future<void> _region(WidgetTester tester, String r) async {
  await tester.ensureVisible(find.byKey(const Key('marketsRegions')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(r).first);
  await tester.pumpAndSettle();
}

void main() {
  mergeMarketsTests();
  testWidgets('Markets body renders every section with formatted numbers',
      (tester) async {
    await tester.pumpWidget(_app(_data));
    // Each heading appears twice: ribbon chip + section header.
    for (final h in ['SESSIONS', 'INDICES', 'WATCHLIST', 'FX', 'COMMODITIES']) {
      expect(find.text(h), findsNWidgets(2), reason: h);
    }
    // Region pills: INDIA opens; CRYPTO is only its pill until picked.
    for (final r in ['INDIA', 'MF', 'BONDS', 'IPO', 'UNLISTED', 'CRYPTO', 'US']) {
      expect(find.text(r), findsOneWidget, reason: r);
    }
    expect(find.text('GLOBAL'), findsNothing); // no meta.global ticks here
    expect(find.text('ODDS'), findsNothing);
    expect(find.text('MACRO'), findsNothing); // empty section = no chip either
    for (final h in [
      'TODAY',
      'MOOD',
      'MOVES',
      'QUAKES',
      'CALENDAR',
      'POSITIONING',
      'SHIPPING',
      'MONSOON'
    ]) {
      expect(find.text(h), findsNothing, reason: '$h needs its blob');
    }
    expect(find.text('NIFTY 50'), findsOneWidget);
    expect(find.text('₹24,252'), findsOneWidget);
    expect(find.text('▲0.08%'), findsOneWidget);
    expect(find.text('₹73,95,017'), findsNothing); // crypto: its own tab
    expect(find.text('\$4,624.10'), findsOneWidget);
    expect(find.text('intl spot × USD/INR, ex-duty'), findsOneWidget);
    expect(find.textContaining('Nothing followed yet'), findsOneWidget);
    expect(find.text('SEARCH'), findsOneWidget); // stock search door
    await _toEnd(tester); // the footer sits below the test viewport
    expect(find.textContaining('as of'), findsOneWidget);
    expect(find.textContaining('stale'), findsNothing);
    // Pick CRYPTO: pill + chip + header; India-only sections leave the page.
    await _region(tester, 'CRYPTO');
    expect(find.text('CRYPTO'), findsNWidgets(3));
    expect(find.text('₹73,95,017'), findsOneWidget);
    expect(find.text('−14,076'), findsOneWidget); // 24h ₹ move
    expect(find.text('₹4,00,566 Cr'), findsOneWidget); // 24h volume
    await tester.tap(find.text('USD'));
    await tester.pump();
    expect(find.text('\$88,000'), findsOneWidget);
    expect(find.text('\$47.7B'), findsOneWidget);
    expect(find.text('−167.50'), findsOneWidget);
    await tester.tap(find.text('INR'));
    await tester.pump();
    expect(find.text('₹73,95,017'), findsOneWidget);
    expect(find.text('INDICES'), findsNothing);
    expect(find.text('SECTIONS'), findsNothing);
    expect(find.text('SESSIONS'), findsNWidgets(2)); // pinned above the pills
    await _region(tester, 'UNLISTED');
    expect(find.textContaining('source not wired yet'), findsOneWidget);
    await _region(tester, 'INDIA');
    expect(find.text('INDICES'), findsNWidgets(2));
  });

  testWidgets('TRENDS: bucket pills switch the table, turning rows show Was',
      (tester) async {
    await tester.pumpWidget(_app(_phase3));
    expect(find.text('TRENDS'), findsNWidgets(2));
    // MC order: TRENDS right after INDICES, before OI TRENDS and TOP.
    expect(
        tester.getTopLeft(find.text('INDICES').last).dy <
            tester.getTopLeft(find.text('TRENDS').last).dy,
        isTrue);
    expect(
        tester.getTopLeft(find.text('TRENDS').last).dy <
            tester.getTopLeft(find.text('OI TRENDS').last).dy,
        isTrue);
    expect(find.text('RELIANCE'), findsWidgets); // bullish bucket opens
    expect(find.text('▲11.49%'), findsOneWidget);
    expect(find.text('▼3.08%'), findsNothing); // INFY is an OI row elsewhere
    await tester.ensureVisible(find.text('TURNING BEARISH'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TURNING BEARISH'));
    await tester.pump();
    expect(find.text('INFY'), findsWidgets);
    expect(find.text('bullish'), findsOneWidget); // Was column
    expect(find.text('▼3.08%'), findsOneWidget);
    expect(find.text('▲11.49%'), findsNothing);
    await tester.tap(find.text('BEARISH').first);
    await tester.pump();
    expect(find.text('none in this bucket'), findsOneWidget);
  });

  testWidgets('watchlist rows show the live % from ticks and tolerate a gap',
      (tester) async {
    ticks.value = {'TCS': _t('TCS', 'equity', 'TCS', 2302, 0.17)};
    final d = MarketsData(ticks: _data.ticks, watchlist: [
      Company.fromJson(
          {'id': 1, 'name': 'Tata Consultancy', 'nse_symbol': 'TCS'}),
      Company.fromJson({'id': 2, 'name': 'Infosys', 'nse_symbol': 'INFY'}),
    ]);
    await tester.pumpWidget(_app(d));
    expect(find.text('\$TCS'), findsOneWidget);
    expect(find.text('▲0.17%'), findsOneWidget);
    expect(find.text('\$INFY'), findsOneWidget);
    expect(find.text('—'), findsOneWidget); // no quote yet, row still there
    ticks.value = {};
  });

  testWidgets(
      'phase 3 sections: MF (followed first, star toggles), economy, '
      'NSE lists, sector tiles', (tester) async {
    final toggles = <(int, bool)>[];
    await tester
        .pumpWidget(_app(_phase3, onFollow: (c, f) => toggles.add((c, f))));
    // Sectors open the tab: heatmap first, watchlist right below. (Two
    // matches per heading: ribbon chip first in the tree, header second.)
    expect(find.text('SECTORS'), findsNWidgets(2));
    // Sentiment/signal cards (today / mood / moves) come after flows, so
    // the heatmap still opens the tab.
    for (final h in ['TODAY', 'MOOD', 'MOVES']) {
      expect(find.text(h), findsNWidgets(2), reason: h);
    }
    expect(find.textContaining('Mood: neutral (48)'), findsOneWidget);
    expect(
        tester.getTopLeft(find.text('FLOWS').last).dy <
            tester.getTopLeft(find.text('TODAY').last).dy,
        isTrue);
    expect(find.text('Fear & Greed'), findsOneWidget);
    expect(find.text('Neutral'), findsOneWidget);
    expect(find.text('India VIX'), findsNWidgets(2)); // F&G and risk components
    expect(find.text('Elevated'), findsOneWidget);
    // F&G v2 components + the cross-asset correlation grid inside MOOD
    expect(find.text('Put/call ratio'), findsOneWidget);
    expect(find.text('NIFTY vs gold'), findsOneWidget);
    expect(find.text('CROSS-ASSET · 1M'), findsOneWidget);
    expect(find.text('0.62'), findsNWidgets(2)); // symmetric matrix cell
    // freight rides the SHIPPING section
    expect(find.text('SCFI'), findsOneWidget);
    expect(find.textContaining('w/w +2.29%'), findsOneWidget);
    expect(find.text('ANANTRAJ'), findsOneWidget);
    expect(find.text('▲7.67%'), findsOneWidget);
    // Moves: story row + NSE-filing row, whole headline, source, impact.
    expect(
        find.text(
            'NSE Questions Anant Raj Over Sudden Surge in Trading Volume'),
        findsOneWidget);
    expect(find.text('6/10'), findsOneWidget);
    expect(find.text('Mint Markets'), findsOneWidget);
    expect(find.text('Bagging of orders worth Rs 120 crore from NHAI'),
        findsOneWidget);
    expect(find.text('NSE filing'), findsOneWidget);
    expect(find.text('filing'), findsOneWidget);
    expect(find.textContaining('3 more moved'), findsOneWidget);
    expect(find.text('No news we carry'), findsNothing);
    // Today: the joined text splits into bullets.
    expect(find.text('•  '), findsWidgets);
    expect(find.text('IT'), findsOneWidget); // NIFTY prefix dropped
    expect(find.text('100'),
        findsNWidgets(2)); // broad market tile + insider qty cell
    expect(
        tester.getTopLeft(find.text('SECTORS').last).dy <
            tester.getTopLeft(find.text('WATCHLIST').last).dy,
        isTrue);
    // Everything lays out eagerly now, so the rest is visible to finders
    // without scrolling; only taps need the widget on screen.
    expect(find.text('−₹543 Cr'), findsOneWidget); // FII net, red side
    expect(find.text('+₹2,124 Cr'), findsOneWidget); // DII net
    expect(find.text('1.08'), findsOneWidget); // NIFTY PCR tile
    expect(find.text('25↑ 24↓'), findsOneWidget);
    // Followed scheme (Axis) sorts above the default (Parag) despite the alphabet.
    await _region(tester, 'MF');
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
    // Global layer: world rows leave INDICES, form GLOBAL under US; odds too.
    await _region(tester, 'US');
    expect(find.text('GLOBAL'), findsNWidgets(2));
    expect(find.text('S&P 500'), findsOneWidget);
    expect(find.text('INDIA ADRS (NYSE)'), findsOneWidget);
    expect(find.text('ODDS'), findsNWidgets(2));
    expect(find.textContaining('Fed cut 25 bps'), findsOneWidget);
    // US stocks are their own MARKET MOVERS table, not GLOBAL rows.
    expect(find.text('MARKET MOVERS'), findsNWidgets(2));
    expect(find.text('Nvidia'), findsOneWidget);
    expect(find.text('VERY BULLISH'), findsOneWidget);
    expect(find.text('222.25'), findsOneWidget);
    expect(find.text('+2.91'), findsOneWidget); // Chg \$ from prev close
    expect(find.text('▲1.33%'), findsOneWidget);
    expect(find.text('Caterpillar'), findsOneWidget);
    await tester.ensureVisible(find.text('NASDAQ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NASDAQ'));
    await tester.pump();
    expect(find.text('Caterpillar'), findsNothing); // Dow-only name filtered
    await tester.tap(find.text('ALL'));
    await tester.pump();
    await tester.tap(find.text('52W HIGH'));
    await tester.pump();
    expect(find.text('Nvidia'), findsOneWidget); // within 2% of its high
    expect(find.text('Caterpillar'), findsNothing);
    await tester.tap(find.text('LOSERS'));
    await tester.pump();
    expect(
        tester.getTopLeft(find.text('Caterpillar')).dy <
            tester.getTopLeft(find.text('Nvidia')).dy,
        isTrue);
    await _region(tester, 'INDIA');
    expect(find.text('4.33%'), findsOneWidget);
    expect(find.text('-0.25'), findsOneWidget);
    expect(find.text('RESULTS'), findsNWidgets(2));
    expect(find.text('28 Aug'), findsWidgets); // results date, G-Sec as-of
    expect(find.text('DEALS'), findsNWidgets(2));
    expect(find.text('₹8.0 Cr'), findsOneWidget);
    expect(find.text('NOTRE DAME'), findsOneWidget); // whole client name
    expect(find.textContaining('NSE · '), findsWidgets); // blob stamp on deals
    expect(find.textContaining('A Person'), findsOneWidget);
  });

  testWidgets('ribbon chip tracks the scroll and taps jump to the section',
      (tester) async {
    FontWeight? chipWeight(String label) =>
        tester.widget<Text>(find.text(label).first).style?.fontWeight;
    await tester.pumpWidget(_app(_phase3));
    // Before any scroll the first section owns the ribbon.
    expect(chipWeight('SESSIONS'), FontWeight.w700);
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

  testWidgets('trader coverage: TOP, OI TRENDS, bonds and IPO sections render',
      (tester) async {
    await tester.pumpWidget(_app(_phase3));
    for (final h in ['TOP', 'OI TRENDS']) {
      expect(find.text(h), findsNWidgets(2), reason: h); // chip + header
    }
    // PCR lives in OI TRENDS, above the OI movers; TOP holds gainers/losers.
    expect(
        tester.getTopLeft(find.text('OI TRENDS').last).dy <
            tester.getTopLeft(find.text('NIFTY PCR')).dy,
        isTrue);
    expect(
        tester.getTopLeft(find.text('TOP').last).dy <
            tester.getTopLeft(find.text('TOP GAINERS')).dy,
        isTrue);
    expect(find.text('+38.2%'), findsOneWidget); // OI chg column
    expect(find.text('−12.0%'), findsOneWidget);
    expect(find.text('OI up'), findsOneWidget); // old blob: no `read`
    expect(find.text('34↑ 12↓'), findsOneWidget);
    expect(find.text('ADANIENT'), findsOneWidget); // heat grid tile
    expect(find.text('▲4.50%'), findsOneWidget); // top gainers table
    await _region(tester, 'BONDS');
    expect(find.text('6.82%'), findsOneWidget);
    expect(find.text('−3.0'), findsOneWidget); // Δ bp column
    expect(find.text('6.85%'), findsOneWidget); // prev yield column
    expect(find.text('28 Aug'), findsWidgets);
    // 0.31.0: named benchmark G-Secs, the curve (2+ points), RBI policy box
    expect(find.text('6.20% GS 2029'), findsOneWidget);
    expect(find.text('Repo rate'), findsOneWidget);
    expect(find.text('5.25%'), findsOneWidget);
    expect(find.text('91-day T-bill cut-off'), findsOneWidget);
    // World Bank rows ride the MACRO section; quakes get their own
    await _region(tester, 'INDIA');
    expect(find.byType(Sparkline), findsWidgets); // index rows
    expect(find.text('GDP growth'), findsOneWidget);
    expect(find.text('7.10%'), findsOneWidget); // PRIOR column, units %
    expect(find.text('2024'), findsWidgets); // PRIOR YR column
    expect(find.text('2025'), findsWidgets); // YEAR column
    expect(find.text('% of GDP'), findsOneWidget); // UNITS column
    expect(find.text('-0.85'), findsOneWidget);
    expect(find.text('QUAKES'), findsNWidgets(2));
    expect(find.text('M5.1'), findsOneWidget);
    expect(find.text('3 Sep'), findsWidgets); // quake date (and a G-Sec as-of)
    expect(find.text('115 km NE of Joshimath, India'), findsOneWidget);
    await _region(tester, 'IPO');
    expect(find.text('ABC Ltd'), findsOneWidget); // IPO: its own column
    expect(find.text('1 Sep'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('ribbon search filters headings and jumps on tap',
      (tester) async {
    await tester.pumpWidget(_app(_phase3));
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'flo');
    await tester.pump();
    // Chips filtered to FLOWS; section headers (and region pills) untouched.
    expect(find.text('MOOD'), findsOneWidget); // header only, chip gone
    expect(find.text('FLOWS'), findsNWidgets(2));
    await tester.tap(find.text('FLOWS').first);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing); // search closes on jump
    final header = tester.getTopLeft(find.text('FLOWS').last);
    expect(header.dy, greaterThanOrEqualTo(0));
    expect(header.dy, lessThan(600));
  });

  testWidgets('sector horizon pills re-tint and re-sort tiles', (tester) async {
    await tester.pumpWidget(_app(_phase3));
    await tester.pump();
    expect(find.text('1D'), findsOneWidget);
    // Today: IT is the only sectoral tile and reads its day change.
    expect(find.text('−0.46%'), findsOneWidget);
    await tester.tap(find.text('30D'));
    await tester.pump();
    expect(find.text('+1.80%'), findsOneWidget); // pct_30d
    expect(find.text('−0.46%'), findsNothing);
    await tester.tap(find.text('1Y'));
    await tester.pump();
    expect(find.text('−4.20%'), findsOneWidget); // pct_1y
  });

  testWidgets('tapping a sector tile opens the full NSE row in a sheet',
      (tester) async {
    await tester.pumpWidget(_app(_phase3));
    await tester.tap(find.text('IT'));
    await tester.pumpAndSettle();
    expect(find.text('NIFTY IT'), findsOneWidget); // sheet title
    expect(find.text('P/E'), findsOneWidget);
    expect(find.text('3↑ 7↓'), findsOneWidget);
    expect(find.text('▲1.80%'), findsOneWidget); // 30d
    expect(find.text('▼4.20%'), findsOneWidget); // 1y
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
    expect(companyEventLines(_blobs, 'AMAGI').single,
        contains('Block BUY 1,42,857 @ ₹560.00'));
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
      ticks: [
        _t('^NSEI', 'index', 'NIFTY 50', 24252, 0.08),
        _t('bitcoin', 'crypto', 'Bitcoin', 7395017, -0.19)
      ],
      watchlist: const [],
      blobs: const {
        'flows': {'pcr': 1.08},
        'fno': {'hi52': 34}
      },
      blobUpdated: {
        'flows': DateTime.utc(2026, 9, 2, 9),
        'fno': DateTime.utc(2026, 9, 2, 9)
      },
    );
    final merged = mergeMarkets(
      prev,
      [_t('^NSEI', 'index', 'NIFTY 50', 24300, 0.28)],
      {
        'flows': {'pcr': 1.11}
      },
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
    final prev = MarketsData(ticks: [
      _t('^NSEI', 'index', 'NIFTY 50', 24252, 0.08)
    ], watchlist: const [], blobs: const {
      'bonds': {'yields': []}
    }, blobUpdated: const {});
    final merged =
        mergeMarkets(prev, const [], const {}, const {}, const [], const {});
    expect(merged.ticks.single.price, 24252);
    expect(merged.blobs['bonds'], isNotNull);
  });

  testWidgets(
      'context layer: calendar, positioning, shipping, monsoon, CB rates',
      (tester) async {
    await tester.pumpWidget(_app(_phase3));
    for (final h in ['CALENDAR', 'POSITIONING', 'SHIPPING', 'MONSOON']) {
      expect(find.text(h), findsNWidgets(2), reason: h); // chip + header
    }
    expect(find.text('US CPI'), findsOneWidget);
    expect(find.text('11 Sep'), findsOneWidget);
    expect(find.text('NET IDX FUT'), findsOneWidget); // positioning table
    expect(find.text('−2,35,102'), findsOneWidget);
    expect(find.text('−35,102'), findsOneWidget); // Δ d/d
    expect(find.text('54,70,310'), findsOneWidget); // total long, whole
    expect(find.text('2,68,604'),
        findsOneWidget); // fut short (never shown before)
    expect(find.text('Hormuz'), findsOneWidget);
    expect(find.text('−12.5% vs 30d'), findsOneWidget);
    expect(find.text('JNPT port calls'), findsOneWidget);
    expect(find.text('−13%'), findsOneWidget);
    expect(find.text('Rayalaseema'), findsOneWidget);
    await _region(tester, 'BONDS'); // CB rates ride the BONDS tab
    expect(find.text('ECB deposit'), findsOneWidget);
    expect(find.text('2.25%'), findsOneWidget);
    // Sessions is always there, first, and every venue has a row.
    expect(find.text('SESSIONS'), findsNWidgets(2));
    for (final v in ['NSE', 'LONDON', 'NEW YORK', 'TOKYO', 'HONG KONG']) {
      expect(find.text(v), findsOneWidget, reason: v);
    }
  });
}
