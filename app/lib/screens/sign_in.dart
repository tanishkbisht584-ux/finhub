import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';

class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key});

  Future<void> _google(BuildContext context) async {
    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'finswipe://login-callback',
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
    } on AuthException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: aurora('Markets'),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('FinSwipe',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 42, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('Understand market news in 15 seconds',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
            const SizedBox(height: 48),
            FilledButton.icon(
              onPressed: () => _google(context),
              icon: const Icon(Icons.login),
              label: const Text('Continue with Google'),
            ),
            const SizedBox(height: 24),
            Text('Not investment advice.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: Colors.white.withValues(alpha: 0.5))),
          ],
        ),
      ),
    );
  }
}
