import 'dart:convert';

import 'package:finflick/models.dart';
import 'package:finflick/saved_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Story _story(int id, {String? hook}) => Story.fromJson({
      'id': id,
      'hook': hook ?? 'Hook $id',
      'headline': 'Headline $id',
      'summary': 'Summary.',
      'impact_score': 7,
      'impact_direction': 'up',
      'source_name': 'Mint',
      'source_url': 'https://example.com/$id',
      'category': 'markets',
      'sectors': ['it', 'banks'],
      'published_at': '2026-09-26T10:00:00Z',
      'outlets': [
        {'source_name': 'ET', 'source_url': 'https://et/$id', 'published_at': '2026-09-26T09:00:00Z', 'headline': 'ET take'}
      ],
      'companies': [
        {'id': 5, 'name': 'TCS', 'nse_symbol': 'TCS'}
      ],
      'why_it_matters': 'because',
      'is_featured': true,
    });

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Story.toJson round-trips through fromJson, outlets and companies included', () {
    final s = _story(1);
    final back = Story.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(back.id, 1);
    expect(back.hook, 'Hook 1');
    expect(back.sectors, ['it', 'banks']);
    expect(back.publishedAt, s.publishedAt);
    expect(back.outlets.single.headline, 'ET take');
    expect(back.companies.single.nseSymbol, 'TCS');
    expect(back.whyItMatters, 'because');
    expect(back.isFeatured, isTrue);
  });

  test('toggle persists and a fresh store reloads it from prefs, newest first', () async {
    final a = SavedStore(uid: 'u1', cloudFetch: () async => const []);
    await a.load();
    expect(await a.toggle(_story(1)), isTrue);
    expect(await a.toggle(_story(2)), isTrue);
    expect(a.state.map((s) => s.id), [2, 1]);
    expect(await a.toggle(_story(1)), isFalse);
    final b = SavedStore(uid: 'u1', cloudFetch: () async => throw StateError('must not import again'));
    await b.load();
    expect(b.state.map((s) => s.id), [2]);
    expect(b.contains(2), isTrue);
  });

  test('accounts are isolated and a signed-out store is empty and inert', () async {
    final a = SavedStore(uid: 'u1', cloudFetch: () async => const []);
    await a.load();
    await a.save(_story(9));
    final other = SavedStore(uid: 'u2', cloudFetch: () async => const []);
    await other.load();
    expect(other.state, isEmpty);
    final out = SavedStore(uid: null);
    await out.load();
    await out.save(_story(9));
    expect(out.state, isEmpty);
  });

  test('first run imports the cloud list once, even when empty', () async {
    var calls = 0;
    final a = SavedStore(uid: 'u3', cloudFetch: () async {
      calls++;
      return [_story(7), _story(8)];
    });
    await a.load();
    expect(a.state.map((s) => s.id), [7, 8]);
    await a.load();
    expect(calls, 1);

    var emptyCalls = 0;
    final e = SavedStore(uid: 'u4', cloudFetch: () async {
      emptyCalls++;
      return const [];
    });
    await e.load();
    await e.load();
    expect(emptyCalls, 1); // the key is written even when nothing came back
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('saved_stories_v1_u4'), '[]');
  });

  test('cap drops the oldest', () async {
    final a = SavedStore(uid: 'u5', cloudFetch: () async => const [], cap: 3);
    await a.load();
    for (var i = 1; i <= 5; i++) {
      await a.save(_story(i));
    }
    expect(a.state.map((s) => s.id), [5, 4, 3]);
  });
}
