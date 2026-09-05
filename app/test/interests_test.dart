import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:finswipe/screens/feed.dart'
    show enabledCategories, feedCategories, setInitialCategories;
import 'package:finswipe/screens/interests.dart';

void main() {
  test('categories match the pipeline enum exactly', () {
    expect(kCategories, [
      'Markets',
      'Economy',
      'IPO',
      'Global',
      'Commodities',
      'Corporate',
      'Policy',
      'Geopolitics',
    ]);
  });

  testWidgets('Continue stays disabled until three picks', (tester) async {
    await tester.pumpWidget(MaterialApp(home: InterestsScreen(onDone: () {})));
    final button = () => tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button().onPressed, isNull);
    for (final c in ['Markets', 'Economy', 'IPO']) {
      await tester.tap(find.text(c));
      await tester.pump();
    }
    expect(button().onPressed, isNotNull);
  });

  test('picks narrow the feed filter; all/none leave the default', () async {
    SharedPreferences.setMockInitialValues({});
    enabledCategories.value = {...feedCategories};

    await setInitialCategories({'Markets', 'Economy', 'IPO'});
    expect(enabledCategories.value, {'Markets', 'Economy', 'IPO'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('feed_categories_v1'),
        ['Economy', 'IPO', 'Markets']);

    // Picking everything (or nothing) is no narrowing at all.
    enabledCategories.value = {...feedCategories};
    await prefs.remove('feed_categories_v1');
    await setInitialCategories({...feedCategories});
    expect(enabledCategories.value, feedCategories.toSet());
    expect(prefs.getStringList('feed_categories_v1'), isNull);
    await setInitialCategories({});
    expect(prefs.getStringList('feed_categories_v1'), isNull);
  });
}
