// 037: concall cards and the backtest block render from fixtures; the
// fundamentals loader routes kind=concall rows and drops no_text stubs.
import 'package:finflick/fundamentals.dart';
import 'package:finflick/screens/screens.dart';
import 'package:finflick/screens/stock_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FundamentalsData keeps summarised concalls only, newest last', () {
    final d = FundamentalsData.fromRows([
      {'kind': 'concall', 'period': '2026-04-17', 'data': {'summary': 'Q4 fine', 'sentiment': 'cautious'}},
      {'kind': 'concall', 'period': '2026-07-17', 'data': {'summary': 'Q1 strong', 'sentiment': 'confident'}},
      {'kind': 'concall', 'period': '2026-01-17', 'data': {'note': 'no_text'}},
      {'kind': 'docs', 'period': 'latest', 'data': {'concalls': []}},
    ]);
    expect(d.concalls.keys.toList(), ['2026-04-17', '2026-07-17']);
    expect(d.concalls['2026-07-17']!['sentiment'], 'confident');
    expect(d.hasDocsRow, isTrue);
  });

  testWidgets('ConcallSection shows summary, bullets, sentiment and the PDF pill', (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: ConcallSection({
      '2026-07-17': {
        'subject': 'Q1 FY27 earnings call transcript',
        'url': 'https://x/t.pdf',
        'summary': 'Volumes grew double digits; margins held.',
        'guidance': ['capex ₹5,000 Cr in FY27'],
        'risks': ['input cost inflation'],
        'qa_highlights': ['Q: pricing? A: pass-through in Q2'],
        'sentiment': 'confident',
      },
    })))));
    expect(find.textContaining('Volumes grew'), findsOneWidget);
    expect(find.text('· capex ₹5,000 Cr in FY27'), findsOneWidget);
    expect(find.text('CONFIDENT'), findsOneWidget);
    expect(find.text('OPEN TRANSCRIPT'), findsOneWidget);
  });

  testWidgets('BacktestSection renders the stats from a result', (t) async {
    final dates = [for (var i = 0; i < 37; i++) '2023-${(i % 12 + 1).toString().padLeft(2, '0')}-01'];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: BacktestSection({
      'curve': [for (var i = 0; i < 37; i++) 100.0 + i * 2],
      'nifty': [for (var i = 0; i < 37; i++) 100.0 + i],
      'dates': dates,
      'cagr': 21.3,
      'nifty_cagr': 11.2,
      'mdd': -8.1,
      'nifty_mdd': -12.4,
      'hit_rate': 61,
      'n': 20,
      'from': '2023-10-03',
      'to': '2026-09-25',
      'symbols': ['TCS', 'INFY'],
      'computed_at': '2026-09-27T17:30:00Z',
    }, name: 'VALUE')))));
    expect(find.byType(BacktestSection), findsOneWidget);
    expect(find.text('+21.3%'), findsOneWidget);
    expect(find.text('61%'), findsOneWidget);
    expect(find.text('TCS · INFY'), findsOneWidget);
    expect(find.textContaining('survivorship'), findsOneWidget);
  });
}
