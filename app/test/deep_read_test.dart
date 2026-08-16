// Deep read contract (spec 2026-08-16): pages of {heading, body}; a refusal
// or truncated payload degrades to zero pages, never a crash.
import 'package:finswipe/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses pages with heading and body', () {
    final d = DeepRead.fromJson({
      'pages': [
        {'heading': 'What happened', 'body': 'The RBI cut rates.'},
        {'heading': null, 'body': 'More detail.'},
      ]
    });
    expect(d.pages.length, 2);
    expect(d.pages.first.heading, 'What happened');
    expect(d.pages[1].heading, isNull);
    expect(d.hasContent, isTrue);
  });

  test('refusal, null and garbage all degrade to empty', () {
    expect(DeepRead.fromJson({'pages': []}).hasContent, isFalse);
    expect(DeepRead.fromJson(null).hasContent, isFalse);
    expect(DeepRead.fromJson({'pages': 'junk'}).hasContent, isFalse);
    // a page without a body is dropped, not rendered blank
    final d = DeepRead.fromJson({'pages': [{'heading': 'x'}, {'body': 'ok'}]});
    expect(d.pages.length, 1);
    expect(d.pages.first.body, 'ok');
  });
}
