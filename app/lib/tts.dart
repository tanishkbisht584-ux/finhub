import 'package:flutter_tts/flutter_tts.dart';

/// The app's one TTS voice — L1 voice alerts (main.dart). One engine so a
/// new speak displaces the old instead of talking over it.
final tts = FlutterTts();
