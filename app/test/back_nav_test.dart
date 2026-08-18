// Android back two pages into a deep read must return to the story card,
// not pop the root route (i.e. exit the app).
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryPager;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('system back inside a deep read returns to the card',
      (tester) async {
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
    expect(find.text('Hook'), findsNothing); // we're on the deep page

    // The system back button.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Hook'), findsOneWidget); // back on the card
  });

  testWidgets('read-more strip turns the page like a left swipe',
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
    await tester.tap(find.text('Read more'));
    // The card's double-tap-save detector holds the arena for the double-tap
    // window; advance past it so the strip's single tap resolves.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Hook'), findsNothing); // off the card, into the read
  });
}
