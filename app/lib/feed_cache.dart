import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Last good feed, kept on the device.
///
/// Without this a flaky train tunnel turns the app into an error screen: the
/// query throws, Riverpod surfaces the error, and yesterday's perfectly
/// readable news is thrown away. Degrading to a saved copy is strictly better
/// than degrading to nothing.
class FeedCache {
  static const _key = 'feed_cache_v1';
  static const _stampKey = 'feed_cache_at_v1';

  static Future<void> save(List<Map<String, dynamic>> rows) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(rows));
    await prefs.setInt(_stampKey, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<List<Map<String, dynamic>>?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      // Materialize eagerly: .cast() is a lazy view whose element-type errors
      // would escape this try and detonate later in Story.fromJson, where the
      // self-heal below can't reach them.
      return [
        for (final e in jsonDecode(raw) as List) Map<String, dynamic>.from(e as Map)
      ];
    } catch (_) {
      await prefs.remove(_key); // corrupt cache heals itself on next refresh
      return null;
    }
  }

  /// When the cache was written, for the "showing saved copy" line.
  static Future<DateTime?> savedAt() async {
    final ms = (await SharedPreferences.getInstance()).getInt(_stampKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }
}
