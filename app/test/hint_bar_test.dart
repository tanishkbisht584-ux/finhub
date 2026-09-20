import 'package:finflick/ledger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('HintBar shows once, GOT IT hides it and remembers', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: HintBar('t_hints', [('swipe', 'does a thing')]))));
    await tester.pumpAndSettle();
    expect(find.text('HOW TO READ THIS'), findsOneWidget);
    expect(find.textContaining('swipe'), findsOneWidget);
    await tester.tap(find.text('GOT IT'));
    await tester.pumpAndSettle();
    expect(find.text('HOW TO READ THIS'), findsNothing);
    expect((await SharedPreferences.getInstance()).getBool('t_hints'), isTrue);
  });

  testWidgets('HintBar stays hidden once dismissed', (tester) async {
    SharedPreferences.setMockInitialValues({'t_hints': true});
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: HintBar('t_hints', [('swipe', 'does a thing')]))));
    await tester.pumpAndSettle();
    expect(find.text('HOW TO READ THIS'), findsNothing);
  });
}
