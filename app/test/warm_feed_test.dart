// Warm start: a saved page younger than 6 h shows under the spinner while the
// network page is still loading, so a cold start opens on cards.
import 'dart:async';
import 'dart:convert';

import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _row(int id) => {
      'id': id,
      'headline': 'Headline $id',
      'hook': 'Hook $id',
      'summary': 'Summary.',
      'impact_score': 7,
      'source_name': 'ET',
      'source_url': 'https://e.co/$id',
      'sectors': const [],
      'published_at': DateTime.now().toUtc().toIso8601String(),
    };

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      // Network page never arrives: the warm copy is all the screen has.
      storiesProvider.overrideWith((_) => Completer<List<Story>>().future),
    ],
    child: const MaterialApp(home: Scaffold(body: FeedScreen())),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    enabledCategories.value = {...feedCategories};
    minImpact.value = 0;
    horizonFilter.value = 'all';
    pendingStory.value = null;
    lastSeenAtLaunch.value = null;
  });

  testWidgets('fresh cache renders cards while loading', (tester) async {
    SharedPreferences.setMockInitialValues({
      'gesture_hints_v1': true,
      'feed_cache_v1': jsonEncode([_row(1), _row(2)]),
      'feed_cache_at_v1': DateTime.now().millisecondsSinceEpoch,
    });
    await _pump(tester);
    expect(find.text('Hook 1'), findsOneWidget);
  });

  testWidgets('a stale cache stays under the spinner', (tester) async {
    SharedPreferences.setMockInitialValues({
      'gesture_hints_v1': true,
      'feed_cache_v1': jsonEncode([_row(1)]),
      'feed_cache_at_v1': DateTime.now()
          .subtract(const Duration(hours: 7))
          .millisecondsSinceEpoch,
    });
    await _pump(tester);
    expect(find.text('Hook 1'), findsNothing);
  });
}
