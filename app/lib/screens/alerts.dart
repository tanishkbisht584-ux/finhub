import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../alerts.dart';
import '../ledger.dart';
import '../models.dart';
import '../theme.dart';
import '../ticks.dart';
import 'feed.dart' show filterPill;
import 'stock.dart';

/// Bottom sheet from the stock page's bell: pick a rule, set the number,
/// see the warning, ADD. The symbol's existing alerts sit below with ×.
/// [initial] / [onAdd] / [onDelete] are the test seams.
class AlertSheet extends StatefulWidget {
  const AlertSheet(this.symbol,
      {super.key, this.tick, this.initial, this.onAdd, this.onDelete});
  final String symbol;
  final Tick? tick;
  final List<PriceAlert>? initial;
  final Future<void> Function(String kind, double? threshold)? onAdd;
  final Future<void> Function(int id)? onDelete;

  @override
  State<AlertSheet> createState() => _AlertSheetState();
}

class _AlertSheetState extends State<AlertSheet> {
  String _kind = 'above';
  final _value = TextEditingController();
  List<PriceAlert> _alerts = const [];
  String? _err;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.tick != null && widget.tick!.price > 0) _value.text = fmtNum(widget.tick!.price).replaceAll(',', '');
    if (widget.initial != null) {
      _alerts = widget.initial!;
    } else {
      _reload();
    }
  }

  Future<void> _reload() async {
    try {
      final a = await loadAlerts(symbol: widget.symbol);
      if (mounted) setState(() => _alerts = a);
    } catch (_) {}
  }

  double? get _threshold => double.tryParse(_value.text.trim().replaceAll(',', ''));

  Future<void> _add() async {
    final why = validateThreshold(_kind, _value.text);
    if (why != null) {
      setState(() => _err = why);
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await (widget.onAdd ?? (k, t) => addAlert(widget.symbol, k, t))(_kind, _threshold);
      if (widget.initial == null) await _reload();
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _err = '$e'.contains('price_alerts')
              ? 'alerts are not switched on for this build yet'
              : 'could not save — try again';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final needsNumber = _kind != 'hi52' && _kind != 'lo52';
    final warn = alreadyCrossed(_kind, _threshold, widget.tick);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('PRICE ALERT · ${widget.symbol}', style: mono.copyWith(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(alertHonesty, style: mono.copyWith(fontSize: 10, color: inkDim, height: 1.4)),
            const SizedBox(height: 10),
            pillRow([
              for (final k in alertKinds)
                filterPill(alertKindLabel[k]!, _kind == k, green, () => setState(() {
                      _kind = k;
                      _err = null;
                      if (k == 'move') _value.text = '3';
                      if ((k == 'above' || k == 'below') && widget.tick != null && widget.tick!.price > 0) {
                        _value.text = fmtNum(widget.tick!.price).replaceAll(',', '');
                      }
                    })),
            ]),
            if (needsNumber) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _value,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: mono.copyWith(fontSize: 14),
                decoration: InputDecoration(
                    prefixText: _kind == 'move' ? '± ' : '₹ ',
                    prefixStyle: mono.copyWith(fontSize: 14, color: inkDim),
                    suffixText: _kind == 'move' ? '%' : null,
                    hintText: _kind == 'move' ? 'percent' : 'price'),
                onChanged: (_) => setState(() => _err = null),
              ),
            ],
            if (warn != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(warn, style: mono.copyWith(fontSize: 10, color: amber)),
              ),
            if (_err != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_err!, style: mono.copyWith(fontSize: 11, color: red)),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                  onPressed: _busy || validateThreshold(_kind, _value.text) != null ? null : _add,
                  child: Text(_busy ? 'SAVING…' : 'ADD',
                      style: mono.copyWith(
                          color: _busy || validateThreshold(_kind, _value.text) != null ? inkDim : green))),
            ),
            if (_alerts.isNotEmpty) ...[
              const Divider(height: 1),
              for (final a in _alerts)
                Row(children: [
                  Expanded(
                    child: Text(a.label, style: mono.copyWith(fontSize: 12, color: a.active ? ink : inkDim)),
                  ),
                  Text(a.active ? 'armed' : 'fired',
                      style: mono.copyWith(fontSize: 10, color: a.active ? green : inkDim)),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16, color: inkDim),
                    onPressed: () async {
                      try {
                        await (widget.onDelete ?? deleteAlert)(a.id);
                        if (widget.initial == null) {
                          await _reload();
                        } else if (mounted) {
                          setState(() => _alerts = [for (final x in _alerts) if (x.id != a.id) x]);
                        }
                      } catch (_) {}
                    },
                  ),
                ]),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Profile › Price alerts / Markets › WATCHLIST › ALERTS: every active and
/// fired alert, then the history the pipeline recorded.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key, this.initialAlerts, this.initialFires});
  final List<PriceAlert>? initialAlerts;
  final List<AlertFire>? initialFires;

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<PriceAlert>? _alerts;
  List<AlertFire> _fires = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _alerts = widget.initialAlerts;
    _fires = widget.initialFires ?? const [];
    if (widget.initialAlerts == null) _load();
  }

  Future<void> _load() async {
    try {
      final a = await loadAlerts();
      List<AlertFire> f = const [];
      try {
        f = await loadFires();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _alerts = a;
        _fires = f;
        _error = null;
      });
      unawaited(loadTicks({for (final x in a) x.symbol}));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _openSymbol(String symbol) async {
    try {
      final row = await Supabase.instance.client
          .from('companies')
          .select('id,name,nse_symbol')
          .eq('nse_symbol', symbol)
          .maybeSingle();
      if (row == null || !mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => StockScreen(company: Company.fromJson(Map<String, dynamic>.from(row)))));
      if (mounted && widget.initialAlerts == null) _load();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final alerts = _alerts;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        surfaceTintColor: bg,
        elevation: 0,
        leading: const BackButton(color: ink),
        title: Text('PRICE ALERTS', style: monoLabel),
      ),
      body: alerts == null
          ? Center(
              child: _error == null
                  ? appSpinner()
                  : Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(
                            '$_error'.contains('price_alerts')
                                ? 'Price alerts are not switched on for this build yet.'
                                : 'Could not load your alerts',
                            textAlign: TextAlign.center,
                            style: mono.copyWith(fontSize: 13, height: 1.6)),
                        const SizedBox(height: 16),
                        OutlinedButton(onPressed: _load, child: const Text('Try again')),
                      ]),
                    ))
          : ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
              LedgerSection('Active', footnote: alertHonesty, children: [
                if (alerts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text('No alerts yet. Open a stock and tap the bell.',
                        style: mono.copyWith(fontSize: 12, height: 1.5)),
                  )
                else
                  for (final a in alerts)
                    GestureDetector(
                      onLongPress: () async {
                        try {
                          await deleteAlert(a.id);
                          if (widget.initialAlerts == null) {
                            await _load();
                          } else if (mounted) {
                            setState(() => _alerts = [for (final x in alerts) if (x.id != a.id) x]);
                          }
                        } catch (_) {}
                      },
                      child: LedgerRow(
                        lead: a.symbol,
                        main: a.label,
                        sub: a.active
                            ? 'armed · since ${dmy(a.createdAt.toIso8601String())}'
                            : 'fired ${a.lastFiredAt == null ? '' : hhmmIst(a.lastFiredAt!)} · tap to re-arm',
                        trail: a.active ? 'armed' : 're-arm',
                        trailColor: a.active ? green : amber,
                        onTap: a.active
                            ? () => _openSymbol(a.symbol)
                            : () async {
                                try {
                                  await rearmAlert(a.id);
                                  if (widget.initialAlerts == null) await _load();
                                } catch (_) {}
                              },
                      ),
                    ),
                if (alerts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('hold a row to delete it · tap an armed row to open the stock',
                        style: mono.copyWith(fontSize: 10, color: inkDim)),
                  ),
              ]),
              if (_fires.isNotEmpty)
                LedgerSection('History', children: [
                  const SizedBox(height: 4),
                  LedgerTable(const [
                    LtCol('When', right: false),
                    LtCol('Symbol', right: false),
                    LtCol('Rule', right: false, text: true),
                    LtCol('Price'),
                  ], [
                    for (final f in _fires)
                      (
                        cells: [
                          '${dmy(f.at.toIso8601String())} ${hhmmIst(f.at)}',
                          f.symbol,
                          alertLabel(f.kind, f.threshold),
                          fmtNum(f.price),
                        ],
                        tone: 0,
                        onTap: () => _openSymbol(f.symbol),
                      ),
                  ], initial: 20),
                ]),
            ]),
    );
  }
}
