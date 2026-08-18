import 'package:finswipe/feed_cache.dart';
import 'package:finswipe/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Story survives null headline and source fields', () {
    final s = Story.fromJson({'id': 1});
    expect(s.headline, '');
    expect(s.sourceName, '');
    expect(s.sourceUrl, '');
  });

  test('QaAnswer.isBlank flags an all-defaulted 200 body', () {
    expect(QaAnswer.fromJson(const {}).isBlank, isTrue);
    expect(QaAnswer.fromJson(const {'refused': true}).isBlank, isFalse);
    expect(QaAnswer.fromJson(const {'why': 'x'}).isBlank, isFalse);
    expect(
        QaAnswer.fromJson(const {
          'sections': [
            {'heading': 'h', 'body': 'b'}
          ]
        }).isBlank,
        isFalse);
  });

  test('corrupt feed cache returns null and clears itself', () async {
    for (final garbage in ['not json', '{"a":1}', '[1,2,3]']) {
      SharedPreferences.setMockInitialValues({'feed_cache_v1': garbage});
      expect(await FeedCache.load(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('feed_cache_v1'), isNull,
          reason: 'self-heal must remove the bad payload: $garbage');
    }
  });

  test('valid feed cache round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    await FeedCache.save([
      {'id': 1, 'headline': 'h'}
    ]);
    final rows = await FeedCache.load();
    expect(rows, isNotNull);
    expect(rows!.single['headline'], 'h');
  });
}
