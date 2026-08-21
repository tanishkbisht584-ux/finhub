import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../analytics.dart';
import '../models.dart';
import '../theme.dart';

final savedProvider = FutureProvider<List<Story>>((ref) async {
  // Sign-out can re-run this while the Saved route is still pushed (it lives
  // on the root navigator) — an empty list beats a null-check crash.
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return const [];
  final rows = await Supabase.instance.client
      .from('saves')
      .select('stories($storyCols)')
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
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return;
  final messenger = ScaffoldMessenger.of(context);
  // The root container outlives this screen; `ref` does not, and both the
  // finally below and the Undo run after awaits that can outlive it.
  final container = ProviderScope.containerOf(context, listen: false);
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
    container.invalidate(savedProvider); // keeps the feed's bookmark honest too
  }
  // Clear first: removing several in a row queued the toasts, so each waited
  // its turn and the last sat on screen long after the action.
  messenger.clearSnackBars();
  final toast = messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 4),
    content: const Text('Removed from saved'),
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () async {
        try {
          await Supabase.instance.client
              .from('saves')
              .upsert({'user_id': uid, 'story_id': s.id});
          track('save', {'story_id': s.id});
        } catch (_) {
          messenger.showSnackBar(const SnackBar(
              content: Text('Could not undo — try saving again')));
        }
        container.invalidate(savedProvider);
      },
    ),
  ));
  // `duration` alone is not enough: Flutter skips the dismiss timer entirely
  // for a SnackBar that has an action while an accessibility service is
  // running, so the undo sat on screen indefinitely. Own the timer.
  // Close only if still up; removing two items ~1s apart otherwise let the
  // first timer cut the second toast's undo window short.
  Timer(const Duration(seconds: 4), () {
    try {
      toast.close();
    } catch (_) {}
  });
}

/// Saved — a table, not a card wall (minimal mockup).
class SavedScreen extends ConsumerWidget {
  const SavedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedProvider);
    return SafeArea(
      // skipLoadingOnRefresh false: the invalidate after a dismiss otherwise
      // rebuilds with the previous list, leaving the dismissed Dismissible in
      // the tree (debug throw, ghost row in release).
      child: saved.when(
        skipLoadingOnRefresh: false,
        loading: () => Center(child: appSpinner()),
        // Scrollable like the empty state: pull-to-refresh while offline put
        // raw exception text here that could not be pulled on — the one moment
        // you most want to retry was the one moment you could not.
        error: (e, _) => RefreshIndicator(
          onRefresh: () =>
              ref.refresh(savedProvider.future).then((_) {}, onError: (_) {}),
          child: ListView(children: [
            const SizedBox(height: 120),
            Center(
                child: Text('Could not load saves — pull to retry',
                    style: mono.copyWith(fontSize: 13))),
          ]),
        ),
        data: (list) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
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
                // The rejection is already rendered by .when — an unhandled
                // async error on top helps nobody.
                onRefresh: () => ref
                    .refresh(savedProvider.future)
                    .then((_) {}, onError: (_) {}),
                child: list.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 120),
                        Center(
                            child: Text('Nothing saved yet',
                                style: mono.copyWith(fontSize: 13))),
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
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
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
                              onTap: () => openExternal(context, s.sourceUrl),
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
