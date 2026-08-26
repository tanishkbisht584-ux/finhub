// Watchlist ranking floats followed-company stories within 6h bands only —
// chronology stays sacred at macro scale. orderSeed pins index 0, splits at
// the last-visit boundary, and gives the new segment the morning digest.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart'
    show isDigestMorning, orderSeed, rankStories;
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

  group('isDigestMorning', () {
    test('null stamp is not a digest morning', () {
      expect(isDigestMorning(null, DateTime.utc(2026, 8, 26, 6)), isFalse);
    });

    test('same IST day: false', () {
      expect(
          isDigestMorning(
              DateTime.utc(2026, 8, 26, 2), DateTime.utc(2026, 8, 26, 10)),
          isFalse);
    });

    test('crossing IST midnight (18:30 UTC) flips the day', () {
      // 18:00 UTC = 23:30 IST 26th; 19:00 UTC = 00:30 IST 27th.
      expect(
          isDigestMorning(
              DateTime.utc(2026, 8, 26, 18), DateTime.utc(2026, 8, 26, 19)),
          isTrue);
    });
  });

  group('orderSeed', () {
    final stamp = _base;
    final page = [
      _s(9, at: _base.subtract(const Duration(hours: 20))), // old featured pin
      _s(1, at: _base.add(const Duration(hours: 3)), impact: 4),
      _s(2, at: _base.add(const Duration(hours: 2)), impact: 9),
      _s(3, at: _base.add(const Duration(hours: 1)), impact: 9),
      _s(5, at: _base.subtract(const Duration(hours: 1))),
      _s(4, at: _base.subtract(const Duration(hours: 2)), companies: [7]),
    ];

    test('digest sorts the new segment by impact, ties keep recency', () {
      final out = orderSeed(page, lastSeen: stamp, digest: true);
      // Pin stays, new segment 2,3 (impact 9) before 1, old segment intact
      // order (5 newer than 4, same band, no watchlist).
      expect(_ids(out), [9, 2, 3, 1, 5, 4]);
    });

    test('no digest: both segments watchlist-ranked, boundary respected', () {
      final out = orderSeed(page, lastSeen: stamp, watchlist: {7});
      // New segment chronological (no hits); old segment floats 4 above 5
      // within their shared band; 4 never rises above the new segment.
      expect(_ids(out), [9, 1, 2, 3, 4, 5]);
    });

    test('single story and empty page are identity', () {
      expect(_ids(orderSeed([_s(1, at: _base)], digest: true)), [1]);
      expect(orderSeed(const [], digest: true), isEmpty);
    });
  });
}
