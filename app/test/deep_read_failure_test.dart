// Network failure and AI refusal are different states: a failed deepread
// fetch must offer a retry, never the refusal copy ("Full story unavailable"),
// and the retry storm (_onScroll re-firing _ensureRead per pixel) must stay
// dead: one failure = one error page until the button is pressed.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryPager;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('failed deep read shows Try again, not the refusal copy',
      (tester) async {
    // Supabase is uninitialized in tests, so _ensureRead's invoke throws —
    // exactly the failure path under test.
    final story = Story.fromJson({
      'id': 1,
      'headline': 'RBI holds',
      'hook': 'Hook',
      'summary': 'Short.',
      'sectors': const [],
    });
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: Scaffold(body: StoryPager(story: story)))));
    await tester.fling(find.text('Hook'), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining("Couldn't load"), findsOneWidget);
    expect(find.textContaining('unavailable'), findsNothing);
  });

  testWidgets('prefetch fails silently; the open retries once, then shows it',
      (tester) async {
    final story = Story.fromJson({
      'id': 2,
      'headline': 'RBI holds',
      'hook': 'Hook',
      'summary': 'Short.',
      'sectors': const [],
    });
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: Scaffold(body: StoryPager(story: story)))));
    // The 2s dwell prefetch fires and (Supabase uninitialized) fails — the
    // card must stay pristine: no error page pre-baked behind it.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Hook'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);

    // Opening retries once silently; it fails again, and only now does the
    // honest error page show.
    await tester.fling(find.text('Hook'), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
  });
}
