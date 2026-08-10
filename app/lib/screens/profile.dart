import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';

/// Spread-merges [current] with [key]: [value], leaving every other key —
/// notably the pipeline's `pa` per-user counters living in the same jsonb —
/// untouched.
Map<String, dynamic> mergedAlertSettings(
        Map<String, dynamic> current, String key, bool value) =>
    {...current, key: value};

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final name = (user?.userMetadata?['full_name'] as String?) ??
        user?.email ??
        'Signed in';
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(children: [
            _photo(user, name),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (user?.email != null)
                Text(user!.email!, style: mono.copyWith(fontSize: 12)),
            ]),
          ]),
          const SizedBox(height: 32),
          Text('ALERTS', style: mono.copyWith(fontSize: 12, letterSpacing: 1.2)),
          const SizedBox(height: 8),
          const Divider(height: 1),
          if (user != null) AlertSettingsSection(userId: user.id),
          const SizedBox(height: 32),
          Text('APP', style: mono.copyWith(fontSize: 12, letterSpacing: 1.2)),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: _signOut,
            style: OutlinedButton.styleFrom(
              foregroundColor: red,
              side: BorderSide(color: red.withValues(alpha: 0.5)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: const Text('Sign out'),
          ),
          const SizedBox(height: 32),
          Text(
            'FinSwipe explains news. It never gives investment advice. '
            'Consult a SEBI-registered advisor before investing.',
            style: mono.copyWith(fontSize: 11, height: 1.6),
          ),
          const SizedBox(height: 14),
          // The sign-in screen's version marker is invisible once you are
          // signed in, which is exactly when "which build am I on?" matters.
          Text('FinSwipe $appVersion',
              style: mono.copyWith(fontSize: 11, color: inkDim)),
        ],
      ),
    );
  }

  /// Best-effort clear the device token before signing out, so the next
  /// account on this (possibly shared) device doesn't inherit this
  /// account's live FCM token and never registers its own. Never blocks
  /// sign-out on it — a stale token just means a missed alert, not a stuck
  /// sign-out button.
  Future<void> _signOut() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid != null) {
      try {
        await Supabase.instance.client
            .from('profiles')
            .update({'fcm_token': null}).eq('id', uid);
      } catch (_) {}
    }
    await Supabase.instance.client.auth.signOut();
  }

  /// Google picture when there is one, initial when there isn't — same rule as
  /// the nav bar, so the two never disagree.
  Widget _photo(User? user, String name) {
    final meta = user?.userMetadata ?? const {};
    final url = (meta['avatar_url'] ?? meta['picture']) as String?;
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    final fallback = Container(
      color: surface,
      alignment: Alignment.center,
      child: Text(initial, style: serif.copyWith(fontSize: 22)),
    );
    return ClipOval(
      child: SizedBox(
        width: 52,
        height: 52,
        child: url == null || url.isEmpty
            ? fallback
            : Image.network(url,
                fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback),
      ),
    );
  }
}

/// Two alert toggles, backed by `profiles.alert_settings` jsonb. Loads once
/// on mount rather than per-build — a FutureBuilder here would refetch on
/// every rebuild the ListView triggers above it.
///
/// One `_current` map lives on this widget's state, not on the individual
/// toggles: two toggles each holding their own copy of the settings map go
/// stale the moment the *other* one writes, so the second flip merges from
/// an outdated map and silently reverts the first flip on the server.
class AlertSettingsSection extends StatefulWidget {
  const AlertSettingsSection({
    super.key,
    required this.userId,
    this.initial,
    this.fetcher,
    this.writer,
  });
  final String userId;

  /// Test seam: when set, skips the Supabase fetch and seeds `_current`
  /// with this map directly.
  final Map<String, dynamic>? initial;

  /// Test seam: when set, replaces the Supabase read `_fetch` performs — for
  /// the initial load (when [initial] is absent) and for the fresh re-read
  /// `_toggle` does before every write.
  final Future<Map<String, dynamic>> Function()? fetcher;

  /// Test seam: when set, replaces the Supabase `profiles.update` write —
  /// lets a widget test assert on the merged map without a live client.
  final Future<void> Function(Map<String, dynamic> merged)? writer;

  @override
  State<AlertSettingsSection> createState() => AlertSettingsSectionState();
}

class AlertSettingsSectionState extends State<AlertSettingsSection> {
  late Future<Map<String, dynamic>> _load;
  Map<String, dynamic> _current = {};

  @override
  void initState() {
    super.initState();
    _load = widget.initial != null ? Future.value(widget.initial) : _fetch();
    _load.then((v) {
      if (mounted) setState(() => _current = v);
    });
  }

  Future<Map<String, dynamic>> _fetch() async {
    if (widget.fetcher != null) return widget.fetcher!();
    final row = await Supabase.instance.client
        .from('profiles')
        .select('alert_settings')
        .eq('id', widget.userId)
        .maybeSingle();
    return (row?['alert_settings'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  Future<void> _write(Map<String, dynamic> merged) {
    if (widget.writer != null) return widget.writer!(merged);
    return Supabase.instance.client
        .from('profiles')
        .update({'alert_settings': merged}).eq('id', widget.userId);
  }

  /// Both alerts default ON when the key is absent from the jsonb.
  bool _value(String key) => (_current[key] as bool?) ?? true;

  Future<void> _toggle(String key, bool v) async {
    final was = _current;
    // Optimistic flip for the UI only. The WRITE below merges from a fresh
    // read instead of this snapshot: the pipeline rewrites alert_settings.pa
    // every 45s, so `_current` (fixed at initState) goes stale, and merging a
    // stale copy would rewind/delete `pa` — breaking the 5/day cap and
    // causing duplicate pushes.
    setState(() => _current = mergedAlertSettings(_current, key, v));
    Map<String, dynamic>? fresh;
    try {
      fresh = await _fetch();
    } catch (_) {
      fresh = null; // couldn't re-read: best effort, merge from the snapshot
    }
    final merged = mergedAlertSettings(fresh ?? _current, key, v);
    try {
      await _write(merged);
      if (mounted) setState(() => _current = merged); // fold fresh pa back in
    } catch (e) {
      if (!mounted) return;
      setState(() => _current = was); // never leave a lie on screen
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update alert: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _load,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('Could not load alert settings.',
                style: mono.copyWith(fontSize: 12, color: red)),
          );
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return Column(children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Read the biggest stories aloud',
                style: serif.copyWith(fontSize: 15)),
            value: _value('voice_l1'),
            activeThumbColor: green,
            onChanged: (v) => _toggle('voice_l1', v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Alerts for my watchlist',
                style: serif.copyWith(fontSize: 15)),
            value: _value('personalized'),
            activeThumbColor: green,
            onChanged: (v) => _toggle('personalized', v),
          ),
        ]);
      },
    );
  }
}
