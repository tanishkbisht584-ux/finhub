import 'package:finswipe/fundamentals.dart';
import 'package:finswipe/heat.dart';
import 'package:finswipe/ledger.dart';
import 'package:finswipe/theme.dart';
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

    testWidgets('heat tints cells by change vs the previous period', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: StatementTable(
                  periods: const ['FY2025', 'FY2026'],
                  rows: rows,
                  byPeriod: byPeriod,
                  heat: true))));
      Color? bg(String text) =>
          (t.widget<Container>(find.ancestor(
                      of: find.text(text), matching: find.byType(Container)).first)
                  .decoration as BoxDecoration?)
              ?.color;
      expect(bg('800'), isNull); // first period has nothing to compare
      expect(bg('1,000'), deltaHeat(1000, 800, scale: 20)); // +25% -> deep green
      expect(bg('20%'), deltaHeat(20.0, 18.8, scale: 3, points: true)); // +1.2 pts
    });
  });

  group('KvTable', () {
    testWidgets('renders headers, rows, and tones the read cell', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: KvTable(const ['METRIC', 'VALUE', 'SECTOR', 'READ'], const [
        (metric: 'ROE', value: '47.7%', third: '15.0%', read: 'above peers', tone: 1),
        (metric: 'D/E', value: '1.20', third: '0.50', read: 'heavier', tone: -1),
        (metric: 'Rev growth', value: '+13.9%', third: '—', read: 'YoY', tone: 1),
      ]))));
      expect(find.text('METRIC'), findsOneWidget);
      expect(find.text('47.7%'), findsOneWidget);
      expect(find.text('15.0%'), findsOneWidget);
      expect(t.widget<Text>(find.text('above peers')).style!.color, green);
      expect(t.widget<Text>(find.text('heavier')).style!.color, red);
      expect(t.widget<Text>(find.text('+13.9%')).style!.color, green);
    });
  });

  group('growthGrid', () {
    testWidgets('one heat cell per horizon, dash for gaps', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: growthGrid(const {
        'sales': {'y10': 15.0, 'y5': 18.0, 'y3': 6.0, 'ttm': 15.0},
        'roe': {'y10': 9.0, 'y5': 8.0, 'y3': 9.0},
      }))));
      expect(find.text('10Y'), findsOneWidget);
      expect(find.text('Sales'), findsOneWidget);
      expect(find.text('ROE'), findsOneWidget);
      expect(find.text('Profit'), findsNothing); // absent block hidden
      expect(find.text('18%'), findsOneWidget);
      expect(find.text('—'), findsOneWidget); // ROE ttm missing
      expect(find.byType(HeatCell), findsNWidgets(8));
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
    Map<String, dynamic> row(String sym, double price, num mcap, num? pe) => {
          'symbol': sym, 'name': '$sym Ltd', 'price': price,
          'mcap_cr': mcap, 'pe': pe, 'roe': 12.0,
        };

    testWidgets('self pinned on top, others by market cap, capped at 10',
        (t) async {
      final peers = [
        for (var i = 0; i < 12; i++) row('P$i', 100.0 + i, 1000 - i, 20),
        row('SELF', 50, 99999, 5),
      ];
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: PeersTable(peers, self: 'SELF'))));
      expect(find.text('SELF Ltd'), findsOneWidget);
      expect(find.text('P0 Ltd'), findsOneWidget); // biggest mcap first
      expect(find.text('P11 Ltd'), findsNothing); // 11th largest cut
      expect(t.getRect(find.text('SELF Ltd')).top,
          lessThan(t.getRect(find.text('P0 Ltd')).top));
      expect(find.text('COMPANY'), findsOneWidget);
      expect(find.text('P/E'), findsOneWidget);
    });

    testWidgets('no other peers -> nothing', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: PeersTable([row('SELF', 1, 1, 1)], self: 'SELF'))));
      expect(find.text('SELF Ltd'), findsNothing);
    });
  });
}
