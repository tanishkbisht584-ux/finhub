import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryPager;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Story _s(int id, {required String summary}) => Story.fromJson({
      'id': id,
      'headline': 'Headline $id',
      'hook': 'Hook $id',
      'summary': summary,
      'impact_score': 7,
      'source_name': 'RBI Press',
      'source_url': 'https://rbi.org.in/x',
      'sectors': const [],
    });

Widget _app(String summary) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: PageView.builder(
            scrollDirection: Axis.vertical,
            itemCount: 3,
            itemBuilder: (_, i) => StoryPager(story: _s(i, summary: summary)),
          ),
        ),
      ),
    );

void main() {
  testWidgets('drag on a short summary advances to the next story',
      (tester) async {
    await tester.pumpWidget(_app('Rates unchanged.'));
    await tester.pump(); // post-frame overflow measurement
    await tester.pump();
    expect(find.text('Hook 0'), findsOneWidget);
    // Drag upward starting on the summary text — the largest tap region of
    // the card. Pre-fix the inner scroll view ate this and nothing moved.
    await tester.fling(
        find.text('Rates unchanged.').first, const Offset(0, -400), 1200);
    await tester.pumpAndSettle();
    expect(find.text('Hook 1'), findsOneWidget);
    expect(find.text('Hook 0'), findsNothing);
  });

  testWidgets('a long summary scrolls in place instead of changing story',
      (tester) async {
    final long = List.generate(60, (i) => 'Line $i of a very long summary.')
        .join(' ');
    await tester.pumpWidget(_app(long));
    await tester.pump();
    await tester.pump(); // second frame applies the measured overflow
    await tester.drag(
        find.textContaining('Line 1 of').first, const Offset(0, -300));
    await tester.pumpAndSettle();
    // Still on story 0 — the summary consumed the drag.
    expect(find.text('Hook 0'), findsOneWidget);
    expect(find.text('Hook 1'), findsNothing);
  });
}
