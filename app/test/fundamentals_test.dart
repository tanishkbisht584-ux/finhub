import 'package:finswipe/fundamentals.dart';
import 'package:finswipe/models.dart';
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

  group('peSeries', () {
    final quarters = {
      '2025-06': {'eps': 8.0},
      '2025-09': {'eps': 10.0},
      '2025-12': {'eps': 10.0},
      '2026-03': {'eps': 10.0},
      '2026-06': {'eps': 12.0},
    };

    test('price over TTM eps as a step function on quarter ends', () {
      final pe = peSeries(
          [400, 420],
          [DateTime(2026, 5, 1), DateTime(2026, 8, 1)],
          quarters);
      // May: TTM = 8+10+10+10 = 38 · Aug: 10+10+10+12 = 42
      expect(pe[0], closeTo(400 / 38, 0.01));
      expect(pe[1], closeTo(420 / 42, 0.01));
    });

    test('null until four quarters exist before t', () {
      final pe = peSeries(
          [100, 100],
          [DateTime(2025, 8, 1), DateTime(2026, 8, 1)],
          quarters);
      expect(pe[0], isNull); // only 2025-06 ended by Aug 2025
      expect(pe[1], isNotNull);
    });

    test('negative TTM eps gives null, empty inputs give empty', () {
      final loss = {
        for (final e in quarters.entries) e.key: {'eps': -1.0}
      };
      expect(peSeries([100], [DateTime(2026, 8, 1)], loss), [null]);
      expect(peSeries([], [], quarters), isEmpty);
    });
  });

  group('DocsSection', () {
    testWidgets('renders report years and announcement subjects', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: DocsSection(const {
        'annual_reports': [
          {'fy': '2026', 'url': 'https://x/ar26.pdf'},
        ],
        'announcements': [
          {'date': '28-Aug-2026 18:05:00', 'subject': 'Board Meeting', 'url': 'https://x/a.pdf'},
        ],
      }))));
      expect(find.text('FY2026'), findsOneWidget);
      expect(find.text('Board Meeting'), findsOneWidget);
      expect(find.textContaining('28-Aug-2026'), findsOneWidget);
    });

    testWidgets('empty docs renders nothing', (t) async {
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: DocsSection({}))));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('renders concalls and credit ratings blocks', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: DocsSection(const {
        'concalls': [
          {'date': '25-Jul-2026', 'subject': 'Transcript of Earnings Call', 'url': 'u1'},
        ],
        'credit_ratings': [
          {'agency': 'CRISIL', 'rating': 'AAA/Stable', 'date': '03-Jul-2026', 'url': 'u2'},
        ],
      })))));
      expect(find.text('CONCALLS'), findsOneWidget);
      expect(find.text('Transcript of Earnings Call'), findsOneWidget);
      expect(find.text('CREDIT RATINGS'), findsOneWidget);
      expect(find.textContaining('CRISIL'), findsOneWidget);
      expect(find.textContaining('AAA/Stable'), findsOneWidget);
    });
  });

  group('PeersTable', () {
    Tick tick(String sym, double price, num mcap, num? pe) => Tick.fromJson({
          'symbol': sym, 'kind': 'equity', 'name': '$sym Ltd', 'price': price,
          'meta': {'f': {'mcap': mcap, if (pe != null) 'pe': pe, 'roe': 12.0}},
        });

    testWidgets('sorts by market cap, excludes self, caps at 10', (t) async {
      final peers = [
        for (var i = 0; i < 12; i++) tick('P$i', 100.0 + i, 1000 - i, 20),
        tick('SELF', 50, 99999, 5),
      ];
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: PeersTable(peers, self: 'SELF'))));
      expect(find.text('SELF Ltd'), findsNothing);
      expect(find.text('P0 Ltd'), findsOneWidget); // biggest mcap first
      expect(find.text('P11 Ltd'), findsNothing); // 11th largest cut
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
