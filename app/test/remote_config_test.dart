import 'package:finswipe/remote_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('versionLess compares semver and ignores the build number', () {
    expect(versionLess('0.18.1+34', '0.18.2'), isTrue);
    expect(versionLess('0.18.1+34', '0.18.1'), isFalse);
    expect(versionLess('0.18.1', '0.18.1+99'), isFalse);
    expect(versionLess('0.9.0', '0.18.0'), isTrue); // numeric, not lexical
    expect(versionLess('1.0', '1.0.1'), isTrue); // missing part = 0
  });

  test('an unparseable side never walls anyone off', () {
    expect(versionLess('dev', '9.9.9'), isFalse);
    expect(versionLess('0.1.0', 'latest'), isFalse);
    expect(versionLess('', '1.0.0'), isFalse);
  });

  test('fromJson falls back field by field', () {
    expect(RemoteConfig.fromJson(null), RemoteConfig.defaults);
    final c = RemoteConfig.fromJson({
      'min_version': '0.19.0',
      'flags': {'qa_enabled': false, 'live_poll_seconds': 2, 'ambient_poll_seconds': '120'},
      'maintenance': 7, // wrong type -> default
    });
    expect(c.minVersion, '0.19.0');
    expect(c.qaEnabled, isFalse);
    expect(c.deepReadEnabled, isTrue);
    expect(c.livePollSeconds, 15); // below the 5 s floor -> default
    expect(c.ambientPollSeconds, 120); // numeric string accepted
    expect(c.maintenance, '');
    expect(c.forceUpdateMessage, RemoteConfig.defaults.forceUpdateMessage);
  });
}
