import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryCard;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Story _s() => Story.fromJson({
      'id': 7,
      'headline': 'RBI holds repo rate',
      'hook': 'RBI stands still',
      'summary': 'Rates unchanged.',
      'impact_score': 7,
      'source_name': 'RBI Press',
      'source_url': 'https://rbi.org.in/x',
      'sectors': const [],
    });

void main() {
  testWidgets('holding the card raises the share palette', (tester) async {
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: Scaffold(body: StoryCard(story: _s())))));

    final gesture = await tester.startGesture(
        tester.getCenter(find.byType(StoryCard)));
    await tester.pump(const Duration(milliseconds: 700)); // past long-press
    await tester.pump(const Duration(milliseconds: 300)); // palette animation

    expect(find.text('WhatsApp'), findsOneWidget,
        reason: 'palette should be on screen while the card is held');
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('holding inside the feed still raises it — a thumb wobbles',
      (tester) async {
    // The real screen: the card lives in a vertical PageView. A finger that
    // drifts a few pixels before the press registers used to hand the gesture
    // to the scroll view, and the palette never appeared.
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: PageView(
            scrollDirection: Axis.vertical,
            children: [StoryCard(story: _s())],
          ),
        ),
      ),
    ));

    final start = tester.getCenter(find.byType(StoryCard));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveTo(start + const Offset(0, 22)); // thumb drift
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('WhatsApp'), findsOneWidget,
        reason: 'a small drift must not cancel the hold');
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('holding the bookmark opens the saved ribbon, not the palette',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: Scaffold(body: StoryCard(story: _s())))));

    final g = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.bookmark_border_rounded)));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byIcon(Icons.bookmarks_rounded), findsOneWidget,
        reason: 'the saved-articles ribbon should be on screen');
    expect(find.text('WhatsApp'), findsNothing,
        reason: 'the share palette must not hijack the bookmark hold');
    await g.up();
    await tester.pumpAndSettle();
  });
}
