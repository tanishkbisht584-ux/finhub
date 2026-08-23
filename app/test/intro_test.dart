import 'package:finswipe/intro.dart';
import 'package:finswipe/screens/sign_in.dart';
import 'package:finswipe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Explicit pump(duration) throughout — never pumpAndSettle around a running
// animation (see outlets_test.dart).
Widget _app({VoidCallback? onDone, Widget child = const Text('dest')}) =>
    MaterialApp(
        theme: appTheme, home: SwipeIntro(onDone: onDone, child: child));

final _finger = find.byKey(const ValueKey('intro-finger'));

void main() {
  testWidgets('destination slides up under the finger, then overlay leaves',
      (tester) async {
    var done = false;
    await tester.pumpWidget(_app(onDone: () => done = true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_finger, findsOneWidget);
    final early = tester.getTopLeft(find.text('dest')).dy;
    expect(early, greaterThan(100)); // still mostly below the fold
    await tester.pump(const Duration(milliseconds: 900));
    final late_ = tester.getTopLeft(find.text('dest')).dy;
    expect(late_, lessThan(early)); // riding up with the swipe
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(done, isTrue);
    expect(_finger, findsNothing); // overlay fully gone, bare child remains
    expect(tester.getTopLeft(find.text('dest')).dy, 0);
  });

  testWidgets('a tap skips straight to the destination', (tester) async {
    var done = false;
    await tester.pumpWidget(_app(onDone: () => done = true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(SwipeIntro));
    await tester.pump();
    expect(done, isTrue);
    expect(_finger, findsNothing);
    expect(tester.getTopLeft(find.text('dest')).dy, 0);
  });

  testWidgets('the real sign-in screen renders inside the intro',
      (tester) async {
    await tester.pumpWidget(_app(child: const SignInScreen()));
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(find.text('FinSwipe'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
  });
}
