import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final name = (user?.userMetadata?['full_name'] as String?) ??
        user?.email ??
        'Signed in';
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(border: Border.all(color: border)),
              child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: serif.copyWith(fontSize: 22)),
            ),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (user?.email != null)
                Text(user!.email!, style: mono.copyWith(fontSize: 12)),
            ]),
          ]),
          const SizedBox(height: 32),
          Text('APP', style: mono.copyWith(fontSize: 12, letterSpacing: 1.2)),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => Supabase.instance.client.auth.signOut(),
            style: OutlinedButton.styleFrom(
              foregroundColor: red,
              side: BorderSide(color: red.withValues(alpha: 0.5)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: const Text('Sign out'),
          ),
          const SizedBox(height: 32),
          Text(
            'FinSwipe explains news. It never gives investment advice. '
            'Consult a SEBI-registered advisor before investing.',
            style: mono.copyWith(fontSize: 11, height: 1.6),
          ),
        ],
      ),
    );
  }
}
