// Tapping an alert must land you *in* the feed on that card, so the next
// swipe carries on into the rest of the news. The jump is the logic; the
// PageView tree around it is the same one FeedScreen builds.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart'
    show StoryCard, feedEntries, jumpToStory;
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

    expect(jumpToStory(pc, feedEntries(list, null, false), 12), isTrue);
    await tester.pumpAndSettle();

    expect(find.text('Hook 12'), findsOneWidget);
    expect(find.text('Hook 10'), findsNothing);
  });

  test('a caught-up divider shifts the landing index past itself', () {
    // Stories 10-11 are new, 12 is old: the divider sits at page 2, so story
    // 12 lives at page 3 — jumpToStory must index entries, not stories.
    DateTime t(int h) => DateTime.utc(2026, 8, 26, h);
    Story at(int id, DateTime p) => Story.fromJson({
          'id': id,
          'headline': 'Headline $id',
          'hook': 'Hook $id',
          'summary': 'Summary.',
          'sectors': const [],
          'published_at': p.toIso8601String(),
        });
    final list2 = [at(10, t(12)), at(11, t(11)), at(12, t(8))];
    final entries = feedEntries(list2, t(10), false);
    expect(entries.indexWhere((e) => e.story?.id == 12), 3);
  });

  testWidgets('reports a miss when the story is not in the loaded feed',
      (tester) async {
    // Aged past the 48h window or unapproved since the alert: FeedScreen falls
    // back to the standalone detail screen instead of a wrong card.
    final pc = PageController();
    await tester.pumpWidget(_feed(pc, list));
    expect(jumpToStory(pc, feedEntries(list, null, false), 999), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('Hook 10'), findsOneWidget);
  });
}
