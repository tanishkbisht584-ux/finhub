import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../analytics.dart';
import '../charts.dart';
import '../ledger.dart';
import '../models.dart';
import '../portfolio.dart';
import '../theme.dart';
import '../ticks.dart';
import 'feed.dart' show filterPill;
import 'stock.dart';

const _honesty = 'Quotes refresh every 15 min in NSE hours. FinFlick never places orders.';
const _splitNote = 'prices as entered — a split after your buy shows as a loss until you edit the lot';

String _inr(double v) => '₹${fmtNum(v)}';
String _signed(double v, {int decimals = 0}) =>
    '${v >= 0 ? '+' : '−'}${fmtNum(v.abs(), decimals: decimals)}';
String _signedPct(double v) => '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(2)}%';
Color _tone(double v) => v > 0
    ? green
    : v < 0
        ? red
        : ink;

/// Everything the tiles and tables need, computed once per (trades, ticks).
class _Book {
  _Book(this.trades, Map<String, Tick> ticks)
      : holdings = holdingsFrom(trades).where((h) => h.qty > 0).toList()
          ..sort((a, b) => a.symbol.compareTo(b.symbol)),
        realised = holdingsFrom(trades).fold(0.0, (s, h) => s + h.realised) {
    for (final h in holdings) {
      final t = ticks[h.symbol];
      if (t == null || t.price <= 0) continue;
      price[h.symbol] = t.price;
      current += h.qty * t.price;
      invested += h.invested;
      if (t.prevClose != null) day += h.qty * (t.price - t.prevClose!);
      priced++;
    }
  }
  final List<Trade> trades;
  final List<Holding> holdings;
  final double realised;
  final price = <String, double>{};
  double current = 0, invested = 0, day = 0;
  int priced = 0;

  double get pnl => current - invested;
  double get pnlPct => invested == 0 ? 0 : pnl / invested * 100;
  double get dayPct => (current - day) == 0 ? 0 : day / (current - day) * 100;
  bool get allPriced => priced == holdings.length;
  double? get xirrValue {
    final flows = cashFlows(trades, price, DateTime.now());
    return flows == null ? null : xirr(flows);
  }
}

/// The Markets › INDIA tile strip: four numbers and an OPEN door. Self-loading
/// so markets.dart needs no new plumbing; [initialTrades] is the test seam.
class PortfolioSummary extends StatefulWidget {
  const PortfolioSummary({super.key, this.initialTrades});
  final List<Trade>? initialTrades;
  @override
  State<PortfolioSummary> createState() => _PortfolioSummaryState();
}

class _PortfolioSummaryState extends State<PortfolioSummary> {
  List<Trade>? _trades;
  bool _missing = false; // migration 028 not applied yet

  @override
  void initState() {
    super.initState();
    _trades = widget.initialTrades;
    if (_trades == null) _load();
  }

  Future<void> _load() async {
    try {
      final t = await loadTrades();
      if (!mounted) return;
      setState(() => _trades = t);
      unawaited(loadTicks({for (final x in t) x.symbol}));
    } catch (e) {
      if (mounted) setState(() => _missing = '$e'.contains('portfolio_trades'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final trades = _trades;
    return LedgerSection('Portfolio',
        action: filterPill('OPEN', false, green, () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PortfolioScreen(initialTrades: trades)));
          if (mounted) _load();
        }, fontSize: 10),
        children: [
          if (_missing)
            _note('Portfolio is not switched on for this build yet.')
          else if (trades == null)
            const SizedBox(height: 40, child: Center(child: SizedBox.shrink()))
          else if (trades.isEmpty)
            _note('No holdings yet. Tap OPEN to add a trade or import a broker CSV.')
          else
            ValueListenableBuilder<Map<String, Tick>>(
              valueListenable: ticks,
              builder: (_, m, __) {
                final b = _Book(trades, m);
                return StatGrid([
                  StatTile('INVESTED', _inr(b.invested)),
                  StatTile('CURRENT', _inr(b.current),
                      sub: b.allPriced ? null : '${b.holdings.length - b.priced} awaiting quotes'),
                  StatTile('DAY', _signed(b.day), sub: _signedPct(b.dayPct), color: _tone(b.day)),
                  StatTile('OVERALL', _signed(b.pnl), sub: _signedPct(b.pnlPct), color: _tone(b.pnl)),
                ], columns: 4);
              },
            ),
        ]);
  }
}

Widget _note(String s) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(s, style: mono.copyWith(fontSize: 12, height: 1.5)),
    );

class PortfolioScreen extends StatefulWidget {
  const PortfolioScreen({super.key, this.initialTrades, this.initialFacts});
  final List<Trade>? initialTrades;
  final Map<String, Map<String, dynamic>>? initialFacts; // test seam
  @override
  State<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends State<PortfolioScreen> {
  List<Trade>? _trades;
  Map<String, Map<String, dynamic>> _facts = const {};
  Object? _error;
  String _alloc = 'sector';

  @override
  void initState() {
    super.initState();
    _trades = widget.initialTrades;
    _facts = widget.initialFacts ?? const {};
    if (widget.initialTrades == null) {
      _load();
    } else if (widget.initialFacts == null) {
      _loadFacts();
    }
  }

  Future<void> _load() async {
    try {
      final t = await loadTrades();
      if (!mounted) return;
      setState(() {
        _trades = t;
        _error = null;
      });
      unawaited(loadTicks({for (final x in t) x.symbol}));
      unawaited(_loadFacts());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadFacts() async {
    try {
      final f = await screenerFacts({for (final t in _trades ?? const <Trade>[]) t.symbol});
      if (mounted) setState(() => _facts = f);
    } catch (_) {}
  }

  Future<void> _openSymbol(String symbol) async {
    try {
      final row = await Supabase.instance.client
          .from('companies')
          .select('id,name,nse_symbol')
          .eq('nse_symbol', symbol)
          .maybeSingle();
      if (row == null || !mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => StockScreen(company: Company.fromJson(Map<String, dynamic>.from(row)))));
    } catch (_) {}
  }

  Future<void> _delete(Trade t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surface,
        title: Text('Delete this trade?', style: serif.copyWith(fontSize: 16)),
        content: Text('${t.side.toUpperCase()} ${fmtNum(t.qty, decimals: 0)} ${t.symbol} @ ${_inr(t.price)} · ${ymd(t.tradedOn)}',
            style: mono.copyWith(fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('KEEP')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('DELETE', style: mono.copyWith(color: red))),
        ],
      ),
    );
    if (ok != true || t.id == null) return;
    try {
      await deleteTrade(t.id!);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not delete')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final trades = _trades;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        surfaceTintColor: bg,
        elevation: 0,
        leading: const BackButton(color: ink),
        title: Text('PORTFOLIO', style: monoLabel),
        actions: [
          TextButton(
              onPressed: _import,
              child: Text('IMPORT', style: mono.copyWith(fontSize: 11, color: green))),
          IconButton(
              tooltip: 'Add trade',
              onPressed: _addTrade,
              icon: const Icon(Icons.add, color: ink)),
        ],
      ),
      body: trades == null
          ? Center(
              child: _error == null
                  ? appSpinner()
                  : Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(
                            '$_error'.contains('portfolio_trades')
                                ? 'Portfolio is not switched on for this build yet.'
                                : 'Could not load your portfolio',
                            textAlign: TextAlign.center,
                            style: mono.copyWith(fontSize: 13, height: 1.6)),
                        const SizedBox(height: 16),
                        OutlinedButton(onPressed: _load, child: const Text('Try again')),
                      ]),
                    ))
          : ValueListenableBuilder<Map<String, Tick>>(
              valueListenable: ticks,
              builder: (_, m, __) => _body(_Book(trades, m)),
            ),
    );
  }

  Widget _body(_Book b) {
    if (b.trades.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('No holdings yet.\nTap + to add a trade, or IMPORT a broker CSV.',
              textAlign: TextAlign.center, style: mono.copyWith(fontSize: 13, height: 1.6)),
        ),
      );
    }
    final x = b.xirrValue;
    String sector(String s) => '${_facts[s]?['sector'] ?? 'Other'}';
    final alloc = allocation(b.holdings, b.price, _alloc == 'sector' ? sector : (s) => s);
    final allocSorted = alloc.entries.toList()..sort((a, c) => c.value.compareTo(a.value));
    const palette = [green, amber, Color(0xFF6FA8DC), Color(0xFFB07CC6), Color(0xFFE28C5A), inkDim];
    final flagged = [
      for (final h in b.holdings)
        if (_facts[h.symbol] != null)
          for (final f in healthFlags(_facts[h.symbol]!, b.price[h.symbol])) (h.symbol, f)
    ];
    final up = b.holdings.where((h) => _facts[h.symbol]?['trend'] == 'bullish').length;
    final down = b.holdings.where((h) => _facts[h.symbol]?['trend'] == 'bearish').length;
    double wPe = 0, wTot = 0;
    for (final h in b.holdings) {
      final pe = (_facts[h.symbol]?['pe'] as num?)?.toDouble(), p = b.price[h.symbol];
      if (pe == null || pe <= 0 || p == null) continue;
      wPe += pe * h.qty * p;
      wTot += h.qty * p;
    }
    return ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
      LedgerSection('Summary', footnote: _honesty, children: [
        const SizedBox(height: 8),
        StatGrid([
          StatTile('INVESTED', _inr(b.invested)),
          StatTile('CURRENT', _inr(b.current),
              sub: b.allPriced ? null : '${b.holdings.length - b.priced} awaiting quotes'),
          StatTile('DAY', _signed(b.day), sub: _signedPct(b.dayPct), color: _tone(b.day)),
          StatTile('OVERALL', _signed(b.pnl), sub: _signedPct(b.pnlPct), color: _tone(b.pnl)),
          StatTile('REALISED', _signed(b.realised), color: _tone(b.realised)),
          StatTile('XIRR', x == null ? '—' : _signedPct(x * 100),
              sub: x == null
                  ? (b.allPriced ? 'needs a buy and a value' : 'awaiting quotes')
                  : 'annualised',
              color: x == null ? inkDim : _tone(x)),
        ]),
      ]),
      LedgerSection('Holdings', footnote: 'LTP = last 15-min quote · $_splitNote', children: [
        const SizedBox(height: 4),
        LedgerTable(const [
          LtCol('Symbol', right: false),
          LtCol('Qty'),
          LtCol('Avg'),
          LtCol('LTP'),
          LtCol('Day'),
          LtCol('P&L'),
          LtCol('%'),
        ], [
          for (final h in b.holdings)
            () {
              final p = b.price[h.symbol];
              final t = ticks.value[h.symbol];
              final pnl = p == null ? null : h.qty * (p - h.avgCost);
              return (
                cells: [
                  h.overSold ? '${h.symbol} ⚠' : h.symbol,
                  fmtNum(h.qty, decimals: h.qty == h.qty.roundToDouble() ? 0 : 2),
                  fmtNum(h.avgCost),
                  p == null ? '—' : fmtNum(p),
                  t?.changePct == null ? '—' : fmtPct(t!.changePct),
                  pnl == null ? '—' : _signed(pnl),
                  pnl == null || h.invested == 0 ? '—' : _signedPct(pnl / h.invested * 100),
                ],
                tone: pnl == null ? 0 : pnl.sign.toInt(),
                onTap: () => _openSymbol(h.symbol),
              );
            }(),
        ]),
        if (b.holdings.any((h) => h.overSold))
          _note('⚠ a sell exceeded the lots held — add the missing buy or delete the sell'),
      ]),
      if (alloc.isNotEmpty)
        LedgerSection('Allocation',
            action: pillRow([
              for (final (k, l) in const [('sector', 'SECTOR'), ('stock', 'STOCK')])
                filterPill(l, _alloc == k, green, () => setState(() => _alloc = k), fontSize: 9),
            ]),
            footnote: 'share of current value · sector from the daily screener',
            children: [
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Donut([
                  for (var i = 0; i < allocSorted.length; i++)
                    (allocSorted[i].value, palette[i % palette.length], allocSorted[i].key)
                ], center: '${allocSorted.length}'),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(children: [
                    for (var i = 0; i < allocSorted.length && i < 8; i++)
                      LedgerRow(
                        lead: null,
                        main: allocSorted[i].key,
                        trail: '${(allocSorted[i].value * 100).toStringAsFixed(1)}%',
                        bar: allocSorted[i].value,
                        barColor: palette[i % palette.length],
                      ),
                  ]),
                ),
              ]),
            ]),
      if (_facts.isNotEmpty)
        LedgerSection('Health', footnote: 'facts from the daily screener, not advice', children: [
          const SizedBox(height: 8),
          StatGrid([
            StatTile('P/E (weighted)', wTot == 0 ? '—' : (wPe / wTot).toStringAsFixed(1),
                sub: 'by current value'),
            StatTile('TREND UP', '$up', sub: 'of ${b.holdings.length}', color: up > 0 ? green : ink),
            StatTile('TREND DOWN', '$down', sub: 'of ${b.holdings.length}', color: down > 0 ? red : ink),
          ]),
          const SizedBox(height: 6),
          if (flagged.isEmpty)
            _note('no balance-sheet or price flags on your holdings')
          else
            for (final (sym, flag) in flagged)
              LedgerRow(lead: sym, main: flag, trailColor: amber, onTap: () => _openSymbol(sym)),
        ]),
      LedgerSection('Trades', footnote: 'hold a row to delete it', children: [
        const SizedBox(height: 4),
        LedgerTable(const [
          LtCol('Date', right: false),
          LtCol('Symbol', right: false),
          LtCol('Side', right: false),
          LtCol('Qty'),
          LtCol('Price'),
          LtCol('Value'),
          LtCol('Src', right: false),
        ], [
          for (final t in b.trades.reversed)
            (
              cells: [
                ymd(t.tradedOn),
                t.symbol,
                t.side.toUpperCase(),
                fmtNum(t.qty, decimals: t.qty == t.qty.roundToDouble() ? 0 : 2),
                fmtNum(t.price),
                fmtNum(t.value, decimals: 0),
                t.source,
              ],
              tone: t.isBuy ? 0 : 1,
              onTap: () => _delete(t),
            ),
        ], initial: 10, toneCol: 2),
      ]),
    ]);
  }

  // ---------- add one trade ----------

  Future<void> _addTrade() async {
    final symbol = TextEditingController(), qty = TextEditingController(), price = TextEditingController();
    final note = TextEditingController();
    var side = 'buy';
    var date = DateTime.now();
    String? err;
    var busy = false;
    final added = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: bg,
      shape: const RoundedRectangleBorder(),
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('ADD A TRADE', style: mono.copyWith(fontSize: 12, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                pillRow([
                  for (final (k, l) in const [('buy', 'BUY'), ('sell', 'SELL')])
                    filterPill(l, side == k, k == 'buy' ? green : red, () => setSheet(() => side = k)),
                ]),
                const SizedBox(height: 8),
                _field(symbol, 'NSE symbol (e.g. TCS)', caps: true),
                Row(children: [
                  Expanded(child: _field(qty, 'quantity', num: true)),
                  const SizedBox(width: 8),
                  Expanded(child: _field(price, 'price per share ₹', num: true)),
                ]),
                _field(note, 'note (optional)'),
                const SizedBox(height: 8),
                Row(children: [
                  filterPill('DATE · ${ymd(date)}', false, green, () async {
                    final d = await showDatePicker(
                        context: ctx, initialDate: date, firstDate: DateTime(1995), lastDate: DateTime.now());
                    if (d != null) setSheet(() => date = d);
                  }),
                  const Spacer(),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            final s = normaliseSymbol(symbol.text);
                            final q = double.tryParse(qty.text.trim()), p = double.tryParse(price.text.trim());
                            if (s.isEmpty || q == null || q <= 0 || p == null || p < 0) {
                              setSheet(() => err = 'symbol, a quantity above 0 and a price are needed');
                              return;
                            }
                            setSheet(() {
                              busy = true;
                              err = null;
                            });
                            try {
                              if (!(await knownSymbols([s])).contains(s)) {
                                setSheet(() {
                                  busy = false;
                                  err = '$s is not an NSE symbol we know';
                                });
                                return;
                              }
                              await addTrades([
                                Trade(symbol: s, side: side, qty: q, price: p, tradedOn: date, note: note.text.trim())
                              ]);
                              if (ctx.mounted) Navigator.pop(ctx, true);
                            } catch (e) {
                              setSheet(() {
                                busy = false;
                                err = 'could not save — ${'$e'.contains('portfolio_trades') ? 'portfolio not switched on yet' : 'try again'}';
                              });
                            }
                          },
                    child: Text(busy ? 'SAVING…' : 'ADD', style: mono.copyWith(color: green)),
                  ),
                ]),
                if (err != null) Text(err!, style: mono.copyWith(fontSize: 11, color: red)),
              ]),
            ),
          ),
        ),
      ),
    );
    if (added == true) {
      track('portfolio_trade', const {'source': 'manual'});
      await _load();
    }
  }

  // ---------- broker CSV import ----------

  Future<void> _import() async {
    final text = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: bg,
      shape: const RoundedRectangleBorder(),
      isScrollControlled: true,
      builder: (ctx) => _ImportSheet(),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    final parsed = parseTradesCsv(text);
    if (parsed.rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No holdings found — the file needs a symbol/ISIN column and a quantity column')));
      return;
    }
    // Resolve: ISIN → symbol for rows without one (Groww), then confirm
    // every symbol against the companies table. Lookups failing = nothing
    // matched, never a crash: the review sheet shows red rows + RE-CHECK.
    var byIsin = const <String, String>{};
    if (parsed.rows.any((r) => r.symbol.isEmpty && r.isin.isNotEmpty)) {
      try {
        byIsin = await symbolsByIsin(parsed.rows.map((r) => r.isin));
      } catch (_) {}
    }
    final resolved = <({CsvRow row, String symbol})>[
      for (final r in parsed.rows) (row: r, symbol: r.symbol.isNotEmpty ? r.symbol : (byIsin[r.isin] ?? ''))
    ];
    var known = const <String>{};
    try {
      known = await knownSymbols(resolved.map((e) => e.symbol));
    } catch (_) {}
    if (!mounted) return;
    final ok = await showModalBottomSheet<List<Trade>>(
      context: context,
      backgroundColor: bg,
      shape: const RoundedRectangleBorder(),
      isScrollControlled: true,
      builder: (_) => _ReviewSheet(resolved, known, parsed),
    );
    if (ok == null || ok.isEmpty || !mounted) return;
    try {
      await addTrades(ok);
      track('portfolio_import', {'source': parsed.source, 'rows': ok.length});
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('$e'.contains('portfolio_trades')
                ? 'Portfolio is not switched on for this build yet'
                : 'Could not import')));
      }
    }
  }
}

Widget _field(TextEditingController c, String hint, {bool num = false, bool caps = false}) => TextField(
      controller: c,
      keyboardType: num ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
      textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.none,
      style: mono.copyWith(fontSize: 14),
      decoration: InputDecoration(hintText: hint, hintStyle: mono.copyWith(fontSize: 12, color: inkDim)),
    );

/// PICK FILE (file_picker, CSV/TXT) or PASTE — returns the raw text.
class _ImportSheet extends StatefulWidget {
  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  final _text = TextEditingController();
  String? _err;

  Future<void> _pick() async {
    try {
      final f = await FilePicker.pickFile();
      if (f == null) return;
      if (f.extension?.toLowerCase() == 'xlsx' || f.extension?.toLowerCase() == 'xls') {
        setState(() => _err = 'Excel files are not read — open it in Sheets/Excel and save as CSV');
        return;
      }
      final bytes = await f.readAsBytes();
      if (mounted) Navigator.pop(context, utf8.decode(bytes, allowMalformed: true));
    } catch (e) {
      setState(() => _err = 'could not open a file picker on this phone — paste the CSV instead');
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('IMPORT FROM YOUR BROKER', style: mono.copyWith(fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                  'Zerodha Console › Reports › Tradebook (best: has dates) or Holdings · Kite holdings download · Groww or Upstox holdings export. CSV only — save Excel exports as CSV first.',
                  style: mono.copyWith(fontSize: 10, height: 1.5, color: inkDim)),
              const SizedBox(height: 10),
              pillRow([
                filterPill('PICK FILE', false, green, _pick),
                filterPill('PASTE BELOW', false, green, () {}),
              ]),
              const SizedBox(height: 8),
              TextField(
                controller: _text,
                minLines: 4,
                maxLines: 8,
                style: mono.copyWith(fontSize: 11),
                decoration: InputDecoration(
                    hintText: 'symbol,trade_type,quantity,price,trade_date\nTCS,buy,10,3900,2026-06-12',
                    hintStyle: mono.copyWith(fontSize: 11, color: inkDim)),
              ),
              if (_err != null) Text(_err!, style: mono.copyWith(fontSize: 11, color: red)),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                    onPressed: () => Navigator.pop(context, _text.text),
                    child: Text('REVIEW', style: mono.copyWith(color: green))),
              ),
            ]),
          ),
        ),
      );
}

/// Matched rows in ink, unmatched in red with an editable symbol; a toggle
/// skips a row. Returns the trades to insert.
class _ReviewSheet extends StatefulWidget {
  const _ReviewSheet(this.rows, this.known, this.parsed);
  final List<({CsvRow row, String symbol})> rows;
  final Set<String> known;
  final ParsedCsv parsed;
  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  late final List<TextEditingController> _sym =
      [for (final r in widget.rows) TextEditingController(text: r.symbol)];
  late final List<bool> _keep = [for (final r in widget.rows) widget.known.contains(r.symbol)];
  late Set<String> _known = {...widget.known};
  bool _checking = false;

  Future<void> _recheck() async {
    setState(() => _checking = true);
    try {
      final more = await knownSymbols([for (final c in _sym) normaliseSymbol(c.text)]);
      if (mounted) {
        setState(() {
          _known = {..._known, ...more};
          for (var i = 0; i < _sym.length; i++) {
            if (_known.contains(normaliseSymbol(_sym[i].text))) _keep[i] = true;
          }
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.parsed;
    final today = DateTime.now();
    final ready = [
      for (var i = 0; i < widget.rows.length; i++)
        if (_keep[i] && _known.contains(normaliseSymbol(_sym[i].text))) i
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('REVIEW · ${p.source.toUpperCase()} · ${widget.rows.length} rows',
                style: mono.copyWith(fontSize: 12, fontWeight: FontWeight.w700)),
            if (!p.dated)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('no trade dates in this file — every lot is dated today, so XIRR is approximate',
                    style: mono.copyWith(fontSize: 10, color: amber)),
              ),
            if (p.skipped.isNotEmpty)
              Text('${p.skipped.length} line(s) without a quantity/price were ignored',
                  style: mono.copyWith(fontSize: 10, color: inkDim)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
              child: ListView(shrinkWrap: true, children: [
                for (var i = 0; i < widget.rows.length; i++)
                  () {
                    final r = widget.rows[i].row;
                    final ok = _known.contains(normaliseSymbol(_sym[i].text));
                    return Row(children: [
                      Checkbox(
                          value: _keep[i],
                          activeColor: green,
                          onChanged: ok ? (v) => setState(() => _keep[i] = v ?? false) : null),
                      SizedBox(
                        width: 96,
                        child: TextField(
                          controller: _sym[i],
                          textCapitalization: TextCapitalization.characters,
                          style: mono.copyWith(fontSize: 12, color: ok ? ink : red),
                          decoration: InputDecoration(
                              isDense: true,
                              hintText: r.name.isEmpty ? 'symbol' : r.name,
                              hintStyle: mono.copyWith(fontSize: 10, color: inkDim)),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            '${r.side.toUpperCase()} ${fmtNum(r.qty, decimals: 0)} @ ${fmtNum(r.price)}'
                            '${r.date == null ? '' : ' · ${ymd(r.date!)}'}'
                            '${ok ? '' : ' · not an NSE symbol we know'}',
                            style: mono.copyWith(fontSize: 10, color: ok ? inkDim : red)),
                      ),
                    ]);
                  }(),
              ]),
            ),
            Row(children: [
              if (ready.length < widget.rows.length)
                TextButton(
                    onPressed: _checking ? null : _recheck,
                    child: Text(_checking ? 'CHECKING…' : 'RE-CHECK SYMBOLS', style: mono.copyWith(fontSize: 11))),
              const Spacer(),
              TextButton(
                onPressed: ready.isEmpty
                    ? null
                    : () => Navigator.pop(context, [
                          for (final i in ready)
                            Trade(
                                symbol: normaliseSymbol(_sym[i].text),
                                side: widget.rows[i].row.side,
                                qty: widget.rows[i].row.qty,
                                price: widget.rows[i].row.price,
                                tradedOn: widget.rows[i].row.date ?? today,
                                source: p.source)
                        ]),
                child: Text('IMPORT ${ready.length}', style: mono.copyWith(color: ready.isEmpty ? inkDim : green)),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
