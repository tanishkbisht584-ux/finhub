import 'package:flutter/material.dart';

import '../fundamentals.dart';
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
  ('No. of Shareholders', 'n_holders', CellFmt.cr),
];

/// Sticky label column + horizontally scrollable period columns. reverse:true
/// starts the scroll at the newest period (Screener keeps oldest on the left).
class StatementTable extends StatelessWidget {
  const StatementTable(
      {super.key, required this.periods, required this.rows, required this.byPeriod});
  final List<String> periods; // ascending
  final List<(String, String, CellFmt)> rows;
  final Map<String, Map<String, dynamic>> byPeriod;

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (final r in rows)
        if (periods.any((p) => byPeriod[p]?[r.$2] != null)) r
    ];
    if (visible.isEmpty) return const SizedBox.shrink();
    Widget cell(String s, {bool head = false, bool label = false}) => Container(
          height: 26,
          width: label ? null : 66,
          alignment: label ? Alignment.centerLeft : Alignment.centerRight,
          child: Text(s,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono.copyWith(
                  fontSize: 11, color: head ? inkDim : ink)),
        );
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 118,
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
            for (final p in periods)
              Column(children: [
                cell(periodLabel(p), head: true),
                for (final r in visible)
                  cell(fmtCell(byPeriod[p]?[r.$2] as num?, r.$3)),
              ]),
          ]),
        ),
      ),
    ]);
  }
}

const _cagrLabels = [('y10', '10Y'), ('y5', '5Y'), ('y3', '3Y'),
                     ('y1', '1Y'), ('ttm', 'TTM'), ('last', 'Last')];

/// "Compounded Sales Growth"-style block: 10Y/5Y/3Y/TTM percent cells.
class CagrStrip extends StatelessWidget {
  const CagrStrip(this.title, this.block, {super.key});
  final String title;
  final Map<String, dynamic> block;

  @override
  Widget build(BuildContext context) {
    final cells = [
      for (final (k, label) in _cagrLabels)
        if (block[k] != null) (label, fmtCell(block[k] as num?, CellFmt.pct))
    ];
    if (cells.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: mono.copyWith(fontSize: 11, color: inkDim)),
        const SizedBox(height: 4),
        Row(children: [
          for (final (label, v) in cells)
            Padding(
              padding: const EdgeInsets.only(right: 18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: mono.copyWith(fontSize: 10, color: inkDim)),
                Text(v, style: mono.copyWith(fontSize: 12, color: ink)),
              ]),
            ),
        ]),
      ]),
    );
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
