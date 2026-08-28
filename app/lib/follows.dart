import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Company ids the signed-in reader follows. Loaded once at feed init and
/// mirrored optimistically by the stock page's star — the feed's watchlist
/// ranking reads it at page-entry time only, so a mid-session follow shapes
/// future pages, never the one being read. Anon/offline stays empty, which
/// makes the ranking a no-op. A ValueNotifier like ticks/homeTab so plain
/// widgets could listen without a WidgetRef.
final followedCompanyIds = ValueNotifier<Set<int>>({});

/// Clusters (stories) the reader follows — the card rail's bell (015). A
/// followed cluster pings only when the story develops. Same posture as
/// companies: anon/offline stays empty.
final followedClusterIds = ValueNotifier<Set<String>>({});

/// Silent on failure, like loadTicks — a missing watchlist is a plain
/// chronological feed, never an error.
Future<void> loadFollowedCompanies() async {
  try {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    final rows = await Supabase.instance.client
        .from('follows')
        .select('target_type,target_id')
        .eq('user_id', uid)
        .inFilter('target_type', ['company', 'cluster']);
    final ids = <int>{};
    final clusters = <String>{};
    for (final r in rows) {
      if (r['target_type'] == 'cluster') {
        clusters.add('${r['target_id']}');
      } else {
        final id = int.tryParse('${r['target_id']}'); // target_id is text
        if (id != null) ids.add(id);
      }
    }
    followedCompanyIds.value = ids;
    followedClusterIds.value = clusters;
  } catch (_) {}
}

/// Optimistic toggle, rollback on failure — the stock-page star's pattern.
Future<void> toggleFollowCluster(String clusterId) async {
  String? uid;
  try {
    uid = Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {} // uninitialized Supabase (tests, hostile boot) = anon
  if (uid == null) return;
  final was = followedClusterIds.value.contains(clusterId);
  followedClusterIds.value = was
      ? ({...followedClusterIds.value}..remove(clusterId))
      : {...followedClusterIds.value, clusterId};
  try {
    final t = Supabase.instance.client.from('follows');
    if (was) {
      await t
          .delete()
          .eq('user_id', uid)
          .eq('target_type', 'cluster')
          .eq('target_id', clusterId);
    } else {
      await t.upsert({
        'user_id': uid,
        'target_type': 'cluster',
        'target_id': clusterId,
      });
    }
  } catch (_) {
    followedClusterIds.value = was
        ? {...followedClusterIds.value, clusterId}
        : ({...followedClusterIds.value}..remove(clusterId));
  }
}
