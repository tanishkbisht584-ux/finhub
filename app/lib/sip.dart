// SIP / lumpsum / step-up / goal arithmetic (free-parity P4) + the calculator
// sheet. Pure functions first so the numbers are tested; monthly compounding
// at annualPct / 12, SIP instalments at the start of each month (the usual
// AMC-calculator convention).
import 'package:flutter/material.dart';

import 'ledger.dart';
import 'models.dart';
import 'screens/feed.dart' show filterPill, showPillSheet;
import 'theme.dart';

double _m(double annualPct) => annualPct / 100 / 12;

/// Value of a monthly SIP after [months] at [annualPct].
double sipFuture(double monthly, double annualPct, int months) {
  final r = _m(annualPct);
  if (months <= 0) return 0;
  if (r == 0) return monthly * months;
  final g = _pow(1 + r, months);
  return monthly * (g - 1) / r * (1 + r);
}

/// One-time investment compounded monthly for [years].
double lumpsumFuture(double amount, double annualPct, double years) =>
    amount * _pow(1 + _m(annualPct), (years * 12).round());

/// Monthly SIP that reaches [target] in [months] at [annualPct].
double sipForTarget(double target, double annualPct, int months) {
  final unit = sipFuture(1, annualPct, months);
  return unit <= 0 ? 0 : target / unit;
}

/// SIP that grows [stepUpPct] every 12 months.
double stepUpSip(double monthly, double annualPct, int months, double stepUpPct) {
  final r = _m(annualPct);
  var value = 0.0, inst = monthly;
  for (var k = 0; k < months; k++) {
    if (k > 0 && k % 12 == 0) inst *= 1 + stepUpPct / 100;
    value = (value + inst) * (1 + r);
  }
  return value;
}

double investedIn(double monthly, int months, double stepUpPct) {
  var total = 0.0, inst = monthly;
  for (var k = 0; k < months; k++) {
    if (k > 0 && k % 12 == 0) inst *= 1 + stepUpPct / 100;
    total += inst;
  }
  return total;
}

double _pow(double b, int n) {
  var out = 1.0;
  for (var i = 0; i < n; i++) {
    out *= b;
  }
  return out;
}

/// The calculator, as a pill sheet: mode pills, three fields, a StatGrid.
void showSipSheet(BuildContext context, {double ratePct = 12, String? fundName}) {
  var mode = 'SIP';
  final amount = TextEditingController(text: '10000');
  final years = TextEditingController(text: '10');
  final rate = TextEditingController(text: ratePct.toStringAsFixed(1));
  final step = TextEditingController(text: '10');
  showPillSheet(
    context,
    'SIP CALCULATOR${fundName == null ? '' : ' · $fundName'}',
    (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
      final a = double.tryParse(amount.text.replaceAll(',', '')) ?? 0;
      final y = double.tryParse(years.text) ?? 0;
      final r = double.tryParse(rate.text) ?? 0;
      final s = double.tryParse(step.text) ?? 0;
      final months = (y * 12).round();
      double invested, value;
      String lead;
      switch (mode) {
        case 'LUMPSUM':
          invested = a;
          value = lumpsumFuture(a, r, y);
          lead = 'one-time';
        case 'STEP-UP':
          invested = investedIn(a, months, s);
          value = stepUpSip(a, r, months, s);
          lead = 'monthly, +$s%/yr';
        case 'GOAL':
          value = a;
          final need = sipForTarget(a, r, months);
          invested = need * months;
          lead = 'needs ₹${fmtNum(need, decimals: 0)}/month';
        default:
          invested = a * months;
          value = sipFuture(a, r, months);
          lead = 'monthly';
      }
      Widget field(String label, TextEditingController c, {String? suffix}) => Expanded(
            child: TextField(
              controller: c,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: mono.copyWith(fontSize: 13),
              onChanged: (_) => setSheet(() {}),
              decoration: InputDecoration(
                  isDense: true,
                  labelText: label,
                  suffixText: suffix,
                  labelStyle: mono.copyWith(fontSize: 10, color: inkDim)),
            ),
          );
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        pillRow([
          for (final m in const ['SIP', 'LUMPSUM', 'STEP-UP', 'GOAL'])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: filterPill(m, m == mode, green, () => setSheet(() => mode = m)),
            ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          field(mode == 'GOAL' ? 'TARGET ₹' : mode == 'LUMPSUM' ? 'AMOUNT ₹' : 'MONTHLY ₹', amount),
          const SizedBox(width: 8),
          field('YEARS', years),
          const SizedBox(width: 8),
          field('RETURN', rate, suffix: '%'),
          if (mode == 'STEP-UP') ...[const SizedBox(width: 8), field('STEP-UP', step, suffix: '%/yr')],
        ]),
        const SizedBox(height: 12),
        StatGrid([
          StatTile('Invested', '₹${fmtNum(invested, decimals: 0)}', sub: lead),
          StatTile('Gains', '₹${fmtNum(value - invested, decimals: 0)}',
              color: value >= invested ? green : red),
          StatTile('Value', '₹${fmtNum(value, decimals: 0)}', sub: '${y.toStringAsFixed(0)} yrs · ${r.toStringAsFixed(1)}%'),
        ]),
        const SizedBox(height: 8),
        Text('monthly compounding · instalments at the start of each month · returns are assumptions, not promises',
            style: mono.copyWith(fontSize: 10, color: inkDim)),
      ]);
    }),
  );
}
