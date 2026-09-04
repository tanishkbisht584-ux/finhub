import 'package:flutter/material.dart';

import '../analysis.dart';
import '../fundamentals.dart';
import '../heat.dart';
import '../ledger.dart';
import '../models.dart';
import '../theme.dart';

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
  ('No. of Shareholders', 'n_holders', CellFmt.cr),
];

/// Labelled text table for FUNDAMENTALS / TECHNICALS: metric · value · third
/// · read. Numeric columns right-aligned, the read column wraps.
class KvTable extends StatelessWidget {
  const KvTable(this.columns, this.rows, {super.key});
  final List<String> columns; // 4 headers
  final List<KvRow> rows;

  static Color toneColor(int tone) => tone > 0 ? green : tone < 0 ? red : ink;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    Widget cell(String s,
            {bool head = false, bool right = true, Color? color, bool wrap = false}) =>
        Container(
          constraints: const BoxConstraints(minHeight: 28),
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          padding: EdgeInsets.only(left: right ? 6 : 0),
          child: Text(s,
              maxLines: wrap ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              textAlign: right ? TextAlign.right : TextAlign.left,
              style: mono.copyWith(
                  fontSize: head ? 10 : 11,
                  letterSpacing: head ? 0.6 : 0,
                  color: color ?? (head ? inkDim : ink))),
        );
    Color valueColor(String v) =>
        v.startsWith('+') ? green : v.startsWith('−') ? red : ink;
    return Table(
      columnWidths: const {
        0: FixedColumnWidth(92),
        1: FlexColumnWidth(1.1),
        2: FlexColumnWidth(0.9),
        3: FlexColumnWidth(1.5),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: border))),
          children: [
            cell(columns[0], head: true, right: false),
            cell(columns[1], head: true),
            cell(columns[2], head: true),
            Padding(
                padding: const EdgeInsets.only(left: 10),
                child: cell(columns[3], head: true, right: false)),
          ],
        ),
        for (final r in rows)
          TableRow(children: [
            cell(r.metric, right: false),
            cell(r.value, color: valueColor(r.value)),
            cell(r.third, color: inkDim),
            Padding(
                padding: const EdgeInsets.only(left: 10),
                child: cell(r.read,
                    right: false, wrap: true, color: toneColor(r.tone))),
          ]),
      ],
    );
  }
}

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
    final visible = [
      for (final r in rows)
        if (periods.any((p) => byPeriod[p]?[r.$2] != null)) r
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
  const PeersTable(this.peers, {super.key, required this.self});
  final List<Map<String, dynamic>> peers;
  final String self;

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
          col(fmtCell(r['pe'] as num?, CellFmt.num2), 54),
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
          col('P/E', 54, head: true),
          col('ROE', 60, head: true),
        ]),
      ),
      for (final r in rows) line(r),
    ]);
  }
}

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
