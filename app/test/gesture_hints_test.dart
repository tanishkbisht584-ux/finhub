import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/screens/feed.dart' show GestureHints;

void main() {
  testWidgets('coach marks list the hidden gestures and dismiss on tap',
      (tester) async {
    var dismissed = false;
    await tester.pumpWidget(MaterialApp(
        home: Stack(children: [
      GestureHints(onDismiss: () => dismissed = true),
    ])));

    expect(find.text('THE MOVES'), findsOneWidget);
    expect(find.textContaining('swipe left'), findsOneWidget);
    expect(find.textContaining('double-tap'), findsOneWidget);
    expect(find.textContaining('hold the bookmark'), findsOneWidget);
    expect(find.textContaining('IMPACT'), findsOneWidget);
    expect(find.text('GOT IT'), findsOneWidget);

    await tester.tap(find.text('GOT IT'));
    expect(dismissed, isTrue);
  });
}
