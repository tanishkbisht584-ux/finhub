// Tapping an alert must land you *in* the feed on that card, so the next
// swipe carries on into the rest of the news. The jump is the logic; the
// PageView tree around it is the same one FeedScreen builds.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryCard, jumpToStory;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Story _s(int id) => Story.fromJson({
      'id': id,
      'headline': 'Headline $id',
      'hook': 'Hook $id',
      'summary': 'Summary.',
      'impact_score': 7,
      'source_name': 'RBI Press',
      'source_url': 'https://rbi.org.in/x',
      'sectors': const [],
    });

Widget _feed(PageController pc, List<Story> list) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: PageView.builder(
            controller: pc,
            scrollDirection: Axis.vertical,
            itemCount: list.length,
            itemBuilder: (_, i) => StoryCard(story: list[i]),
          ),
        ),
      ),
    );

void main() {
  final list = [_s(10), _s(11), _s(12)];

  testWidgets('lands on the alerted story, not the top of the feed',
      (tester) async {
    final pc = PageController();
    await tester.pumpWidget(_feed(pc, list));
    expect(find.text('Hook 10'), findsOneWidget);

    expect(jumpToStory(pc, list, 12), isTrue);
    await tester.pumpAndSettle();

    expect(find.text('Hook 12'), findsOneWidget);
    expect(find.text('Hook 10'), findsNothing);
  });

  testWidgets('reports a miss when the story is not in the loaded feed',
      (tester) async {
    // Aged past the 48h window or unapproved since the alert: FeedScreen falls
    // back to the standalone detail screen instead of a wrong card.
    final pc = PageController();
    await tester.pumpWidget(_feed(pc, list));
    expect(jumpToStory(pc, list, 999), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('Hook 10'), findsOneWidget);
  });
}
