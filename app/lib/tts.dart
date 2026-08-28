import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// The app's one TTS voice — shared by L1 voice alerts (main.dart) and the
/// morning digest's play button. One engine so a new speak displaces the old
/// instead of talking over it.
final tts = FlutterTts();

/// Whether the digest brief is currently speaking; the play pill listens.
final speaking = ValueNotifier<bool>(false);

/// The 60-second brief: top digest stories as hook + why-it-matters lines.
/// Pure so it's testable; NULL why lines (old stories, weak lanes) fall back
/// to the hook alone.
String briefText(List<({String? hook, String? why})> items, {int top = 5}) {
  final lines = <String>[];
  for (final s in items.take(top)) {
    final hook = (s.hook ?? '').trim();
    final why = (s.why ?? '').trim();
    if (hook.isEmpty && why.isEmpty) continue;
    lines.add(why.isEmpty ? hook : '$hook. $why');
  }
  return lines.join('. ');
}

Future<void> speakBrief(String text) async {
  if (text.isEmpty) return;
  speaking.value = true;
  tts.setCompletionHandler(() => speaking.value = false);
  tts.setCancelHandler(() => speaking.value = false);
  await tts.speak(text);
}

Future<void> stopSpeaking() async {
  if (!speaking.value) return;
  speaking.value = false;
  await tts.stop();
}
