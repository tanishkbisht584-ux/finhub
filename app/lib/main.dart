import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/ask.dart';
import 'screens/feed.dart';
import 'screens/profile.dart';
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

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

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

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null) return const SignInScreen();
        _ensureProfile(session.user);
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

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [FeedScreen(), AskScreen(), ProfileScreen()],
      ),
      // Three destinations, not four: Saved is a place you visit occasionally,
      // not a peer of the feed. It now hangs off the bookmark on a card, where
      // the thought "I want my saved ones" actually occurs.
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.newspaper_outlined),
              selectedIcon: Icon(Icons.newspaper),
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
