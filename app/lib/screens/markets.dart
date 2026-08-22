import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../theme.dart';
import '../ticks.dart';
import 'feed.dart' show homeTab, marketsTab;
import 'stock.dart';

/// Everything the Markets tab shows, from the pipeline's `quotes` table
/// (pipeline/market.py): indices, FX, crypto, commodities, plus the signed-in
/// user's followed companies with their quotes.
class MarketsData {
  const MarketsData({required this.ticks, required this.watchlist});
  final List<Tick> ticks;
  final List<Company> watchlist;

  List<Tick> kind(String k) => [
        for (final t in ticks)
          if (t.kind == k) t
      ];

  /// Newest refresh across everything shown — the "as of" line.
  DateTime? get updatedAt => ticks
      .map((t) => t.updatedAt)
      .whereType<DateTime>()
      .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
}

final marketsProvider = FutureProvider.autoDispose<MarketsData>((ref) async {
  final sb = Supabase.instance.client;
  final rows = await sb
      .from('quotes')
      .select(tickColsWithCloses)
      .inFilter('kind', ['index', 'fx', 'crypto', 'commodity']).order('symbol');
  final all = [
    for (final r in rows) Tick.fromJson(Map<String, dynamic>.from(r))
  ];
  var watch = <Company>[];
  final uid = sb.auth.currentUser?.id;
  if (uid != null) {
    try {
      final follows = await sb
          .from('follows')
          .select('target_id')
          .eq('user_id', uid)
          .eq('target_type', 'company');
      final ids = [for (final f in follows) int.parse(f['target_id'])];
      if (ids.isNotEmpty) {
        final cs = await sb
            .from('companies')
            .select('id,name,nse_symbol')
            .inFilter('id', ids)
            .order('name');
        watch = [
          for (final c in cs) Company.fromJson(Map<String, dynamic>.from(c))
        ];
        await loadTicks([for (final c in watch) c.nseSymbol]);
      }
    } catch (_) {
      // The watchlist section is a bonus on this screen; indices still show.
    }
  }
  mergeTicks(all);
  return MarketsData(ticks: all, watchlist: watch);
});

/// Spec add-on (2026-08-22): "what is the market doing" next to "what
/// happened". Numbers only, minimal ledger; every row that is a company opens
/// its stock page.
class MarketsScreen extends ConsumerStatefulWidget {
  const MarketsScreen({super.key});

  @override
  ConsumerState<MarketsScreen> createState() => _MarketsScreenState();
}

class _MarketsScreenState extends ConsumerState<MarketsScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    homeTab.addListener(_onTab);
    _onTab();
  }

  /// Refresh only while this tab is showing: the IndexedStack keeps the screen
  /// alive behind the feed, and a hidden tab must not spend reads.
  void _onTab() {
    _timer?.cancel();
    _timer = null;
    if (homeTab.value != marketsTab) return;
    ref.invalidate(marketsProvider);
    _timer = Timer.periodic(
        const Duration(seconds: 60), (_) => ref.invalidate(marketsProvider));
  }

  @override
  void dispose() {
    homeTab.removeListener(_onTab);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(marketsProvider);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(title: const Text('Markets')),
      body: data.when(
        loading: () => Center(child: appSpinner()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Could not load market data',
                  style: mono.copyWith(fontSize: 13)),
              const SizedBox(height: 16),
              OutlinedButton(
                  onPressed: () => ref.invalidate(marketsProvider),
                  child: const Text('Try again')),
            ]),
          ),
        ),
        data: (d) => RefreshIndicator(
          color: green,
          backgroundColor: surface,
          onRefresh: () => ref.refresh(marketsProvider.future),
          child: MarketsBody(d),
        ),
      ),
    );
  }
}

/// The sections themselves, stateless so a test can feed it [MarketsData].
class MarketsBody extends StatelessWidget {
  const MarketsBody(this.data, {super.key});
  final MarketsData data;

  @override
  Widget build(BuildContext context) {
    final indices = data.kind('index');
    final watch = data.watchlist;
    final stale = _stale(data.updatedAt);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        if (indices.isEmpty && data.ticks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Text(
                'No market data yet.\nThe pipeline fills this in within a few minutes.',
                textAlign: TextAlign.center,
                style: mono.copyWith(fontSize: 13, height: 1.6)),
          ),
        if (indices.isNotEmpty)
          _Section('Indices', [
            for (final t in indices) _TickRow(t, spark: true),
          ]),
        _Section('Your watchlist', [
          if (watch.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                  'Nothing followed yet. Open a company from any card and tap the star.',
                  style: mono.copyWith(fontSize: 12, height: 1.5)),
            )
          else
            ValueListenableBuilder<Map<String, Tick>>(
              valueListenable: ticks,
              builder: (_, m, __) => Column(children: [
                for (final c in watch)
                  _CompanyRow(c, m[c.nseSymbol]),
              ]),
            ),
        ]),
        if (data.kind('fx').isNotEmpty)
          _Section('Currencies', [
            for (final t in data.kind('fx')) _TickRow(t, spark: true),
          ]),
        if (data.kind('crypto').isNotEmpty)
          _Section('Crypto', [
            for (final t in data.kind('crypto')) _TickRow(t),
          ]),
        if (data.kind('commodity').isNotEmpty)
          _Section('Commodities', [
            for (final t in data.kind('commodity'))
              _TickRow(t, spark: t.closes.length > 1),
          ]),
        const SizedBox(height: 20),
        Text(
            [
              if (data.updatedAt != null)
                'as of ${_hhmmIst(data.updatedAt!)} IST',
              if (stale) 'stale — pipeline has not refreshed',
              'Yahoo Finance · CoinGecko · delayed',
            ].join(' · '),
            style: mono.copyWith(fontSize: 10, color: stale ? amber : inkDim)),
      ],
    );
  }
}

/// Two hours is 2x the slowest Phase-1 cadence (equities off-hours); older
/// than that the numbers are shown but called out, never passed off as live.
bool _stale(DateTime? updatedAt) =>
    updatedAt != null &&
    DateTime.now().difference(updatedAt) > const Duration(hours: 2);

String _hhmmIst(DateTime t) {
  final ist = t.toUtc().add(const Duration(hours: 5, minutes: 30));
  return '${ist.hour.toString().padLeft(2, '0')}:${ist.minute.toString().padLeft(2, '0')}';
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 22),
          Text(title.toUpperCase(), style: monoLabel),
          const SizedBox(height: 6),
          const Divider(height: 1),
          ...children,
        ],
      );
}

/// One instrument: name (+ label) left, price and % right, optional sparkline.
class _TickRow extends StatelessWidget {
  const _TickRow(this.t, {this.spark = false});
  final Tick t;
  final bool spark;

  @override
  Widget build(BuildContext context) {
    final color = t.changePct == null ? inkDim : (t.up ? green : red);
    final label = t.meta['label'] as String?;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: border))),
      child: Row(children: [
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: serif.copyWith(fontSize: 15)),
                if (label != null)
                  Text(label, style: mono.copyWith(fontSize: 10)),
              ]),
        ),
        if (spark && t.closes.length > 1)
          SizedBox(
              width: 64, height: 22, child: Sparkline(t.closes, color)),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(fmtMoney(t.price, t.currency),
              style: mono.copyWith(fontSize: 14, color: ink)),
          Text(fmtPct(t.changePct),
              style: mono.copyWith(fontSize: 11, color: color)),
        ]),
      ]),
    );
  }
}

/// A followed company: symbol + name, live % when the quote is in, opens the
/// stock page.
class _CompanyRow extends StatelessWidget {
  const _CompanyRow(this.c, this.t);
  final Company c;
  final Tick? t;

  @override
  Widget build(BuildContext context) {
    final color = t?.changePct == null ? inkDim : (t!.up ? green : red);
    return InkWell(
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => StockScreen(company: c))),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: border))),
        child: Row(children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('\$${c.nseSymbol}',
                      style: mono.copyWith(fontSize: 12, color: ink)),
                  Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: serif.copyWith(fontSize: 14)),
                ]),
          ),
          if (t != null)
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(fmtMoney(t!.price, t!.currency),
                  style: mono.copyWith(fontSize: 14, color: ink)),
              Text(fmtPct(t!.changePct),
                  style: mono.copyWith(fontSize: 11, color: color)),
            ])
          else
            Text('—', style: mono.copyWith(fontSize: 13)),
          const SizedBox(width: 6),
          const Icon(Icons.north_east_rounded, size: 12, color: inkDim),
        ]),
      ),
    );
  }
}
