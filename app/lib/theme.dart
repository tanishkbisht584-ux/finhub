import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Build stamp, injected with --dart-define=APP_VERSION at build time.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// Legal pages. Empty until the Play listing's URLs exist — every render
/// site guards on isNotEmpty so no dead link ever ships.
const kTermsUrl = '';
const kPrivacyUrl = '';

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
/// aurora, no colour-by-category. Red/green only for direction — a tick, a
/// heat cell's growth, a period-on-period change — and on/off state. Tiles
/// and tables are bordered, square, and share one right edge (lib/ledger.dart).
/// Numbers monospace, the hook serif — it alone carries weight.

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

/// Section headers ("APP", "RECENT STORIES", explainer headings) — one style,
/// three screens were drifting between weights/sizes/letter-spacing.
final monoLabel = mono.copyWith(
    fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2);

/// The one spinner: 20px, hairline, green — the default 36px Material wheel
/// reads loud against the minimal ledger.
Widget appSpinner() => const SizedBox(
    width: 20,
    height: 20,
    child: CircularProgressIndicator(strokeWidth: 2, color: green));

final appTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: bg,
  colorScheme: const ColorScheme.dark(
    surface: bg,
    primary: green,
    error: red,
    // Without these, M3's lilac-tinted defaults leak: lavender nav-bar
    // labels and a light-grey SnackBar over the clay-black feed.
    onSurface: ink,
    onSurfaceVariant: inkDim,
  ),
  // Unstyled Text otherwise inherits pure #FFF — a colder, brighter second
  // ink next to everything that is explicitly `ink`.
  textTheme:
      Typography.material2021().white.apply(bodyColor: ink, displayColor: ink),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: surface,
    contentTextStyle: mono.copyWith(color: ink, fontSize: 13),
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: border)),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: bg,
    surfaceTintColor: bg,
    elevation: 0,
    iconTheme: IconThemeData(color: ink),
    titleTextStyle: TextStyle(fontFamily: 'serif', color: ink, fontSize: 18),
  ),
  // The app's actual button. Hand-styled copies at six call sites had
  // already split into two shapes; the theme is the single source now.
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: ink,
      side: const BorderSide(color: border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
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
