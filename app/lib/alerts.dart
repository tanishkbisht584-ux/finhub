import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

/// User-set price alerts (Phase B, 26 Sep 2026). Rows live in `price_alerts`
/// (migration 029); the pipeline evaluates them on the 15-minute equity lap
/// in NSE hours and pushes through the device token. The app only creates,
/// lists, re-arms and deletes.

const alertKinds = ['above', 'below', 'move', 'hi52', 'lo52'];
const alertKindLabel = {
  'above': 'ABOVE',
  'below': 'BELOW',
  'move': 'DAY MOVE %',
  'hi52': '52W HIGH',
  'lo52': '52W LOW',
};

/// The honesty line every alert surface shows.
const alertHonesty =
    'checked every 15 min in NSE hours (09:15–15:45) · not tick-level · 52-week = daily closes';

class PriceAlert {
  const PriceAlert(
      {required this.id,
      required this.symbol,
      required this.kind,
      this.threshold,
      required this.active,
      required this.createdAt,
      this.lastFiredAt,
      this.fireCount = 0});
  final int id;
  final String symbol, kind;
  final double? threshold;
  final bool active;
  final DateTime createdAt;
  final DateTime? lastFiredAt;
  final int fireCount;

  factory PriceAlert.fromJson(Map<String, dynamic> j) => PriceAlert(
        id: j['id'] as int,
        symbol: '${j['symbol']}',
        kind: '${j['kind']}',
        threshold: (j['threshold'] as num?)?.toDouble(),
        active: j['active'] as bool? ?? true,
        createdAt: DateTime.tryParse('${j['created_at']}') ?? DateTime.now(),
        lastFiredAt: DateTime.tryParse('${j['last_fired_at'] ?? ''}'),
        fireCount: (j['fire_count'] as num?)?.toInt() ?? 0,
      );

  String get label => alertLabel(kind, threshold);
}

/// Same wording as the pipeline's push title (price_alerts.LABEL).
String alertLabel(String kind, double? threshold) => switch (kind) {
      'above' => 'above ₹${fmtNum(threshold ?? 0, decimals: 2)}',
      'below' => 'below ₹${fmtNum(threshold ?? 0, decimals: 2)}',
      'move' => 'moves ${_g(threshold ?? 0)}% in a day',
      'hi52' => 'new 52-week high',
      'lo52' => 'new 52-week low',
      _ => kind,
    };

String _g(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// Null when [text] is a usable threshold for [kind]; else the reason.
String? validateThreshold(String kind, String text) {
  if (kind == 'hi52' || kind == 'lo52') return null;
  final v = double.tryParse(text.trim().replaceAll(',', ''));
  if (v == null) return 'enter a number';
  if (v <= 0) return 'must be above 0';
  if (kind == 'move' && v > 50) return 'a day move over 50% is not a useful alert';
  return null;
}

/// A warning when the rule is already true right now — it will fire on the
/// next check, which is probably not what the person meant.
String? alreadyCrossed(String kind, double? threshold, Tick? tick) {
  if (tick == null || tick.price <= 0) return null;
  final p = tick.price;
  if (kind == 'above' && threshold != null && p > threshold) {
    return 'price is already above ₹${fmtNum(threshold)} — this fires on the next check';
  }
  if (kind == 'below' && threshold != null && p < threshold) {
    return 'price is already below ₹${fmtNum(threshold)} — this fires on the next check';
  }
  if (kind == 'move' && threshold != null && (tick.changePct ?? 0).abs() >= threshold) {
    return 'today\'s move is already ${fmtPct(tick.changePct)} — this fires on the next check';
  }
  return null;
}

SupabaseClient get _sb => Supabase.instance.client;

Future<List<PriceAlert>> loadAlerts({String? symbol}) async {
  final uid = _sb.auth.currentUser?.id;
  if (uid == null) return const [];
  var q = _sb
      .from('price_alerts')
      .select('id,symbol,kind,threshold,active,created_at,last_fired_at,fire_count')
      .eq('user_id', uid);
  if (symbol != null) q = q.eq('symbol', symbol);
  final rows = await q.order('created_at', ascending: false);
  return [for (final r in rows) PriceAlert.fromJson(Map<String, dynamic>.from(r))];
}

Future<void> addAlert(String symbol, String kind, double? threshold) async {
  final uid = _sb.auth.currentUser?.id;
  if (uid == null) return;
  await _sb.from('price_alerts').insert({
    'user_id': uid,
    'symbol': symbol,
    'kind': kind,
    'threshold': kind == 'hi52' || kind == 'lo52' ? null : threshold,
  });
}

Future<void> deleteAlert(int id) => _sb.from('price_alerts').delete().eq('id', id);

Future<void> rearmAlert(int id) => _sb.from('price_alerts').update({'active': true}).eq('id', id);

typedef AlertFire = ({DateTime at, String symbol, String kind, double? threshold, double price});

Future<List<AlertFire>> loadFires({int limit = 100}) async {
  final uid = _sb.auth.currentUser?.id;
  if (uid == null) return const [];
  final rows = await _sb
      .from('price_alert_fires')
      .select('fired_at,symbol,kind,threshold,price')
      .eq('user_id', uid)
      .order('fired_at', ascending: false)
      .limit(limit);
  return [
    for (final r in rows)
      (
        at: DateTime.tryParse('${r['fired_at']}') ?? DateTime.now(),
        symbol: '${r['symbol']}',
        kind: '${r['kind']}',
        threshold: (r['threshold'] as num?)?.toDouble(),
        price: (r['price'] as num?)?.toDouble() ?? 0,
      )
  ];
}
