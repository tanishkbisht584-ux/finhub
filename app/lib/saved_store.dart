import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

/// Saved stories live on the phone (26 Sep 2026), not in the `saves` table:
/// no round trip per save, the Saved screen works offline, and the daily
/// retention sweep no longer has to keep old story rows alive for them. One
/// SharedPreferences key per account, newest first.
/// ponytail: capped at [cap] cards — the oldest drops off; nobody curates 200.
class SavedStore extends StateNotifier<List<Story>> {
  SavedStore({this.uid, this.cloudFetch, this.cap = 200}) : super(const []);

  /// Account the list belongs to; null = signed out (always empty, read-only).
  final String? uid;

  /// One-time import of the old cloud list; injected in tests.
  final Future<List<Story>> Function()? cloudFetch;
  final int cap;

  String get _key => 'saved_stories_v1_$uid';

  bool contains(int id) => state.any((s) => s.id == id);

  Future<void> load() async {
    if (uid == null) {
      state = const [];
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        state = _decode(raw);
        return;
      }
      // First run on this phone for this account: bring the old cloud saves
      // across once, then write the key (even empty) so this never runs again.
      var imported = const <Story>[];
      try {
        imported = await (cloudFetch ?? _fetchCloud)();
      } catch (_) {}
      state = imported.take(cap).toList();
      await prefs.setString(_key, _encode(state));
    } catch (_) {
      // prefs unavailable (private mode, corrupt): stay empty rather than crash
    }
  }

  Future<void> save(Story s) async {
    if (uid == null) return;
    state = [s, ...state.where((x) => x.id != s.id)].take(cap).toList();
    await _persist();
  }

  Future<void> unsave(int id) async {
    if (uid == null) return;
    state = [for (final x in state) if (x.id != id) x];
    await _persist();
  }

  /// Returns the new saved state.
  Future<bool> toggle(Story s) async {
    if (contains(s.id)) {
      await unsave(s.id);
      return false;
    }
    await save(s);
    return true;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, _encode(state));
    } catch (_) {}
  }

  static String _encode(List<Story> list) => jsonEncode([for (final s in list) s.toJson()]);

  static List<Story> _decode(String raw) {
    try {
      return [
        for (final r in jsonDecode(raw) as List) Story.fromJson(Map<String, dynamic>.from(r as Map))
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Story>> _fetchCloud() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await Supabase.instance.client
        .from('saves')
        .select('stories($storyCols)')
        .eq('user_id', uid)
        .order('saved_at', ascending: false)
        .limit(100);
    return rows.map((r) => r['stories']).whereType<Map<String, dynamic>>().map(Story.fromJson).toList();
  }
}

/// The app's saved list. Re-created on sign-in / sign-out because it watches
/// the auth state; `load()` runs on creation.
final savedProvider = StateNotifierProvider<SavedStore, List<Story>>((ref) {
  String? uid;
  try {
    uid = Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {
    uid = null; // tests without Supabase
  }
  final store = SavedStore(uid: uid);
  store.load();
  return store;
});
