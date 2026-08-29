import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'theme.dart';

/// Remote config (admin → App Config page → app_config row 'app'), read once
/// at boot. Every field falls back to the compiled default, so a missing row,
/// a slow network or an older schema changes nothing — the app never waits on
/// it past [loadRemoteConfig]'s timeout and never crashes on it.
class RemoteConfig {
  const RemoteConfig({
    this.minVersion = '0.0.0',
    this.forceUpdateMessage = 'Please update FinSwipe to keep reading.',
    this.updateUrl = '',
    this.maintenance = '',
    this.deepReadEnabled = true,
    this.qaEnabled = true,
    this.screenerPageEnabled = true,
    this.liveDefault = true,
    this.livePollSeconds = 15,
    this.ambientPollSeconds = 90,
  });

  final String minVersion;
  final String forceUpdateMessage;
  final String updateUrl;
  final String maintenance;
  final bool deepReadEnabled;
  final bool qaEnabled;
  final bool screenerPageEnabled;
  final bool liveDefault;
  final int livePollSeconds;
  final int ambientPollSeconds;

  static const defaults = RemoteConfig();

  factory RemoteConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return defaults;
    final f = j['flags'] is Map ? Map<String, dynamic>.from(j['flags'] as Map) : const <String, dynamic>{};
    String str(dynamic v, String d) => v is String ? v : d;
    bool flag(String k, bool d) => f[k] is bool ? f[k] as bool : d;
    int secs(String k, int d, int min) {
      final v = f[k];
      final n = v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
      return n == null || n < min ? d : n;
    }
    return RemoteConfig(
      minVersion: str(j['min_version'], defaults.minVersion),
      forceUpdateMessage: str(j['force_update_message'], defaults.forceUpdateMessage),
      updateUrl: str(j['update_url'], defaults.updateUrl),
      maintenance: str(j['maintenance'], defaults.maintenance),
      deepReadEnabled: flag('deep_read_enabled', defaults.deepReadEnabled),
      qaEnabled: flag('qa_enabled', defaults.qaEnabled),
      screenerPageEnabled: flag('screener_page_enabled', defaults.screenerPageEnabled),
      liveDefault: flag('live_default', defaults.liveDefault),
      livePollSeconds: secs('live_poll_seconds', defaults.livePollSeconds, 5),
      ambientPollSeconds: secs('ambient_poll_seconds', defaults.ambientPollSeconds, 15),
    );
  }
}

RemoteConfig remoteConfig = RemoteConfig.defaults;

/// One select, bounded: 4 s on a cold start is the most a config read may
/// cost. Anything else (no row, no table, RLS, offline) keeps the defaults.
Future<void> loadRemoteConfig() async {
  try {
    final row = await Supabase.instance.client
        .from('app_config')
        .select('value')
        .eq('key', 'app')
        .maybeSingle()
        .timeout(const Duration(seconds: 4));
    final v = row?['value'];
    remoteConfig = RemoteConfig.fromJson(
        v is Map ? Map<String, dynamic>.from(v) : null);
  } catch (_) {
    remoteConfig = RemoteConfig.defaults;
  }
}

/// "0.18.1+34" -> [0, 18, 1]; anything non-numeric (e.g. 'dev') -> [].
List<int> versionParts(String v) {
  final core = v.split('+').first.trim();
  final parts = core.split('.').map(int.tryParse).toList();
  return parts.any((p) => p == null) || parts.isEmpty ? const [] : parts.cast<int>();
}

/// a < b by semver parts. An unparseable side is never "less" — a dev build
/// must not be walled off, and a garbage min_version must not wall anyone.
bool versionLess(String a, String b) {
  final x = versionParts(a), y = versionParts(b);
  if (x.isEmpty || y.isEmpty) return false;
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final xi = i < x.length ? x[i] : 0, yi = i < y.length ? y[i] : 0;
    if (xi != yi) return xi < yi;
  }
  return false;
}

bool get updateRequired => versionLess(appVersion, remoteConfig.minVersion);

/// The update wall: shown instead of the app when this build is below the
/// admin's minimum. No way past it but updating — that is the point.
class ForceUpdateScreen extends StatelessWidget {
  const ForceUpdateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final url = remoteConfig.updateUrl;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.system_update_alt, size: 40, color: inkDim),
            const SizedBox(height: 16),
            Text(remoteConfig.forceUpdateMessage, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('installed $appVersion · required ${remoteConfig.minVersion}',
                style: const TextStyle(color: inkDim, fontSize: 12)),
            if (url.isNotEmpty) ...[
              const SizedBox(height: 20),
              FilledButton(
                  onPressed: () => openExternal(context, url),
                  child: const Text('Update')),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Thin strip over the top of the shell while the admin's maintenance text
/// is non-empty. Informational only — nothing is disabled by it.
class MaintenanceBanner extends StatelessWidget {
  const MaintenanceBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Material(
        color: surface,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: border))),
          child: Text(remoteConfig.maintenance,
              style: const TextStyle(color: ink, fontSize: 12),
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}
