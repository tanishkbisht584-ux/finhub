import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/share_palette.dart';

void main() {
  test('ribbon holds cancel/watchlist/saved and still opens on Saved', () {
    expect([for (final t in ribbonTargets) t.id],
        ['cancel', 'watchlist', 'saved']);
    expect(ribbonTargets[defaultRibbonTarget].id, 'saved');
  });
}
