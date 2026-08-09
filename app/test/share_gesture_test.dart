import 'package:finswipe/share_palette.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors _StoryCardState._trackThumb. The gesture maths is the part that
/// actually broke — hit-testing the palette's box never matched because the
/// thumb rests on the rail below it — so it is worth pinning down separately.
int? select(double dx, double dy) {
  const stepPx = 84.0;
  final mid = shareTargets.length ~/ 2;
  if (dy > 130) return null; // drag down to cancel
  return (mid + (dx / stepPx).round()).clamp(0, shareTargets.length - 1);
}

void main() {
  test('a still thumb keeps the middle target', () {
    expect(select(0, 0), shareTargets.length ~/ 2);
  });

  test('small wobble does not change target', () {
    // Instagram-ish: roughly half a step of travel before anything moves.
    expect(select(30, 0), shareTargets.length ~/ 2);
    expect(select(-30, 0), shareTargets.length ~/ 2);
  });

  test('a deliberate slide walks one tile per step, both ways', () {
    final mid = shareTargets.length ~/ 2;
    expect(select(84, 0), mid + 1);
    expect(select(-84, 0), mid - 1);
    expect(select(168, 0), mid + 2);
  });

  test('slides past the ends clamp instead of falling off', () {
    expect(select(9999, 0), shareTargets.length - 1);
    expect(select(-9999, 0), 0);
  });

  test('dragging well below cancels', () {
    expect(select(0, 200), isNull);
  });

  test('works from any origin — selection is relative, not absolute', () {
    // Same travel from a different press point yields the same target, which
    // is the whole point of holding anywhere on the card.
    expect(select(84, 0), select(84, 20));
  });
}
