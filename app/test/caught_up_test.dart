// The caught-up divider: feedEntries decides where (pure), FeedScreen shows
// the page and persists the stamp. The divider must vanish entirely for a
// first install, a nothing-new session, and an everything-new session.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

DateTime _t(int h) => DateTime.utc(2026, 8, 26, h);

Story _s(int id, DateTime? at, {int impact = 7}) => Story.fromJson({
      'id': id,
      'headline': 'Headline $id',
      'hook': 'Hook $id',
      'summary': 'Summary.',
      'impact_score': impact,
      'source_name': 'ET',
      'source_url': 'https://e.co/$id',
      'sectors': const [],
      if (at != null) 'published_at': at.toIso8601String(),
    });

List<int?> _ids(List<FeedEntry> es) => [for (final e in es) e.story?.id];

void main() {
  group('feedEntries', () {
    test('null stamp (first install): stories only, end when exhausted', () {
      final list = [_s(1, _t(12)), _s(2, _t(11))];
      expect(_ids(feedEntries(list, null, false)), [1, 2]);
      final es = feedEntries(list, null, true);
      expect(_ids(es), [1, 2, null]);
      expect(es.last.isEnd, isTrue);
    });

    test('everything new: no divider (no new→old transition)', () {
      final list = [_s(1, _t(12)), _s(2, _t(11))];
      expect(_ids(feedEntries(list, _t(1), false)), [1, 2]);
    });

    test('nothing new: no divider', () {
      final list = [_s(1, _t(12)), _s(2, _t(11))];
      expect(_ids(feedEntries(list, _t(14), false)), [1, 2]);
    });

    test('mid stamp: divider before the first old story, count right', () {
      final list = [_s(1, _t(12)), _s(2, _t(11)), _s(3, _t(8)), _s(4, _t(7))];
      final es = feedEntries(list, _t(10), false);
      expect(_ids(es), [1, 2, null, 3, 4]);
      expect(es[2].newCount, 2);
      expect(es[2].isEnd, isFalse);
    });

    test('old featured pin at the top does not suppress the divider', () {
      // is_featured desc ordering can put an OLD story at index 0 above the
      // new ones; the divider keys on the first new→old transition, not on
      // "first old story".
      final list = [
        _s(9, _t(2)), // pinned featured, old
        _s(1, _t(12)),
        _s(2, _t(11)),
        _s(3, _t(8)),
      ];
      final es = feedEntries(list, _t(10), false);
      expect(_ids(es), [9, 1, 2, null, 3]);
      expect(es[3].newCount, 2);
    });

    test('published_at equal to the stamp counts as already seen', () {
      final list = [_s(1, _t(12)), _s(2, _t(10))];
      // Story 2 is exactly the stamp: old. Divider between 1 and 2, count 1.
      final es = feedEntries(list, _t(10), false);
      expect(_ids(es), [1, null, 2]);
      expect(es[1].newCount, 1);
    });

    test('divider and end page coexist', () {
      final list = [_s(1, _t(12)), _s(2, _t(8))];
      final es = feedEntries(list, _t(10), true);
      expect(_ids(es), [1, null, 2, null]);
      expect(es[1].newCount, 1);
      expect(es.last.isEnd, isTrue);
    });
  });

  group('FeedScreen', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(
          {'feed_last_seen_v1': _t(10).toIso8601String()});
      enabledCategories.value = {...feedCategories};
      minImpact.value = 0;
      horizonFilter.value = 'all';
      pendingStory.value = null;
      lastSeenAtLaunch.value = null;
    });

    Future<void> pumpFeed(WidgetTester tester, List<Story> stories) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [storiesProvider.overrideWith((_) async => stories)],
        child: const MaterialApp(home: Scaffold(body: FeedScreen())),
      ));
      // Resolve the provider future and the async prefs stamp load. Explicit
      // pumps, not pumpAndSettle — the fresh-poll periodic timer never ends.
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    Future<void> swipeUp(WidgetTester tester) async {
      await tester.fling(
          find.byType(PageView).first, const Offset(0, -500), 1200);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('divider page renders after the new stories', (tester) async {
      await pumpFeed(tester,
          [_s(1, _t(12)), _s(2, _t(11)), _s(3, _t(8))]);
      expect(find.text('Hook 1'), findsOneWidget);
      await swipeUp(tester); // -> story 2
      await swipeUp(tester); // -> divider
      expect(find.text("That's everything new"), findsOneWidget);
      expect(find.textContaining('2 new stories'), findsOneWidget);
      // Ticks can't load with Supabase uninitialized: the pulse row is
      // simply absent, never an error.
      expect(find.textContaining('NIFTY'), findsNothing);
      await swipeUp(tester); // -> story 3, feed continues past the divider
      expect(find.text('Hook 3'), findsOneWidget);
    });

    testWidgets('no stamp, no divider — and the visit stamps the newest',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpFeed(tester, [_s(1, _t(12)), _s(2, _t(11))]);
      await swipeUp(tester);
      expect(find.text("That's everything new"), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('feed_last_seen_v1'),
          _t(12).toIso8601String());
    });
  });
}
