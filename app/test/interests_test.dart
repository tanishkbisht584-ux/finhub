import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/screens/interests.dart';

void main() {
  test('categories match the pipeline enum exactly', () {
    expect(kCategories, [
      'Markets', 'Economy', 'IPO', 'Global',
      'Commodities', 'Corporate', 'Policy', 'Geopolitics',
    ]);
  });

  testWidgets('Continue stays disabled until three picks', (tester) async {
    await tester.pumpWidget(MaterialApp(home: InterestsScreen(onDone: () {})));
    final button = () => tester
        .widget<FilledButton>(find.byType(FilledButton));
    expect(button().onPressed, isNull);
    for (final c in ['Markets', 'Economy', 'IPO']) {
      await tester.tap(find.text(c));
      await tester.pump();
    }
    expect(button().onPressed, isNotNull);
  });
}
