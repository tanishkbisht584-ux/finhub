import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'theme.dart' show appVersion;

/// Rows for one table, sent in a single insert instead of one per event.
/// A view row per swipe made `events` the hottest table in the project and
/// each swipe its own round trip on cellular; 1000 readers × 35 cards a day
/// is 35k inserts. Flushes at [max] rows, after [every], and when the feed
/// asks (app paused, sign-out).
/// ponytail: in-memory only — a force-kill loses <= [max] view rows, which is
/// bookkeeping, not data.
class EventBuffer {
  EventBuffer(this._send,
      {this.max = 20, this.every = const Duration(seconds: 30)});
  final Future<void> Function(List<Map<String, Object?>> rows) _send;
  final int max;
  final Duration every;
  final _rows = <Map<String, Object?>>[];
  Timer? _timer;

  int get pending => _rows.length;

  void add(Map<String, Object?> row) {
    _rows.add(row);
    _timer ??= Timer(every, flush);
    if (_rows.length >= max) flush();
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_rows.isEmpty) return;
    final batch = List<Map<String, Object?>>.of(_rows);
    _rows.clear();
    try {
      await _send(batch);
    } catch (_) {
      // Offline: bookkeeping lost, never an error surface.
    }
  }
}

/// The app's one buffer for `events` rows written from the client.
final viewEvents =
    EventBuffer((rows) => Supabase.instance.client.from('events').insert(rows));

/// PostHog capture, by hand (M10). The public project token can only WRITE
/// events — it reads nothing — which is why it may live in source and inside
/// the APK. The official SDK would add a dependency and native config for
/// features we don't use; one POST per event is the whole protocol.
const _phToken = 'phc_z3Z9CSbtH9QErQZXVVik8RnpTPpGyspG3KNBWSGoXzdh';
const _phHost = 'us.i.posthog.com';

/// The capture payload, pure and testable.
Map<String, Object?> buildCapture(String event, String distinctId,
        [Map<String, Object?> props = const {}]) =>
    {
      'api_key': _phToken,
      'event': event,
      'distinct_id': distinctId,
      'properties': {...props, 'app_version': appVersion},
    };

String analyticsDistinctId() =>
    Supabase.instance.client.auth.currentUser?.id ?? 'anon';

/// One long-lived client: a fresh HttpClient per event meant a full TCP+TLS
/// handshake per swipe (fifty swipes = fifty handshakes, radio held high on
/// cellular). Keep-alive reuses the connection; a single global can't leak.
final _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

/// Fire-and-forget: analytics must never slow a swipe or surface an error.
void track(String event, [Map<String, Object?> props = const {}]) {
  () async {
    try {
      final req = await _client.postUrl(Uri.https(_phHost, '/capture/'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(buildCapture(event, analyticsDistinctId(), props)));
      // connectionTimeout only bounds the connect; a stalled response would
      // otherwise hold its socket indefinitely.
      await (await req.close().timeout(const Duration(seconds: 10)))
          .drain<void>();
    } catch (_) {
      // Offline or PostHog down: the Supabase events table still has it.
    }
  }();
}
