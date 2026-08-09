import 'package:finswipe/share_palette.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors _StoryCardState._trackThumb. The gesture maths is the part that
/// actually broke — hit-testing the palette's box never matched because the
/// thumb rests on the rail below it — so it is worth pinning down separately.
int? select(double dx, double dy) {
  const stepPx = 84.0;
  if (dy > 130) return null; // drag down to cancel
  return (defaultShareTarget + (dx / stepPx).round())
      .clamp(0, shareTargets.length - 1);
}

void main() {
  test('opens on the card tile', () {
    expect(shareTargets[defaultShareTarget].id, 'card');
    expect(select(0, 0), defaultShareTarget);
  });

  test('small wobble does not change target', () {
    // Instagram-ish: roughly half a step of travel before anything moves.
    expect(select(30, 0), defaultShareTarget);
    expect(select(-30, 0), defaultShareTarget);
  });

  test('one short slide right reaches Cancel', () {
    expect(shareTargets[select(84, 0)!].id, 'cancel');
  });

  test('sliding left walks the messaging targets', () {
    expect(shareTargets[select(-84, 0)!].id, 'copy');
    expect(shareTargets[select(-168, 0)!].id, 'x');
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
