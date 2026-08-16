import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryCard, StoryPager;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Story _s(int id) => Story.fromJson({
      'id': id,
      'headline': 'RBI holds repo rate',
      'hook': 'RBI stands still',
      'summary': 'Rates unchanged.',
      'impact_score': 7,
      'source_name': 'RBI Press',
      'source_url': 'https://rbi.org.in/x',
      'sectors': const [],
    });

/// The real tree: Column > Expanded > RefreshIndicator > PageView >
/// StoryPager (deep-read wrapper) > card. Nesting StoryPager here is what
/// actually exercises the gesture pass-through the feed relies on — a bare
/// StoryCard would pass even if StoryPager swallowed the gestures.
Widget _app() => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {},
                child: PageView.builder(
                  scrollDirection: Axis.vertical,
                  itemCount: 3,
                  itemBuilder: (_, i) => StoryPager(story: _s(i)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );

void main() {
  testWidgets('share palette opens inside the real feed tree', (tester) async {
    await tester.pumpWidget(_app());
    final g = await tester.startGesture(
        tester.getCenter(find.byType(StoryCard).first));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('WhatsApp'), findsOneWidget);
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('bookmark ribbon opens inside the real feed tree', (tester) async {
    await tester.pumpWidget(_app());
    final g = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.bookmark_border_rounded).first));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.bookmarks_rounded), findsOneWidget);
    expect(find.text('WhatsApp'), findsNothing);
    await g.up();
    await tester.pumpAndSettle();
  });
}
