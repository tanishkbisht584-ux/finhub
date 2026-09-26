import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics.dart';
import '../models.dart';
import '../saved_store.dart';
import '../theme.dart';

export '../saved_store.dart' show savedProvider;

/// Removing a save, with an undo — a mis-tap on a list you curated by hand
/// should cost a tap to fix, not a hunt back through the feed. Local store
/// (26 Sep): no network, so nothing here can fail.
Future<void> _unsave(BuildContext context, WidgetRef ref, Story s) async {
  final messenger = ScaffoldMessenger.of(context);
  final store = ref.read(savedProvider.notifier);
  await store.unsave(s.id);
  // Clear first: removing several in a row queued the toasts, so each waited
  // its turn and the last sat on screen long after the action.
  messenger.clearSnackBars();
  final toast = messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 4),
    content: const Text('Removed from saved'),
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () {
        store.save(s);
        track('save', {'story_id': s.id});
      },
    ),
  ));
  // `duration` alone is not enough: Flutter skips the dismiss timer entirely
  // for a SnackBar that has an action while an accessibility service is
  // running, so the undo sat on screen indefinitely. Own the timer.
  Timer(const Duration(seconds: 4), () {
    try {
      toast.close();
    } catch (_) {}
  });
}

/// Saved — a table, not a card wall (minimal mockup). Reads the phone's list.
class SavedScreen extends ConsumerWidget {
  const SavedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(savedProvider);
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Saved', style: serif.copyWith(fontSize: 26, fontWeight: FontWeight.w700)),
                Text('${list.length} stories', style: mono),
              ],
            ),
          ),
          Expanded(
            // Pull-to-refresh re-reads the phone's copy (a second device or a
            // reinstall has none — saves are per phone, per account).
            child: RefreshIndicator(
              onRefresh: () => ref.read(savedProvider.notifier).load(),
              child: list.isEmpty
                  ? ListView(children: [
                      const SizedBox(height: 120),
                      Center(
                          child: Text('Nothing saved yet\nDouble-tap a card, or tap its bookmark.',
                              textAlign: TextAlign.center, style: mono.copyWith(fontSize: 13, height: 1.6))),
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
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text.rich(TextSpan(children: [
                              TextSpan(
                                  text: 'Impact ${s.impactScore ?? '–'}/10',
                                  style: mono.copyWith(fontSize: 12, color: impactColor(s.impactScore))),
                              TextSpan(text: '  ${s.sourceName}', style: mono.copyWith(fontSize: 12)),
                            ])),
                            // Swipe-to-remove is invisible until you try it;
                            // a filled bookmark you can tap off is not.
                            trailing: IconButton(
                              icon: const Icon(Icons.bookmark_rounded, color: green, size: 20),
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
    );
  }
}
