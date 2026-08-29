import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../theme.dart';
import 'feed.dart' show filterPill, showPillSheet;
import 'stock.dart';

/// The screening engine ("screens" half of Screener): filter/rank the
/// `screener_metrics` table server-side — one PostgREST query per change,
/// <=50 rows back. Metrics are rebuilt daily by pipeline/fundamentals.py.

typedef ScreenFilter = ({String metric, bool gte, double value});
typedef ScreenPreset = ({String name, List<ScreenFilter> filters, String sortCol, bool asc});

/// Column, chip label, curated threshold pills (label, gte, value).
/// ponytail: pill thresholds only; add a TextField row when someone asks
/// for PE < 17.3.
typedef MetricDef = ({String col, String label, String unit, List<(String, bool, double)> choices});

const List<MetricDef> metricDefs = [
  (col: 'pe', label: 'PE', unit: '', choices: [
    ('≤ 10', false, 10), ('≤ 15', false, 15), ('≤ 25', false, 25), ('≥ 25', true, 25)]),
  (col: 'pb', label: 'PB', unit: '', choices: [
    ('≤ 1', false, 1), ('≤ 3', false, 3), ('≥ 3', true, 3)]),
  (col: 'mcap_cr', label: 'MCAP', unit: ' CR', choices: [
    ('≥ 300', true, 300), ('≥ 500', true, 500), ('≥ 5000', true, 5000),
    ('≤ 5000', false, 5000), ('≥ 20000', true, 20000)]),
  (col: 'div_yield', label: 'DIV YIELD', unit: '%', choices: [
    ('≥ 1', true, 1), ('≥ 3', true, 3), ('≥ 5', true, 5)]),
  (col: 'roe', label: 'ROE', unit: '%', choices: [
    ('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]),
  (col: 'roce', label: 'ROCE', unit: '%', choices: [
    ('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]),
  (col: 'de', label: 'DEBT/EQ', unit: '', choices: [
    ('≤ 0.1', false, 0.1), ('≤ 0.3', false, 0.3), ('≤ 1', false, 1)]),
  (col: 'opm', label: 'OPM', unit: '%', choices: [
    ('≥ 10', true, 10), ('≥ 20', true, 20)]),
  (col: 'sales_cagr_3y', label: 'SALES 3Y', unit: '%', choices: [
    ('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 25', true, 25)]),
  (col: 'profit_cagr_3y', label: 'PROFIT 3Y', unit: '%', choices: [
    ('≥ 10', true, 10), ('≥ 20', true, 20)]),
  (col: 'sales_cagr_5y', label: 'SALES 5Y', unit: '%', choices: [
    ('≥ 10', true, 10), ('≥ 15', true, 15)]),
  (col: 'profit_cagr_5y', label: 'PROFIT 5Y', unit: '%', choices: [
    ('≥ 15', true, 15), ('≥ 25', true, 25)]),
  (col: 'promoter_pct', label: 'PROMOTER', unit: '%', choices: [
    ('≥ 50', true, 50), ('≥ 60', true, 60), ('≥ 75', true, 75)]),
];

const List<ScreenPreset> screenPresets = [
  (name: 'VALUE', sortCol: 'pe', asc: true, filters: [
    (metric: 'pe', gte: false, value: 15.0),
    (metric: 'roe', gte: true, value: 15.0),
    (metric: 'de', gte: false, value: 0.5),
    (metric: 'mcap_cr', gte: true, value: 500.0)]),
  (name: 'COMPOUNDERS', sortCol: 'profit_cagr_5y', asc: false, filters: [
    (metric: 'roe', gte: true, value: 20.0),
    (metric: 'roce', gte: true, value: 20.0),
    (metric: 'profit_cagr_5y', gte: true, value: 15.0),
    (metric: 'de', gte: false, value: 0.3)]),
  (name: 'DIVIDEND', sortCol: 'div_yield', asc: false, filters: [
    (metric: 'div_yield', gte: true, value: 3.0),
    (metric: 'roe', gte: true, value: 12.0),
    (metric: 'de', gte: false, value: 1.0)]),
  (name: 'GROWTH', sortCol: 'profit_cagr_3y', asc: false, filters: [
    (metric: 'sales_cagr_3y', gte: true, value: 15.0),
    (metric: 'profit_cagr_3y', gte: true, value: 20.0),
    (metric: 'pe', gte: false, value: 30.0)]),
  (name: 'DEBT-FREE SMALLCAP', sortCol: 'roe', asc: false, filters: [
    (metric: 'de', gte: false, value: 0.1),
    (metric: 'mcap_cr', gte: true, value: 300.0),
    (metric: 'mcap_cr', gte: false, value: 5000.0),
    (metric: 'roe', gte: true, value: 15.0)]),
  (name: 'PROMOTER HEAVY', sortCol: 'mcap_cr', asc: false, filters: [
    (metric: 'promoter_pct', gte: true, value: 60.0),
    (metric: 'roe', gte: true, value: 15.0),
    (metric: 'pe', gte: false, value: 25.0)]),
];

MetricDef _def(String col) => metricDefs.firstWhere((m) => m.col == col);

String _trim(double v) =>
    v == v.roundToDouble() ? '${v.round()}' : '$v';

String filterLabel(ScreenFilter f) {
  final d = _def(f.metric);
  return '${d.label} ${f.gte ? '≥' : '≤'} ${_trim(f.value)}${d.unit}'.trimRight();
}

/// 'PE 14.2' · 'ROE 22%' · 'MCAP 2,800 CR' — the result-row trail bits.
String metricText(String col, num? v) {
  if (v == null) return '';
  final d = _def(col);
  final s = col == 'mcap_cr'
      ? fmtNum(v.toDouble(), decimals: 0)
      : (v.toDouble() == v.roundToDouble()
          ? '${v.round()}'
          : v.toDouble().toStringAsFixed(1));
  return '${d.label} $s${d.unit}';
}

/// Pure render half — takes rows directly so tests feed data (MarketsBody
/// pattern). The screen around it owns state and queries.
class ScreensBody extends StatelessWidget {
  const ScreensBody(this.rows,
      {super.key,
      required this.filters,
      required this.sortCol,
      required this.onRemoveFilter,
      this.onAddFilter,
      this.onSort,
      this.onTapRow,
      this.updatedAt});
  final List<Map<String, dynamic>> rows;
  final List<ScreenFilter> filters;
  final String sortCol;
  final void Function(ScreenFilter) onRemoveFilter;
  final VoidCallback? onAddFilter;
  final VoidCallback? onSort;
  final void Function(String symbol)? onTapRow;
  final DateTime? updatedAt;

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(20), children: [
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final f in filters)
          filterPill(filterLabel(f), true, green, () => onRemoveFilter(f), fontSize: 10),
        if (onAddFilter != null)
          filterPill('+ FILTER', false, green, onAddFilter!, fontSize: 10),
        if (onSort != null)
          filterPill('SORT · ${_def(sortCol).label}', false, amber, onSort!, fontSize: 10),
      ]),
      const SizedBox(height: 14),
      if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text('No matches — loosen a filter.',
              style: mono.copyWith(fontSize: 13)),
        )
      else ...[
        for (final r in rows)
          InkWell(
            onTap: onTapRow == null ? null : () => onTapRow!('${r['symbol']}'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(children: [
                SizedBox(
                    width: 86,
                    child: Text('${r['symbol']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono.copyWith(fontSize: 11))),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${r['name'] ?? r['symbol']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: ink,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                        Text(
                            [
                              if (r['price'] != null)
                                '₹${fmtNum((r['price'] as num).toDouble())}',
                              metricText(sortCol, r[sortCol] as num?),
                              for (final f in filters)
                                if (f.metric != sortCol)
                                  metricText(f.metric, r[f.metric] as num?),
                            ].where((s) => s.isNotEmpty).take(3).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: mono.copyWith(fontSize: 10)),
                      ]),
                ),
              ]),
            ),
          ),
        const SizedBox(height: 10),
        Text(
            '${rows.length} matches'
            '${rows.length == 50 ? ' (top 50)' : ''}'
            '${updatedAt != null ? ' · metrics as of ${fmtDayShort(updatedAt!)}' : ''}'
            ' · rebuilt daily',
            style: mono.copyWith(fontSize: 10)),
      ],
    ]);
  }
}

String fmtDayShort(DateTime t) {
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final ist = t.toUtc().add(const Duration(hours: 5, minutes: 30));
  return '${ist.day} ${m[ist.month - 1]}';
}

class ScreensScreen extends StatefulWidget {
  const ScreensScreen({super.key, this.preset});
  final ScreenPreset? preset;

  @override
  State<ScreensScreen> createState() => _ScreensScreenState();
}

class _ScreensScreenState extends State<ScreensScreen> {
  late List<ScreenFilter> _filters =
      List.of(widget.preset?.filters ?? const <ScreenFilter>[]);
  late String _sortCol = widget.preset?.sortCol ?? 'mcap_cr';
  late bool _asc = widget.preset?.asc ?? false;
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      var q = Supabase.instance.client.from('screener_metrics').select();
      for (final f in _filters) {
        q = f.gte ? q.gte(f.metric, f.value) : q.lte(f.metric, f.value);
      }
      final rows = await q
          .order(_sortCol, ascending: _asc)
          .limit(50)
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() {
        _rows = [for (final r in rows) Map<String, dynamic>.from(r)];
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  void _addFilter() {
    showPillSheet(
      context,
      'ADD FILTER',
      (ctx) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final m in metricDefs)
          filterPill(m.label, false, green, () {
            Navigator.of(ctx).pop();
            showPillSheet(
              context,
              m.label,
              (ctx2) => Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (label, gte, value) in m.choices)
                  filterPill(label, false, green, () {
                    Navigator.of(ctx2).pop();
                    setState(() => _filters = [
                          ..._filters.where(
                              (f) => f.metric != m.col || f.gte != gte),
                          (metric: m.col, gte: gte, value: value.toDouble()),
                        ]);
                    _run();
                  }),
              ]),
            );
          }),
      ]),
    );
  }

  void _pickSort() {
    showPillSheet(
      context,
      'SORT BY',
      (ctx) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final m in metricDefs)
          filterPill(m.label, m.col == _sortCol, amber, () {
            Navigator.of(ctx).pop();
            setState(() {
              // low-is-good columns rank ascending, the rest descending
              _asc = const {'pe', 'pb', 'de'}.contains(m.col);
              _sortCol = m.col;
            });
            _run();
          }),
      ]),
    );
  }

  Future<void> _openStock(String symbol) async {
    try {
      final row = await Supabase.instance.client
          .from('companies')
          .select('id,name,nse_symbol')
          .eq('nse_symbol', symbol)
          .maybeSingle();
      if (row == null || !mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              StockScreen(company: Company.fromJson(Map<String, dynamic>.from(row)))));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final stamp = _rows.isEmpty
        ? null
        : DateTime.tryParse('${_rows.first['updated_at'] ?? ''}');
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(widget.preset?.name ?? 'SCREENS',
            style: serif.copyWith(fontSize: 18)),
      ),
      body: _loading
          ? Center(child: appSpinner())
          : _failed
              ? Center(
                  child: GestureDetector(
                    onTap: _run,
                    child: Text('Could not run the screen — tap to retry',
                        style: mono.copyWith(fontSize: 13)),
                  ),
                )
              : ScreensBody(_rows,
                  filters: _filters,
                  sortCol: _sortCol,
                  updatedAt: stamp,
                  onRemoveFilter: (f) {
                    setState(() => _filters =
                        [..._filters.where((x) => x != f)]);
                    _run();
                  },
                  onAddFilter: _addFilter,
                  onSort: _pickSort,
                  onTapRow: _openStock),
    );
  }
}
