import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.person),
            title: Text(user?.email ?? 'Signed in'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () => Supabase.instance.client.auth.signOut(),
          ),
          const SizedBox(height: 24),
          Text(
            'FinSwipe explains market news. It is not investment advice. '
            'Consult a SEBI-registered advisor before investing.',
            style: TextStyle(
                fontSize: 12, color: Colors.white.withValues(alpha: 0.5)),
          ),
        ],
      ),
    );
  }
}
