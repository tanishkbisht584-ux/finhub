// One event carried by several outlets shows as ONE card that credits whoever
// published first, with the rest behind "+N more". The pipeline files them
// under a shared cluster and keeps every outlet's link; this is the render
// side of that.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryCard;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Story _story({List<Map<String, dynamic>> outlets = const []}) =>
    Story.fromJson({
      'id': 1,
      'hook': 'Court pauses the FSSAI order',
      'headline': "Delhi High Court stays FSSAI order on Dabur's '100% pure' claim",
      'summary': 'The stay holds until the next hearing.',
      'impact_direction': 'positive',
      'impact_strength': 2,
      'impact_horizon': 'short_term',
      'impact_score': 6,
      'confidence': 'high',
      // The row the pipeline happened to process — deliberately NOT the outlet
      // that broke the story, so a card crediting this would be wrong.
      'source_name': 'Mint Companies',
      'source_url': 'https://mint.example/late',
      'category': 'Policy',
      'sectors': const ['FMCG'],
      'outlets': outlets,
    });

const _threeOutlets = [
  {
    'source_name': 'Business Standard',
    'source_url': 'https://bs.example/first',
    'published_at': '2026-08-09T09:00:00Z',
  },
  {
    'source_name': 'Mint Companies',
    'source_url': 'https://mint.example/late',
    'published_at': '2026-08-09T10:30:00Z',
  },
  {
    'source_name': 'ET Top Stories',
    'source_url': 'https://et.example/latest',
    'published_at': '2026-08-09T11:15:00Z',
  },
];

Widget _wrap(Story s) => ProviderScope(
    child: MaterialApp(home: Scaffold(body: StoryCard(story: s))));

void main() {
  test('outlets parse in the order given, with their publish times', () {
    final s = _story(outlets: _threeOutlets);
    expect(s.outlets.map((o) => o.name).toList(),
        ['Business Standard', 'Mint Companies', 'ET Top Stories']);
    expect(s.outlets.first.publishedAt, DateTime.utc(2026, 8, 9, 9));
  });

  test('a story nobody else carried has no outlet list', () {
    expect(_story().outlets, isEmpty);
  });

  testWidgets('credits the outlet that published first, not the processed row',
      (tester) async {
    await tester.pumpWidget(_wrap(_story(outlets: _threeOutlets)));
    // Business Standard broke it 90 minutes before the row we actually stored.
    expect(find.text('Business Standard'), findsOneWidget);
    expect(find.text('+2 more'), findsOneWidget);
  });

  testWidgets('single-outlet story shows no "more" affordance', (tester) async {
    await tester.pumpWidget(_wrap(_story(outlets: [_threeOutlets.first])));
    expect(find.text('Business Standard'), findsOneWidget);
    expect(find.textContaining('more'), findsNothing);
  });

  testWidgets('falls back to the story\'s own source when nothing is attached',
      (tester) async {
    // Cards cached before this feature shipped carry no outlet list, and must
    // still render their attribution rather than an empty byline.
    await tester.pumpWidget(_wrap(_story()));
    expect(find.text('Mint Companies'), findsOneWidget);
    expect(find.textContaining('more'), findsNothing);
  });

  testWidgets('tapping "+N more" lists every outlet, earliest marked FIRST',
      (tester) async {
    await tester.pumpWidget(_wrap(_story(outlets: _threeOutlets)));
    await tester.tap(find.text('+2 more'));
    await tester.pumpAndSettle();
    expect(find.text('Reported by 3 outlets'), findsOneWidget);
    expect(find.text('FIRST'), findsOneWidget);
    for (final name in ['Business Standard', 'Mint Companies', 'ET Top Stories']) {
      expect(find.text(name), findsWidgets, reason: '$name missing from sheet');
    }
  });
}
