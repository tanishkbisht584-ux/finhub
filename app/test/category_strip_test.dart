// Feed category strip (spec 2026-08-12): chips narrow the feed client-side,
// the hide-sheet removes categories everywhere (All included), and a
// notification tap must never land behind a chip filter.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart'
    show CategoryStrip, visibleStories, feedCategories, hiddenCategories,
         selectedCategory, pendingStory, setCategoryHidden, resetFilterForAlert;
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
    hiddenCategories.value = const {};
    selectedCategory.value = null;
    pendingStory.value = null;
  });

  test('visibleStories: All hides hidden, chip narrows, null tolerated', () {
    final list = [_s(1, 'Markets'), _s(2, 'IPO'), _s(3, 'Policy'), _s(4, null)];
    // All, nothing hidden: everything shows (null category included)
    expect(visibleStories(list, const {}, null).map((s) => s.id), [1, 2, 3, 4]);
    // hidden is hidden everywhere — All respects it
    expect(visibleStories(list, const {'IPO'}, null).map((s) => s.id), [1, 3, 4]);
    // a chip narrows to exactly that category; null-category never matches one
    expect(visibleStories(list, const {}, 'Markets').map((s) => s.id), [1]);
    // selecting a hidden category yields nothing rather than leaking it
    expect(visibleStories(list, const {'IPO'}, 'IPO'), isEmpty);
  });

  test('strip order is the fixed 8, not data-driven', () {
    expect(feedCategories, [
      'Markets', 'Economy', 'IPO', 'Corporate', 'Policy', 'Global',
      'Commodities', 'Geopolitics',
    ]);
  });

  test('hiding the selected category resets selection to All', () async {
    selectedCategory.value = 'IPO';
    await setCategoryHidden('IPO', true);
    expect(selectedCategory.value, isNull);
    expect(hiddenCategories.value, contains('IPO'));
    // and the choice persisted
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('hidden_categories_v1'), ['IPO']);
  });

  test('a notification tap resets the chip filter to All', () {
    selectedCategory.value = 'Policy';
    pendingStory.value = 7;
    // FeedScreen._land calls resetFilterForAlert() before jumping; the reset
    // rule itself is what we pin here.
    resetFilterForAlert();
    expect(selectedCategory.value, isNull);
  });

  testWidgets('strip renders All + visible chips, tap narrows, hidden absent',
      (tester) async {
    hiddenCategories.value = const {'Geopolitics'};
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CategoryStrip())));
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Markets'), findsOneWidget);
    expect(find.text('Geopolitics'), findsNothing); // hidden chip is gone
    await tester.tap(find.text('IPO'));
    await tester.pump();
    expect(selectedCategory.value, 'IPO');
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(selectedCategory.value, isNull);
  });
}
