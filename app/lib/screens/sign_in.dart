import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  // The only button on the app's front door looked dead during the OAuth
  // launch, and a second tap started a second auth flow.
  bool _busy = false;

  Future<void> _google(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not open a browser for sign-in')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Sign-in failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
                style:
                    serif.copyWith(fontSize: 40, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text('Understand the market in fifteen\nseconds a day',
                textAlign: TextAlign.center,
                style: serif.copyWith(
                    fontSize: 15, fontStyle: FontStyle.italic, color: inkDim)),
            const SizedBox(height: 48),
            OutlinedButton(
              onPressed: _busy ? null : () => _google(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: ink,
                side: const BorderSide(color: border),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6)),
              ),
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Continue with Google'),
            ),
            const SizedBox(height: 32),
            // Terms/Privacy become links once their URLs exist (theme.dart).
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                Text('Not investment advice · ',
                    style: mono.copyWith(fontSize: 11)),
                GestureDetector(
                  onTap: kTermsUrl.isEmpty
                      ? null
                      : () => openExternal(context, kTermsUrl),
                  child: Text('Terms',
                      style: mono.copyWith(
                          fontSize: 11,
                          decoration: kTermsUrl.isEmpty
                              ? null
                              : TextDecoration.underline)),
                ),
                Text(' · ', style: mono.copyWith(fontSize: 11)),
                GestureDetector(
                  onTap: kPrivacyUrl.isEmpty
                      ? null
                      : () => openExternal(context, kPrivacyUrl),
                  child: Text('Privacy',
                      style: mono.copyWith(
                          fontSize: 11,
                          decoration: kPrivacyUrl.isEmpty
                              ? null
                              : TextDecoration.underline)),
                ),
                Text(' · v$appVersion', style: mono.copyWith(fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
