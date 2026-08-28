// Glance lines (014): why-it-matters bold line + one merged chip row
// (winners/losers · claim status · watchlist flag). NULL fields — every story
// scored before 014, and weak-lane stories — must render NOTHING, and a card
// carrying every field must clamp the summary instead of tipping into
// _FitScroll's inner-scroll mode.
import 'package:finswipe/follows.dart';
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Story _s(int id,
        {String? why,
        String? winners,
        String? claim,
        List<String> symbols = const []}) =>
    Story.fromJson({
      'id': id,
      'headline': 'Headline $id',
      'hook': 'Hook $id',
      'summary': 'A sentence about the story. ' * 8,
      'source_name': 'ET',
      'sectors': const [],
      'why_it_matters': why,
      'winners_losers': winners,
      'claim_status': claim,
      'companies': [
        for (final (i, sym) in symbols.indexed)
          {'id': 100 * id + i, 'name': sym, 'nse_symbol': sym}
      ],
    });

Future<void> _pumpCard(WidgetTester tester, Story story) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(ProviderScope(
    overrides: [
      storiesProvider.overrideWith((_) async => [story])
    ],
    child: const MaterialApp(home: Scaffold(body: FeedScreen())),
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => followedCompanyIds.value = {});

  testWidgets('all fields render: bold line + merged chip row',
      (tester) async {
    followedCompanyIds.value = {100}; // _s computes company id = 100*id + i
    await _pumpCard(
        tester,
        _s(1,
            why: 'Cheaper loans likely by Diwali',
            winners: 'Banks gain / NBFCs hurt',
            claim: 'rumour',
            symbols: ['TCS']));
    expect(find.text('Cheaper loans likely by Diwali'), findsOneWidget);
    expect(find.text('Banks gain / NBFCs hurt'), findsOneWidget);
    expect(find.text('rumour'), findsOneWidget);
    expect(find.text('★ TCS on your watchlist'), findsOneWidget);
  });

  testWidgets('NULL fields render nothing extra', (tester) async {
    await _pumpCard(tester, _s(2));
    expect(find.textContaining('watchlist'), findsNothing);
    expect(find.text('confirmed'), findsNothing);
    expect(find.text('reported'), findsNothing);
    expect(find.text('rumour'), findsNothing);
  });

  testWidgets('watchlist flag only for followed companies', (tester) async {
    await _pumpCard(tester, _s(3, symbols: ['INFY'])); // 301 not followed
    expect(find.textContaining('watchlist'), findsNothing);
  });

  testWidgets('small phone: summary clamps, no unbounded growth',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pumpCard(
        tester,
        _s(4,
            why: 'Cheaper loans likely by Diwali',
            winners: 'Banks gain / NBFCs hurt',
            claim: 'confirmed',
            symbols: ['TCS']));
    // The summary Text is clamped when glance lines are present.
    final summary = tester.widget<Text>(
        find.textContaining('A sentence about the story.').first);
    expect(summary.maxLines, isNotNull);
    // And nothing overflowed (an overflow throws during layout).
    expect(tester.takeException(), isNull);
  });
}
