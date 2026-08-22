import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

/// Live quotes by symbol, shared by every card chip, the watchlist, the stock
/// header and the Markets tab. One map rather than per-card state: cards sit
/// in a PageView that reuses State across stories, and anything stored on the
/// story row itself would be persisted by FeedCache and replay a stale % as
/// live. A ValueNotifier (like homeTab/pendingStory) so plain widgets can
/// listen without a WidgetRef.
final ticks = ValueNotifier<Map<String, Tick>>({});

void mergeTicks(Iterable<Tick> fresh) {
  if (fresh.isEmpty) return;
  ticks.value = {...ticks.value, for (final t in fresh) t.symbol: t};
}

/// Pull `quotes` rows for [symbols] into [ticks]. Silent on failure — a price
/// is a bonus on every surface that shows one, never a reason to show less.
Future<void> loadTicks(Iterable<String> symbols) async {
  final syms = symbols.where((s) => s.isNotEmpty).toSet().toList();
  if (syms.isEmpty) return;
  try {
    final rows = await Supabase.instance.client
        .from('quotes')
        .select(tickCols)
        .inFilter('symbol', syms);
    mergeTicks([
      for (final r in rows) Tick.fromJson(Map<String, dynamic>.from(r))
    ]);
  } catch (_) {}
}
