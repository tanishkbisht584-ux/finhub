import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../theme.dart';

final storiesProvider = FutureProvider<List<Story>>((ref) async {
  // Spec §3 feed ranking: recency + impact. Last 48h, featured pinned,
  // severity first (L1 top, L4 minor sinks), newest within a level.
  final since = DateTime.now()
      .toUtc()
      .subtract(const Duration(hours: 48))
      .toIso8601String();
  final rows = await Supabase.instance.client
      .from('stories')
      .select()
      .eq('status', 'approved')
      .gte('published_at', since)
      .order('is_featured', ascending: false)
      .order('severity_level', ascending: true, nullsFirst: false)
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
      error: (e, _) => Center(
          child: Text('Could not load feed\n$e', textAlign: TextAlign.center)),
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

  String get _horizon => switch (story.impactHorizon) {
        'short_term' => 'SHORT',
        'long_term' => 'LONG',
        'both' => 'SHORT + LONG',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final dir = directionColor(story.impactDirection);
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: surface,
          border: Border(left: BorderSide(color: dir, width: 3)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // IMPACT 9/10 · SHORT + LONG — monospace ledger line
            Text.rich(TextSpan(children: [
              TextSpan(
                  text: 'IMPACT ${story.impactScore ?? '–'}/10',
                  style: mono.copyWith(
                      color: impactColor(story.impactScore),
                      fontWeight: FontWeight.w700)),
              if (_horizon.isNotEmpty)
                TextSpan(text: '  ·  $_horizon', style: mono),
            ])),
            const SizedBox(height: 14),
            if (story.hook != null)
              Text(story.hook!,
                  style: serif.copyWith(
                      fontSize: 30, fontWeight: FontWeight.w700, height: 1.2)),
            const SizedBox(height: 12),
            Text(story.headline,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, height: 1.35)),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(story.summary ?? '',
                        style: TextStyle(
                            fontSize: 15, height: 1.55, color: ink.withValues(alpha: 0.8))),
                    if (story.sectors.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: story.sectors
                            .map((s) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                      border: Border.all(color: border)),
                                  child: Text(s,
                                      style: mono.copyWith(fontSize: 12)),
                                ))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 20),
            Row(children: [
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: story.sourceName, style: mono.copyWith(fontSize: 12)),
                    const TextSpan(text: '   '),
                    TextSpan(
                      text: 'Read original →',
                      style: mono.copyWith(
                          fontSize: 12,
                          color: ink,
                          decoration: TextDecoration.underline),
                    ),
                  ]),
                ),
              ),
              if (story.confidence != null && story.confidence != 'high')
                Text(story.confidence!, style: mono.copyWith(fontSize: 12)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              _action('Save', () => _save(context)),
              _action('Source',
                  () => launchUrl(Uri.parse(story.sourceUrl),
                      mode: LaunchMode.externalApplication)),
              const Spacer(),
              Text('Not investment advice',
                  style: mono.copyWith(fontSize: 11)),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _action(String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 18),
        child: InkWell(
          onTap: onTap,
          child: Text(label,
              style: const TextStyle(
                  color: green, fontWeight: FontWeight.w600, fontSize: 14)),
        ),
      );
}
