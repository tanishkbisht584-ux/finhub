import 'package:finflick/screen_query.dart';
import 'package:finflick/screens/screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every metric label and column resolves to itself', () {
    for (final d in metricDefs) {
      expect(resolveMetric(d.col), d.col, reason: d.col);
      expect(resolveMetric(d.label), d.col, reason: d.label);
    }
  });

  test('aliases: Screener.in / MC wording, case and ratio suffix', () {
    expect(resolveMetric('P/E'), 'pe');
    expect(resolveMetric('pe ratio'), 'pe');
    expect(resolveMetric('Debt to equity'), 'de');
    expect(resolveMetric('market cap'), 'mcap_cr');
    expect(resolveMetric('Market Capitalisation'), 'mcap_cr');
    expect(resolveMetric('dividend yield %'), 'div_yield');
    expect(resolveMetric('sales growth 3y'), 'sales_cagr_3y');
    expect(resolveMetric('Promoter holding'), 'promoter_pct');
    expect(resolveMetric('1y return'), 'ret_1y');
    expect(resolveMetric('Altman Z score'), 'altman_z');
    expect(resolveMetric('beta'), 'beta_5y');
    expect(resolveMetric('EV/EBITDA'), 'ev_ebitda');
    expect(resolveMetric('nonsense'), isNull);
  });

  test('parse: operators, AND forms, units, equality', () {
    final p = parseScreenQuery('ROCE > 20 AND Debt to equity < 0.5 and market cap >= 5,000 cr, PE <= 25; ROE ≥ 15%');
    expect(p.error, isNull);
    expect(p.filters, [
      (metric: 'roce', gte: true, value: 20.0),
      (metric: 'de', gte: false, value: 0.5),
      (metric: 'mcap_cr', gte: true, value: 5000.0),
      (metric: 'pe', gte: false, value: 25.0),
      (metric: 'roe', gte: true, value: 15.0),
    ]);
    expect(parseScreenQuery('mcap > 20k').filters.single.value, 20000.0);
    final eq = parseScreenQuery('f score = 9').filters;
    expect(eq.length, 2);
    expect(eq.map((f) => f.gte), [true, false]);
    expect(parseScreenQuery('').filters, isEmpty);
    expect(parseScreenQuery('').error, isNull);
  });

  test('parse errors name the problem', () {
    expect(parseScreenQuery('PE < 15 OR ROE > 20').error, contains('OR'));
    expect(parseScreenQuery('PE < sector pe').error, contains('two metrics'));
    expect(parseScreenQuery('bananas > 3').error, contains('unknown metric'));
    expect(parseScreenQuery('just words').error, contains('could not read'));
  });

  test('filters → text → filters round-trips every preset', () {
    for (final preset in screenPresets) {
      final text = screenQueryText(preset.filters);
      final back = parseScreenQuery(text);
      expect(back.error, isNull, reason: text);
      expect(back.filters, preset.filters, reason: text);
    }
    expect(screenQueryText([(metric: 'pe', gte: false, value: 15.0), (metric: 'roe', gte: true, value: 17.5)]),
        'PE <= 15 AND ROE >= 17.5');
  });

  test('every example parses', () {
    for (final e in screenQueryExamples) {
      expect(parseScreenQuery(e).error, isNull, reason: e);
    }
  });

  testWidgets('ScreensBody shows the formula bar, error line, COPY and show-more', (tester) async {
    var runs = 0, more = 0, copied = 0, deleted = -1;
    final ctl = TextEditingController(text: 'PE <= 15');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ScreensBody(
      const [
        {'symbol': 'TCS', 'name': 'TCS', 'price': 4000.0, 'pe': 24.0, 'mcap_cr': 1450000.0}
      ],
      filters: const [(metric: 'pe', gte: false, value: 15.0)],
      sortCol: 'mcap_cr',
      onRemoveFilter: (_) {},
      queryController: ctl,
      queryError: 'unknown metric "bananas"',
      onRunQuery: () => runs++,
      onCopyQuery: () => copied++,
      onMore: () => more++,
      savedNames: const ['MINE'],
      onLoadSaved: (_) {},
      onDeleteSaved: (i) => deleted = i,
    ))));
    expect(find.text('FORMULA'), findsOneWidget);
    expect(find.textContaining('unknown metric'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    expect(runs, 1);
    await tester.tap(find.text('COPY'));
    expect(copied, 1);
    await tester.tap(find.text('show 50 more'));
    expect(more, 1);
    expect(find.textContaining('so far'), findsOneWidget);
    await tester.longPress(find.text('MINE'));
    expect(deleted, 0);
  });
}
