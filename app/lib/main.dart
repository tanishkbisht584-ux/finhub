import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'analytics.dart';
import 'remote_config.dart';
import 'screens/ask.dart';
import 'screens/feed.dart';
import 'screens/interests.dart';
import 'screens/markets.dart';
import 'screens/profile.dart';
import 'screens/saved.dart';
import 'screens/watchlist.dart';
import 'share_palette.dart';
import 'screens/sign_in.dart';
import 'theme.dart';

// Injected at build time: flutter build apk --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabasePublishableKey =
    String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

final navigatorKey = GlobalKey<NavigatorState>();

void _openStory(RemoteMessage m) {
  final id = int.tryParse(m.data['story_id'] ?? '');
  if (id == null) return;
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid != null) {
    Supabase.instance.client
        .from('events')
        .insert({'user_id': uid, 'story_id': id, 'type': 'alert_open'}).then(
            (_) {},
            onError: (_) {});
    track('alert_open', {'story_id': id});
  }
  // Land in the feed itself, on that card, so the next swipe carries straight
  // on into the rest of the news. Pushing a detail screen put you in a box you
  // had to back out of before you could swipe at all.
  navigatorKey.currentState?.popUntil((r) => r.isFirst);
  homeTab.value = 0;
  pendingStory.value = id;
}

final _tts = FlutterTts();

/// L1 voice (spec §7): a foreground push with impact >= 9 speaks the hook —
/// ~3 s of on-device TTS, gated on the profile toggle, on by default.
Future<void> _maybeSpeak(RemoteMessage m) async {
  final score = int.tryParse(m.data['impact_score'] ?? '') ?? 0;
  final hook = m.data['hook'] ?? '';
  if (score < 9 || hook.isEmpty) return;
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid != null) {
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('alert_settings')
          .eq('id', uid)
          .maybeSingle();
      if (row?['alert_settings']?['voice_l1'] == false) return;
    } catch (_) {} // can't read the toggle -> default on (it's L1-rare)
  }
  await _tts.speak(hook);
}

// Set once the token's been pushed so AuthGate's per-rebuild call is a no-op
// after the first success — token refreshes go through the onTokenRefresh
// listener instead, not through this flag.
bool _fcmTokenSaved = false;

/// The pipeline needs the device token to send personalized alerts.
Future<void> _saveFcmToken() async {
  if (_fcmTokenSaved) return;
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return;
  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await Supabase.instance.client
          .from('profiles')
          .update({'fcm_token': token}).eq('id', uid);
      _fcmTokenSaved = true;
    }
  } catch (_) {} // no Firebase on this build/device — personalized just stays off
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Supabase.initialize(
        url: supabaseUrl, publishableKey: supabasePublishableKey);
    // Admin's remote config: kill switches, poll cadence, force-update floor.
    // Bounded to 4 s and never throws — defaults are the compiled values.
    await loadRemoteConfig();
    liveMode.value = remoteConfig.liveDefault;
  } catch (_) {
    // A broken build (missing --dart-define) or hostile boot environment:
    // a message beats the native crash screen.
    runApp(MaterialApp(
        theme: appTheme, // not a full-white Material-light crash screen
        home: const Scaffold(
            body: Center(
                child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('FinSwipe could not start — check for an update.',
              textAlign: TextAlign.center),
        )))));
    return;
  }
  // Decoded heroes are ~1.5MB each; the 100MB default kept ~50 cards' worth
  // of bitmaps alive on a 3GB phone. 32MB still holds a screenful + neighbors.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 32 << 20;
  RemoteMessage? initial;
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onMessageOpenedApp.listen(_openStory);
    // Only getInitialMessage is on the deep-link path. requestPermission
    // blocks on the Android 13+ OS dialog and subscribeToTopic is a network
    // round trip — neither belongs before the first frame.
    initial = await FirebaseMessaging.instance.getInitialMessage();
    FirebaseMessaging.onMessage.listen(_maybeSpeak);
    FirebaseMessaging.instance.onTokenRefresh.listen((_) {
      _fcmTokenSaved = false;
      _saveFcmToken();
    });
    FirebaseMessaging.instance
        .requestPermission()
        .then((_) => FirebaseMessaging.instance.subscribeToTopic('alerts'))
        .then((_) {}, onError: (_) {});
  } catch (_) {
    // no google-services / Play Services: app works, alerts don't arrive
  }
  track('app_open');
  runApp(const ProviderScope(child: FinSwipeApp()));
  // App killed, opened via notification tap: navigatorKey has no live
  // NavigatorState until the first frame is up, so the push has to wait.
  if (initial != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _openStory(initial!));
  }
}

class FinSwipeApp extends StatelessWidget {
  const FinSwipeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'FinSwipe',
      theme: appTheme,
      debugShowCheckedModeBanner: false,
      // Below the admin's minimum version: the update wall, nothing else.
      home: updateRequired ? const ForceUpdateScreen() : const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  /// null = unknown yet; checked once per signed-in session. Errors count as
  /// "has interests" — a flaky network must never re-run onboarding.
  bool? _needsInterests;
  bool _profileEnsured = false;

  /// saves/events carry a foreign key to profiles, so without this row every
  /// save silently fails. Safe to call on each launch — it upserts.
  Future<void> _ensureProfile(User user) async {
    if (_profileEnsured) return; // build() re-fires this on every rebuild
    try {
      await Supabase.instance.client.from('profiles').upsert({
        'id': user.id,
        'display_name': user.userMetadata?['full_name'] ?? user.email,
        // version telemetry for the admin (which builds are in the wild)
        'app_version': appVersion,
        'last_seen_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'id');
      _profileEnsured = true;
    } catch (_) {
      // offline or transient: saves retry the upsert themselves
    }
  }

  Future<void> _checkInterests(User user) async {
    if (_needsInterests != null) return;
    try {
      final rows = await Supabase.instance.client
          .from('follows')
          .select('target_id')
          .eq('user_id', user.id)
          .limit(1);
      if (mounted) setState(() => _needsInterests = rows.isEmpty);
    } catch (_) {
      if (mounted) setState(() => _needsInterests = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null) {
          _needsInterests = null;
          // A device-shared user's next account must register its own token
          // and profile row, not inherit the previous account's.
          _fcmTokenSaved = false;
          _profileEnsured = false;
          return const SignInScreen();
        }
        _ensureProfile(session.user);
        _checkInterests(session.user);
        _saveFcmToken();
        if (_needsInterests == null) {
          return Scaffold(body: Center(child: appSpinner()));
        }
        if (_needsInterests == true) {
          return InterestsScreen(
              onDone: () => setState(() => _needsInterests = false));
        }
        return const HomeShell();
      },
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  int _tab = homeTab.value;

  // Same hold-and-slide as the card's bookmark, hung off the News tab so the
  // Saved panel has a way in that does not depend on finding a story first.
  static const _tileSize = 46.0;
  static const _tileGap = 10.0;
  static const _stepPx = 84.0;
  int? _active;
  Offset? _origin;
  late final AnimationController _ribbon = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 200));

  @override
  void initState() {
    super.initState();
    homeTab.addListener(_syncTab);
  }

  void _syncTab() {
    if (mounted) setState(() => _tab = homeTab.value);
  }

  @override
  void dispose() {
    homeTab.removeListener(_syncTab);
    _ribbon.dispose();
    super.dispose();
  }

  void _open(Offset origin) {
    HapticFeedback.mediumImpact();
    _origin = origin;
    setState(() => _active = defaultRibbonTarget);
    _ribbon.forward();
  }

  void _track(Offset global) {
    if (_origin == null) return;
    final next =
        (defaultRibbonTarget + ((global.dy - _origin!.dy) / _stepPx).round())
            .clamp(0, ribbonTargets.length - 1);
    if (next != _active) {
      HapticFeedback.selectionClick();
      setState(() => _active = next);
    }
  }

  Future<void> _close({bool commit = false}) async {
    final chosen = _active;
    await _ribbon.reverse();
    if (!mounted) return;
    setState(() => _active = null);
    if (!commit || chosen == null) return;
    final id = ribbonTargets[chosen].id;
    if (id != 'saved' && id != 'watchlist') return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
              appBar: AppBar(
                  backgroundColor: bg,
                  surfaceTintColor: bg,
                  elevation: 0,
                  leading: const BackButton(color: ink)),
              body:
                  id == 'saved' ? const SavedScreen() : const WatchlistScreen(),
            )));
  }

  @override
  Widget build(BuildContext context) {
    // Back on Ask/Profile returns to News instead of exiting the app; back
    // on News (deep read handles its own case) exits as usual. Deep read is
    // only reachable on tab 0, so the two PopScopes never fight over a pop.
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _tab != 0) homeTab.value = 0;
      },
      child: Scaffold(
        body: Stack(children: [
          IndexedStack(
            index: _tab,
            children: const [
              FeedScreen(),
              MarketsScreen(),
              AskScreen(),
              ProfileScreen()
            ],
          ),
          IgnorePointer(
            child: FadeTransition(
              opacity: Tween<double>(begin: 0, end: 0.55).animate(_ribbon),
              child: Container(color: bg),
            ),
          ),
          Positioned(
            left: 22,
            bottom: 12,
            child: IgnorePointer(
              child: RibbonColumn(
                animation: _ribbon,
                activeIndex: _active,
                tileSize: _tileSize,
                gap: _tileGap,
              ),
            ),
          ),
          if (remoteConfig.maintenance.isNotEmpty)
            const Positioned(
                left: 0, right: 0, top: 0, child: MaintenanceBanner()),
        ]),
        // News · Markets · Ask · Profile (homeTabLabels). Saved is not a
        // destination: it is a place you visit occasionally, so it hangs off
        // the bookmark on a card, where the thought "I want my saved ones"
        // actually occurs. Markets earned a tab because "what is the market
        // doing" is asked as often as "what happened".
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => homeTab.value = i,
          destinations: [
            NavigationDestination(
                icon: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPressStart: (d) => _open(d.globalPosition),
                  onLongPressMoveUpdate: (d) => _track(d.globalPosition),
                  onLongPressEnd: (_) => _close(commit: true),
                  onLongPressCancel: () => _close(),
                  child: Icon(
                      _tab == 0 ? Icons.newspaper : Icons.newspaper_outlined),
                ),
                label: 'News'),
            NavigationDestination(
                icon: Icon(_tab == marketsTab
                    ? Icons.show_chart
                    : Icons.show_chart_outlined),
                label: 'Markets'),
            const NavigationDestination(icon: Icon(Icons.search), label: 'Ask'),
            NavigationDestination(icon: const _Avatar(), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}

/// The signed-in user's Google picture, falling back to their initial when
/// there is no photo or it fails to load — a broken image icon in the nav bar
/// would look like the app itself is broken.
class _Avatar extends StatelessWidget {
  const _Avatar();

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final meta = user?.userMetadata ?? const {};
    final url = (meta['avatar_url'] ?? meta['picture']) as String?;
    final name =
        (meta['full_name'] ?? meta['name'] ?? user?.email ?? '?') as String;
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();

    return ClipOval(
      child: SizedBox(
        width: 26,
        height: 26,
        child: url == null || url.isEmpty
            ? _initialAvatar(initial)
            : Image.network(url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _initialAvatar(initial)),
      ),
    );
  }

  Widget _initialAvatar(String initial) => Container(
        color: surface,
        alignment: Alignment.center,
        child: Text(initial,
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: inkDim)),
      );
}
