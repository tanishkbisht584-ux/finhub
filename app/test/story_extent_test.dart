// Phase 2 (2026-08-28): glossary segmentation for tappable terms, the
// story-so-far timeline (zero AI, cluster data), and the deep read's optional
// structured extras (glossary page, key-stat callout) — old cached
// {pages}-only payloads must render exactly as before.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart'
    show DeepReadPages, FeedScreen, storiesProvider;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Outlet _o(String name, String headline, String at) => Outlet.fromJson(
    {'source_name': name, 'source_url': '', 'published_at': at, 'headline': headline});

void main() {
  group('glossarySegments', () {
    test('marks whole-word hits case-insensitively', () {
      final segs = glossarySegments('RBI cut the Repo Rate by 25 basis points.');
      final terms = [for (final s in segs.where((s) => s.isTerm)) s.text];
      expect(terms, ['Repo Rate', 'basis points']);
      expect(segs.map((s) => s.text).join(), 'RBI cut the Repo Rate by 25 basis points.');
    });

    test('no partial-word matches', () {
      // "pat" must not fire inside "patient", nor "sip" inside "recipe".
      final segs = glossarySegments('The patient recipe was fine.');
      expect(segs.where((s) => s.isTerm), isEmpty);
    });

    test('longest term wins over its prefix/substring sibling', () {
      final segs = glossarySegments('reverse repo stayed put');
      final terms = [for (final s in segs.where((s) => s.isTerm)) s.text];
      expect(terms, ['reverse repo']);
    });

    test('empty text -> no segments', () {
      expect(glossarySegments(''), isEmpty);
    });
  });

  group('storyTimeline', () {
    test('sorts oldest first, dedupes by headline not newsroom', () {
      final t = storyTimeline([
        _o('Mint', 'RBI cuts rates', '2026-08-28T10:00:00Z'),
        _o('ET', 'RBI cuts rates', '2026-08-28T09:00:00Z'), // same wording, later dupe
        _o('ET', 'Banks pass on the cut', '2026-08-28T12:00:00Z'), // same paper, new episode
      ]);
      expect([for (final e in t) e.headline],
          ['RBI cuts rates', 'Banks pass on the cut']);
      expect(t.first.name, 'ET'); // earliest telling of the first episode
    });

    test('entries without headlines (old cache) are dropped', () {
      final t = storyTimeline([
        Outlet.fromJson({'source_name': 'ET', 'published_at': '2026-08-28T09:00:00Z'}),
        _o('Mint', 'A development', '2026-08-28T10:00:00Z'),
      ]);
      expect(t.length, 1);
    });
  });

  group('story-so-far page in the pager', () {
    Story feedStory({List<Map<String, String>> timeline = const []}) =>
        Story.fromJson({
          'id': 1,
          'headline': 'Headline',
          'hook': 'Hook 1',
          'summary': 'Plain summary.',
          'source_name': 'ET',
          'sectors': const [],
          'timeline': timeline,
        });

    Future<void> pumpFeed(WidgetTester tester, Story s) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(ProviderScope(
        overrides: [
          storiesProvider.overrideWith((_) async => [s])
        ],
        child: const MaterialApp(home: Scaffold(body: FeedScreen())),
      ));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('>=2 distinct headlines -> page appears on left swipe',
        (tester) async {
      await pumpFeed(
          tester,
          feedStory(timeline: [
            {
              'source_name': 'ET',
              'headline': 'RBI cuts rates',
              'published_at': '2026-08-28T09:00:00Z'
            },
            {
              'source_name': 'Mint',
              'headline': 'Banks pass on the cut',
              'published_at': '2026-08-28T12:00:00Z'
            },
          ]));
      await tester.fling(find.text('Hook 1'), const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('THE STORY SO FAR'), findsOneWidget);
      expect(find.text('RBI cuts rates'), findsOneWidget);
      expect(find.text('Banks pass on the cut'), findsOneWidget);
    });

    testWidgets('single-episode cluster -> no story-so-far page',
        (tester) async {
      await pumpFeed(
          tester,
          feedStory(timeline: [
            {
              'source_name': 'ET',
              'headline': 'RBI cuts rates',
              'published_at': '2026-08-28T09:00:00Z'
            },
          ]));
      await tester.drag(find.text('Hook 1'), const Offset(-400, 0));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('THE STORY SO FAR'), findsNothing);
    });
  });

  group('DeepRead structured extras', () {
    final structured = DeepRead.fromJson({
      'pages': [
        {'heading': 'What happened', 'body': 'A thing occurred.'},
      ],
      'glossary': [
        {'term': 'QIP', 'definition': 'A fast share sale to big investors.'},
        {'term': 7, 'definition': 'garbage dropped'},
      ],
      'key_stat': {'value': 'Rs 5,000 cr', 'label': 'about 2% of market value'},
    });

    test('parses glossary and key_stat, drops garbage', () {
      expect(structured.glossary.length, 1);
      expect(structured.glossary.first.term, 'QIP');
      expect(structured.keyStat?.value, 'Rs 5,000 cr');
    });

    test('old {pages}-only payload has no extras', () {
      final old = DeepRead.fromJson({
        'pages': [
          {'heading': 'H', 'body': 'B'}
        ]
      });
      expect(old.glossary, isEmpty);
      expect(old.keyStat, isNull);
    });

    testWidgets('key-stat callout renders on the opening page only',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: DeepReadPages(read: structured, pageIndex: 0))));
      expect(find.text('Rs 5,000 cr'), findsOneWidget);
      expect(find.text('about 2% of market value'), findsOneWidget);
    });

    testWidgets('glossary page renders past the last AI page', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: DeepReadPages(read: structured, pageIndex: 1))));
      expect(find.text('In plain words'), findsOneWidget);
      expect(find.text('QIP'), findsOneWidget);
      expect(find.text('A fast share sale to big investors.'), findsOneWidget);
      expect(find.text('Rs 5,000 cr'), findsNothing);
    });

    testWidgets('payload without extras renders plain pages unchanged',
        (tester) async {
      final old = DeepRead.fromJson({
        'pages': [
          {'heading': 'H', 'body': 'B'}
        ]
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: DeepReadPages(read: old, pageIndex: 0))));
      expect(find.text('H'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(find.text('In plain words'), findsNothing);
    });
  });
}
