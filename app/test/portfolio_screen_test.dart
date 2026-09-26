import 'package:finflick/models.dart';
import 'package:finflick/portfolio.dart';
import 'package:finflick/screens/portfolio.dart';
import 'package:finflick/ticks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Tick _tick(String sym, double price, double prev) => Tick.fromJson({
      'symbol': sym,
      'kind': 'equity',
      'name': sym,
      'price': price,
      'prev_close': prev,
      'change_pct': (price / prev - 1) * 100,
      'currency': 'INR',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });

final _trades = [
  Trade(id: 1, symbol: 'TCS', side: 'buy', qty: 10, price: 3900, tradedOn: DateTime(2026, 6, 1)),
  Trade(id: 2, symbol: 'TCS', side: 'sell', qty: 4, price: 4100, tradedOn: DateTime(2026, 7, 1)),
  Trade(id: 3, symbol: 'INFY', side: 'buy', qty: 20, price: 1500, tradedOn: DateTime(2026, 6, 15)),
];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ticks.value = {};
  });

  // Every section on one tall canvas: the body is a lazy ListView, so HEALTH
  // and TRADES would otherwise never be built at the default 800×600.
  Future<void> tall(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('summary tiles, holdings rows, realised and XIRR from injected trades + ticks',
      (tester) async {
    await tall(tester);
    mergeTicks([_tick('TCS', 4000, 3950), _tick('INFY', 1600, 1620)]);
    await tester.pumpWidget(MaterialApp(
        home: PortfolioScreen(initialTrades: _trades, initialFacts: const {
      'TCS': {'sector': 'IT', 'pe': 25.0, 'trend': 'bullish', 'de': 0.1},
      'INFY': {'sector': 'IT', 'pe': 22.0, 'trend': 'bearish', 'de': 3.0, 'lo52': 1580.0},
    })));
    await tester.pump();
    // invested: 6×3900 + 20×1500 = 53,400 · current: 6×4000 + 20×1600 = 56,000
    expect(find.text('₹53,400'), findsOneWidget);
    expect(find.text('₹56,000'), findsOneWidget);
    expect(find.text('+2,600'), findsOneWidget); // overall
    expect(find.text('+800'), findsOneWidget); // realised 4 × (4100 − 3900)
    expect(find.text('XIRR'), findsOneWidget);
    expect(find.textContaining('annualised'), findsOneWidget);
    // holdings rows + health flags (D/E > 2, near 52w low) on INFY only
    expect(find.text('TCS'), findsWidgets);
    expect(find.text('D/E 3.0'), findsOneWidget);
    expect(find.text('near 52w low'), findsOneWidget);
    expect(find.text('TREND UP'), findsOneWidget);
    // trades table shows every lot, newest first
    expect(find.text('SELL'), findsOneWidget);
  });

  testWidgets('empty portfolio shows the two doors; unpriced holdings say so', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PortfolioScreen(initialTrades: [], initialFacts: {})));
    await tester.pump();
    expect(find.textContaining('No holdings yet'), findsOneWidget);

    // A new key: otherwise Flutter reuses the first screen's State (and its
    // empty trades) for the second pump.
    await tester.pumpWidget(MaterialApp(
        home: PortfolioScreen(key: const ValueKey(2), initialTrades: _trades, initialFacts: const {})));
    await tester.pump();
    expect(find.text('2 awaiting quotes'), findsOneWidget);
  });

  testWidgets('PortfolioSummary strip renders four tiles from injected trades', (tester) async {
    mergeTicks([_tick('TCS', 4000, 3950), _tick('INFY', 1600, 1620)]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ListView(children: [PortfolioSummary(initialTrades: _trades)]))));
    await tester.pump();
    expect(find.text('PORTFOLIO'), findsOneWidget);
    expect(find.text('OPEN'), findsOneWidget);
    expect(find.text('INVESTED'), findsOneWidget);
    expect(find.text('₹56,000'), findsOneWidget);
  });
}
