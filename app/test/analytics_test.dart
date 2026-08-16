// PostHog capture payloads (M10): the shape is the contract — a wrong field
// name silently drops the event server-side.
import 'package:finswipe/analytics.dart' show buildCapture;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('capture payload carries token, event, distinct id, merged props', () {
    final p = buildCapture('view', 'user-42', {'story_id': 7});
    expect(p['api_key'], startsWith('phc_'));
    expect(p['event'], 'view');
    expect(p['distinct_id'], 'user-42');
    final props = p['properties'] as Map;
    expect(props['story_id'], 7);
    expect(props.containsKey('app_version'), isTrue);
  });

  test('props default to empty without losing app_version', () {
    final props = buildCapture('app_open', 'anon')['properties'] as Map;
    expect(props.keys, ['app_version']);
  });
}
