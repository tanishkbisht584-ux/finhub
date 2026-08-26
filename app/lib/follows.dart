import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Company ids the signed-in reader follows. Loaded once at feed init and
/// mirrored optimistically by the stock page's star — the feed's watchlist
/// ranking reads it at page-entry time only, so a mid-session follow shapes
/// future pages, never the one being read. Anon/offline stays empty, which
/// makes the ranking a no-op. A ValueNotifier like ticks/homeTab so plain
/// widgets could listen without a WidgetRef.
final followedCompanyIds = ValueNotifier<Set<int>>({});

/// Silent on failure, like loadTicks — a missing watchlist is a plain
/// chronological feed, never an error.
Future<void> loadFollowedCompanies() async {
  try {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    final rows = await Supabase.instance.client
        .from('follows')
        .select('target_id')
        .eq('user_id', uid)
        .eq('target_type', 'company');
    final ids = <int>{};
    for (final r in rows) {
      final id = int.tryParse('${r['target_id']}'); // target_id is text
      if (id != null) ids.add(id);
    }
    followedCompanyIds.value = ids;
  } catch (_) {}
}
