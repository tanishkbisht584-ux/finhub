import 'package:finswipe/models.dart';
import 'package:finswipe/share_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Story _story() => Story.fromJson({
      'id': 42,
      'headline': 'RBI holds repo rate at 5.25%',
      'hook': 'RBI stands still',
      'source_name': 'RBI Press',
      'source_url': 'https://rbi.org.in/x',
      'sectors': const [],
    });

void main() {
  test('share text carries the hook and a working link', () {
    final t = shareText(_story());
    expect(t, contains('RBI stands still'));
    expect(t, contains('https://rbi.org.in/x'));
    expect(t, contains('FinSwipe'));
  });

  test('falls back to the headline when the AI produced no hook', () {
    final s = Story.fromJson({
      'id': 1,
      'headline': 'Headline only',
      'source_name': 'ET',
      'source_url': 'https://et.com/a',
      'sectors': const [],
    });
    expect(shareText(s), startsWith('Headline only'));
  });

  testWidgets('every target renders, and only the held one is highlighted',
      (tester) async {
    final anim = AnimationController(
        vsync: const TestVSync(), duration: const Duration(milliseconds: 1))
      ..value = 1;
    addTearDown(anim.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SharePaletteRow(
          animation: anim,
          activeIndex: 2,
          tileSize: 46,
          gap: 10,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    for (final t in shareTargets) {
      expect(find.text(t.label), findsOneWidget);
    }
    // the held tile is scaled up; its neighbours are not
    final held = tester.widget<AnimatedScale>(find.ancestor(
        of: find.byIcon(shareTargets[2].icon),
        matching: find.byType(AnimatedScale)));
    final other = tester.widget<AnimatedScale>(find.ancestor(
        of: find.byIcon(shareTargets[0].icon),
        matching: find.byType(AnimatedScale)));
    expect(held.scale, greaterThan(other.scale));
  });
}
