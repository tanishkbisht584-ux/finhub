import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/ask.dart';
import 'screens/feed.dart';
import 'screens/interests.dart';
import 'screens/profile.dart';
import 'screens/saved.dart';
import 'screens/watchlist.dart';
import 'share_palette.dart';
import 'screens/sign_in.dart';
import 'theme.dart';

// Injected at build time: flutter build apk --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabasePublishableKey);
  runApp(const ProviderScope(child: FinSwipeApp()));
}

class FinSwipeApp extends StatelessWidget {
  const FinSwipeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FinSwipe',
      theme: appTheme,
      debugShowCheckedModeBanner: false,
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  /// null = unknown yet; checked once per app start. Errors count as "has
  /// interests" — a flaky network must never re-run onboarding.
  bool? _needsInterests;

  /// saves/events carry a foreign key to profiles, so without this row every
  /// save silently fails. Safe to call on each launch — it upserts.
  Future<void> _ensureProfile(User user) async {
    try {
      await Supabase.instance.client.from('profiles').upsert({
        'id': user.id,
        'display_name': user.userMetadata?['full_name'] ?? user.email,
      }, onConflict: 'id');
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
        if (session == null) return const SignInScreen();
        _ensureProfile(session.user);
        _checkInterests(session.user);
        if (_needsInterests == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
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
  int _tab = 0;

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
  void dispose() {
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
    final next = (defaultRibbonTarget + ((global.dy - _origin!.dy) / _stepPx).round())
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
              body: id == 'saved' ? const SavedScreen() : const WatchlistScreen(),
            )));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        IndexedStack(
          index: _tab,
          children: const [FeedScreen(), AskScreen(), ProfileScreen()],
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
      ]),
      // Three destinations, not four: Saved is a place you visit occasionally,
      // not a peer of the feed. It now hangs off the bookmark on a card, where
      // the thought "I want my saved ones" actually occurs.
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
              icon: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: (d) => _open(d.globalPosition),
                onLongPressMoveUpdate: (d) => _track(d.globalPosition),
                onLongPressEnd: (_) => _close(commit: true),
                onLongPressCancel: () => _close(),
                child: Icon(_tab == 0
                    ? Icons.newspaper
                    : Icons.newspaper_outlined),
              ),
              label: 'News'),
          const NavigationDestination(
              icon: Icon(Icons.search), label: 'Ask'),
          NavigationDestination(icon: const _Avatar(), label: 'Profile'),
        ],
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
    final name = (meta['full_name'] ?? meta['name'] ?? user?.email ?? '?') as String;
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
