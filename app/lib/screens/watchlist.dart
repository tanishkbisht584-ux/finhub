import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../theme.dart';
import 'stock.dart';
import 'story_detail.dart';

/// Spec §8 screen 5: followed entities + filtered feed. Category/sector
/// follows shape the main feed's future ranking; this screen shows the
/// company follows, where "did my stock do something today" lives.
class WatchlistScreen extends StatefulWidget {
  const WatchlistScreen({super.key});
  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  List<Company>? _companies; // null = loading
  List<Story> _stories = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _error = null; // stale error from a previous run must not survive a retry
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    if (uid == null) return setState(() => _companies = const []);
    List<int> ids;
    try {
      final follows = await sb
          .from('follows')
          .select('target_id')
          .eq('user_id', uid)
          .eq('target_type', 'company');
      if (!mounted) return;
      ids = [for (final f in follows) int.parse(f['target_id'])];
      if (ids.isEmpty) return setState(() => _companies = const []);
      final companies = await sb
          .from('companies')
          .select('id,name,nse_symbol')
          .inFilter('id', ids);
      if (!mounted) return;
      setState(() => _companies = [
            for (final c in companies)
              Company.fromJson(Map<String, dynamic>.from(c))
          ]);
    } catch (e) {
      // Companies never loaded — nothing to show behind the error, so the
      // empty-state branch in build() must not be allowed to claim this.
      if (mounted) setState(() => _error = e);
      return;
    }
    try {
      final links = await sb
          .from('story_companies')
          .select('story_id')
          .inFilter('company_id', ids)
          .order('story_id', ascending: false)
          .limit(200);
      final storyIds = {for (final l in links) l['story_id']}.toList();
      final stories = storyIds.isEmpty
          ? const <Map<String, dynamic>>[]
          : await sb
              .from('stories')
              .select()
              .inFilter('id', storyIds)
              .eq('status', 'approved')
              .order('published_at', ascending: false)
              .limit(30);
      if (!mounted) return;
      setState(() => _stories = [
            for (final s in stories)
              Story.fromJson(Map<String, dynamic>.from(s))
          ]);
    } catch (e) {
      // Companies already rendered; only the feed half failed — keep them
      // on screen and say so, instead of pretending there's nothing here.
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final companies = _companies;
    if (companies == null) {
      if (_error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Could not load watchlist',
                  textAlign: TextAlign.center,
                  style: mono.copyWith(fontSize: 13, height: 1.6)),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () {
                  setState(() => _error = null);
                  _load();
                },
                child: const Text('Try again'),
              ),
            ]),
          ),
        );
      }
      return Center(child: appSpinner());
    }
    if (companies.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing followed yet.\nOpen a company from any card and tap the star.',
            textAlign: TextAlign.center,
            style: mono.copyWith(fontSize: 13, height: 1.6),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in companies)
              ActionChip(
                backgroundColor: surface,
                side: const BorderSide(color: border),
                label: Text(c.nseSymbol,
                    style: mono.copyWith(fontSize: 13, color: ink)),
                // Reload on return: an unfollow on the stock page must not
                // leave the chip (and its stories) ghosting here.
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => StockScreen(company: c)));
                  if (mounted) _load();
                },
              ),
          ],
        ),
        const Divider(height: 32),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(children: [
              Text('Could not load your stories',
                  style: mono.copyWith(fontSize: 13)),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ]),
          )
        else if (_stories.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('No stories on your companies yet',
                style: mono.copyWith(fontSize: 13)),
          ),
        for (final s in _stories)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.hook ?? s.headline,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: ink, fontWeight: FontWeight.w600)),
            subtitle: Text(s.sourceName, style: mono.copyWith(fontSize: 11)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => StoryDetailScreen(storyId: s.id))),
          ),
      ],
    );
  }
}
