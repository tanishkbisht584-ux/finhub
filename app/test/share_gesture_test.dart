import 'package:finswipe/share_palette.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors _StoryCardState._trackThumb. The gesture maths is the part that
/// actually broke — hit-testing the palette's box never matched because the
/// thumb rests on the rail below it — so it is worth pinning down separately.
int? select(double dx, double dy) {
  const step = 52.0;
  const cols = shareGridColumns;
  final rows = (shareTargets.length / cols).ceil();
  if (dy > 240) return null; // drag far below to cancel
  final col = (1 + (dx / step).round()).clamp(0, cols - 1);
  final row = (1 + (dy / step).round()).clamp(0, rows - 1);
  return (row * cols + col).clamp(0, shareTargets.length - 1);
}

String at(double dx, double dy) => shareTargets[select(dx, dy)!].id;

void main() {
  test('opens on the card tile, dead centre of the grid', () {
    expect(shareTargets[defaultShareTarget].id, 'card');
    expect(at(0, 0), 'card');
  });

  test('a wobble stays on the centre cell', () {
    expect(at(20, 0), 'card');
    expect(at(-20, 18), 'card');
  });

  test('every neighbour is one short glide away', () {
    expect(at(-52, -52), 'whatsapp');
    expect(at(0, -52), 'telegram');
    expect(at(52, -52), 'messenger');
    expect(at(-52, 0), 'reddit');
    expect(at(52, 0), 'x');
    expect(at(-52, 52), 'discord');
    expect(at(0, 52), 'copy');
    expect(at(52, 52), 'cancel');
  });

  test('overshooting sideways clamps to the edge cell', () {
    expect(at(-9999, -9999), 'whatsapp');
    expect(at(9999, -9999), 'messenger');
    expect(at(9999, 0), 'x');
  });

  test('dragging far below clears the selection, so release does nothing', () {
    // Past the grid there is no cell to land on. Releasing with no selection
    // fires nothing, which is the same outcome as the Cancel tile — the tile
    // is for people who look, this is for people who just pull away.
    expect(select(0, 300), isNull);
    expect(select(0, 52), isNotNull); // the Copy row must still be reachable
  });

  // The vertical ribbon (bookmark on a card, and the News tab) uses the same
  // stepping on the other axis. Opens on Saved; sliding up reaches Cancel.
  int ribbon(double dy) => (defaultRibbonTarget + (dy / 84.0).round())
      .clamp(0, ribbonTargets.length - 1);

  test('ribbon opens on Saved', () {
    expect(ribbonTargets[ribbon(0)].id, 'saved');
  });

  test('sliding up the ribbon reaches Cancel', () {
    expect(ribbonTargets[ribbon(-84)].id, 'cancel');
  });

  test('ribbon ignores a wobble and clamps at both ends', () {
    expect(ribbonTargets[ribbon(-30)].id, 'saved');
    expect(ribbonTargets[ribbon(-9999)].id, 'cancel');
    expect(ribbonTargets[ribbon(9999)].id, 'saved');
  });
}
