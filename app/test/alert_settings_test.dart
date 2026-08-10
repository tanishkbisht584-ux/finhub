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
}
