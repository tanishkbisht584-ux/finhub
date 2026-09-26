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

/// 034: one underlying's full F&O chain (every expiry and strike) with
/// `asof` folded in, or null (no row, table missing, offline).
Future<Map<String, dynamic>?> fetchChain(String symbol) async {
  try {
    final r = await Supabase.instance.client
        .from('fno_chain')
        .select('asof,data')
        .eq('symbol', symbol)
        .maybeSingle();
    if (r == null) return null;
    return {'asof': r['asof'], ...Map<String, dynamic>.from(r['data'] as Map)};
  } catch (_) {
    return null;
  }
}

/// symbol -> Company in one `companies` read (the push opener, the screener
/// and Markets rows all used to carry their own copy). Null on a miss.
Future<Company?> companyOf(String symbol) async {
  try {
    final row = await Supabase.instance.client
        .from('companies')
        .select('id,name,nse_symbol')
        .eq('nse_symbol', symbol)
        .maybeSingle();
    return row == null ? null : Company.fromJson(Map<String, dynamic>.from(row));
  } catch (_) {
    return null;
  }
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
