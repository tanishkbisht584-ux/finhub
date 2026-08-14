// Infinite feed (owner 2026-08-14): endless while there is news — older
// pages join at the bottom, fresh arrivals slot in at the top without
// yanking the card being read — and an honest end when the 48h window is
// drained. The merge is the logic; it must never duplicate a card.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show mergeStories, insertFresh;
import 'package:flutter_test/flutter_test.dart';

Story _s(int id, String at) => Story.fromJson({
      'id': id,
      'headline': 'H$id',
      'source_name': 'ET',
      'source_url': 'https://e.co/$id',
      'sectors': const [],
      'published_at': at,
    });

void main() {
  test('older page appends at the bottom, overlap deduped by id', () {
    final current = [_s(3, '2026-08-14T09:00:00Z'), _s(2, '2026-08-14T08:00:00Z')];
    final page = [_s(2, '2026-08-14T08:00:00Z'), _s(1, '2026-08-14T07:00:00Z')];
    final merged = mergeStories(current, page);
    expect(merged.map((s) => s.id), [3, 2, 1]);
  });

  test('fresh arrivals join at the top, deduped, order kept', () {
    final current = [_s(3, '2026-08-14T09:00:00Z')];
    final fresh = [_s(5, '2026-08-14T09:20:00Z'), _s(4, '2026-08-14T09:10:00Z'),
                   _s(3, '2026-08-14T09:00:00Z')];
    final merged = mergeStories(current, fresh, atTop: true);
    expect(merged.map((s) => s.id), [5, 4, 3]);
  });

  test('pure no-op when the page brings nothing new', () {
    final current = [_s(2, '2026-08-14T08:00:00Z')];
    expect(mergeStories(current, [_s(2, '2026-08-14T08:00:00Z')]).length, 1);
    expect(mergeStories(current, const []).map((s) => s.id), [2]);
  });

  test('fresh cards become the very NEXT swipe after the anchor card', () {
    // Owner 2026-08-14: "swipe a story, recent news comes, next swipe shows
    // the latest card" — fresh inserts right after the card on screen.
    final feed = [_s(3, '2026-08-14T09:00:00Z'), _s(2, '2026-08-14T08:00:00Z'),
                  _s(1, '2026-08-14T07:00:00Z')];
    final fresh = [_s(9, '2026-08-14T09:30:00Z'), _s(8, '2026-08-14T09:25:00Z')];
    // reading card 2 -> fresh lands between 2 and 1
    expect(insertFresh(feed, fresh, 2).map((s) => s.id), [3, 2, 9, 8, 1]);
    // no anchor (feed not started) -> top
    expect(insertFresh(feed, fresh, null).map((s) => s.id), [9, 8, 3, 2, 1]);
    // anchor card gone (merged away) -> top, never lost
    expect(insertFresh(feed, fresh, 77).map((s) => s.id), [9, 8, 3, 2, 1]);
    // already-known ids never duplicate
    expect(insertFresh(feed, [_s(3, '2026-08-14T09:00:00Z')], 2).length, 3);
  });

  test('Story parses published_at for the pagination cursor', () {
    expect(_s(1, '2026-08-14T07:00:00Z').publishedAt,
        DateTime.utc(2026, 8, 14, 7));
    final bare = Story.fromJson({'id': 2, 'headline': 'x',
        'source_name': 'ET', 'source_url': 'https://e.co', 'sectors': null});
    expect(bare.publishedAt, isNull);
  });
}
