import 'package:finswipe/publishers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('faviconUrl keys on the article host and skips Google News proxies', () {
    expect(faviconUrl('https://economictimes.indiatimes.com/markets/x.cms'),
        'https://www.google.com/s2/favicons?domain=economictimes.indiatimes.com&sz=64');
    expect(faviconUrl('https://news.google.com/rss/articles/CBMi...'), isNull);
    expect(faviconUrl('https://www.google.com/url?q=x'), isNull);
    expect(faviconUrl(''), isNull);
    expect(faviconUrl('not a url'), isNull);
  });
}
