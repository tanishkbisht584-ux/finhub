import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import 'feed.dart';

final savedProvider = FutureProvider<List<Story>>((ref) async {
  final uid = Supabase.instance.client.auth.currentUser!.id;
  final rows = await Supabase.instance.client
      .from('saves')
      .select('stories(*)')
      .eq('user_id', uid)
      .order('saved_at', ascending: false);
  return rows
      .map((r) => r['stories'])
      .whereType<Map<String, dynamic>>()
      .map(Story.fromJson)
      .toList();
});

class SavedScreen extends ConsumerWidget {
  const SavedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedProvider);
    return saved.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Could not load saves\n$e')),
      data: (list) => list.isEmpty
          ? const Center(child: Text('Nothing saved yet'))
          : PageView.builder(
              scrollDirection: Axis.vertical,
              itemCount: list.length,
              itemBuilder: (context, i) => StoryCard(story: list[i]),
            ),
    );
  }
}
