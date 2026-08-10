import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/screens/profile.dart';

void main() {
  test('toggle write preserves unrelated keys (pipeline pa state)', () {
    final merged = mergedAlertSettings(
        {'personalized': true, 'voice_l1': true, 'pa': {'d': '2026-08-10', 'n': 2}},
        'voice_l1', false);
    expect(merged['voice_l1'], false);
    expect(merged['pa'], {'d': '2026-08-10', 'n': 2});
    expect(merged['personalized'], true);
  });

  testWidgets(
      'flipping both toggles writes one shared, up-to-date map each time — '
      'a stale per-toggle copy would let the second write revert the first',
      (tester) async {
    final writes = <Map<String, dynamic>>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AlertSettingsSection(
      userId: 'u1',
      initial: const {
        'personalized': true,
        'voice_l1': true,
        'pa': {'d': '2026-08-10', 'n': 2},
      },
      writer: (merged) async => writes.add(merged),
    ))));
    await tester.pump();

    await tester.tap(find.byType(SwitchListTile).at(0)); // voice_l1 -> false
    await tester.pump();
    await tester.tap(find.byType(SwitchListTile).at(1)); // personalized -> false
    await tester.pump();

    expect(writes.length, 2);
    final last = writes.last;
    expect(last['voice_l1'], false);
    expect(last['personalized'], false);
    expect(last['pa'], {'d': '2026-08-10', 'n': 2});
  });
}
