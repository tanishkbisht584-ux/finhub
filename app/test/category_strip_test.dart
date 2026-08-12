// Feed filters (owner's calls 2026-08-12): ONE feed; a round tune tile at
// top right (share-palette style) opens the panel; categories toggle in/out,
// a minimum-impact dial narrows further; choices persist on-device; a
// notification tap must never land behind any filter.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart'
    show FeedFilterButton, visibleStories, feedCategories, enabledCategories,
         minImpact, setMinImpact, pendingStory, toggleCategory,
         enableAllCategories, resetFilterForAlert, filtersActive;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Story _s(int id, String? cat, {int? impact}) => Story.fromJson({
      'id': id,
      'headline': 'Headline $id',
      'hook': 'Hook $id',
      'summary': 'S.',
      'impact_score': impact,
      'source_name': 'ET',
      'source_url': 'https://e.co/$id',
      'category': cat,
      'sectors': const [],
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    enabledCategories.value = {...feedCategories};
    minImpact.value = 0;
    pendingStory.value = null;
  });

  test('visibleStories: categories compose the feed, min impact narrows it',
      () {
    final list = [
      _s(1, 'Markets', impact: 9),
      _s(2, 'IPO', impact: 5),
      _s(3, 'Policy', impact: 7),
      _s(4, null), // null category AND null score
    ];
    expect(visibleStories(list, {...feedCategories}, 0).map((s) => s.id),
        [1, 2, 3, 4]);
    final minusIpo = {...feedCategories}..remove('IPO');
    expect(visibleStories(list, minusIpo, 0).map((s) => s.id), [1, 3]);
    // impact dial: null score counts as 0 and drops out
    expect(visibleStories(list, {...feedCategories}, 6).map((s) => s.id),
        [1, 3]);
    expect(visibleStories(list, {...feedCategories}, 8).map((s) => s.id), [1]);
    // both dials together
    expect(visibleStories(list, minusIpo, 8).map((s) => s.id), [1]);
  });

  test('choices persist; reset opens everything back up', () async {
    await toggleCategory('IPO');
    await setMinImpact(6);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('feed_categories_v1'), isNot(contains('IPO')));
    expect(prefs.getInt('feed_min_impact_v1'), 6);
    expect(filtersActive(), isTrue);
    resetFilterForAlert();
    expect(enabledCategories.value, {...feedCategories});
    expect(minImpact.value, 0);
    expect(filtersActive(), isFalse);
    await enableAllCategories();
    expect(enabledCategories.value, {...feedCategories});
  });

  testWidgets('tune tile opens the panel; pills toggle live', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: FeedFilterButton()))));
    expect(find.byIcon(Icons.tune), findsOneWidget);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('YOUR FEED'), findsOneWidget);
    expect(find.text('MIN IMPACT'), findsOneWidget);
    await tester.tap(find.text('IPO'));
    await tester.pump();
    expect(enabledCategories.value, isNot(contains('IPO')));
    await tester.tap(find.text('8+'));
    await tester.pump();
    expect(minImpact.value, 8);
    expect(filtersActive(), isTrue);
    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(filtersActive(), isFalse);
  });
}
