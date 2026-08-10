import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';

/// Spread-merges [current] with [key]: [value], leaving every other key —
/// notably the pipeline's `pa` per-user counters living in the same jsonb —
/// untouched.
Map<String, dynamic> mergedAlertSettings(
        Map current, String key, bool value) =>
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
          if (user != null) _AlertSettings(userId: user.id),
          const SizedBox(height: 32),
          Text('APP', style: mono.copyWith(fontSize: 12, letterSpacing: 1.2)),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => Supabase.instance.client.auth.signOut(),
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
class _AlertSettings extends StatefulWidget {
  const _AlertSettings({required this.userId});
  final String userId;

  @override
  State<_AlertSettings> createState() => _AlertSettingsState();
}

class _AlertSettingsState extends State<_AlertSettings> {
  late Future<Map<String, dynamic>> _load;

  @override
  void initState() {
    super.initState();
    _load = _fetch();
  }

  Future<Map<String, dynamic>> _fetch() async {
    final row = await Supabase.instance.client
        .from('profiles')
        .select('alert_settings')
        .eq('id', widget.userId)
        .maybeSingle();
    return (row?['alert_settings'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _load,
      builder: (context, snapshot) {
        final settings = snapshot.data ?? const {};
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
          _AlertToggle(
            title: 'Read the biggest stories aloud',
            settingsKey: 'voice_l1',
            settings: settings,
            userId: widget.userId,
          ),
          _AlertToggle(
            title: 'Alerts for my watchlist',
            settingsKey: 'personalized',
            settings: settings,
            userId: widget.userId,
          ),
        ]);
      },
    );
  }
}

class _AlertToggle extends StatefulWidget {
  const _AlertToggle({
    required this.title,
    required this.settingsKey,
    required this.settings,
    required this.userId,
  });

  final String title;
  final String settingsKey;
  final Map<String, dynamic> settings;
  final String userId;

  @override
  State<_AlertToggle> createState() => _AlertToggleState();
}

class _AlertToggleState extends State<_AlertToggle> {
  late Map<String, dynamic> _current = widget.settings;
  // Both alerts default ON when the key is absent from the jsonb.
  bool get _value => (_current[widget.settingsKey] as bool?) ?? true;

  Future<void> _toggle(bool v) async {
    final was = _current;
    final merged = mergedAlertSettings(_current, widget.settingsKey, v);
    setState(() => _current = merged);
    try {
      await Supabase.instance.client
          .from('profiles')
          .update({'alert_settings': merged}).eq('id', widget.userId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _current = was); // never leave a lie on screen
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update alert: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(widget.title, style: serif.copyWith(fontSize: 15)),
      value: _value,
      activeThumbColor: green,
      onChanged: _toggle,
    );
  }
}
