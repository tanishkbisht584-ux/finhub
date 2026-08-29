// Phase 3 (2026-08-28): follow-a-story rail bell (cluster follows).
import 'package:finswipe/follows.dart';
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart';
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
}
