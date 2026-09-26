import 'package:finflick/screens/stock_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('033 recordRows: ATH/ATL/52w rows from the screener row', (t) async {
    final rows = recordRows({
      'sa': {'allTimeHigh': 1611.8, 'allTimeHighDate': '2026-01-05', 'allTimeLow': 21.5,
             'allTimeLowDate': '2009-03-09', 'high52Date': '2026-01-05', 'low52Date': '2025-11-03'},
      'ath_pct': -21.9, 'from_atl_pct': 5700.0, 'hi52': 1611.8, 'lo52': 1115.0,
      'days_since_hi52': 264, 'days_since_lo52': 327,
    });
    expect(rows.length, 4);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: rows))));
    expect(find.textContaining('all-time high'), findsOneWidget);
    expect(find.textContaining('21.9% below it'), findsOneWidget);
    expect(find.textContaining('264 d ago'), findsOneWidget);
    expect(recordRows(const {}), isEmpty);
  });
}
