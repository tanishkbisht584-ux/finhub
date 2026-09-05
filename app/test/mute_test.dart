// Mutes are curation, not a lens: visibleStories drops muted publishers
// (normalized through publisher(), so 'ET Economy' mutes as 'Economic
// Times') and muted tickers; the rail's volume-off button mutes, the dial's
// MUTED row unmutes.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Story _s(int id, {String source = 'ET', List<String> symbols = const []}) =>
    Story.fromJson({
      'id': id,
      'headline': 'Headline $id',
      'hook': 'Hook $id',
      'summary': 'S.',
      'source_name': source,
      'sectors': const [],
      'companies': [
        for (final (i, sym) in symbols.indexed)
          {'id': 100 * id + i, 'name': sym, 'nse_symbol': sym}
      ],
    });

void main() {
  final all = {...feedCategories};

  group('visibleStories mutes', () {
    test('defaults are identity', () {
      final l = [_s(1), _s(2)];
      expect(visibleStories(l, all, 0, 'all').length, 2);
    });

    test('muted publisher drops the story, alias normalized', () {
      final l = [_s(1, source: 'ET Economy'), _s(2, source: 'Mint')];
      final out = visibleStories(l, all, 0, 'all',
          mutedSrc: {'Economic Times'});
      expect([for (final s in out) s.id], [2]);
    });

    test('muted ticker drops any story tagging it', () {
      final l = [
        _s(1, symbols: ['TCS', 'INFY']),
        _s(2, symbols: ['RELIANCE']),
      ];
      final out = visibleStories(l, all, 0, 'all', mutedSym: {'TCS'});
      expect([for (final s in out) s.id], [2]);
    });
  });

  group('mute flow', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({'gesture_hints_v1': true});
      enabledCategories.value = {...feedCategories};
      minImpact.value = 0;
      horizonFilter.value = 'all';
      pendingStory.value = null;
      lastSeenAtLaunch.value = null;
      mutedSources.value = {};
      mutedSymbols.value = {};
    });

    testWidgets('rail mute hides the card; dial unmute restores it',
        (tester) async {
      final stories = [_s(1, source: 'Mint'), _s(2, source: 'ET')];
      await tester.pumpWidget(ProviderScope(
        overrides: [storiesProvider.overrideWith((_) async => stories)],
        child: const MaterialApp(home: Scaffold(body: FeedScreen())),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.text('Hook 1'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.block_outlined).first);
      // Single taps sit behind the card's 300ms double-tap arena, then the
      // sheet's entrance animation needs settling.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MUTE MINT'));
      await tester.pumpAndSettle();

      expect(mutedSources.value, {'Mint'});
      expect(find.text('Hook 1'), findsNothing);
      expect(find.text('Hook 2'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('feed_muted_sources_v1'), ['Mint']);

      // Unmute from the dial sheet.
      showFeedFilterSheet(
          tester.element(find.byType(FeedScreen)));
      await tester.pumpAndSettle();
      expect(find.text('MUTED — TAP TO UNMUTE'), findsOneWidget);
      await tester.tap(find.text('MINT'));
      await tester.pumpAndSettle();
      expect(mutedSources.value, isEmpty);
    });
  });
}
