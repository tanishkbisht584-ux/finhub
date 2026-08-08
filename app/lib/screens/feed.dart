import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../feed_cache.dart';
import '../models.dart';
import '../theme.dart';

/// Whether the feed currently on screen came from the device cache.
final servingCacheProvider = StateProvider<DateTime?>((ref) => null);

final storiesProvider = FutureProvider<List<Story>>((ref) async {
  // Feed ranking: the single current featured story pinned, then newest
  // first. Severity-first ordering froze the feed — 41 stale L1/L2 cards
  // outranked every fresh L3/L4 story; impact is on the card instead.
  final since = DateTime.now()
      .toUtc()
      .subtract(const Duration(hours: 48))
      .toIso8601String();
  try {
    final rows = await Supabase.instance.client
        .from('stories')
        .select()
        .eq('status', 'approved')
        .gte('published_at', since)
        .order('is_featured', ascending: false)
        .order('published_at', ascending: false)
        .limit(50);
    await FeedCache.save(rows.cast<Map<String, dynamic>>());
    ref.read(servingCacheProvider.notifier).state = null;
    return rows.map(Story.fromJson).toList();
  } catch (_) {
    // Offline, or Supabase having a moment. Yesterday's news beats an error
    // screen; only surface the failure if we have nothing saved either.
    final cached = await FeedCache.load();
    if (cached == null || cached.isEmpty) rethrow;
    ref.read(servingCacheProvider.notifier).state = await FeedCache.savedAt();
    return cached.map(Story.fromJson).toList();
  }
});

class FeedScreen extends ConsumerWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stories = ref.watch(storiesProvider);
    final cachedAt = ref.watch(servingCacheProvider);
    return stories.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Offline(onRetry: () => ref.refresh(storiesProvider)),
      data: (list) => list.isEmpty
          ? const Center(child: Text('No stories yet — check back soon'))
          : Column(children: [
              if (cachedAt != null) _CacheBanner(savedAt: cachedAt),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => ref.refresh(storiesProvider.future),
                  child: PageView.builder(
                    scrollDirection: Axis.vertical,
                    itemCount: list.length,
                    onPageChanged: (i) => _logView(list[i].id),
                    itemBuilder: (context, i) => StoryCard(story: list[i]),
                  ),
                ),
              ),
            ]),
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

class StoryCard extends StatefulWidget {
  const StoryCard({super.key, required this.story});
  final Story story;

  @override
  State<StoryCard> createState() => _StoryCardState();
}

class _StoryCardState extends State<StoryCard>
    with SingleTickerProviderStateMixin {
  Story get story => widget.story;
  bool _saved = false;

  late final AnimationController _burst = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 550));

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  Future<void> _save({bool viaDoubleTap = false}) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    if (viaDoubleTap) _burst.forward(from: 0);
    try {
      await Supabase.instance.client
          .from('saves')
          .upsert({'user_id': user.id, 'story_id': story.id});
      if (!mounted) return;
      setState(() => _saved = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          duration: Duration(milliseconds: 900), content: Text('Saved')));
    } catch (e) {
      if (!mounted) return;
      // used to fail silently — surface it instead
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
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
      child: GestureDetector(
        onDoubleTap: () => _save(viaDoubleTap: true),
        child: Stack(alignment: Alignment.center, children: [
          _card(dir),
          // brief bookmark flash confirming the double tap registered
          FadeTransition(
            opacity: Tween<double>(begin: 1, end: 0).animate(
                CurvedAnimation(parent: _burst, curve: const Interval(0.5, 1))),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.6, end: 1.25).animate(
                  CurvedAnimation(parent: _burst, curve: Curves.easeOutBack)),
              child: IgnorePointer(
                child: _burst.isAnimating || _burst.isCompleted
                    ? const Icon(Icons.bookmark_rounded, size: 96, color: green)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _card(Color dir) {
    return Container(
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
              _action(_saved ? 'Saved ✓' : 'Save', () => _save()),
              _action('Source',
                  () => launchUrl(Uri.parse(story.sourceUrl),
                      mode: LaunchMode.externalApplication)),
              const Spacer(),
              Text('double-tap to save',
                  style: mono.copyWith(fontSize: 11)),
            ]),
          ],
        ));
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


/// Shown when the network failed and there is nothing cached to fall back on.
class _Offline extends StatelessWidget {
  const _Offline({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 40, color: inkDim),
            const SizedBox(height: 14),
            Text("Can't reach FinSwipe",
                style: serif.copyWith(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Check your connection — your saved stories still work.',
                textAlign: TextAlign.center, style: mono.copyWith(fontSize: 12)),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                  foregroundColor: ink, side: const BorderSide(color: border)),
              child: const Text('Try again'),
            ),
          ]),
        ),
      );
}

/// Quiet line marking the feed as a saved copy, so nothing on screen is
/// silently passed off as live.
class _CacheBanner extends StatelessWidget {
  const _CacheBanner({required this.savedAt});
  final DateTime savedAt;

  String get _age {
    final m = DateTime.now().difference(savedAt).inMinutes;
    if (m < 1) return 'just now';
    if (m < 60) return '$m min ago';
    final h = m ~/ 60;
    return h < 24 ? '$h h ago' : '${h ~/ 24} d ago';
  }

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: amber.withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text('Offline — showing stories saved $_age. Pull to retry.',
            style: mono.copyWith(fontSize: 11, color: amber)),
      );
}
