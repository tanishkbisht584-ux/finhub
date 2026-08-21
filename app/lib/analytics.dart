import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'theme.dart' show appVersion;

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
