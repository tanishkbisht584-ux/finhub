import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';

class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key});

  Future<void> _google(BuildContext context) async {
    // signInWithOAuth returns false (no throw) when the browser launch fails,
    // so a silent failure needs the fallback + explicit message below.
    try {
      var ok = await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'finswipe://login-callback',
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      if (!ok) {
        ok = await Supabase.instance.client.auth.signInWithOAuth(
          OAuthProvider.google,
          redirectTo: 'finswipe://login-callback',
          authScreenLaunchMode: LaunchMode.platformDefault,
        );
      }
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open a browser for sign-in')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Sign-in failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('FinSwipe',
                textAlign: TextAlign.center,
                style: serif.copyWith(fontSize: 40, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text('Understand the market in fifteen\nseconds a day',
                textAlign: TextAlign.center,
                style: serif.copyWith(
                    fontSize: 15,
                    fontStyle: FontStyle.italic,
                    color: inkDim)),
            const SizedBox(height: 48),
            OutlinedButton(
              onPressed: () => _google(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: ink,
                side: const BorderSide(color: border),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6)),
              ),
              child: const Text('Continue with Google'),
            ),
            const SizedBox(height: 32),
            Text('Not investment advice · Terms · Privacy · v0.6.1',
                textAlign: TextAlign.center, style: mono.copyWith(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
