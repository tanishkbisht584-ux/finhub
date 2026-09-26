import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../screen_query.dart';
import '../theme.dart';
import 'feed.dart' show filterPill, showPillSheet;
import 'stock.dart';

/// The screening engine ("screens" half of Screener): filter/rank the
/// `screener_metrics` table server-side — one PostgREST query per change,
/// <=50 rows back. Metrics are rebuilt daily by pipeline/fundamentals.py.

typedef ScreenFilter = ({String metric, bool gte, double value});
typedef ScreenPreset = ({
  String name,
  List<ScreenFilter> filters,
  String sortCol,
  bool asc
});

/// Column, chip label, curated threshold pills (label, gte, value).
/// ponytail: pill thresholds only; add a TextField row when someone asks
/// for PE < 17.3.
typedef MetricDef = ({
  String col,
  String label,
  String unit,
  List<(String, bool, double)> choices
});

const List<MetricDef> metricDefs = [
  (
    col: 'pe',
    label: 'PE',
    unit: '',
    choices: [
      ('≤ 10', false, 10),
      ('≤ 15', false, 15),
      ('≤ 25', false, 25),
      ('≥ 25', true, 25)
    ]
  ),
  (
    col: 'pb',
    label: 'PB',
    unit: '',
    choices: [('≤ 1', false, 1), ('≤ 3', false, 3), ('≥ 3', true, 3)]
  ),
  (
    col: 'mcap_cr',
    label: 'MCAP',
    unit: ' CR',
    choices: [
      ('≥ 300', true, 300),
      ('≥ 500', true, 500),
      ('≥ 5000', true, 5000),
      ('≤ 5000', false, 5000),
      ('≥ 20000', true, 20000)
    ]
  ),
  (
    col: 'div_yield',
    label: 'DIV YIELD',
    unit: '%',
    choices: [('≥ 1', true, 1), ('≥ 3', true, 3), ('≥ 5', true, 5)]
  ),
  (
    col: 'roe',
    label: 'ROE',
    unit: '%',
    choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]
  ),
  (
    col: 'roce',
    label: 'ROCE',
    unit: '%',
    choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]
  ),
  (
    col: 'de',
    label: 'DEBT/EQ',
    unit: '',
    choices: [('≤ 0.1', false, 0.1), ('≤ 0.3', false, 0.3), ('≤ 1', false, 1)]
  ),
  (
    col: 'opm',
    label: 'OPM',
    unit: '%',
    choices: [('≥ 10', true, 10), ('≥ 20', true, 20)]
  ),
  (
    col: 'sales_cagr_3y',
    label: 'SALES 3Y',
    unit: '%',
    choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 25', true, 25)]
  ),
  (
    col: 'profit_cagr_3y',
    label: 'PROFIT 3Y',
    unit: '%',
    choices: [('≥ 10', true, 10), ('≥ 20', true, 20)]
  ),
  (
    col: 'sales_cagr_5y',
    label: 'SALES 5Y',
    unit: '%',
    choices: [('≥ 10', true, 10), ('≥ 15', true, 15)]
  ),
  (
    col: 'profit_cagr_5y',
    label: 'PROFIT 5Y',
    unit: '%',
    choices: [('≥ 15', true, 15), ('≥ 25', true, 25)]
  ),
  (
    col: 'promoter_pct',
    label: 'PROMOTER',
    unit: '%',
    choices: [('≥ 50', true, 50), ('≥ 60', true, 60), ('≥ 75', true, 75)]
  ),
  // ---- Stock Analysis (S&P Global) columns, pipeline/stockanalysis.py ----
  (
    col: 'ret_1w',
    label: 'RET 1W',
    unit: '%',
    choices: [('≥ 5', true, 5), ('≤ -5', false, -5)]
  ),
  (
    col: 'ret_1m',
    label: 'RET 1M',
    unit: '%',
    choices: [('≥ 0', true, 0), ('≥ 10', true, 10), ('≤ -10', false, -10)]
  ),
  (
    col: 'ret_3m',
    label: 'RET 3M',
    unit: '%',
    choices: [('≥ 0', true, 0), ('≥ 10', true, 10), ('≤ -10', false, -10)]
  ),
  (
    col: 'ret_6m',
    label: 'RET 6M',
    unit: '%',
    choices: [('≥ 0', true, 0), ('≥ 20', true, 20), ('≤ -20', false, -20)]
  ),
  (
    col: 'ret_ytd',
    label: 'RET YTD',
    unit: '%',
    choices: [('≥ 0', true, 0), ('≥ 20', true, 20), ('≤ -10', false, -10)]
  ),
  (
    col: 'ret_1y',
    label: 'RET 1Y',
    unit: '%',
    choices: [
      ('≥ 0', true, 0),
      ('≥ 25', true, 25),
      ('≥ 50', true, 50),
      ('≤ -20', false, -20)
    ]
  ),
  (
    col: 'ret_3y',
    label: 'RET 3Y',
    unit: '%',
    choices: [('≥ 50', true, 50), ('≥ 100', true, 100), ('≥ 200', true, 200)]
  ),
  (
    col: 'ret_5y',
    label: 'RET 5Y',
    unit: '%',
    choices: [('≥ 100', true, 100), ('≥ 200', true, 200), ('≥ 500', true, 500)]
  ),
  (
    col: 'ath_pct',
    label: 'FROM ATH',
    unit: '%',
    choices: [('≥ -5', true, -5), ('≥ -20', true, -20), ('≤ -50', false, -50)]
  ),
  (
    col: 'turnover_cr',
    label: 'TURNOVER',
    unit: ' CR',
    choices: [('≥ 1', true, 1), ('≥ 10', true, 10), ('≥ 100', true, 100)]
  ),
  (
    col: 'avg_vol',
    label: 'AVG VOL',
    unit: '',
    choices: [('≥ 100000', true, 100000), ('≥ 1000000', true, 1000000)]
  ),
  (
    col: 'rel_vol',
    label: 'REL VOL',
    unit: 'x',
    choices: [('≥ 1.5', true, 1.5), ('≥ 3', true, 3)]
  ),
  (
    col: 'sharpe',
    label: 'SHARPE',
    unit: '',
    choices: [('≥ 0.5', true, 0.5), ('≥ 1', true, 1), ('≥ 2', true, 2)]
  ),
  (
    col: 'sortino',
    label: 'SORTINO',
    unit: '',
    choices: [('≥ 0.5', true, 0.5), ('≥ 1', true, 1), ('≥ 2', true, 2)]
  ),
  (
    col: 'atr',
    label: 'ATR',
    unit: '',
    choices: [('≤ 10', false, 10), ('≤ 50', false, 50)]
  ),
  (
    col: 'graham_upside',
    label: 'GRAHAM UPSIDE',
    unit: '%',
    choices: [('≥ 0', true, 0), ('≥ 25', true, 25), ('≥ 50', true, 50)]
  ),
  (
    col: 'f_score',
    label: 'F-SCORE',
    unit: '',
    choices: [('≥ 6', true, 6), ('≥ 7', true, 7), ('≥ 8', true, 8)]
  ),
  (
    col: 'ps',
    label: 'P/S',
    unit: '',
    choices: [('≤ 1', false, 1), ('≤ 3', false, 3), ('≤ 10', false, 10)]
  ),
  (
    col: 'earnings_yield',
    label: 'EARN YIELD',
    unit: '%',
    choices: [('≥ 4', true, 4), ('≥ 8', true, 8)]
  ),
  (
    col: 'fcf_yield',
    label: 'FCF YIELD',
    unit: '%',
    choices: [('≥ 3', true, 3), ('≥ 5', true, 5), ('≥ 8', true, 8)]
  ),
  (
    col: 'roic',
    label: 'ROIC',
    unit: '%',
    choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]
  ),
  (
    col: 'int_cov',
    label: 'INT COVER',
    unit: 'x',
    choices: [('≥ 3', true, 3), ('≥ 5', true, 5), ('≥ 10', true, 10)]
  ),
  (
    col: 'ev_ebitda',
    label: 'EV/EBITDA',
    unit: '',
    choices: [('≤ 8', false, 8), ('≤ 12', false, 12), ('≤ 20', false, 20)]
  ),
  (
    col: 'sector_pe',
    label: 'SECTOR PE',
    unit: '',
    choices: [('≤ 15', false, 15), ('≤ 25', false, 25)]
  ),
  (
    col: 'industry_pe',
    label: 'INDUSTRY PE',
    unit: '',
    choices: [('≤ 15', false, 15), ('≤ 25', false, 25)]
  ),
  (
    col: 'shares_yoy',
    label: 'SHARES YOY',
    unit: '%',
    choices: [('≤ 0', false, 0), ('≤ 2', false, 2), ('≥ 5', true, 5)]
  ),
  // Phase C (26 Sep): the universe technicals / quality columns 024-026 added.
  (
    col: 'rsi',
    label: 'RSI',
    unit: '',
    choices: [('≤ 30', false, 30), ('≤ 40', false, 40), ('≥ 60', true, 60), ('≥ 70', true, 70)]
  ),
  (
    col: 'altman_z',
    label: 'ALTMAN Z',
    unit: '',
    choices: [('≥ 3', true, 3), ('≥ 1.8', true, 1.8), ('≤ 1.8', false, 1.8)]
  ),
  (
    col: 'beta_5y',
    label: 'BETA',
    unit: '',
    choices: [('≤ 0.8', false, 0.8), ('≤ 1', false, 1), ('≥ 1.2', true, 1.2)]
  ),
];

const List<ScreenPreset> screenPresets = [
  (
    name: 'VALUE',
    sortCol: 'pe',
    asc: true,
    filters: [
      (metric: 'pe', gte: false, value: 15.0),
      (metric: 'roe', gte: true, value: 15.0),
      (metric: 'de', gte: false, value: 0.5),
      (metric: 'mcap_cr', gte: true, value: 500.0)
    ]
  ),
  (
    name: 'COMPOUNDERS',
    sortCol: 'profit_cagr_5y',
    asc: false,
    filters: [
      (metric: 'roe', gte: true, value: 20.0),
      (metric: 'roce', gte: true, value: 20.0),
      (metric: 'profit_cagr_5y', gte: true, value: 15.0),
      (metric: 'de', gte: false, value: 0.3)
    ]
  ),
  (
    name: 'DIVIDEND',
    sortCol: 'div_yield',
    asc: false,
    filters: [
      (metric: 'div_yield', gte: true, value: 3.0),
      (metric: 'roe', gte: true, value: 12.0),
      (metric: 'de', gte: false, value: 1.0)
    ]
  ),
  (
    name: 'GROWTH',
    sortCol: 'profit_cagr_3y',
    asc: false,
    filters: [
      (metric: 'sales_cagr_3y', gte: true, value: 15.0),
      (metric: 'profit_cagr_3y', gte: true, value: 20.0),
      (metric: 'pe', gte: false, value: 30.0)
    ]
  ),
  (
    name: 'DEBT-FREE SMALLCAP',
    sortCol: 'roe',
    asc: false,
    filters: [
      (metric: 'de', gte: false, value: 0.1),
      (metric: 'mcap_cr', gte: true, value: 300.0),
      (metric: 'mcap_cr', gte: false, value: 5000.0),
      (metric: 'roe', gte: true, value: 15.0)
    ]
  ),
  (
    name: 'PROMOTER HEAVY',
    sortCol: 'mcap_cr',
    asc: false,
    filters: [
      (metric: 'promoter_pct', gte: true, value: 60.0),
      (metric: 'roe', gte: true, value: 15.0),
      (metric: 'pe', gte: false, value: 25.0)
    ]
  ),
];

/// Plain-words line per preset — what the screen hunts, for readers the pill
/// names alone don't reach. The filter pills below it spell the exact cuts.
const presetBlurbs = {
  'VALUE': 'cheap earnings · solid returns · low debt',
  'COMPOUNDERS': 'high ROE/ROCE, profits compounding for 5 years',
  'DIVIDEND': 'pays ≥3% yield without wrecking the balance sheet',
  'GROWTH': 'sales and profits accelerating, P/E still sane',
  'DEBT-FREE SMALLCAP': 'small companies, near-zero debt, real returns',
  'PROMOTER HEAVY': 'founders own ≥60% — skin in the game',
};

// ---------- saved screens (SharedPreferences, same pattern as feed filters) ----------

typedef SavedScreen = ({
  String name,
  List<ScreenFilter> filters,
  String sortCol,
  bool asc
});

String encodeScreen(SavedScreen s) => jsonEncode({
      'name': s.name,
      'filters': [
        for (final f in s.filters)
          {'metric': f.metric, 'gte': f.gte, 'value': f.value}
      ],
      'sortCol': s.sortCol,
      'asc': s.asc,
    });

SavedScreen? decodeScreen(String raw) {
  try {
    final j = jsonDecode(raw) as Map;
    return (
      name: j['name'] as String,
      filters: [
        for (final f in j['filters'] as List)
          (
            metric: f['metric'] as String,
            gte: f['gte'] as bool,
            value: (f['value'] as num).toDouble()
          )
      ],
      sortCol: j['sortCol'] as String,
      asc: j['asc'] as bool,
    );
  } catch (_) {
    return null;
  }
}

Future<List<SavedScreen>> loadSavedScreens() async {
  final prefs = await SharedPreferences.getInstance();
  return [
    for (final raw in prefs.getStringList('saved_screens') ?? const [])
      if (decodeScreen(raw) != null) decodeScreen(raw)!
  ];
}

Future<void> persistSavedScreens(List<SavedScreen> screens) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(
      'saved_screens', [for (final s in screens) encodeScreen(s)]);
}

/// Phase C (030): the account's screens, merged over the local cache (cloud
/// wins on the same name), cache refreshed. Any failure → the local list.
Future<List<SavedScreen>> syncSavedScreens() async {
  final local = await loadSavedScreens();
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return local;
  try {
    final rows = await Supabase.instance.client
        .from('user_screens')
        .select('name,filters,sort_col,sort_asc')
        .eq('user_id', uid);
    final cloud = <String, SavedScreen>{
      for (final r in rows)
        '${r['name']}': (
          name: '${r['name']}',
          filters: [
            for (final f in (r['filters'] as List? ?? const []))
              (metric: '${f['metric']}', gte: f['gte'] == true, value: (f['value'] as num).toDouble())
          ],
          sortCol: '${r['sort_col'] ?? 'mcap_cr'}',
          asc: r['sort_asc'] == true,
        )
    };
    final merged = [
      for (final s in local)
        if (!cloud.containsKey(s.name)) s,
      ...cloud.values,
    ];
    // local-only screens (saved before 030 / offline) go up now
    for (final s in local) {
      if (!cloud.containsKey(s.name)) await cloudSaveScreen(s);
    }
    await persistSavedScreens(merged);
    return merged;
  } catch (_) {
    return local;
  }
}

Future<void> cloudSaveScreen(SavedScreen s) async {
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return;
  await Supabase.instance.client.from('user_screens').upsert({
    'user_id': uid,
    'name': s.name,
    'query': screenQueryText(s.filters),
    'filters': [
      for (final f in s.filters) {'metric': f.metric, 'gte': f.gte, 'value': f.value}
    ],
    'sort_col': s.sortCol,
    'sort_asc': s.asc,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  });
}

Future<void> cloudDeleteScreen(String name) async {
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return;
  await Supabase.instance.client.from('user_screens').delete().match({'user_id': uid, 'name': name});
}

MetricDef _def(String col) => metricDefs.firstWhere((m) => m.col == col);

String _trim(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

String filterLabel(ScreenFilter f) {
  final d = _def(f.metric);
  return '${d.label} ${f.gte ? '≥' : '≤'} ${_trim(f.value)}${d.unit}'
      .trimRight();
}

/// 'PE 14.2' · 'ROE 22%' · 'MCAP 2,800 CR' — the result-row trail bits.
String metricText(String col, num? v) {
  if (v == null) return '';
  final d = _def(col);
  final s = const {'mcap_cr', 'avg_vol', 'turnover_cr'}.contains(col)
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
      this.onSave,
      this.onTapRow,
      this.savedNames = const [],
      this.onLoadSaved,
      this.onDeleteSaved,
      this.updatedAt,
      this.blurb,
      this.queryController,
      this.queryError,
      this.onRunQuery,
      this.onCopyQuery,
      this.onMore});
  final List<Map<String, dynamic>> rows;
  final List<ScreenFilter> filters;
  final String sortCol;
  final void Function(ScreenFilter) onRemoveFilter;
  final VoidCallback? onAddFilter;
  final VoidCallback? onSort;
  final VoidCallback? onSave;
  final void Function(String symbol)? onTapRow;
  final List<String> savedNames;
  final void Function(int index)? onLoadSaved;
  final void Function(int index)? onDeleteSaved; // long-press a saved chip
  final DateTime? updatedAt;

  /// Phase C: the formula bar. Null hides it (preset pages, tests).
  final TextEditingController? queryController;
  final String? queryError;
  final VoidCallback? onRunQuery, onCopyQuery;

  /// Non-null when a further page of results exists.
  final VoidCallback? onMore;

  /// One plain-words line under a preset's title — what this screen hunts.
  final String? blurb;

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(20), children: [
      if (blurb != null) ...[
        Text(blurb!, style: mono.copyWith(fontSize: 10.5, color: inkDim)),
        const SizedBox(height: 12),
      ],
      if (queryController != null && onRunQuery != null) ...[
        Text('FORMULA', style: mono.copyWith(fontSize: 10, color: inkDim)),
        const SizedBox(height: 6),
        TextField(
          key: const Key('screenQuery'),
          controller: queryController,
          minLines: 1,
          maxLines: 3,
          style: mono.copyWith(fontSize: 12),
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => onRunQuery!(),
          decoration: InputDecoration(
              isDense: true,
              hintText: 'e.g. ${screenQueryExamples.first}',
              hintStyle: mono.copyWith(fontSize: 11, color: inkDim),
              suffixIcon: IconButton(
                  tooltip: 'Run',
                  icon: const Icon(Icons.play_arrow_rounded, color: green),
                  onPressed: onRunQuery)),
        ),
        if (queryError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(queryError!, style: mono.copyWith(fontSize: 10, color: red)),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('metric > number, joined with AND · > and < mean at least / at most',
                style: mono.copyWith(fontSize: 9.5, color: inkDim)),
          ),
        const SizedBox(height: 10),
      ],
      if (savedNames.isNotEmpty && onLoadSaved != null) ...[
        Text('SAVED${onDeleteSaved == null ? '' : ' · hold to delete'}',
            style: mono.copyWith(fontSize: 10, color: inkDim)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (var i = 0; i < savedNames.length; i++)
            GestureDetector(
              onLongPress: onDeleteSaved == null ? null : () => onDeleteSaved!(i),
              child: filterPill(savedNames[i], false, inkDim, () => onLoadSaved!(i),
                  fontSize: 10),
            ),
        ]),
        const SizedBox(height: 10),
      ],
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final f in filters)
          filterPill(filterLabel(f), true, green, () => onRemoveFilter(f),
              fontSize: 10),
        if (onAddFilter != null)
          filterPill('+ FILTER', false, green, onAddFilter!, fontSize: 10),
        if (onSort != null)
          filterPill('SORT · ${_def(sortCol).label}', false, amber, onSort!,
              fontSize: 10),
        if (onSave != null && filters.isNotEmpty)
          filterPill('SAVE', false, inkDim, onSave!, fontSize: 10),
        if (onCopyQuery != null && filters.isNotEmpty)
          filterPill('COPY', false, inkDim, onCopyQuery!, fontSize: 10),
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
        if (onMore != null)
          TextButton(
              onPressed: onMore,
              child: Text('show 50 more', style: mono.copyWith(fontSize: 12, color: green))),
        const SizedBox(height: 10),
        Text(
            '${rows.length} matches'
            '${onMore != null ? ' so far' : ''}'
            '${updatedAt != null ? ' · metrics as of ${fmtDayShort(updatedAt!)}' : ''}'
            ' · rebuilt daily',
            style: mono.copyWith(fontSize: 10)),
      ],
    ]);
  }
}

String fmtDayShort(DateTime t) {
  const m = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
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
  bool _hasMore = false;
  List<SavedScreen> _saved = const [];
  // Phase C: the typed formula. Pills regenerate it; RUN parses it into pills.
  late final TextEditingController _query =
      TextEditingController(text: screenQueryText(_filters));
  String? _queryError;

  @override
  void initState() {
    super.initState();
    _run();
    if (widget.preset == null) {
      syncSavedScreens().then((s) {
        if (mounted) setState(() => _saved = s);
      });
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _setFilters(List<ScreenFilter> next) {
    setState(() {
      _filters = next;
      _query.text = screenQueryText(next);
      _queryError = null;
    });
    _run();
  }

  void _runQuery() {
    final p = parseScreenQuery(_query.text);
    if (p.error != null) {
      setState(() => _queryError = p.error);
      return;
    }
    setState(() {
      _filters = p.filters;
      _queryError = null;
    });
    _run();
  }

  Future<void> _copyQuery() async {
    final text = _query.text.trim().isEmpty ? screenQueryText(_filters) : _query.text.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Formula copied')));
    }
  }

  Future<void> _deleteSaved(int i) async {
    final s = _saved[i];
    final next = [..._saved.where((x) => x.name != s.name)];
    await persistSavedScreens(next);
    if (mounted) setState(() => _saved = next);
    cloudDeleteScreen(s.name).then((_) {}, onError: (_) {});
  }

  Future<void> _save() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surface,
        shape: const RoundedRectangleBorder(),
        title: Text('SAVE SCREEN', style: mono.copyWith(fontSize: 12)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          style: mono.copyWith(fontSize: 13),
          decoration: InputDecoration(
              hintText: 'name…',
              hintStyle: mono.copyWith(fontSize: 12, color: inkDim)),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctl.text),
              child: Text('SAVE', style: mono.copyWith(color: green))),
        ],
      ),
    );
    final trimmed = (name ?? '').trim().toUpperCase();
    if (trimmed.isEmpty) return;
    final next = [
      ..._saved.where((s) => s.name != trimmed),
      (name: trimmed, filters: List.of(_filters), sortCol: _sortCol, asc: _asc),
    ];
    await persistSavedScreens(next);
    if (mounted) setState(() => _saved = next);
    cloudSaveScreen(next.last).then((_) {}, onError: (_) {});
  }

  void _loadSaved(int i) {
    final s = _saved[i];
    setState(() {
      _sortCol = s.sortCol;
      _asc = s.asc;
    });
    _setFilters(List.of(s.filters));
  }

  static const _page = 50;

  Future<void> _run({bool more = false}) async {
    final start = more ? _rows.length : 0;
    setState(() {
      if (!more) _loading = true;
      _failed = false;
    });
    try {
      // explicit projection: the `sa` jsonb (stock-page extras) never rides
      // along on a 50-row screen; updated_at feeds the "as of" stamp
      var q = Supabase.instance.client.from('screener_metrics').select(
          'symbol,name,price,updated_at,${metricDefs.map((m) => m.col).join(',')}');
      for (final f in _filters) {
        q = f.gte ? q.gte(f.metric, f.value) : q.lte(f.metric, f.value);
      }
      final rows = await q
          .order(_sortCol, ascending: _asc)
          .range(start, start + _page - 1)
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final fresh = [for (final r in rows) Map<String, dynamic>.from(r)];
      setState(() {
        _rows = more ? [..._rows, ...fresh] : fresh;
        _hasMore = fresh.length == _page;
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
              (ctx2) {
                void apply(bool gte, double value) {
                  Navigator.of(ctx2).pop();
                  _setFilters([
                    ..._filters.where((f) => f.metric != m.col || f.gte != gte),
                    (metric: m.col, gte: gte, value: value),
                  ]);
                }

                final ctl = TextEditingController();
                return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final (label, gte, value) in m.choices)
                          filterPill(label, false, green,
                              () => apply(gte, value.toDouble())),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        SizedBox(
                          width: 90,
                          child: TextField(
                            controller: ctl,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true, signed: true),
                            style: mono.copyWith(fontSize: 13),
                            decoration: InputDecoration(
                                isDense: true,
                                hintText: 'custom…',
                                hintStyle:
                                    mono.copyWith(fontSize: 12, color: inkDim)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        for (final (label, gte) in const [
                          ('≥', true),
                          ('≤', false)
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: filterPill(label, false, amber, () {
                              final v = double.tryParse(ctl.text.trim());
                              if (v != null) apply(gte, v);
                            }),
                          ),
                      ]),
                    ]);
              },
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
              _asc = const {'pe', 'pb', 'de', 'ps', 'ev_ebitda', 'shares_yoy'}
                  .contains(m.col);
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
          builder: (_) => StockScreen(
              company: Company.fromJson(Map<String, dynamic>.from(row)))));
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
                  blurb: presetBlurbs[widget.preset?.name],
                  savedNames: [for (final s in _saved) s.name],
                  onLoadSaved: _saved.isEmpty ? null : _loadSaved,
                  onDeleteSaved: _saved.isEmpty ? null : _deleteSaved,
                  onRemoveFilter: (f) =>
                      _setFilters([..._filters.where((x) => x != f)]),
                  onAddFilter: _addFilter,
                  onSort: _pickSort,
                  onSave: widget.preset == null ? _save : null,
                  onTapRow: _openStock,
                  queryController: _query,
                  queryError: _queryError,
                  onRunQuery: _runQuery,
                  onCopyQuery: _copyQuery,
                  onMore: _hasMore ? () => _run(more: true) : null),
    );
  }
}
