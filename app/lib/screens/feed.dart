import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../theme.dart';

final storiesProvider = FutureProvider<List<Story>>((ref) async {
  final rows = await Supabase.instance.client
      .from('stories')
      .select()
      .eq('status', 'approved')
      .order('is_featured', ascending: false)
      .order('published_at', ascending: false)
      .limit(50);
  return rows.map(Story.fromJson).toList();
});

class FeedScreen extends ConsumerWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stories = ref.watch(storiesProvider);
    return stories.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Could not load feed\n$e',
          textAlign: TextAlign.center)),
      data: (list) => list.isEmpty
          ? const Center(child: Text('No stories yet — check back soon'))
          : RefreshIndicator(
              onRefresh: () => ref.refresh(storiesProvider.future),
              child: PageView.builder(
                scrollDirection: Axis.vertical,
                itemCount: list.length,
                onPageChanged: (i) => _logView(list[i].id),
                itemBuilder: (context, i) => StoryCard(story: list[i]),
              ),
            ),
    );
  }

  void _logView(int storyId) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    // fire-and-forget analytics event (spec §6: rec-engine training data)
    Supabase.instance.client
        .from('events')
        .insert({'user_id': uid, 'story_id': storyId, 'type': 'view'})
        .then((_) {}, onError: (_) {});
  }
}

class StoryCard extends StatelessWidget {
  const StoryCard({super.key, required this.story});
  final Story story;

  Future<void> _save(BuildContext context) async {
    final uid = Supabase.instance.client.auth.currentUser!.id;
    await Supabase.instance.client
        .from('saves')
        .upsert({'user_id': uid, 'story_id': story.id});
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final impact = impactColor(story.impactDirection);
    return Container(
      decoration: aurora(story.category),
      padding: const EdgeInsets.fromLTRB(20, 60, 20, 90),
      child: GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                _chip(story.category ?? '—', Colors.white24),
                const SizedBox(width: 8),
                _chip('${story.impactScore ?? '?'}/10', impact.withValues(alpha: 0.25),
                    textColor: impact),
                if (story.severityLevel == 1) ...[
                  const SizedBox(width: 8),
                  _chip('L1', emberL1.withValues(alpha: 0.3), textColor: emberL1),
                ],
                if (story.confidence != null && story.confidence != 'high') ...[
                  const SizedBox(width: 8),
                  _chip(story.confidence!, Colors.white12),
                ],
              ]),
              const SizedBox(height: 20),
              if (story.hook != null)
                Text(story.hook!,
                    style: const TextStyle(
                        fontSize: 28, fontWeight: FontWeight.w800, height: 1.15)),
              const SizedBox(height: 12),
              Text(story.headline,
                  style: TextStyle(
                      fontSize: 16,
                      color: Colors.white.withValues(alpha: 0.85))),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(story.summary ?? '',
                      style: TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: Colors.white.withValues(alpha: 0.75))),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: InkWell(
                    onTap: () => launchUrl(Uri.parse(story.sourceUrl),
                        mode: LaunchMode.externalApplication),
                    child: Text(story.sourceName,
                        style: const TextStyle(
                            decoration: TextDecoration.underline,
                            color: Colors.white60)),
                  ),
                ),
                IconButton(
                    onPressed: () => _save(context),
                    icon: const Icon(Icons.bookmark_add_outlined)),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, Color bg, {Color? textColor}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(label,
            style: TextStyle(fontSize: 12, color: textColor ?? Colors.white70)),
      );
}
