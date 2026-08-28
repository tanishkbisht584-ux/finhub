// Phase 3 (2026-08-28): follow-a-story rail bell (cluster follows) and the
// morning brief's text builder + play pill (digest mornings only).
import 'package:finswipe/follows.dart';
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart';
import 'package:finswipe/tts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Story _s(int id, {String? cluster}) => Story.fromJson({
      'id': id,
      'headline': 'Headline $id',
      'hook': 'Hook $id',
      'summary': 'S.',
      'source_name': 'ET',
      'sectors': const [],
      'cluster_id': cluster,
    });

Future<void> _pump(WidgetTester tester, List<Story> stories,
    {Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues(prefs);
  await tester.pumpWidget(ProviderScope(
    overrides: [storiesProvider.overrideWith((_) async => stories)],
    child: const MaterialApp(home: Scaffold(body: FeedScreen())),
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    followedClusterIds.value = {};
    lastSeenAtLaunch.value = null;
  });

  group('briefText', () {
    test('hook + why per story, top 5, joined', () {
      final t = briefText([
        for (var i = 1; i <= 7; i++) (hook: 'Hook $i', why: 'Why $i')
      ]);
      expect(t, contains('Hook 1. Why 1'));
      expect(t, contains('Hook 5. Why 5'));
      expect(t, isNot(contains('Hook 6')));
    });

    test('NULL why falls back to hook alone; empty stories skipped', () {
      final t = briefText([
        (hook: 'Hook 1', why: null),
        (hook: '', why: ''),
        (hook: 'Hook 3', why: 'Why 3'),
      ]);
      expect(t, 'Hook 1. Hook 3. Why 3');
    });

    test('empty list -> empty text', () {
      expect(briefText([]), '');
    });
  });

  group('rail follow bell', () {
    testWidgets('toggles the followed set optimistically (anon: no-op)',
        (tester) async {
      await _pump(tester, [_s(1, cluster: 'abc')]);
      expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
      // Anon session: tap is a no-op server-side; the bell still renders.
      await tester.tap(find.byIcon(Icons.notifications_none_rounded));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      // followedClusterIds untouched for anon (no user) — bell stays off.
      expect(followedClusterIds.value, isEmpty);
    });

    testWidgets('no cluster id -> no bell', (tester) async {
      await _pump(tester, [_s(2)]);
      expect(find.byIcon(Icons.notifications_none_rounded), findsNothing);
    });

    testWidgets('followed cluster renders the active bell', (tester) async {
      followedClusterIds.value = {'abc'};
      await _pump(tester, [_s(3, cluster: 'abc')]);
      expect(find.byIcon(Icons.notifications_active_rounded), findsOneWidget);
    });
  });

  group('brief pill', () {
    testWidgets('absent when not a digest morning', (tester) async {
      lastSeenAtLaunch.value = DateTime.now(); // same day -> not digest
      await _pump(tester, [_s(4)]);
      expect(find.text('BRIEF'), findsNothing);
    });

    testWidgets('present on a digest morning', (tester) async {
      // The feed loads the stamp from prefs at init (session-frozen), so the
      // fixture goes in as the persisted value, not the notifier.
      await _pump(tester, [_s(5)], prefs: {
        'feed_last_seen_v1': DateTime.now()
            .subtract(const Duration(days: 1))
            .toIso8601String(),
      });
      await tester.pump();
      expect(find.text('BRIEF'), findsOneWidget);
    });
  });
}
