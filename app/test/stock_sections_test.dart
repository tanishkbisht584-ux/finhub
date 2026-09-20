import 'package:finswipe/screens/stock_sections.dart';
import 'package:finswipe/fundamentals.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('withOthers adds the remainder only for quarters with the split', () {
    final sh = withOthers({
      '2025-06': {'promoters': 71.77, 'public': 28.23},
      '2026-06': {'promoters': 71.77, 'fiis': 9.06, 'diis': 13.47, 'govt': 0.0, 'public': 5.69, 'employee_trusts': 0.0},
      '2026-03': {'promoters': 50.0, 'fiis': 20.0, 'diis': 29.5, 'public': 0.0},
    });
    expect(sh['2025-06']!.containsKey('others'), isFalse); // master-only quarter
    expect(sh['2026-06']!.containsKey('others'), isFalse); // 99.99: under the 0.05 floor
    expect(sh['2026-03']!['others'], 0.5);
  });

  testWidgets('StatementTable hides rows that are null or zero in every period', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatementTable(periods: const ['2026-03', '2026-06'], rows: const [
      ('Promoters %', 'promoters', CellFmt.pct),
      ('Employee Trusts %', 'employee_trusts', CellFmt.pct),
      ('Government %', 'govt', CellFmt.pct),
    ], byPeriod: {
      '2026-03': {'promoters': 71.77, 'employee_trusts': 0.0},
      '2026-06': {'promoters': 71.77, 'employee_trusts': 0.0, 'govt': null},
    }))));
    expect(find.text('Promoters %'), findsOneWidget);
    expect(find.text('Employee Trusts %'), findsNothing);
    expect(find.text('Government %'), findsNothing);
  });
}
