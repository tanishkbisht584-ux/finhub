// The session recap page follows every 25th story, never sits at the list
// end, and never lands adjacent to the caught-up divider (sentinels must
// always follow a story). Content helpers are pure.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart'
    show
        FeedEntry,
        biggestMover,
        feedEntries,
        recapEvery,
        recordSessionView,
        sessionCategoryCounts,
        sessionSymbols,
        sessionViewedIds,
        topCategory;
import 'package:flutter_test/flutter_test.dart';

Story _s(int id, {DateTime? at, String? cat, List<String> symbols = const []}) =>
    Story.fromJson({
      'id': id,
      'headline': 'H$id',
      'hook': 'K$id',
      'summary': 'S.',
      'category': cat,
      'sectors': const [],
      if (at != null) 'published_at': at.toIso8601String(),
      'companies': [
        for (final (i, sym) in symbols.indexed)
          {'id': 100 * id + i, 'name': sym, 'nse_symbol': sym}
      ],
    });

bool _recapAt(List<FeedEntry> es, int i) => es[i].isRecap;

void main() {
  test('recap follows every 25th story, none at the list end', () {
    final es = feedEntries([for (var i = 1; i <= 30; i++) _s(i)], null, false);
    // 30 stories + 1 recap after the 25th.
    expect(es.length, 31);
    expect(_recapAt(es, recapEvery), isTrue); // index 25 = after story 25
    expect(es.last.story?.id, 30);

    // Exactly 25 stories: recap would be the last page — suppressed.
    final flat = feedEntries([for (var i = 1; i <= 25; i++) _s(i)], null, true);
    expect(flat.where((e) => e.isRecap), isEmpty);
  });

  test('recap suppressed when the divider sits at the same slot', () {
    final t = DateTime.utc(2026, 8, 26, 12);
    // 25 new stories then old ones: divider lands after story 25 — the recap
    // yields so two sentinels never sit adjacent.
    final stories = [
      for (var i = 1; i <= 25; i++) _s(i, at: t.add(Duration(minutes: i))),
      for (var i = 26; i <= 30; i++)
        _s(i, at: t.subtract(Duration(hours: i))),
    ];
    final es = feedEntries(stories, t, false);
    expect(es.where((e) => e.isRecap), isEmpty);
    expect(es[recapEvery].newCount, isNotNull); // the divider took the slot
  });

  test('session counters dedupe by id; topCategory and biggestMover', () {
    sessionViewedIds.clear();
    sessionCategoryCounts.clear();
    sessionSymbols.clear();

    recordSessionView(_s(1, cat: 'Markets', symbols: ['TCS']));
    recordSessionView(_s(1, cat: 'Markets')); // repeat view, no double count
    recordSessionView(_s(2, cat: 'IPO'));
    recordSessionView(_s(3, cat: 'Markets', symbols: ['INFY']));
    expect(sessionViewedIds.length, 3);
    expect(topCategory(sessionCategoryCounts), 'Markets');
    expect(sessionSymbols, {'TCS', 'INFY'});

    final ticks = {
      'TCS': Tick.fromJson({'symbol': 'TCS', 'change_pct': -3.2}),
      'INFY': Tick.fromJson({'symbol': 'INFY', 'change_pct': 1.1}),
    };
    final mover = biggestMover(sessionSymbols, ticks);
    expect(mover?.symbol, 'TCS');
    expect(mover?.pct, -3.2);
    expect(biggestMover({'ZZZ'}, ticks), isNull);
    expect(topCategory(const {}), isNull);
  });
}
