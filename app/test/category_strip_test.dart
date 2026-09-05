// Feed filters (owner's calls 2026-08-12, reworked 2026-08-21): ONE feed; the
// round tune tile opens a categories-only panel; min impact and horizon live
// behind the card's ledger line (tap IMPACT / tap SHORT+LONG); choices persist
// on-device; a notification tap must never land behind any filter.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart'
    show FeedFilterButton, LiveButton, StoryCard, liveMode, visibleStories,
         feedCategories, enabledCategories, minImpact, setMinImpact,
         horizonFilter, setHorizonFilter, pendingStory, toggleCategory,
         enableAllCategories, resetFilterForAlert, filtersActive;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Story _s(int id, String? cat, {int? impact, String? horizon}) =>
    Story.fromJson({
      'id': id,
      'headline': 'Headline $id',
      'hook': 'Hook $id',
      'summary': 'S.',
      'impact_score': impact,
      'impact_horizon': horizon,
      'source_name': 'ET',
      'source_url': 'https://e.co/$id',
      'category': cat,
      'sectors': const [],
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'gesture_hints_v1': true});
    enabledCategories.value = {...feedCategories};
    minImpact.value = 0;
    horizonFilter.value = 'all';
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
    expect(visibleStories(list, {...feedCategories}, 0, 'all').map((s) => s.id),
        [1, 2, 3, 4]);
    final minusIpo = {...feedCategories}..remove('IPO');
    expect(visibleStories(list, minusIpo, 0, 'all').map((s) => s.id), [1, 3]);
    // impact dial: null score counts as 0 and drops out
    expect(visibleStories(list, {...feedCategories}, 6, 'all').map((s) => s.id),
        [1, 3]);
    expect(visibleStories(list, {...feedCategories}, 8, 'all').map((s) => s.id),
        [1]);
    // both dials together
    expect(visibleStories(list, minusIpo, 8, 'all').map((s) => s.id), [1]);
  });

  test('visibleStories: horizon lens — both belongs to either side', () {
    final list = [
      _s(1, 'Markets', impact: 9, horizon: 'short_term'),
      _s(2, 'Markets', impact: 9, horizon: 'long_term'),
      _s(3, 'Markets', impact: 9, horizon: 'both'),
      _s(4, 'Markets', impact: 9), // no horizon: only under ALL
    ];
    final all = {...feedCategories};
    expect(visibleStories(list, all, 0, 'all').map((s) => s.id), [1, 2, 3, 4]);
    expect(visibleStories(list, all, 0, 'short').map((s) => s.id), [1, 3]);
    expect(visibleStories(list, all, 0, 'long').map((s) => s.id), [2, 3]);
  });

  test('choices persist; reset opens everything back up', () async {
    await toggleCategory('IPO');
    await setMinImpact(6);
    await setHorizonFilter('short');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('feed_categories_v1'), isNot(contains('IPO')));
    expect(prefs.getInt('feed_min_impact_v1'), 6);
    expect(prefs.getString('feed_horizon_v1'), 'short');
    expect(filtersActive(), isTrue);
    resetFilterForAlert();
    expect(enabledCategories.value, {...feedCategories});
    expect(minImpact.value, 0);
    expect(horizonFilter.value, 'all');
    expect(filtersActive(), isFalse);
    await enableAllCategories();
    expect(enabledCategories.value, {...feedCategories});
  });

  testWidgets('tune tile opens the categories-only panel', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: FeedFilterButton()))));
    expect(find.byIcon(Icons.tune), findsOneWidget);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('YOUR FEED'), findsOneWidget);
    expect(find.text('MIN IMPACT'), findsNothing); // moved to the ledger line
    await tester.tap(find.text('IPO'));
    await tester.pump();
    expect(enabledCategories.value, isNot(contains('IPO')));
    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(filtersActive(), isFalse);
  });

  testWidgets('ledger line: IMPACT and SHORT+LONG open their mini sheets',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
                body: StoryCard(
                    story: _s(1, 'Markets', impact: 9, horizon: 'both'),
                    onReadMore: () {})))));

    // Single taps sit behind the card's 300ms double-tap arena.
    await tester.tap(find.text('IMPACT 9/10'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('MIN IMPACT'), findsOneWidget);
    await tester.tap(find.text('8+'));
    await tester.pump();
    expect(minImpact.value, 8);
    Navigator.of(tester.element(find.text('MIN IMPACT'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('SHORT + LONG'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('HORIZON'), findsOneWidget);
    await tester.tap(find.text('LONG'));
    await tester.pump();
    expect(horizonFilter.value, 'long');
  });

  testWidgets('LIVE tile toggles the mode on tap', (tester) async {
    liveMode.value = false;
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: LiveButton()))));
    expect(find.text('LIVE'), findsOneWidget);
    await tester.tap(find.text('LIVE'));
    await tester.pump();
    expect(liveMode.value, isTrue);
    await tester.tap(find.text('LIVE'));
    await tester.pump();
    expect(liveMode.value, isFalse);
  });
}
