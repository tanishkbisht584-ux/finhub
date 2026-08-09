import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../theme.dart';

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

/// Removing a save, with an undo — a mis-tap on a list you curated by hand
/// should cost a tap to fix, not a hunt back through the feed.
Future<void> _unsave(BuildContext context, WidgetRef ref, Story s) async {
  final uid = Supabase.instance.client.auth.currentUser!.id;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await Supabase.instance.client
        .from('saves')
        .delete()
        .eq('user_id', uid)
        .eq('story_id', s.id);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not remove: $e')));
    return;
  } finally {
    ref.invalidate(savedProvider); // keeps the feed's bookmark honest too
  }
  // Clear first: removing several in a row queued the toasts, so each one
  // waited its turn and the last sat on screen long after the action. 4s to undo, then gone.
  messenger.clearSnackBars();
  messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 4),
    content: const Text('Removed from saved'),
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () async {
        await Supabase.instance.client
            .from('saves')
            .upsert({'user_id': uid, 'story_id': s.id});
        ref.invalidate(savedProvider);
      },
    ),
  ));
}

/// Saved — a table, not a card wall (minimal mockup).
class SavedScreen extends ConsumerWidget {
  const SavedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedProvider);
    return SafeArea(
      child: saved.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load saves\n$e')),
        data: (list) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Saved',
                      style: serif.copyWith(
                          fontSize: 26, fontWeight: FontWeight.w700)),
                  Text('${list.length} stories', style: mono),
                ],
              ),
            ),
            Expanded(
              // Pull-to-refresh needs a scrollable even when empty, so the
              // "nothing saved" state is a list too — otherwise the one moment
              // you most want to retry is the one moment you cannot.
              child: RefreshIndicator(
                onRefresh: () => ref.refresh(savedProvider.future),
                child: list.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 120),
                      Center(child: Text('Nothing saved yet')),
                    ])
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, i) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final s = list[i];
                        return Dismissible(
                          key: ValueKey(s.id),
                          direction: DismissDirection.endToStart,
                          onDismissed: (_) => _unsave(context, ref, s),
                          background: Container(
                              color: red.withValues(alpha: 0.2),
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              child: const Icon(Icons.delete_outline)),
                          child: ListTile(
                            title: Text(s.hook ?? s.headline,
                                style:
                                    const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text.rich(TextSpan(children: [
                              TextSpan(
                                  text: 'Impact ${s.impactScore ?? '–'}/10',
                                  style: mono.copyWith(
                                      fontSize: 12,
                                      color: impactColor(s.impactScore))),
                              TextSpan(
                                  text: '  ${s.sourceName}',
                                  style: mono.copyWith(fontSize: 12)),
                            ])),
                            // Swipe-to-remove is invisible until you try it;
                            // a filled bookmark you can tap off is not.
                            trailing: IconButton(
                              icon: const Icon(Icons.bookmark_rounded,
                                  color: green, size: 20),
                              tooltip: 'Remove from saved',
                              onPressed: () => _unsave(context, ref, s),
                            ),
                            onTap: () => launchUrl(Uri.parse(s.sourceUrl),
                                mode: LaunchMode.externalApplication),
                          ),
                        );
                      },
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
