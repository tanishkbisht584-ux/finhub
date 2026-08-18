import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Build stamp, injected with --dart-define=APP_VERSION at build time.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// launchUrl throws synchronously on a malformed stored URL and with a
/// PlatformException when nothing handles the scheme; every tap site was bare,
/// so a bad row made taps die silently. One guarded door for all of them.
Future<void> openExternal(BuildContext context, String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }
}

/// Minimal ledger (docs/mockups/finswipe-minimal-mockup.png): no blur, no
/// aurora, no colour-by-category. Red/green only for market direction and
/// on/off state. Numbers monospace, the hook serif — it alone carries weight.

const bg = Color(0xFF0E100F);
const surface = Color(0xFF161917);
const border = Color(0xFF272B28);
const ink = Color(0xFFE8E6E3);
const inkDim = Color(0xFF9BA09C);
const green = Color(0xFF3ECF8E);
const red = Color(0xFFE5484D);
const amber = Color(0xFFE2B93B);

Color directionColor(String? direction) => switch (direction) {
      'positive' => green,
      'negative' => red,
      'mixed' => amber,
      _ => inkDim,
    };

/// High impact burns ember; the rest stays quiet.
Color impactColor(int? score) => (score ?? 0) >= 8 ? red : inkDim;

const serif = TextStyle(fontFamily: 'serif', color: ink);
const mono = TextStyle(fontFamily: 'monospace', color: inkDim);

final appTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: bg,
  colorScheme: const ColorScheme.dark(
    surface: bg,
    primary: green,
    error: red,
  ),
  dividerColor: border,
  useMaterial3: true,
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: surface,
    indicatorColor: green.withValues(alpha: 0.15),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: green,
      foregroundColor: const Color(0xFF0B2417),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(fontWeight: FontWeight.w600),
    ),
  ),
);
