import 'package:finswipe/screens/screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('presets are well-formed and reference known metric columns', () {
    final cols = {for (final m in metricDefs) m.col};
    expect(screenPresets.length, 6);
    for (final p in screenPresets) {
      expect(p.filters, isNotEmpty);
      expect(cols.contains(p.sortCol), isTrue, reason: p.name);
      for (final f in p.filters) {
        expect(cols.contains(f.metric), isTrue, reason: '${p.name}:${f.metric}');
      }
    }
    final value = screenPresets.firstWhere((p) => p.name == 'VALUE');
    expect(value.filters,
        contains((metric: 'pe', gte: false, value: 15.0)));
    expect(value.sortCol, 'pe');
    expect(value.asc, isTrue);
    // DEBT-FREE SMALLCAP needs two bounds on mcap_cr — filters must be a list
    final small = screenPresets.firstWhere((p) => p.name == 'DEBT-FREE SMALLCAP');
    expect(small.filters.where((f) => f.metric == 'mcap_cr').length, 2);
  });

  test('filterLabel renders operator and trims trailing zeros', () {
    expect(filterLabel((metric: 'pe', gte: false, value: 15.0)), 'PE ≤ 15');
    expect(filterLabel((metric: 'roe', gte: true, value: 17.5)), 'ROE ≥ 17.5%');
    expect(filterLabel((metric: 'mcap_cr', gte: true, value: 500.0)),
        'MCAP ≥ 500 CR');
  });

  test('metricText formats per column type', () {
    expect(metricText('pe', 14.234), 'PE 14.2');
    expect(metricText('roe', 22.0), 'ROE 22%');
    expect(metricText('mcap_cr', 2800.0), 'MCAP 2,800 CR');
    expect(metricText('pe', null), '');
  });

  group('ScreensBody', () {
    final rows = [
      {'symbol': 'TCS', 'name': 'TCS Ltd', 'price': 2302.0, 'pe': 14.2, 'roe': 22.0},
      {'symbol': 'INFY', 'name': 'Infosys Ltd', 'price': 1400.0, 'pe': 18.0, 'roe': 25.0},
    ];
    const filters = [(metric: 'pe', gte: false, value: 15.0)];

    testWidgets('renders rows with symbol, name, and metric trail', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ScreensBody(rows,
                  filters: filters, sortCol: 'pe', onRemoveFilter: (_) {}))));
      expect(find.text('TCS Ltd'), findsOneWidget);
      expect(find.text('TCS'), findsOneWidget);
      expect(find.textContaining('PE 14.2'), findsOneWidget);
      expect(find.textContaining('2 matches'), findsOneWidget);
    });

    testWidgets('active filter pill removes on tap', (t) async {
      ScreenFilter? removed;
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ScreensBody(rows,
                  filters: filters,
                  sortCol: 'pe',
                  onRemoveFilter: (f) => removed = f))));
      await t.tap(find.text('PE ≤ 15'));
      await t.pump();
      expect(removed, filters.first);
    });

    testWidgets('empty rows show the loosen-a-filter copy', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ScreensBody(const [],
                  filters: filters, sortCol: 'pe', onRemoveFilter: (_) {}))));
      expect(find.textContaining('No matches'), findsOneWidget);
    });
  });
}
