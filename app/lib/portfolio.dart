import 'dart:convert';
import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

/// Portfolio (Phase A of the four-gap plan, 26 Sep 2026). One table of dated
/// buy/sell lots (`portfolio_trades`, migration 028); everything else —
/// holdings, average cost, realised and unrealised P&L, XIRR, allocation —
/// is a fold over those lots on the phone. Facts only: FinFlick never places
/// an order.

class Trade {
  const Trade(
      {this.id,
      required this.symbol,
      required this.side,
      required this.qty,
      required this.price,
      required this.tradedOn,
      this.note,
      this.source = 'manual'});
  final int? id;
  final String symbol, side, source;
  final double qty, price;
  final DateTime tradedOn;
  final String? note;

  bool get isBuy => side == 'buy';
  double get value => qty * price;

  factory Trade.fromJson(Map<String, dynamic> j) => Trade(
        id: j['id'] as int?,
        symbol: '${j['symbol']}',
        side: '${j['side']}',
        qty: (j['qty'] as num).toDouble(),
        price: (j['price'] as num).toDouble(),
        tradedOn: DateTime.parse('${j['traded_on']}'),
        note: j['note'] as String?,
        source: '${j['source'] ?? 'manual'}',
      );

  Map<String, Object?> toJson(String userId) => {
        'user_id': userId,
        'symbol': symbol,
        'side': side,
        'qty': qty,
        'price': price,
        'traded_on': ymd(tradedOn),
        if (note != null && note!.isNotEmpty) 'note': note,
        'source': source,
      };
}

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// One symbol after the average-cost fold. [qty] 0 = a closed position that
/// still carries its [realised] P&L. [overSold] = a sell exceeded what was
/// held (a lot is missing) — the sell was clamped to the held quantity.
class Holding {
  Holding(this.symbol);
  final String symbol;
  double qty = 0, avgCost = 0, realised = 0;
  bool overSold = false;
  double get invested => qty * avgCost;
}

/// Average-cost fold in trade order (date, then insertion). Buys move the
/// average; sells realise (price − average) × qty and never move it.
List<Holding> holdingsFrom(List<Trade> trades) {
  final sorted = [...trades]..sort((a, b) {
      final c = a.tradedOn.compareTo(b.tradedOn);
      return c != 0 ? c : (a.id ?? 0).compareTo(b.id ?? 0);
    });
  final by = <String, Holding>{};
  for (final t in sorted) {
    final h = by.putIfAbsent(t.symbol, () => Holding(t.symbol));
    if (t.isBuy) {
      h.avgCost = (h.qty * h.avgCost + t.qty * t.price) / (h.qty + t.qty);
      h.qty += t.qty;
    } else {
      final q = math.min(t.qty, h.qty);
      if (t.qty > h.qty) h.overSold = true;
      h.realised += q * (t.price - h.avgCost);
      h.qty -= q;
      if (h.qty == 0) h.avgCost = 0;
    }
  }
  return by.values.toList();
}

/// Dated cash flows for XIRR: buys out, sells in, plus one terminal inflow of
/// today's value. Null when an open holding has no price yet — an XIRR that
/// silently ignores a position is worse than none.
List<(DateTime, double)>? cashFlows(
    List<Trade> trades, Map<String, double> price, DateTime today) {
  final flows = [
    for (final t in trades) (t.tradedOn, t.isBuy ? -t.value : t.value)
  ];
  var terminal = 0.0;
  for (final h in holdingsFrom(trades)) {
    if (h.qty == 0) continue;
    final p = price[h.symbol];
    if (p == null) return null;
    terminal += h.qty * p;
  }
  if (terminal > 0) flows.add((today, terminal));
  return flows;
}

/// Annualised internal rate of return (act/365) — Newton from [guess], then
/// bisection on [−0.99, 10] if Newton wanders. Null without both an outflow
/// and an inflow, when every flow shares one date, or when nothing converges.
double? xirr(List<(DateTime, double)> flows, {double guess = 0.1}) {
  if (flows.length < 2) return null;
  if (!flows.any((f) => f.$2 < 0) || !flows.any((f) => f.$2 > 0)) return null;
  final t0 = flows.map((f) => f.$1).reduce((a, b) => a.isBefore(b) ? a : b);
  final years = [for (final f in flows) f.$1.difference(t0).inDays / 365.0];
  if (years.every((y) => y == 0)) return null;
  double npv(double r) {
    var s = 0.0;
    for (var i = 0; i < flows.length; i++) {
      s += flows[i].$2 / math.pow(1 + r, years[i]);
    }
    return s;
  }

  double dnpv(double r) {
    var s = 0.0;
    for (var i = 0; i < flows.length; i++) {
      s -= years[i] * flows[i].$2 / math.pow(1 + r, years[i] + 1);
    }
    return s;
  }

  var r = guess;
  for (var i = 0; i < 50; i++) {
    final f = npv(r), d = dnpv(r);
    if (d == 0 || !d.isFinite) break;
    final next = r - f / d;
    if (!next.isFinite || next <= -1) break;
    if ((next - r).abs() < 1e-7) return next;
    r = next;
  }
  var lo = -0.99, hi = 10.0;
  var flo = npv(lo), fhi = npv(hi);
  if (flo.sign == fhi.sign) return null;
  for (var i = 0; i < 200; i++) {
    final mid = (lo + hi) / 2, fm = npv(mid);
    if (fm.abs() < 1e-9 || (hi - lo) < 1e-9) return mid;
    if (fm.sign == flo.sign) {
      lo = mid;
      flo = fm;
    } else {
      hi = mid;
      fhi = fm;
    }
  }
  return (lo + hi) / 2;
}

/// Value share by [key] (sector or symbol) of the open holdings, 0..1.
Map<String, double> allocation(List<Holding> holdings,
    Map<String, double> price, String Function(String symbol) key) {
  final out = <String, double>{};
  var total = 0.0;
  for (final h in holdings) {
    final p = price[h.symbol];
    if (h.qty == 0 || p == null) continue;
    final v = h.qty * p;
    out[key(h.symbol)] = (out[key(h.symbol)] ?? 0) + v;
    total += v;
  }
  if (total == 0) return const {};
  return {for (final e in out.entries) e.key: e.value / total};
}

// ---------- broker CSV ----------

/// One parsed line. [symbol] may be empty when the file only carries a name
/// and ISIN (Groww) — the screen resolves ISIN → symbol before review.
typedef CsvRow = ({
  String symbol,
  String isin,
  String name,
  String side,
  double qty,
  double price,
  DateTime? date,
});

typedef ParsedCsv = ({
  List<CsvRow> rows,
  List<String> skipped, // lines that had a header but no usable qty/price
  bool dated, // false = no trade-date column: XIRR is approximate
  String source, // manual | zerodha | groww | upstox
});

const _symbolCols = {
  'symbol',
  'instrument',
  'tradingsymbol',
  'trading symbol',
  'scrip',
  'scrip name',
  'stock',
  'ticker',
};
const _nameCols = {'stock name', 'company', 'company name', 'name'};
const _sideCols = {'trade_type', 'trade type', 'type', 'side', 'transaction type', 'buy/sell'};
const _qtyCols = {
  'quantity',
  'qty',
  'quantity available',
  'net qty',
  'net quantity',
  'shares',
  'units',
};
const _priceCols = {
  'price',
  'avg cost',
  'avg. cost',
  'average price',
  'average buy price',
  'avg price',
  'avg. price',
  'buy price',
  'average cost',
  'trade price',
  'buy avg',
  'avg buy price',
};
const _dateCols = {
  'trade_date',
  'trade date',
  'date',
  'order_execution_time',
  'transaction date',
  'executed at',
};

String _norm(String h) =>
    h.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'[.:]+$'), '');

/// RFC-4180-lite: quoted fields with doubled quotes, comma / tab / semicolon.
List<String> splitCsvLine(String line, [String sep = ',']) {
  final out = <String>[];
  final b = StringBuffer();
  var q = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (q) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          b.write('"');
          i++;
        } else {
          q = false;
        }
      } else {
        b.write(c);
      }
    } else if (c == '"') {
      q = true;
    } else if (c == sep) {
      out.add(b.toString());
      b.clear();
    } else {
      b.write(c);
    }
  }
  out.add(b.toString());
  return out;
}

double? _num(String s) {
  final t = s.replaceAll(RegExp(r'[₹,\s]'), '').replaceAll(RegExp(r'^\((.*)\)$'), r'-$1');
  if (t.isEmpty || t == '-') return null;
  return double.tryParse(t);
}

DateTime? parseTradeDate(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  final iso = DateTime.tryParse(t.length > 10 && t[10] == ' ' ? t.replaceFirst(' ', 'T') : t);
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  final dmy = RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})').firstMatch(t);
  if (dmy != null) {
    var y = int.parse(dmy[3]!);
    if (y < 100) y += 2000;
    return DateTime(y, int.parse(dmy[2]!), int.parse(dmy[1]!));
  }
  const months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };
  final mon = RegExp(r'^(\d{1,2})[- ]([A-Za-z]{3})[a-z]*[- ](\d{2,4})').firstMatch(t);
  if (mon != null && months[mon[2]!.toLowerCase()] != null) {
    var y = int.parse(mon[3]!);
    if (y < 100) y += 2000;
    return DateTime(y, months[mon[2]!.toLowerCase()]!, int.parse(mon[1]!));
  }
  return null;
}

/// "TCS-EQ", "tcs.ns", " TCS " → "TCS". Only the NSE symbol survives.
String normaliseSymbol(String s) {
  var t = s.trim().toUpperCase();
  t = t.replaceFirst(RegExp(r'\.(NS|BO|NSE|BSE)$'), '');
  t = t.replaceFirst(RegExp(r'-(EQ|BE|BZ|SM|ST|N\d|E\d)$'), '');
  return t;
}

/// Header-sniffing parser for whatever a broker exports (Zerodha Console
/// tradebook / holdings, Kite holdings, Groww holdings, Upstox holdings) —
/// preamble lines are skipped until a line carries a symbol/ISIN header.
/// Layouts assumed from memory: verify against a real file (plan, 20 Sep).
ParsedCsv parseTradesCsv(String text) {
  final lines = const LineSplitter().convert(text);
  var sep = ',';
  var headerAt = -1;
  var header = const <String>[];
  for (var i = 0; i < lines.length; i++) {
    for (final s in const [',', '\t', ';']) {
      final cols = splitCsvLine(lines[i], s).map(_norm).toList();
      final hasSym = cols.any((c) => _symbolCols.contains(c) || _nameCols.contains(c) || c == 'isin');
      final hasQty = cols.any(_qtyCols.contains);
      if (hasSym && hasQty) {
        sep = s;
        headerAt = i;
        header = cols;
        break;
      }
    }
    if (headerAt >= 0) break;
  }
  if (headerAt < 0) {
    return (rows: const [], skipped: const [], dated: false, source: 'manual');
  }
  int col(Set<String> names) => header.indexWhere(names.contains);
  final iSym = col(_symbolCols), iName = col(_nameCols), iIsin = header.indexOf('isin');
  final iSide = col(_sideCols), iQty = col(_qtyCols), iPrice = col(_priceCols), iDate = col(_dateCols);
  final source = header.contains('trade_id') || header.contains('quantity available')
      ? 'zerodha'
      : header.contains('average buy price')
          ? 'groww'
          : header.any((h) => h.contains('instrument')) && header.any((h) => h.contains('invested'))
              ? 'upstox'
              : header.contains('avg. cost') && header.contains('cur. val')
                  ? 'zerodha'
                  : 'manual';
  final rows = <CsvRow>[];
  final skipped = <String>[];
  for (final line in lines.skip(headerAt + 1)) {
    if (line.trim().isEmpty) continue;
    final f = splitCsvLine(line, sep);
    String at(int i) => i >= 0 && i < f.length ? f[i].trim() : '';
    final qty = iQty < 0 ? null : _num(at(iQty));
    final price = iPrice < 0 ? null : _num(at(iPrice));
    final symbol = normaliseSymbol(at(iSym));
    final isin = at(iIsin).toUpperCase();
    final name = at(iName);
    if (symbol.isEmpty && isin.isEmpty && name.isEmpty) continue; // totals / blank
    if (qty == null || qty <= 0 || price == null || price < 0) {
      skipped.add(line.trim());
      continue;
    }
    final sideRaw = at(iSide).toLowerCase();
    rows.add((
      symbol: symbol,
      isin: isin,
      name: name,
      side: sideRaw.startsWith('s') ? 'sell' : 'buy',
      qty: qty,
      price: price,
      date: iDate < 0 ? null : parseTradeDate(at(iDate)),
    ));
  }
  return (rows: rows, skipped: skipped, dated: iDate >= 0 && rows.any((r) => r.date != null), source: source);
}

// ---------- Supabase ----------

SupabaseClient get _sb => Supabase.instance.client;

Future<List<Trade>> loadTrades() async {
  final uid = _sb.auth.currentUser?.id;
  if (uid == null) return const [];
  final rows = await _sb
      .from('portfolio_trades')
      .select('id,symbol,side,qty,price,traded_on,note,source')
      .eq('user_id', uid)
      .order('traded_on')
      .order('id');
  return [for (final r in rows) Trade.fromJson(Map<String, dynamic>.from(r))];
}

/// Inserts in one round trip; the caller reloads (ids come from the server).
Future<void> addTrades(List<Trade> trades) async {
  final uid = _sb.auth.currentUser?.id;
  if (uid == null || trades.isEmpty) return;
  await _sb.from('portfolio_trades').insert([for (final t in trades) t.toJson(uid)]);
}

Future<void> deleteTrade(int id) => _sb.from('portfolio_trades').delete().eq('id', id);

/// Which of [symbols] exist as NSE symbols (companies table).
Future<Set<String>> knownSymbols(Iterable<String> symbols) async {
  final syms = symbols.where((s) => s.isNotEmpty).toSet().toList();
  if (syms.isEmpty) return const {};
  final rows = await _sb.from('companies').select('nse_symbol').inFilter('nse_symbol', syms);
  return {for (final r in rows) '${r['nse_symbol']}'};
}

/// ISIN → NSE symbol through the screener's stored ISIN (the BSE join map).
Future<Map<String, String>> symbolsByIsin(Iterable<String> isins) async {
  final list = isins.where((s) => s.isNotEmpty).toSet().toList();
  if (list.isEmpty) return const {};
  final rows = await _sb
      .from('screener_metrics')
      .select('symbol,isin:sa->>isin')
      .filter('sa->>isin', 'in', '(${list.join(',')})');
  return {for (final r in rows) '${r['isin']}': '${r['symbol']}'};
}

/// Sector / valuation facts for the HEALTH strip — one read, held symbols only.
Future<Map<String, Map<String, dynamic>>> screenerFacts(Iterable<String> symbols) async {
  final syms = symbols.toSet().toList();
  if (syms.isEmpty) return const {};
  final rows = await _sb
      .from('screener_metrics')
      .select('symbol,sector,pe,roe,de,f_score,altman_z,trend,hi52,lo52,price')
      .inFilter('symbol', syms);
  return {for (final r in rows) '${r['symbol']}': Map<String, dynamic>.from(r)};
}

/// Plain-fact flags for one holding (no advice, no scores of our own).
List<String> healthFlags(Map<String, dynamic> f, double? price) {
  double? n(String k) => (f[k] as num?)?.toDouble();
  final out = <String>[];
  if ((n('de') ?? 0) > 2) out.add('D/E ${n('de')!.toStringAsFixed(1)}');
  if (n('altman_z') != null && n('altman_z')! < 1.8) out.add('Altman Z ${n('altman_z')!.toStringAsFixed(1)}');
  if (n('f_score') != null && n('f_score')! <= 3) out.add('F-score ${n('f_score')!.toStringAsFixed(0)}');
  final p = price ?? n('price');
  if (p != null && n('lo52') != null && p <= n('lo52')! * 1.05) out.add('near 52w low');
  if (p != null && n('hi52') != null && p >= n('hi52')! * 0.95) out.add('near 52w high');
  if (n('pe') != null && n('pe')! < 0) out.add('loss-making');
  return out;
}
