// EventBuffer: view rows leave in one insert per 20 cards / 30 s / flush,
// never one per swipe.
import 'package:fake_async/fake_async.dart';
import 'package:finflick/analytics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('flushes at max rows in one send', () {
    final sent = <List<Map<String, Object?>>>[];
    final b = EventBuffer((rows) async => sent.add(rows), max: 20);
    for (var i = 0; i < 20; i++) {
      b.add({'story_id': i});
    }
    expect(sent.length, 1);
    expect(sent.single.length, 20);
    expect(b.pending, 0);
  });

  test('a lone row leaves after the timer, not before', () {
    fakeAsync((async) {
      final sent = <List<Map<String, Object?>>>[];
      final b = EventBuffer((rows) async => sent.add(rows),
          every: const Duration(seconds: 30));
      b.add({'story_id': 1});
      async.elapse(const Duration(seconds: 29));
      expect(sent, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(sent.length, 1);
      expect(sent.single, [
        {'story_id': 1}
      ]);
    });
  });

  test('empty flush sends nothing; a failing send is swallowed', () async {
    var calls = 0;
    final b = EventBuffer((rows) async {
      calls++;
      throw StateError('offline');
    });
    await b.flush();
    expect(calls, 0);
    b.add({'story_id': 1});
    await b.flush(); // must not throw
    expect(calls, 1);
    expect(b.pending, 0);
  });
}
