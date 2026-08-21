import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../theme.dart';
import 'feed.dart' show StoryCard;

/// Deep-link target (spec §8 screen 8): alerts and shares land here.
class StoryDetailScreen extends StatefulWidget {
  const StoryDetailScreen({super.key, required this.storyId});
  final int storyId;

  @override
  State<StoryDetailScreen> createState() => _StoryDetailScreenState();
}

class _StoryDetailScreenState extends State<StoryDetailScreen> {
  // Fetch once on mount — an inline future in build() refetched the story on
  // every rebuild.
  late final Future<Story?> _story = _fetch();

  Future<Story?> _fetch() async {
    final row = await Supabase.instance.client
        .from('stories')
        .select(storyCols)
        .eq('id', widget.storyId)
        .maybeSingle();
    return row == null ? null : Story.fromJson(row);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FinSwipe')),
      body: FutureBuilder<Story?>(
        future: _story,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Center(child: appSpinner());
          }
          // An alert can outlive its story: rejected in the admin panel, or
          // aged past retention. Say so plainly instead of an empty screen.
          if (snap.hasError || snap.data == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.article_outlined, size: 36, color: inkDim),
                  const SizedBox(height: 12),
                  Text('Story unavailable',
                      style: serif.copyWith(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text('It may have been removed since the alert was sent.',
                      textAlign: TextAlign.center,
                      style: mono.copyWith(fontSize: 12)),
                ]),
              ),
            );
          }
          return StoryCard(story: snap.data!);
        },
      ),
    );
  }
}
