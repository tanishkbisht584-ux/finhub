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
      'and each write carries the FRESH pa read at write time, not the '
      'stale pa from the initState snapshot (the pipeline rewrites pa every '
      '~45s, so writing the stale snapshot would rewind/delete it)',
      (tester) async {
    final writes = <Map<String, dynamic>>[];
    // Different from the initial snapshot's pa, simulating the pipeline
    // having advanced the cursor/count between initState and the first
    // toggle. A mutable fake "server" row, so the second toggle's fresh
    // read reflects the first toggle's write, same as a real backend would.
    final freshPa = {'d': '2026-08-10', 'n': 4, 'cur': 99};
    final server = <String, dynamic>{
      'personalized': true,
      'voice_l1': true,
      'pa': freshPa,
    };
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AlertSettingsSection(
      userId: 'u1',
      initial: const {
        'personalized': true,
        'voice_l1': true,
        'pa': {'d': '2026-08-10', 'n': 2, 'cur': 10},
      },
      fetcher: () async => Map<String, dynamic>.from(server),
      writer: (merged) async {
        writes.add(merged);
        server
          ..clear()
          ..addAll(merged);
      },
    ))));
    await tester.pump();

    await tester.tap(find.byType(SwitchListTile).at(0)); // voice_l1 -> false
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile).at(1)); // personalized -> false
    await tester.pumpAndSettle();

    expect(writes.length, 2);
    final last = writes.last;
    expect(last['voice_l1'], false);
    expect(last['personalized'], false);
    expect(last['pa'], freshPa, reason: 'write must carry the FRESH pa read '
        'from the server, not the stale pa from the initState snapshot');
  });
}
