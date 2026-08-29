// Watchlist ranking floats followed-company stories within 6h bands only —
// chronology stays sacred at macro scale. orderSeed keeps the page newest
// first (SQL order), split at the last-visit boundary.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show orderSeed, rankStories;
import 'package:flutter_test/flutter_test.dart';

// Fixed base keeps every story inside deterministic 6h epoch bands.
final _base = DateTime.utc(2026, 8, 26, 12); // 12:00 UTC = band edge

Story _s(int id,
        {DateTime? at, List<int> companies = const [], int? impact}) =>
    Story.fromJson({
      'id': id,
      'headline': 'H$id',
      'hook': 'K$id',
      'summary': 'S.',
      'impact_score': impact,
      'sectors': const [],
      if (at != null) 'published_at': at.toIso8601String(),
      'companies': [
        for (final c in companies)
          {'id': c, 'name': 'C$c', 'nse_symbol': 'SYM$c'}
      ],
    });

List<int> _ids(List<Story> l) => [for (final s in l) s.id];

void main() {
  group('rankStories', () {
    test('empty watchlist is identity', () {
      final l = [_s(1, at: _base), _s(2, at: _base, companies: [7])];
      expect(rankStories(l, {}), same(l));
    });

    test('watchlist story floats to its band top, stable otherwise', () {
      final l = [
        _s(1, at: _base.add(const Duration(hours: 5))),
        _s(2, at: _base.add(const Duration(hours: 4))),
        _s(3, at: _base.add(const Duration(hours: 3)), companies: [7]),
        _s(4, at: _base.add(const Duration(hours: 2))),
      ];
      expect(_ids(rankStories(l, {7})), [3, 1, 2, 4]);
    });

    test('no cross-band jump: a hit stays under a newer band', () {
      final l = [
        _s(1, at: _base.add(const Duration(hours: 7))), // next band
        _s(2, at: _base.add(const Duration(hours: 1))),
        _s(3, at: _base, companies: [7]),
      ];
      expect(_ids(rankStories(l, {7})), [1, 3, 2]);
    });

    test('null publishedAt sinks below everything', () {
      final l = [_s(1, companies: [7]), _s(2, at: _base)];
      expect(_ids(rankStories(l, {7})), [2, 1]);
    });
  });

  group('orderSeed', () {
    final stamp = _base;
    // Page as SQL delivers it: published_at desc, no featured pin.
    final page = [
      _s(1, at: _base.add(const Duration(hours: 3))),
      _s(2, at: _base.add(const Duration(hours: 2))),
      _s(3, at: _base.add(const Duration(hours: 1))),
      _s(5, at: _base.subtract(const Duration(hours: 1))),
      _s(4, at: _base.subtract(const Duration(hours: 2)), companies: [7]),
      _s(9, at: _base.subtract(const Duration(hours: 20))),
    ];

    test('newest first, boundary respected, watchlist floats within band', () {
      final out = orderSeed(page, lastSeen: stamp, watchlist: {7});
      // New segment chronological (no hits); old segment floats 4 above 5
      // within their shared band; 4 never rises above the new segment.
      expect(_ids(out), [1, 2, 3, 4, 5, 9]);
    });

    test('empty watchlist keeps SQL order untouched', () {
      expect(_ids(orderSeed(page, lastSeen: stamp)), [1, 2, 3, 5, 4, 9]);
    });

    test('an old story never leads while fresh ones exist', () {
      // Even fed out of order (the retired featured pin scenario), the fresh
      // stories come first.
      final pinned = [page.last, ...page.sublist(0, page.length - 1)];
      expect(_ids(orderSeed(pinned, lastSeen: stamp)).first, 1);
    });

    test('single story and empty page are identity', () {
      expect(_ids(orderSeed([_s(1, at: _base)])), [1]);
      expect(orderSeed(const []), isEmpty);
    });
  });
}
