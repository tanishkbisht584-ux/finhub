import 'package:finswipe/fundamentals.dart';
import 'package:finswipe/screens/stock_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> row(String kind, String period, Map<String, dynamic> data) =>
    {'symbol': 'TCS', 'kind': kind, 'period': period, 'data': data};

void main() {
  group('FundamentalsData.fromRows', () {
    test('groups by kind and sorts periods ascending', () {
      final d = FundamentalsData.fromRows([
        row('annual', 'FY2026', {'sales': 1000}),
        row('annual', 'FY2016', {'sales': 300}),
        row('quarter', '2026-06', {'sales': 280}),
        row('quarter', '2025-09', {'sales': 240}),
        row('shareholding', '2026-06', {'promoters': 50.1}),
        row('summary', 'latest', {'pros': ['a'], 'cons': []}),
        row('docs', 'latest', {'announcements': []}),
      ]);
      expect(d.annual.keys.toList(), ['FY2016', 'FY2026']);
      expect(d.quarter.keys.toList(), ['2025-09', '2026-06']);
      expect(d.shareholding.keys.toList(), ['2026-06']);
      expect(d.summary['pros'], ['a']);
      expect(d.docs['announcements'], isEmpty);
      expect(d.isEmpty, isFalse);
    });

    test('empty rows -> isEmpty, safe accessors', () {
      final d = FundamentalsData.fromRows(const []);
      expect(d.isEmpty, isTrue);
      expect(d.annual, isEmpty);
      expect(d.summary, isEmpty);
    });
  });

  group('formatting', () {
    test('period labels', () {
      expect(periodLabel('FY2024'), 'FY24');
      expect(periodLabel('2026-06'), 'Jun 26');
      expect(periodLabel('latest'), 'latest');
    });

    test('cells: crores grouped, percents, dashes for null', () {
      expect(fmtCell(142290, CellFmt.cr), '1,42,290');
      expect(fmtCell(15.0, CellFmt.pct), '15%');
      expect(fmtCell(15.5, CellFmt.pct), '15.5%');
      expect(fmtCell(59.69, CellFmt.num2), '59.69');
      expect(fmtCell(null, CellFmt.cr), '—');
    });
  });

  group('StatementTable', () {
    final byPeriod = {
      'FY2025': {'sales': 800, 'opm': 18.8},
      'FY2026': {'sales': 1000, 'opm': 20.0},
    };
    const rows = [
      ('Sales', 'sales', CellFmt.cr),
      ('OPM %', 'opm', CellFmt.pct),
      ('CWIP', 'cwip', CellFmt.cr), // absent everywhere -> hidden
    ];

    testWidgets('renders labels, values, and period headers', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: StatementTable(
                  periods: const ['FY2025', 'FY2026'],
                  rows: rows,
                  byPeriod: byPeriod))));
      expect(find.text('Sales'), findsOneWidget);
      expect(find.text('1,000'), findsOneWidget);
      expect(find.text('20%'), findsOneWidget);
      expect(find.text('FY25'), findsOneWidget);
      expect(find.text('FY26'), findsOneWidget);
    });

    testWidgets('hides rows that are null in every period', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: StatementTable(
                  periods: const ['FY2025', 'FY2026'],
                  rows: rows,
                  byPeriod: byPeriod))));
      expect(find.text('CWIP'), findsNothing);
    });
  });

  group('CagrStrip', () {
    testWidgets('renders 10y/5y/3y/TTM cells from a summary block', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CagrStrip('Compounded Sales Growth',
                  const {'y10': 15.0, 'y5': 18.0, 'y3': 6.0, 'ttm': 15.0}))));
      expect(find.text('Compounded Sales Growth'), findsOneWidget);
      expect(find.text('10Y'), findsOneWidget);
      expect(find.text('18%'), findsOneWidget);
      expect(find.text('TTM'), findsOneWidget);
    });
  });
}
