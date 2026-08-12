// Feed category chips (owner's call 2026-08-12): ONE feed to scroll; each
// chip toggles its category in or out of it, All lights everything, choices
// persist on-device, and a notification tap must never land behind a filter.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart'
    show CategoryStrip, visibleStories, feedCategories, enabledCategories,
         pendingStory, toggleCategory, enableAllCategories, resetFilterForAlert;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Story _s(int id, String? cat) => Story.fromJson({
      'id': id,
      'headline': 'Headline $id',
      'hook': 'Hook $id',
      'summary': 'S.',
      'impact_score': 6,
      'source_name': 'ET',
      'source_url': 'https://e.co/$id',
      'category': cat,
      'sectors': const [],
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    enabledCategories.value = {...feedCategories};
    pendingStory.value = null;
  });

  test('visibleStories: one feed composed of the enabled categories', () {
    final list = [_s(1, 'Markets'), _s(2, 'IPO'), _s(3, 'Policy'), _s(4, null)];
    // everything enabled: all show, null category included
    expect(visibleStories(list, {...feedCategories}).map((s) => s.id),
        [1, 2, 3, 4]);
    // subtract IPO: it leaves the ONE feed; null category hides too, because
    // an unlabeled story can't prove it belongs to what's left
    final minusIpo = {...feedCategories}..remove('IPO');
    expect(visibleStories(list, minusIpo).map((s) => s.id), [1, 3]);
    // down to a single category
    expect(visibleStories(list, const {'Policy'}).map((s) => s.id), [3]);
    expect(visibleStories(list, const {}), isEmpty);
  });

  test('toggle subtracts and re-adds; choices persist; All restores', () async {
    await toggleCategory('IPO');
    expect(enabledCategories.value, isNot(contains('IPO')));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('feed_categories_v1'), isNot(contains('IPO')));
    await toggleCategory('IPO');
    expect(enabledCategories.value, contains('IPO'));
    await toggleCategory('Policy');
    await enableAllCategories();
    expect(enabledCategories.value, {...feedCategories});
  });

  test('a notification tap opens the feed back up', () {
    enabledCategories.value = const {'Markets'};
    resetFilterForAlert();
    expect(enabledCategories.value, {...feedCategories});
  });

  testWidgets('chips render, tapping toggles membership, All relights',
      (tester) async {
    // 9 chips need ~1000 logical px; the ListView only mounts what fits.
    tester.view.physicalSize = const Size(1400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CategoryStrip())));
    expect(find.text('All'), findsOneWidget);
    for (final c in feedCategories) {
      expect(find.text(c), findsOneWidget);
    }
    await tester.tap(find.text('IPO'));
    await tester.pump();
    expect(enabledCategories.value, isNot(contains('IPO')));
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(enabledCategories.value, {...feedCategories});
  });
}
