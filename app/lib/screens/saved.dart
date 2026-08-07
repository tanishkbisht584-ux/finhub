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
              child: list.isEmpty
                  ? const Center(child: Text('Nothing saved yet'))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, i) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final s = list[i];
                        return Dismissible(
                          key: ValueKey(s.id),
                          direction: DismissDirection.endToStart,
                          onDismissed: (_) {
                            final uid = Supabase
                                .instance.client.auth.currentUser!.id;
                            Supabase.instance.client
                                .from('saves')
                                .delete()
                                .eq('user_id', uid)
                                .eq('story_id', s.id)
                                .then((_) {}, onError: (_) {});
                          },
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
                            onTap: () => launchUrl(Uri.parse(s.sourceUrl),
                                mode: LaunchMode.externalApplication),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
