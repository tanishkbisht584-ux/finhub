// Ask history: newest first, one entry per question, capped.
import 'package:finflick/screens/ask.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pushHistory puts the newest first and dedupes by question', () {
    var h = pushHistory(const [], 'Why is Nifty down?', {'tier': 1});
    h = pushHistory(h, 'What is CRR?', {'tier': 0});
    h = pushHistory(h, 'Why is Nifty down?', {'tier': 2}); // asked again
    expect([for (final e in h) e['q']], ['Why is Nifty down?', 'What is CRR?']);
    expect(h.first['raw'], {'tier': 2}); // the fresh answer wins
    expect(h.first['at'], isA<String>());
  });

  test('pushHistory caps the list', () {
    var h = <Map<String, dynamic>>[];
    for (var i = 0; i < 30; i++) {
      h = pushHistory(h, 'q$i', const {}, max: 20);
    }
    expect(h.length, 20);
    expect(h.first['q'], 'q29');
    expect(h.last['q'], 'q10');
  });
}
