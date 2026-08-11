// The strip must never degrade a card: no media -> no gap, dead URL -> silent
// collapse (widget-test HTTP always 400s, which conveniently IS the dead-URL
// case), video -> tappable with a play badge while the thumbnail lives.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryCard;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Story _s(Map<String, dynamic> overrides) => Story.fromJson({
      'id': 1,
      'headline': 'RBI holds repo rate',
      'hook': 'RBI stands still',
      'summary': 'Rates unchanged.',
      'impact_score': 7,
      'source_name': 'RBI Press',
      'source_url': 'https://rbi.org.in/x',
      'sectors': const [],
      ...overrides,
    });

Widget _app(Story s) => ProviderScope(
    child: MaterialApp(home: Scaffold(body: StoryCard(story: s))));

void main() {
  test('Story parses image_url and video_url', () {
    final s = _s({'image_url': 'https://cdn.et.com/a.jpg',
                  'video_url': 'https://www.youtube.com/watch?v=abc'});
    expect(s.imageUrl, 'https://cdn.et.com/a.jpg');
    expect(s.videoUrl, 'https://www.youtube.com/watch?v=abc');
    expect(_s(const {}).imageUrl, isNull);
  });

  testWidgets('no media, no strip — card is exactly today\'s card',
      (tester) async {
    await tester.pumpWidget(_app(_s(const {})));
    expect(find.byType(AspectRatio), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
  });

  testWidgets('dead image URL collapses the strip silently', (tester) async {
    await tester.pumpWidget(_app(_s({'image_url': 'https://x.invalid/a.jpg'})));
    await tester.pumpAndSettle();
    // Test HTTP returns 400 for every request: the errorBuilder path.
    expect(find.byType(AspectRatio), findsNothing);
    expect(find.byIcon(Icons.broken_image), findsNothing);
  });
}
