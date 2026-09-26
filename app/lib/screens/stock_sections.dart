import 'package:flutter/material.dart';

import '../fundamentals.dart';
import '../heat.dart';
import '../ledger.dart';
import '../models.dart';
import '../theme.dart';
import 'feed.dart' show filterPill;

/// Screener-style statement tables and strips for the stock page. All render
/// from FundamentalsData; a row that is null in every period disappears, so
/// banks/NBFCs (no inventory, no OPM) get shorter tables, not dashes.

const pnlRows = [
  ('Sales', 'sales', CellFmt.cr),
  ('Expenses', 'expenses', CellFmt.cr),
  ('Operating Profit', 'op_profit', CellFmt.cr),
  ('OPM %', 'opm', CellFmt.pct),
  ('Other Income', 'other_income', CellFmt.cr),
  ('Interest', 'interest', CellFmt.cr),
  ('Depreciation', 'depreciation', CellFmt.cr),
  ('Profit before tax', 'pbt', CellFmt.cr),
  ('Tax %', 'tax_pct', CellFmt.pct),
  ('Net Profit', 'net_profit', CellFmt.cr),
  ('EPS in Rs', 'eps', CellFmt.num2),
  ('Dividend Payout %', 'div_payout', CellFmt.pct),
];

const quarterRows = [
  ('Sales', 'sales', CellFmt.cr),
  ('Expenses', 'expenses', CellFmt.cr),
  ('Operating Profit', 'op_profit', CellFmt.cr),
  ('OPM %', 'opm', CellFmt.pct),
  ('Other Income', 'other_income', CellFmt.cr),
  ('Interest', 'interest', CellFmt.cr),
  ('Profit before tax', 'pbt', CellFmt.cr),
  ('Tax %', 'tax_pct', CellFmt.pct),
  ('Net Profit', 'net_profit', CellFmt.cr),
  ('EPS in Rs', 'eps', CellFmt.num2),
];

const bsRows = [
  ('Equity Capital', 'equity_cap', CellFmt.cr),
  ('Reserves', 'reserves', CellFmt.cr),
  ('Borrowings', 'borrowings', CellFmt.cr),
  ('Other Liabilities', 'other_liab', CellFmt.cr),
  ('Fixed Assets', 'fixed_assets', CellFmt.cr),
  ('Investments', 'investments', CellFmt.cr),
  ('Other Assets', 'other_assets', CellFmt.cr),
  ('Total Assets', 'total_assets', CellFmt.cr),
];

const cfRows = [
  ('Cash from Operating', 'cfo', CellFmt.cr),
  ('Cash from Investing', 'cfi', CellFmt.cr),
  ('Cash from Financing', 'cff', CellFmt.cr),
  ('Net Cash Flow', 'net_cf', CellFmt.cr),
  ('Free Cash Flow', 'fcf', CellFmt.cr),
];

const ratioRows = [
  ('Debtor Days', 'debtor_days', CellFmt.days),
  ('Inventory Days', 'inventory_days', CellFmt.days),
  ('Days Payable', 'payable_days', CellFmt.days),
  ('Working Capital Days', 'wc_days', CellFmt.days),
  ('ROCE %', 'roce', CellFmt.pct),
  ('ROE %', 'roe', CellFmt.pct),
];

const shareholdingRows = [
  ('Promoters %', 'promoters', CellFmt.pct),
  ('FIIs %', 'fiis', CellFmt.pct),
  ('DIIs %', 'diis', CellFmt.pct),
  ('Government %', 'govt', CellFmt.pct),
  ('Public %', 'public', CellFmt.pct),
  ('Employee Trusts %', 'employee_trusts', CellFmt.pct),
  ('Others %', 'others', CellFmt.pct),
  ('No. of Shareholders', 'n_holders', CellFmt.cr),
];

/// MC's "Others" bucket: whatever the filed split leaves over (> 0.05%).
/// Only for quarters that carry the FII / DII split — a master-only quarter
/// (promoters + public = 100) has no remainder to show.
Map<String, Map<String, dynamic>> withOthers(Map<String, Map<String, dynamic>> sh) => {
      for (final e in sh.entries)
        e.key: () {
          final d = e.value;
          if (d['fiis'] is! num && d['diis'] is! num) return d;
          final known = [
            for (final k in const ['promoters', 'fiis', 'diis', 'govt', 'public', 'employee_trusts'])
              if (d[k] is num) (d[k] as num).toDouble()
          ].fold(0.0, (a, b) => a + b);
          final rest = 100 - known;
          return rest > 0.05 ? {...d, 'others': double.parse(rest.toStringAsFixed(2))} : d;
        }(),
    };

/// Sticky label column + horizontally scrollable period columns. reverse:true
/// starts the scroll at the newest period (Screener keeps oldest on the left).
/// [heat] tints each cell by its change vs the previous period (deltaHeat).
class StatementTable extends StatelessWidget {
  const StatementTable(
      {super.key,
      required this.periods,
      required this.rows,
      required this.byPeriod,
      this.heat = false});
  final List<String> periods; // ascending
  final List<(String, String, CellFmt)> rows;
  final Map<String, Map<String, dynamic>> byPeriod;
  final bool heat;

  @override
  Widget build(BuildContext context) {
    // Review 20 Sep: a row that is null OR zero in every shown period says
    // nothing (Employee Trusts 0% for TCS) — drop it, not dash it.
    final visible = [
      for (final r in rows)
        if (periods.any((p) {
          final v = byPeriod[p]?[r.$2];
          return v is num && v != 0;
        }))
          r
    ];
    if (visible.isEmpty) return const SizedBox.shrink();
    Widget cell(String s, {bool head = false, bool label = false, Color? bg}) =>
        Container(
          height: 28,
          width: label ? null : 68,
          alignment: label ? Alignment.centerLeft : Alignment.centerRight,
          padding: label ? EdgeInsets.zero : const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
              color: bg,
              border: head
                  ? const Border(bottom: BorderSide(color: border))
                  : null),
          child: Text(s,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono.copyWith(fontSize: 11, color: head ? inkDim : ink)),
        );
    Color? tint(int i, (String, String, CellFmt) r) {
      if (!heat || i == 0) return null;
      final cur = byPeriod[periods[i]]?[r.$2] as num?;
      final prev = byPeriod[periods[i - 1]]?[r.$2] as num?;
      // ponytail: pct/days rows compare raw points at scale 3 (a 3-point OPM
      // move is big); money rows compare % change at scale 20.
      final points = r.$3 == CellFmt.pct || r.$3 == CellFmt.days;
      final c = deltaHeat(cur, prev, scale: points ? 3 : 20, points: points);
      return c == border ? null : c;
    }

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 124,
        child: Column(children: [
          cell('', head: true, label: true),
          for (final r in visible) cell(r.$1, head: true, label: true),
        ]),
      ),
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: Row(children: [
            for (var i = 0; i < periods.length; i++)
              Column(children: [
                cell(periodLabel(periods[i]), head: true),
                for (final r in visible)
                  cell(fmtCell(byPeriod[periods[i]]?[r.$2] as num?, r.$3),
                      bg: tint(i, r)),
              ]),
          ]),
        ),
      ),
    ]);
  }
}

const _cagrCols = [('y10', '10Y'), ('y5', '5Y'), ('y3', '3Y'), ('ttm', 'TTM')];
const _cagrRows = [
  ('sales', 'Sales'), ('profit', 'Profit'), ('price', 'Price'), ('roe', 'ROE')
];

/// GROWTH heat grid: Sales / Profit / Price / ROE × 10Y / 5Y / 3Y / TTM, each
/// cell tinted by its compounded rate (scale 20: 20%+ is the deepest tint).
Widget growthGrid(Map<String, dynamic> cagr) {
  Map<String, dynamic> block(String k) =>
      (cagr[k] as Map?)?.cast<String, dynamic>() ?? const {};
  final rows = [
    for (final (k, l) in _cagrRows)
      if (block(k).isNotEmpty) (k, l)
  ];
  if (rows.isEmpty) return const SizedBox.shrink();
  return Column(children: [
    Row(children: [
      const SizedBox(width: 60),
      for (final (_, l) in _cagrCols) ...[
        const SizedBox(width: 8),
        Expanded(
            child: Text(l,
                textAlign: TextAlign.center,
                style: mono.copyWith(fontSize: 10))),
      ],
    ]),
    const SizedBox(height: 6),
    for (final (k, l) in rows) ...[
      Row(children: [
        SizedBox(width: 60, child: Text(l, style: mono.copyWith(fontSize: 11))),
        for (final (ck, _) in _cagrCols) ...[
          const SizedBox(width: 8),
          Expanded(
            child: HeatCell('', (block(k)[ck] as num?)?.toDouble(),
                scale: 20,
                height: 44,
                pctText: fmtCell(block(k)[ck] as num?, CellFmt.pct)),
          ),
        ],
      ]),
      const SizedBox(height: 6),
    ],
  ]);
}

/// Annual-report links + recent NSE announcements from the docs row.
// ---------------- 034: full F&O chain ----------------

/// Strike row as stored: [k, ceLtp, ceOi, ceChg, ceVol, peLtp, peOi, peChg, peVol].
typedef StrikeRow = List<num?>;

List<StrikeRow> strikesOf(Map<String, dynamic> expiry) => [
      for (final s in (expiry['s'] as List? ?? const []))
        [for (final v in (s as List)) v as num?]
    ];

/// PCR, max call/put OI strikes (within ±15 % of spot, all when spot is
/// unknown) and max pain for one expiry.
({double? pcr, num? maxCe, num? maxPe, num? maxPain}) chainStats(
    List<StrikeRow> s, double? und) {
  if (s.isEmpty) return (pcr: null, maxCe: null, maxPe: null, maxPain: null);
  num oi(StrikeRow r, int i) => r[i] ?? 0;
  final ce = s.fold<num>(0, (a, r) => a + oi(r, 2));
  final pe = s.fold<num>(0, (a, r) => a + oi(r, 6));
  final near = und == null
      ? s
      : [for (final r in s) if (((r[0]! / und) - 1).abs() <= 0.15) r];
  final pool = near.isEmpty ? s : near;
  StrikeRow best(int i) => pool.reduce((a, b) => oi(a, i) >= oi(b, i) ? a : b);
  num? pain;
  num? painV;
  for (final r in s) {
    final k = r[0]!;
    final v = s.fold<num>(
        0, (a, x) => a + (k - x[0]!).clamp(0, double.infinity) * oi(x, 2) + (x[0]! - k).clamp(0, double.infinity) * oi(x, 6));
    if (painV == null || v < painV) {
      painV = v;
      pain = k;
    }
  }
  return (
    pcr: ce == 0 ? null : (pe / ce),
    maxCe: best(2)[0],
    maxPe: best(6)[0],
    maxPain: pain,
  );
}

/// The ±[each] strikes around the money (all when spot is unknown).
List<StrikeRow> atmWindow(List<StrikeRow> s, double? und, int each) {
  if (und == null || s.length <= 2 * each) return s;
  var at = s.indexWhere((r) => r[0]! >= und);
  if (at < 0) at = s.length;
  final lo = (at - each).clamp(0, s.length);
  final hi = (at + each).clamp(0, s.length);
  return s.sublist(lo, hi);
}

/// Every expiry and strike for one underlying (fno_chain.data + asof):
/// expiry pills, that expiry's futures line, PCR / max OI / max pain, and
/// the ladder around the money with SHOW ALL.
class ChainSection extends StatefulWidget {
  const ChainSection(this.data, {super.key, this.title = 'F&O', this.stampPrefix = 'NSE'});
  final Map<String, dynamic> data;
  final String title;
  final String stampPrefix;

  @override
  State<ChainSection> createState() => _ChainSectionState();
}

class _ChainSectionState extends State<ChainSection> {
  int _exp = 0;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final exps = [
      for (final e in (widget.data['exp'] as List? ?? const []))
        Map<String, dynamic>.from(e as Map)
    ];
    if (exps.isEmpty) return const SizedBox.shrink();
    final i = _exp.clamp(0, exps.length - 1);
    final e = exps[i];
    final und = (widget.data['u'] as num?)?.toDouble();
    final lot = widget.data['lot'];
    final strikes = strikesOf(e);
    final st = chainStats(strikes, und);
    final fut = (e['fut'] as List?)?.cast<num?>();
    final shown = _all ? strikes : atmWindow(strikes, und, 8);
    String n0(num? v) => v == null ? '—' : fmtNum(v.toDouble(), decimals: 0);
    String px(num? v) => v == null ? '—' : fmtNum(v.toDouble());
    String signed(num? v) => v == null ? '—' : '${v >= 0 ? '+' : '−'}${fmtNum(v.abs().toDouble(), decimals: 0)}';
    return LedgerSection(widget.title,
        action: Text('${widget.stampPrefix} · ${dmy(widget.data['asof'])}',
            style: mono.copyWith(fontSize: 10)),
        footnote:
            'end-of-day bhavcopy · OI in contracts · lot ${n0(lot as num?)} · PCR = put OI ÷ call OI · max pain = strike where option writers pay least',
        children: [
          const SizedBox(height: 8),
          pillRow([
            for (var k = 0; k < exps.length; k++)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: filterPill(dmy(exps[k]['e']), k == i, amber, () => setState(() {
                      _exp = k;
                      _all = false;
                    })),
              ),
          ]),
          if (fut != null) ...[
            const SizedBox(height: 10),
            LedgerRow(
                lead: 'FUTURE',
                main: 'prev ₹${px(fut[1])} · OI ${n0(fut[2])} (${signed(fut[3])}) · vol ${n0(fut[4])}',
                trail: '₹${px(fut[0])}',
                trailColor: (fut[0] ?? 0) >= (fut[1] ?? 0) ? green : red),
          ],
          if (strikes.isNotEmpty) ...[
            const SizedBox(height: 10),
            StatGrid([
              StatTile('PCR', st.pcr == null ? '—' : st.pcr!.toStringAsFixed(2),
                  color: (st.pcr ?? 0) >= 1 ? green : red,
                  sub: (st.pcr ?? 0) >= 1 ? 'puts lead' : 'calls lead'),
              StatTile('Max call OI', '₹${n0(st.maxCe)}', sub: 'resistance'),
              StatTile('Max put OI', '₹${n0(st.maxPe)}', sub: 'support'),
              StatTile('Max pain', '₹${n0(st.maxPain)}', sub: 'expiry magnet'),
              if (und != null) StatTile('Spot', '₹${fmtNum(und)}'),
              StatTile('Strikes', '${strikes.length}', sub: 'with OI'),
            ]),
            const SizedBox(height: 10),
            LedgerTable(const [
              LtCol('Call OI'),
              LtCol('Δ'),
              LtCol('Call ₹'),
              LtCol('Strike'),
              LtCol('Put ₹'),
              LtCol('Δ'),
              LtCol('Put OI'),
            ], [
              for (final s in shown)
                (
                  cells: [n0(s[2]), signed(s[3]), px(s[1]), n0(s[0]), px(s[5]), signed(s[7]), n0(s[6])],
                  tone: und != null && s[0]! >= und ? 1 : -1,
                  onTap: null,
                ),
            ], toneCol: 3),
            if (shown.length < strikes.length || _all)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: filterPill(_all ? 'AROUND THE MONEY' : 'SHOW ALL ${strikes.length} STRIKES',
                    false, green, () => setState(() => _all = !_all)),
              ),
          ],
        ]);
  }
}

/// Markets › INDEX OPTIONS: NIFTY / BANKNIFTY / FINNIFTY / MIDCPNIFTY pills,
/// each chain fetched when picked (never part of the Markets poll).
class IndexChainPanel extends StatefulWidget {
  const IndexChainPanel({super.key, required this.fetch});
  final Future<Map<String, dynamic>?> Function(String symbol) fetch;
  static const indices = ['NIFTY', 'BANKNIFTY', 'FINNIFTY', 'MIDCPNIFTY'];

  @override
  State<IndexChainPanel> createState() => _IndexChainPanelState();
}

class _IndexChainPanelState extends State<IndexChainPanel> {
  String _idx = IndexChainPanel.indices.first;
  late Future<Map<String, dynamic>?> _f = widget.fetch(_idx);

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        pillRow([
          for (final s in IndexChainPanel.indices)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: filterPill(s, s == _idx, green, () => setState(() {
                    _idx = s;
                    _f = widget.fetch(s);
                  })),
            ),
        ]),
        FutureBuilder(
            future: _f,
            builder: (_, snap) => snap.connectionState != ConnectionState.done
                ? Padding(padding: const EdgeInsets.all(12), child: appSpinner())
                : snap.data == null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text('$_idx chain not published yet — it lands with the evening bhavcopy',
                            style: mono.copyWith(fontSize: 12)))
                    : ChainSection(snap.data!, title: '$_idx options')),
      ]);
}

// ---------------- 034: corporate actions ----------------

const actionLabel = {
  'dividend': 'DIVIDEND', 'bonus': 'BONUS', 'split': 'SPLIT', 'rights': 'RIGHTS',
  'buyback': 'BUYBACK', 'agm': 'AGM', 'egm': 'EGM', 'board_meeting': 'BOARD MEET', 'other': 'OTHER',
};

/// DATE · SYMBOL · EVENT · DETAIL rows from `corp_actions` items (+ meetings).
LedgerTable actionsTable(List<Map<String, dynamic>> items, {void Function(String)? onTap, bool symbol = true, int initial = 12}) {
  final today = DateTime.now().toIso8601String().substring(0, 10);
  return LedgerTable([
    const LtCol('Date', right: false),
    if (symbol) const LtCol('Symbol', right: false),
    const LtCol('Event', right: false),
    const LtCol('Detail', right: false, text: true),
  ], [
    for (final a in items)
      (
        cells: [
          dmy(a['ex']),
          if (symbol) '${a['symbol']}',
          actionLabel[a['kind']] ?? '${a['kind']}'.toUpperCase(),
          '${a['detail'] ?? a['subject'] ?? a['purpose'] ?? ''}',
        ],
        tone: '${a['ex']}'.compareTo(today) >= 0 ? 1 : 0,
        onTap: onTap == null || a['symbol'] == null ? null : () => onTap('${a['symbol']}'),
      ),
  ], toneCol: 0, initial: initial);
}

/// 033: all-time / 52-week records from the screener row (+ its `sa` jsonb).
List<Widget> recordRows(Map<String, dynamic> row) {
  final sa = (row['sa'] as Map?)?.cast<String, dynamic>() ?? const {};
  double? n(dynamic v) => (v as num?)?.toDouble();
  String pct(double? v, {String rise = 'above', String fall = 'below'}) => v == null
      ? ''
      : v >= 0
          ? '${v.toStringAsFixed(1)}% $rise'
          : '${(-v).toStringAsFixed(1)}% $fall';
  String ago(dynamic d) => (d as num?) == null ? '' : ' · ${(d as num).round()} d ago';
  final ath = n(sa['allTimeHigh']), atl = n(sa['allTimeLow']);
  final hi = n(row['hi52']), lo = n(row['lo52']);
  return [
    if (ath != null)
      LedgerRow(
          lead: 'ATH',
          main: 'all-time high · ${sa['allTimeHighDate'] ?? ''}',
          trail: '₹${fmtNum(ath)}',
          sub: pct(n(row['ath_pct']), rise: 'above it', fall: 'below it'),
          trailColor: ink),
    if (atl != null)
      LedgerRow(
          lead: 'ATL',
          main: 'all-time low · ${sa['allTimeLowDate'] ?? ''}',
          trail: '₹${fmtNum(atl)}',
          sub: pct(n(row['from_atl_pct']), rise: 'above it', fall: 'below it'),
          trailColor: ink),
    if (hi != null)
      LedgerRow(
          lead: '52W HI',
          main: '${sa['high52Date'] ?? ''}${ago(row['days_since_hi52'])}',
          trail: '₹${fmtNum(hi)}',
          trailColor: green),
    if (lo != null)
      LedgerRow(
          lead: '52W LO',
          main: '${sa['low52Date'] ?? ''}${ago(row['days_since_lo52'])}',
          trail: '₹${fmtNum(lo)}',
          trailColor: red),
  ];
}

class DocsSection extends StatelessWidget {
  const DocsSection(this.docs, {super.key});
  final Map<String, dynamic> docs;

  @override
  Widget build(BuildContext context) {
    final reports = (docs['annual_reports'] as List?) ?? const [];
    final anns = (docs['announcements'] as List?) ?? const [];
    final calls = (docs['concalls'] as List?) ?? const [];
    final ratings = (docs['credit_ratings'] as List?) ?? const [];
    if (reports.isEmpty && anns.isEmpty && calls.isEmpty && ratings.isEmpty) {
      return const SizedBox.shrink();
    }
    Widget linkRow(Map a, {String? trail}) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            onTap: a['url'] == null ? null : () => openExternal(context, '${a['url']}'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${a['subject'] ?? trail}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(fontSize: 12, color: ink, height: 1.3)),
              Text('${a['date'] ?? ''}', style: mono.copyWith(fontSize: 10)),
            ]),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (reports.isNotEmpty) ...[
        Text('ANNUAL REPORTS', style: mono.copyWith(fontSize: 11, color: inkDim)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final Map r in reports.take(12))
            InkWell(
              onTap: () => openExternal(context, '${r['url']}'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(border: Border.all(color: border)),
                child: Text('FY${r['fy']}',
                    style: mono.copyWith(fontSize: 11, color: green)),
              ),
            ),
        ]),
        const SizedBox(height: 12),
      ],
      if (calls.isNotEmpty) ...[
        Text('CONCALLS', style: mono.copyWith(fontSize: 11, color: inkDim)),
        const SizedBox(height: 6),
        for (final a in calls.take(12)) linkRow(a as Map),
      ],
      if (ratings.isNotEmpty) ...[
        Text('CREDIT RATINGS', style: mono.copyWith(fontSize: 11, color: inkDim)),
        const SizedBox(height: 6),
        for (final Map r in ratings)
          linkRow({
            'subject': [r['agency'], r['rating']].where((v) => v != null).join(' · '),
            'date': r['date'],
            'url': r['url'],
          }),
      ],
      if (anns.isNotEmpty) ...[
        Text('ANNOUNCEMENTS', style: mono.copyWith(fontSize: 11, color: inkDim)),
        const SizedBox(height: 6),
        for (final a in anns.take(10)) linkRow(a as Map),
      ],
      Text('NSE filings', style: mono.copyWith(fontSize: 10)),
    ]);
  }
}

/// Same-sector companies from screener_metrics (the full ~1.8k covered
/// market), biggest first, self pinned on top with a green rule. Fixed-width
/// numeric columns share one right edge; the bar under each name is market
/// cap against the largest row.
class PeersTable extends StatelessWidget {
  const PeersTable(this.peers,
      {super.key, required this.self, this.metric = ('pe', 'P/E', CellFmt.num2)});
  final List<Map<String, dynamic>> peers;
  final String self;

  /// (column key, label, format) — the column shown between price and ROE.
  final (String, String, CellFmt) metric;

  @override
  Widget build(BuildContext context) {
    num mcap(Map r) => (r['mcap_cr'] as num?) ?? 0;
    final others = [
      for (final r in peers)
        if (r['symbol'] != self) r
    ]..sort((a, b) => mcap(b).compareTo(mcap(a)));
    if (others.isEmpty) return const SizedBox.shrink();
    final rows = [...peers.where((r) => r['symbol'] == self), ...others.take(10)];
    final top = rows.fold<num>(0, (m, r) => mcap(r) > m ? mcap(r) : m);
    Widget col(String s, double w, {bool head = false}) => SizedBox(
          width: w,
          child: Text(s,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: mono.copyWith(fontSize: 11, color: head ? inkDim : ink)),
        );
    Widget line(Map<String, dynamic> r) {
      final mine = r['symbol'] == self;
      return Container(
        padding: EdgeInsets.fromLTRB(mine ? 8 : 0, 8, 0, 8),
        decoration: BoxDecoration(
            border: Border(
                bottom: const BorderSide(color: border),
                left: mine
                    ? const BorderSide(color: green, width: 2)
                    : BorderSide.none)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${r['name'] ?? r['symbol']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(fontSize: 12, color: ink)),
              const SizedBox(height: 5),
              FractionallySizedBox(
                  widthFactor: 0.7,
                  alignment: Alignment.centerLeft,
                  child: miniBar(top == 0 ? 0 : mcap(r) / top)),
            ]),
          ),
          col(r['price'] == null ? '—' : fmtNum((r['price'] as num).toDouble()), 70),
          col(
              metric.$1 == 'mcap_cr' && r['mcap_cr'] is num
                  ? fmtNum((r['mcap_cr'] as num).toDouble(), decimals: 0)
                  : fmtCell(r[metric.$1] as num?, metric.$3),
              64),
          col(fmtCell(r['roe'] as num?, CellFmt.pct), 60),
        ]),
      );
    }

    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text('COMPANY', style: mono.copyWith(fontSize: 10))),
          col('PRICE', 70, head: true),
          col(metric.$2, 64, head: true),
          col('ROE', 60, head: true),
        ]),
      ),
      for (final r in rows) line(r),
    ]);
  }
}

/// PEERS metric pills (MC's P/B · TTM PE · ROE · ROA · 1Y return selector).
const peerMetrics = <(String, String, CellFmt)>[
  ('mcap_cr', 'MCAP ₹Cr', CellFmt.cr),
  ('pe', 'P/E', CellFmt.num2),
  ('pb', 'P/B', CellFmt.num2),
  ('roe', 'ROE', CellFmt.pct),
  ('roce', 'ROCE', CellFmt.pct),
  ('de', 'D/E', CellFmt.num2),
  ('div_yield', 'DIV %', CellFmt.pct),
];

/// Rule-generated bullets from the pipeline's summary row.
class ProsCons extends StatelessWidget {
  const ProsCons(this.summary, {super.key});
  final Map<String, dynamic> summary;

  @override
  Widget build(BuildContext context) {
    final pros = (summary['pros'] as List?) ?? const [];
    final cons = (summary['cons'] as List?) ?? const [];
    if (pros.isEmpty && cons.isEmpty) return const SizedBox.shrink();
    Widget bullets(String title, List items, Color tint) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: mono.copyWith(fontSize: 11, color: tint)),
            const SizedBox(height: 4),
            for (final p in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('· ', style: TextStyle(color: tint)),
                  Expanded(
                      child: Text('$p',
                          style: mono.copyWith(fontSize: 12, height: 1.4))),
                ]),
              ),
          ],
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (pros.isNotEmpty) bullets('PROS', pros, green),
      if (pros.isNotEmpty && cons.isNotEmpty) const SizedBox(height: 8),
      if (cons.isNotEmpty) bullets('CONS', cons, red),
      Text('rule-based, from the statements below',
          style: mono.copyWith(fontSize: 10)),
    ]);
  }
}
