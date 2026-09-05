import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../charts.dart';
import '../heat.dart';
import '../ledger.dart';
import '../models.dart';
import '../remote_config.dart';
import '../section_ribbon.dart';
import '../sessions.dart';
import '../theme.dart';
import '../ticks.dart';
import 'feed.dart' show homeTab, marketsTab, filterPill, pendingStory;
import 'screens.dart';
import 'stock.dart';

/// Everything the Markets tab shows, from the pipeline's `quotes` and
/// `market_blobs` tables (pipeline/market.py), plus the signed-in user's
/// followed companies and MF schemes.
class MarketsData {
  const MarketsData({
    required this.ticks,
    required this.watchlist,
    this.followedMf = const {},
    this.blobs = const {},
    this.blobUpdated = const {},
  });
  final List<Tick> ticks;
  final List<Company> watchlist;
  final Set<int> followedMf;
  final Map<String, dynamic> blobs; // key -> payload
  final Map<String, DateTime> blobUpdated;

  List<Tick> kind(String k) => [
        for (final t in ticks)
          if (t.kind == k) t
      ];

  List<Map<String, dynamic>> list(String key) => [
        for (final r in (blobs[key] as List? ?? const []))
          Map<String, dynamic>.from(r as Map)
      ];

  List<Map<String, dynamic>> get deals => [
        for (final r
            in ((blobs['bulk_deals'] as Map?)?['deals'] as List? ?? const []))
          Map<String, dynamic>.from(r as Map)
      ];

  /// Newest refresh across everything shown — the "as of" line.
  DateTime? get updatedAt => ticks
      .map((t) => t.updatedAt)
      .whereType<DateTime>()
      .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
}

/// Last full picture + the newest updated_at seen, kept at module level (like
/// [ticks]) so the 60s poll and tab switches pay only for rows that changed
/// since. The pipeline suppresses no-change blob writes (write_blobs), so an
/// off-hours poll transfers nothing instead of every blob every minute.
MarketsData? _lastMarkets;
DateTime? _marketsSince;

/// Pull-to-refresh escape hatch: forget the delta state so the next provider
/// run is a full fetch.
void resetMarketsDelta() {
  _lastMarkets = null;
  _marketsSince = null;
}

/// Pure merge for the delta path: fresh rows override by symbol/key, the rest
/// carry over. watch/followedMf are always re-read (tiny per-user queries).
MarketsData mergeMarkets(
    MarketsData prev,
    List<Tick> freshTicks,
    Map<String, dynamic> freshBlobs,
    Map<String, DateTime> freshBlobUpdated,
    List<Company> watch,
    Set<int> followedMf) {
  final bySym = {for (final t in prev.ticks) t.symbol: t};
  for (final t in freshTicks) {
    bySym[t.symbol] = t;
  }
  return MarketsData(
    ticks: bySym.values.toList()..sort((a, b) => a.symbol.compareTo(b.symbol)),
    watchlist: watch,
    followedMf: followedMf,
    blobs: {...prev.blobs, ...freshBlobs},
    blobUpdated: {...prev.blobUpdated, ...freshBlobUpdated},
  );
}

final marketsProvider = FutureProvider.autoDispose<MarketsData>((ref) async {
  final sb = Supabase.instance.client;
  final prev = _lastMarkets;
  // Strictly-greater misses a same-instant write; the pipeline stamps
  // microseconds and quotes rewrite within 15 min anyway — accepted.
  final since = prev == null ? null : _marketsSince?.toIso8601String();
  var q = sb
      .from('quotes')
      .select(tickColsWithCloses)
      .inFilter('kind', ['index', 'fx', 'crypto', 'commodity', 'mf', 'macro']);
  if (since != null) q = q.gt('updated_at', since);
  final List<dynamic> rows;
  try {
    rows = await q.order('symbol');
  } catch (_) {
    // Offline or Supabase having a moment: yesterday's numbers beat an error
    // screen — but only once we have numbers at all.
    if (prev != null) return prev;
    rethrow;
  }
  final all = [
    for (final r in rows) Tick.fromJson(Map<String, dynamic>.from(r))
  ];
  var blobs = <String, dynamic>{};
  var blobUpdated = <String, DateTime>{};
  try {
    var bq = sb.from('market_blobs').select('key,payload,updated_at');
    if (since != null) bq = bq.gt('updated_at', since);
    final bs = await bq;
    for (final b in bs) {
      blobs[b['key'] as String] = b['payload'];
      final u = DateTime.tryParse(b['updated_at'] ?? '');
      if (u != null) blobUpdated[b['key'] as String] = u;
    }
  } catch (_) {
    // Lists are a bonus; the numbers still show.
  }
  var watch = <Company>[];
  var followedMf = <int>{};
  final uid = sb.auth.currentUser?.id;
  if (uid != null) {
    try {
      final follows = await sb
          .from('follows')
          .select('target_type,target_id')
          .eq('user_id', uid)
          .inFilter('target_type', ['company', 'mf']);
      final ids = <int>[];
      for (final f in follows) {
        final id = int.tryParse('${f['target_id']}');
        if (id == null) continue;
        if (f['target_type'] == 'mf') {
          followedMf.add(id);
        } else {
          ids.add(id);
        }
      }
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
  final data = prev == null
      ? MarketsData(
          ticks: all,
          watchlist: watch,
          followedMf: followedMf,
          blobs: blobs,
          blobUpdated: blobUpdated)
      : mergeMarkets(prev, all, blobs, blobUpdated, watch, followedMf);
  var mx = _marketsSince;
  for (final t in all) {
    final u = t.updatedAt;
    if (u != null && (mx == null || u.isAfter(mx))) mx = u;
  }
  for (final u in blobUpdated.values) {
    if (mx == null || u.isAfter(mx)) mx = u;
  }
  _marketsSince = mx;
  _lastMarkets = data;
  return data;
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
    _timer = Timer.periodic(Duration(seconds: remoteConfig.marketsPollSeconds),
        (_) => ref.invalidate(marketsProvider));
  }

  @override
  void dispose() {
    homeTab.removeListener(_onTab);
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _followMf(int code, bool follow) async {
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    if (uid == null) return;
    final rowKey = {'user_id': uid, 'target_type': 'mf', 'target_id': '$code'};
    try {
      if (follow) {
        await sb.from('follows').upsert(rowKey);
      } else {
        await sb.from('follows').delete().match(rowKey);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not update your funds')));
      }
    }
    ref.invalidate(marketsProvider);
  }

  Future<void> _addMf() async {
    final code = await showModalBottomSheet<int>(
        context: context,
        isScrollControlled: true,
        backgroundColor: surface,
        builder: (_) => const MfSearchSheet());
    if (code != null) {
      await _followMf(code, true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Following — NAV appears within a few minutes')));
      }
    }
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
          onRefresh: () {
            resetMarketsDelta(); // user asked: full fetch, not a delta
            return ref.refresh(marketsProvider.future);
          },
          child: MarketsBody(d, onFollowMf: _followMf, onAddMf: _addMf),
        ),
      ),
    );
  }
}

/// One Markets section: [id] anchors ribbon jumps, [label] is the trader-term
/// heading shown both as the section header and the ribbon chip.
typedef _Sec = ({String id, String label, Widget child});

/// The sections themselves; a test can feed it [MarketsData] directly.
/// Everything lays out eagerly (SingleChildScrollView, not ListView) so every
/// section RenderBox exists for ribbon jump + scroll tracking.
class MarketsBody extends StatefulWidget {
  const MarketsBody(this.data, {super.key, this.onFollowMf, this.onAddMf});
  final MarketsData data;
  final void Function(int code, bool follow)? onFollowMf;
  final VoidCallback? onAddMf;

  @override
  State<MarketsBody> createState() => _MarketsBodyState();
}

class _MarketsBodyState extends State<MarketsBody> {
  final _tracker = SectionTracker();

  /// SECTORS horizon: which nse_indices field tints the tiles.
  String _horizon = 'pct';
  static const _horizons = [
    ('pct', '1D', 3.0),
    ('pct_30d', '30D', 10.0),
    ('pct_1y', '1Y', 30.0)
  ];

  @override
  void dispose() {
    _tracker.dispose();
    super.dispose();
  }

  List<_Sec> _sections() {
    final data = widget.data;
    final onFollowMf = widget.onFollowMf;
    final onAddMf = widget.onAddMf;
    final allIdx = data.kind('index');
    // Global layer (0.32.0): world rows share kind=index, split on meta.
    final indices = [
      for (final t in allIdx)
        if (t.meta['global'] != true) t
    ];
    final worldIdx = [
      for (final t in allIdx)
        if (t.meta['global'] == true && t.meta['adr'] != true) t
    ];
    final adrs = [
      for (final t in allIdx)
        if (t.meta['adr'] == true) t
    ];
    final predictions = _l((data.blobs['predictions'] as Map?)?['markets']);
    final watch = data.watchlist;
    final mf = data.kind('mf')
      ..sort((a, b) {
        final fa = data.followedMf.contains(a.meta['scheme_code']) ? 0 : 1;
        final fb = data.followedMf.contains(b.meta['scheme_code']) ? 0 : 1;
        return fa != fb ? fa - fb : a.name.compareTo(b.name);
      });
    final macro = data.kind('macro');
    final results = data.list('results_calendar');
    final deals = data.deals;
    final insider = data.list('insider_trades');
    final idxGroups = <String, List<Map<String, dynamic>>>{};
    for (final s in data.list('nse_indices')) {
      idxGroups.putIfAbsent('${s['group']}', () => []).add(s);
    }
    final flows =
        (data.blobs['flows'] as Map?)?.cast<String, dynamic>() ?? const {};
    final fno =
        (data.blobs['fno'] as Map?)?.cast<String, dynamic>() ?? const {};
    final bonds = _l((data.blobs['bonds'] as Map?)?['yields']);
    final ipoBlob =
        (data.blobs['ipos'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ipos = [..._l(ipoBlob['current']), ..._l(ipoBlob['upcoming'])];
    // Sentiment + signals (pipeline market.refresh_sentiment / signals.py).
    final summary =
        '${(data.blobs['market_summary'] as Map?)?['text'] ?? ''}'.trim();
    final fg = (data.blobs['fear_greed'] as Map?)?.cast<String, dynamic>();
    final risk = (data.blobs['risk_index'] as Map?)?.cast<String, dynamic>();
    final moves =
        (data.blobs['move_context'] as Map?)?.cast<String, dynamic>() ??
            const {};
    final explained = _l(moves['explained']);
    final unexplained = _l(moves['unexplained']);
    // P4 (0.31.0): RBI policy box, World Bank frame, USGS quakes.
    final rbi =
        (data.blobs['rbi_rates'] as Map?)?.cast<String, dynamic>() ?? const {};
    final wb = ((data.blobs['macro_context'] as Map?)?['series'] as Map?)
            ?.cast<String, dynamic>() ??
        const {};
    final quakes = _l((data.blobs['hazards'] as Map?)?['quakes']);
    // Context layer (0.33.0): calendar, positioning, shipping, monsoon, CB rates.
    final calendar = _l((data.blobs['calendar'] as Map?)?['events']);
    final poiBlob =
        (data.blobs['participant_oi'] as Map?)?.cast<String, dynamic>() ??
            const {};
    final poi = (poiBlob['rows'] as Map?)?.cast<String, dynamic>() ?? const {};
    final shipping =
        (data.blobs['shipping'] as Map?)?.cast<String, dynamic>() ?? const {};
    final chokes = _l(shipping['chokepoints']);
    final ports = _l(shipping['ports']);
    final monsoon =
        (data.blobs['monsoon'] as Map?)?.cast<String, dynamic>() ?? const {};
    final cb = ((data.blobs['cb_rates'] as Map?)?['rates'] as Map?)
            ?.cast<String, dynamic>() ??
        const {};
    final scale = _horizons.firstWhere((h) => h.$1 == _horizon).$3;
    return [
      // Always first: which bells are ringing right now (client-side clock).
      (id: 'sessions', label: 'SESSIONS', child: const _Sessions()),
      if (idxGroups.isNotEmpty)
        (
          id: 'sectors',
          label: 'SECTORS',
          child: LedgerSection('Sectors',
              stamp: data.blobUpdated['nse_indices'],
              action: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final (key, label, _) in _horizons)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: filterPill(label, _horizon == key, green,
                          () => setState(() => _horizon = key),
                          fontSize: 9),
                    ),
                ]),
              ),
              footnote: 'tap a tile for P/E, breadth, 52-wk',
              children: [
                for (final (key, label) in const [
                  ('SECTORAL INDICES', 'SECTORAL'),
                  ('BROAD MARKET INDICES', 'BROAD MARKET'),
                  ('THEMATIC INDICES', 'THEMATIC'),
                  ('STRATEGY INDICES', 'STRATEGY'),
                ])
                  if (idxGroups[key] != null)
                    _HeatGroup(label, idxGroups[key]!,
                        field: _horizon,
                        scale: scale,
                        expanded: key == 'SECTORAL INDICES'),
                const SizedBox(height: 10),
                _heatLegend(scale),
              ]),
        ),
      (
        id: 'watch',
        label: 'WATCHLIST',
        child: LedgerSection('Watchlist',
            action: Builder(
                builder: (context) => filterPill(
                    'SEARCH', false, green, () => _openStockSearch(context),
                    fontSize: 10)),
            children: [
              if (watch.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                      'Nothing followed yet. Tap SEARCH, or open a company from any card and tap the star.',
                      style: mono.copyWith(fontSize: 12, height: 1.5)),
                )
              else
                ValueListenableBuilder<Map<String, Tick>>(
                  valueListenable: ticks,
                  builder: (_, m, __) => Column(children: [
                    for (final c in watch) _CompanyRow(c, m[c.nseSymbol]),
                  ]),
                ),
            ]),
      ),
      if (remoteConfig.screenerQueryEnabled)
        (
          id: 'screens',
          label: 'SCREENS',
          child: LedgerSection('Screens',
              footnote:
                  'filter every covered stock by fundamentals · rebuilt daily',
              children: [
                const SizedBox(height: 10),
                Builder(
                  builder: (context) =>
                      Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final p in screenPresets)
                      filterPill(p.name, false, green, () {
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => ScreensScreen(preset: p)));
                      }, fontSize: 10),
                    filterPill('CUSTOM', false, amber, () {
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const ScreensScreen()));
                    }, fontSize: 10),
                  ]),
                ),
              ]),
        ),
      if (indices.isNotEmpty)
        (
          id: 'indices',
          label: 'INDICES',
          child: LedgerSection('Indices', children: [
            for (final t in indices) _TickRow(t, spark: true),
          ]),
        ),
      if (flows.isNotEmpty)
        (
          id: 'flows',
          label: 'FLOWS',
          child: LedgerSection('Flows',
              stamp: data.blobUpdated['flows'],
              children: [
                for (final side in ['fii', 'dii'])
                  if (flows[side] is Map)
                    ..._flowRows(
                        side.toUpperCase(),
                        (flows[side] as Map).cast<String, dynamic>(),
                        flows['date']?.toString()),
                if (flows['breadth'] is Map)
                  for (final e in (flows['breadth'] as Map).entries)
                    _breadthRow(
                        e.key.toString().replaceFirst('NIFTY ', 'N'),
                        (e.value['adv'] as num?) ?? 0,
                        (e.value['dec'] as num?) ?? 0),
              ]),
        ),
      // One no-AI line after the flows (the heatmap keeps opening the tab): index moves, FII/DII, top mover, mood.
      if (summary.isNotEmpty)
        (
          id: 'today',
          label: 'TODAY',
          child: LedgerSection('Today',
              stamp: data.blobUpdated['market_summary'],
              children: [
                Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(summary, style: serif.copyWith(fontSize: 14))),
              ]),
        ),
      if (calendar.isNotEmpty)
        (
          id: 'calendar',
          label: 'CALENDAR',
          child: LedgerSection('Calendar',
              footnote: 'next 45 days · RBI/MOSPI rule + FRED release dates',
              children: [
                KvTable(const [
                  'DATE',
                  'REGION',
                  'TIME',
                  'EVENT'
                ], [
                  for (final e in calendar)
                    (
                      metric: dmy(e['date']),
                      value: '${e['region'] ?? ''}',
                      third: '${e['time'] ?? ''}',
                      read: '${e['name'] ?? ''}',
                      tone: 0,
                    ),
                ]),
              ]),
        ),
      if (fg != null)
        (
          id: 'mood',
          label: 'MOOD',
          child: LedgerSection('Mood',
              footnote: '0–100 · pipeline methodology',
              children: [
                ..._gaugeRows(
                    'Fear & Greed',
                    fg,
                    (fg['score'] as num) < 44
                        ? red
                        : (fg['score'] as num) > 55
                            ? green
                            : amber,
                    lowIsRed: true),
                if (risk != null)
                  ..._gaugeRows(
                      'Risk index',
                      risk,
                      risk['label'] == 'High'
                          ? red
                          : risk['label'] == 'Elevated'
                              ? amber
                              : green,
                      lowIsRed: false),
              ]),
        ),
      if (explained.isNotEmpty || unexplained.isNotEmpty)
        (
          id: 'moves',
          label: 'MOVES',
          child: LedgerSection('Moves',
              stamp: data.blobUpdated['move_context'],
              children: [
                Collapsible([
                  for (final m in explained)
                    _moveRow(m, '${m['title'] ?? ''}', onTap: () {
                      homeTab.value = 0;
                      pendingStory.value = (m['story_id'] as num?)?.toInt();
                    }),
                  for (final m in unexplained) _moveRow(m, 'No news we carry'),
                ]),
              ]),
        ),
      if (fno.isNotEmpty || flows['pcr'] != null)
        (
          id: 'fno',
          label: 'F&O',
          child:
              LedgerSection('F&O', stamp: data.blobUpdated['fno'], children: [
            if (flows['pcr'] != null) ...[
              LedgerRow(
                  main: 'NIFTY put/call ratio',
                  trail: 'PCR ${flows['pcr']}',
                  trailColor: (flows['pcr'] as num) >= 1 ? green : red,
                  sub:
                      'exp ${flows['expiry'] ?? ''} · max OI at ${fmtNum(((flows['max_oi_strike'] ?? 0) as num).toDouble(), decimals: 0)} · spot ${fmtNum(((flows['underlying'] ?? 0) as num).toDouble(), decimals: 0)}'),
              const SizedBox(height: 6),
              ScaleBar((flows['pcr'] as num).toDouble(),
                  min: 0.5, max: 1.5, marks: const [(1.0, '1.0')]),
              const SizedBox(height: 6),
            ],
            if (fno['hi52'] != null || fno['lo52'] != null)
              _breadthRow(
                  '52W', (fno['hi52'] as num?) ?? 0, (fno['lo52'] as num?) ?? 0,
                  main: 'new highs / lows'),
            for (final (key, label) in const [
              ('gainers', 'TOP GAINERS'),
              ('losers', 'TOP LOSERS')
            ])
              if (_l(fno[key]).isNotEmpty) ...[
                _groupLabel(label),
                StatGrid([
                  for (final r in _l(fno[key]).take(6))
                    HeatCell('${r['symbol']}', (r['pct'] as num?)?.toDouble(),
                        sub: r['ltp'] == null
                            ? null
                            : '₹${fmtNum((r['ltp'] as num).toDouble())}'),
                ]),
              ],
            if (_l(fno['oi_gainers']).isNotEmpty ||
                _l(fno['oi_losers']).isNotEmpty) ...[
              _groupLabel('OPEN INTEREST'),
              KvTable(const [
                'SYMBOL',
                'LTP',
                'OI',
                'PRICE · READ'
              ], [
                for (final r in _l(fno['oi_gainers'])) _oiRow(r, 'build-up'),
                for (final r in _l(fno['oi_losers'])) _oiRow(r, 'unwinding'),
              ]),
            ],
          ]),
        ),
      if (poi.isNotEmpty)
        (
          id: 'positioning',
          label: 'POSITIONING',
          child: LedgerSection('Positioning',
              footnote:
                  'NSE participant-wise F&O open interest · ${dmy(poiBlob['date'])}',
              children: [
                for (final who in const ['FII', 'DII', 'Pro', 'Client'])
                  if (poi[who] is Map)
                    _poiRow(who, (poi[who] as Map).cast<String, dynamic>()),
              ]),
        ),
      if (data.kind('fx').isNotEmpty)
        (
          id: 'fx',
          label: 'FX',
          child: LedgerSection('FX', children: [
            for (final t in data.kind('fx')) _TickRow(t, spark: true),
          ]),
        ),
      if (data.kind('crypto').isNotEmpty)
        (
          id: 'crypto',
          label: 'CRYPTO',
          child: LedgerSection('Crypto', children: [
            for (final t in data.kind('crypto')) _TickRow(t),
          ]),
        ),
      if (worldIdx.isNotEmpty)
        (
          id: 'global',
          label: 'GLOBAL',
          child: LedgerSection('Global', children: [
            for (final t in worldIdx) _TickRow(t, spark: t.closes.length > 1),
            if (adrs.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('INDIA ADRS (NYSE)', style: monoLabel),
              for (final t in adrs) _TickRow(t, spark: t.closes.length > 1),
            ],
          ]),
        ),
      if (predictions.isNotEmpty)
        (
          id: 'odds',
          label: 'ODDS',
          child: LedgerSection('Odds',
              stamp: data.blobUpdated['predictions'],
              stampPrefix: 'Polymarket',
              footnote: 'Polymarket odds — crowd bets, not forecasts',
              children: [
                for (final m in predictions)
                  LedgerRow(
                      lead: '${m['pct']}%',
                      main: '${m['q'] ?? ''}',
                      trail: '${m['label'] ?? ''}',
                      bar: ((m['pct'] as num?) ?? 0).toDouble() / 100,
                      sub: m['end'] == null || '${m['end']}'.isEmpty
                          ? null
                          : 'resolves ${m['end']}'),
              ]),
        ),
      if (data.kind('commodity').isNotEmpty)
        (
          id: 'commodities',
          label: 'COMMODITIES',
          child: LedgerSection('Commodities', children: [
            for (final t in data.kind('commodity'))
              _TickRow(t, spark: t.closes.length > 1),
          ]),
        ),
      if (chokes.isNotEmpty || ports.isNotEmpty)
        (
          id: 'shipping',
          label: 'SHIPPING',
          child: LedgerSection('Shipping',
              footnote:
                  'IMF PortWatch · daily transits, published ~5 days behind',
              children: [
                for (final c in chokes)
                  LedgerRow(
                      lead: '${c['n_total'] ?? ''}',
                      main: '${c['name'] ?? ''}',
                      trail: c['pct'] == null
                          ? ''
                          : '${(c['pct'] as num) >= 0 ? '+' : '−'}${(c['pct'] as num).abs()}% vs 30d',
                      trailColor: c['pct'] == null
                          ? null
                          : ((c['pct'] as num) >= 0 ? green : red),
                      sub:
                          'tankers ${c['n_tanker'] ?? '—'} · ${dmy(c['date'])}'),
                for (final p in ports)
                  LedgerRow(
                      lead: '${p['portcalls'] ?? ''}',
                      main: '${p['name'] ?? ''} port calls',
                      sub:
                          'in ${_kt(p['import'])} · out ${_kt(p['export'])} · ${dmy(p['date'])}'),
              ]),
        ),
      if (mf.isNotEmpty || onAddMf != null)
        (
          id: 'mf',
          label: 'MF',
          child: LedgerSection('MF',
              action: onAddMf == null
                  ? null
                  : TextButton(
                      onPressed: onAddMf,
                      child: Text('+ Add fund',
                          style: mono.copyWith(fontSize: 12, color: green))),
              children: [
                for (final t in mf)
                  _MfRow(t, data.followedMf.contains(t.meta['scheme_code']),
                      onFollowMf),
              ]),
        ),
      if (bonds.isNotEmpty || rbi.isNotEmpty || cb.isNotEmpty)
        (
          id: 'bonds',
          label: 'BONDS',
          child: LedgerSection('Bonds',
              stamp: data.blobUpdated['bonds'],
              stampPrefix: 'Stooq',
              footnote:
                  'falling yield = green${rbi['asof'] == null ? '' : ' · RBI as of ${rbi['asof']}'}',
              children: [
                // The curve: benchmark G-Secs by residual tenor, points at
                // column centres so the tenor row underneath is the axis.
                if (bonds.length >= 2) ...[
                  const SizedBox(height: 12),
                  LabeledLine(
                    [
                      for (final b in bonds)
                        ((b['yield'] ?? 0) as num).toDouble()
                    ],
                    [for (final b in bonds) '${b['tenor'] ?? ''}'],
                    ink,
                  ),
                  const SizedBox(height: 8),
                ],
                KvTable(const [
                  'TENOR',
                  'YIELD',
                  'SERIES',
                  'CHANGE'
                ], [
                  for (final b in bonds)
                    (
                      metric: '${b['tenor'] ?? ''}',
                      value:
                          '${fmtNum(((b['yield'] ?? 0) as num).toDouble())}%',
                      third: '${b['name'] ?? 'G-Sec'}',
                      read: [
                        if (b['chg_bp'] != null)
                          '${(b['chg_bp'] as num) >= 0 ? '+' : '−'}${(b['chg_bp'] as num).abs()} bp',
                        if (b['date'] != null) '${b['date']}',
                      ].join(' · '),
                      // Falling yield = rising bond prices, so down is green here.
                      tone: b['chg_bp'] == null
                          ? 0
                          : ((b['chg_bp'] as num) <= 0 ? 1 : -1),
                    ),
                ]),
                if (rbi.isNotEmpty) ...[
                  _groupLabel('RBI POLICY RATES'),
                  StatGrid(columns: 2, [
                    for (final (key, label) in const [
                      ('repo', 'Repo rate'),
                      ('sdf', 'Standing deposit facility'),
                      ('msf', 'Marginal standing facility'),
                      ('bank_rate', 'Bank rate'),
                      ('reverse_repo', 'Reverse repo'),
                      ('crr', 'CRR'),
                      ('slr', 'SLR'),
                      ('tbill_91d', '91-day T-bill cut-off'),
                      ('tbill_182d', '182-day T-bill cut-off'),
                      ('tbill_364d', '364-day T-bill cut-off'),
                    ])
                      if (rbi[key] != null)
                        StatTile(
                            label, '${fmtNum((rbi[key] as num).toDouble())}%'),
                  ]),
                ],
                // The world's policy rates (BIS), under RBI's own box.
                if (cb.isNotEmpty) ...[
                  _groupLabel('WORLD POLICY RATES'),
                  StatGrid(columns: 2, [
                    for (final (key, label) in const [
                      ('US', 'Fed funds'),
                      ('XM', 'ECB deposit'),
                      ('GB', 'BoE bank rate'),
                      ('JP', 'BoJ policy'),
                      ('CN', 'PBoC 1y LPR'),
                    ])
                      if (cb[key] is Map)
                        StatTile(label,
                            '${fmtNum(((cb[key] as Map)['rate'] as num).toDouble())}%',
                            sub:
                                '${key == 'XM' ? 'EU' : key} · ${(cb[key] as Map)['asof'] ?? ''}'),
                  ]),
                ],
              ]),
        ),
      if (ipos.isNotEmpty)
        (
          id: 'ipos',
          label: 'IPO',
          child:
              LedgerSection('IPO', stamp: data.blobUpdated['ipos'], children: [
            KvTable(const [
              'SYMBOL',
              'BAND ₹',
              'SIZE',
              'COMPANY · DATES · STATUS'
            ], [
              for (final i in ipos)
                (
                  metric: '${i['symbol'] ?? ''}',
                  value: '${i['band'] ?? '—'}',
                  third: '${i['size'] ?? '—'}',
                  read: [
                    if (i['company'] != null) '${i['company']}',
                    if (i['open'] != null || i['close'] != null)
                      '${i['open'] ?? ''}–${i['close'] ?? ''}',
                    if (i['status'] != null) '${i['status']}',
                  ].join(' · '),
                  tone: '${i['status']}'.toLowerCase() == 'open' ? 1 : 0,
                ),
            ]),
          ]),
        ),
      if (macro.isNotEmpty || wb.isNotEmpty)
        (
          id: 'macro',
          label: 'MACRO',
          child: LedgerSection('Macro', children: [
            for (final t in macro) _MacroRow(t),
            // Annual frame from the World Bank: one row per series.
            if (wb.values.any((v) => v is Map && v['value'] != null))
              KvTable(const [
                'SERIES',
                'VALUE',
                'YEAR',
                'PRIOR'
              ], [
                for (final e in wb.entries)
                  if (e.value is Map && (e.value as Map)['value'] != null)
                    (
                      metric: '${(e.value as Map)['name'] ?? e.key}',
                      value:
                          '${fmtNum(((e.value as Map)['value'] as num).toDouble(), decimals: 2)}${(e.value as Map)['units'] == '%' ? '%' : ''}',
                      third: '${(e.value as Map)['year'] ?? ''}',
                      read: [
                        if ((e.value as Map)['units'] != '%')
                          '${(e.value as Map)['units']}',
                        if ((e.value as Map)['prev'] != null)
                          'prev ${(e.value as Map)['prev_year'] ?? ''}: ${fmtNum(((e.value as Map)['prev'] as num).toDouble(), decimals: 2)}',
                      ].join(' · '),
                      tone: 0,
                    ),
              ]),
          ]),
        ),
      if (quakes.isNotEmpty)
        (
          id: 'quakes',
          label: 'QUAKES',
          child: LedgerSection('Quakes',
              stamp: data.blobUpdated['hazards'],
              stampPrefix: 'USGS',
              footnote: 'last 7 days · M4.5+ · India region',
              children: [
                KvTable(const [
                  'MAG',
                  'DATE',
                  '',
                  'PLACE'
                ], [
                  for (final q in quakes)
                    (
                      metric: 'M${q['mag']}',
                      value: '${q['time']}'.length >= 10
                          ? '${q['time']}'.substring(5, 10)
                          : '',
                      third: '',
                      read: '${q['place'] ?? ''}',
                      tone: ((q['mag'] as num?) ?? 0) >= 6 ? -1 : 0,
                    ),
                ]),
              ]),
        ),
      if (monsoon['country'] is Map)
        (
          id: 'monsoon',
          label: 'MONSOON',
          child: LedgerSection('Monsoon',
              footnote:
                  'IMD · rainfall since 1 June vs normal · ${dmy(monsoon['asof'])}',
              children: [
                _depRow('India',
                    (monsoon['country'] as Map).cast<String, dynamic>(),
                    country: true),
                for (final r in _l(monsoon['regions']))
                  _depRow('${r['name']}', r),
                if (_l(monsoon['worst']).isNotEmpty) ...[
                  _groupLabel('MOST DEFICIENT'),
                  for (final r in _l(monsoon['worst']))
                    _depRow('${r['name']}', r),
                ],
              ]),
        ),
      if (results.isNotEmpty)
        (
          id: 'results',
          label: 'RESULTS',
          child: LedgerSection('Results',
              stamp: data.blobUpdated['results_calendar'],
              children: [
                KvTable(const [
                  'SYMBOL',
                  'DATE',
                  '',
                  'COMPANY · PURPOSE'
                ], [
                  for (final r in results)
                    (
                      metric: r['symbol']?.toString() ?? '',
                      value: dmy(r['date']),
                      third: '',
                      read: [
                        if (r['company'] != null) '${r['company']}',
                        if (r['purpose'] != null) '${r['purpose']}',
                      ].join(' · '),
                      tone: 0,
                    ),
                ]),
              ]),
        ),
      if (deals.isNotEmpty)
        (
          id: 'deals',
          label: 'DEALS',
          child: LedgerSection('Deals',
              stamp: data.blobUpdated['bulk_deals'],
              children: [
                KvTable(const [
                  'SYMBOL',
                  'QTY',
                  'PRICE',
                  'CLIENT · SIDE'
                ], [
                  for (final d in deals)
                    (
                      metric: d['symbol']?.toString() ?? '',
                      value: fmtNum((d['qty'] as num).toDouble(), decimals: 0),
                      third: '₹${fmtNum((d['price'] as num).toDouble())}',
                      read:
                          '${d['client'] ?? ''} · ${d['side']} ₹${_crore(d['value'])} · ${d['type']} · ${d['date'] ?? ''}',
                      tone: d['side'] == 'BUY' ? 1 : -1,
                    ),
                ]),
              ]),
        ),
      if (insider.isNotEmpty)
        (
          id: 'insider',
          label: 'INSIDER',
          child: LedgerSection('Insider',
              stamp: data.blobUpdated['insider_trades'],
              children: [
                KvTable(const [
                  'SYMBOL',
                  'QTY',
                  'SIDE',
                  'PERSON · CATEGORY'
                ], [
                  for (final i in insider)
                    (
                      metric: i['symbol']?.toString() ?? '',
                      value: '${i['qty'] ?? ''}',
                      third: '${i['side'] ?? ''}'.toUpperCase(),
                      read:
                          '${i['person'] ?? ''} · ${i['category'] ?? ''} · ${i['mode'] ?? ''} · ${i['date'] ?? ''}',
                      tone:
                          '${i['side']}'.toLowerCase().startsWith('b') ? 1 : -1,
                    ),
                ]),
              ]),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final secs = _sections();
    _tracker.ids = [for (final s in secs) s.id];
    final stale = _stale(data.updatedAt);
    final scroll = SingleChildScrollView(
      key: const Key('marketsScroll'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (data.ticks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Text(
                  'No market data yet.\nThe pipeline fills this in within a few minutes.',
                  textAlign: TextAlign.center,
                  style: mono.copyWith(fontSize: 13, height: 1.6)),
            ),
          for (final s in secs)
            KeyedSubtree(key: _tracker.key(s.id), child: s.child),
          const SizedBox(height: 20),
          Text(
              [
                if (data.updatedAt != null)
                  'as of ${hhmmIst(data.updatedAt!)} IST',
                if (stale) 'stale — pipeline has not refreshed',
                'Yahoo Finance · CoinGecko · mfapi.in · NSE · delayed',
              ].join(' · '),
              style:
                  mono.copyWith(fontSize: 10, color: stale ? amber : inkDim)),
        ],
      ),
    );
    if (secs.length < 2) return scroll;
    return Column(children: [
      SectionRibbon([for (final s in secs) (id: s.id, label: s.label)],
          _tracker.active, _tracker.jump),
      Expanded(
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: _tracker.track,
          child: scroll,
        ),
      ),
    ]);
  }
}

/// A blob's raw List into typed maps (MarketsData.list, but for nested lists).
List<Map<String, dynamic>> _l(Object? v) => [
      for (final r in (v as List? ?? const []))
        Map<String, dynamic>.from(r as Map)
    ];

Widget _groupLabel(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
      child: Text(s, style: mono.copyWith(fontSize: 10)),
    );

/// Nine swatches, most-negative → most-positive, with the horizon's range.
Widget _heatLegend(double scale) {
  final r = scale.toStringAsFixed(0);
  return Row(children: [
    Text('−$r%', style: mono.copyWith(fontSize: 9)),
    const SizedBox(width: 6),
    for (final c in heatSwatches(scale: scale))
      SizedBox(width: 20, height: 8, child: ColoredBox(color: c)),
    const SizedBox(width: 6),
    Text('+$r%', style: mono.copyWith(fontSize: 9)),
    const Spacer(),
    Text('bar = advances vs declines', style: mono.copyWith(fontSize: 9)),
  ]);
}

KvRow _oiRow(Map<String, dynamic> r, String what) {
  final oi = ((r['oi_pct'] ?? 0) as num).toDouble();
  final pct = (r['pct'] as num?)?.toDouble();
  return (
    metric: '${r['symbol']}',
    value: r['ltp'] == null ? '—' : '₹${fmtNum((r['ltp'] as num).toDouble())}',
    third: '${oi >= 0 ? '+' : '−'}${oi.abs().toStringAsFixed(1)}% OI',
    read: [if (pct != null) fmtPct(pct), what].join(' · '),
    tone: pct == null ? 0 : (pct >= 0 ? 1 : -1),
  );
}

/// Two hours is 2x the slowest Phase-1 cadence (equities off-hours); older
/// than that the numbers are shown but called out, never passed off as live.
bool _stale(DateTime? updatedAt) =>
    updatedAt != null &&
    DateTime.now().difference(updatedAt) > const Duration(hours: 2);

/// ₹ value -> "24.7 Cr" / "85 L" — deal sizes read in crores here, nowhere else.
String _crore(Object? v) {
  final n = (v as num?)?.toDouble() ?? 0;
  if (n >= 1e7) return '${(n / 1e7).toStringAsFixed(n >= 1e9 ? 0 : 1)} Cr';
  if (n >= 1e5) return '${(n / 1e5).toStringAsFixed(0)} L';
  return fmtNum(n, decimals: 0);
}

const _componentNames = {
  'vix': 'India VIX',
  'breadth': 'Breadth',
  'fii': 'FII flows',
  'hi_lo': '52-week highs vs lows',
  'momentum': 'NIFTY momentum',
  'fii_outflow': 'FII selling',
  'inr': 'Rupee',
  'news': 'News spikes',
};

/// Score row + a 0-100 scale bar, then one bar row per component.
/// [lowIsRed] flips the zone colours: fear is low on Fear & Greed, risk is high.
List<Widget> _gaugeRows(String name, Map<String, dynamic> g, Color color,
    {required bool lowIsRed}) {
  final comps = (g['components'] as Map?)?.cast<String, dynamic>() ?? const {};
  final score = ((g['score'] ?? 0) as num).toDouble();
  return [
    LedgerRow(
        main: name,
        trail: '${g['label']}',
        trailColor: color,
        sub: 'score ${g['score']}'),
    const SizedBox(height: 4),
    ScaleBar(score, zones: [
      (0, 30, lowIsRed ? red : green),
      (30, 70, amber),
      (70, 100, lowIsRed ? green : red),
    ]),
    const SizedBox(height: 8),
    for (final e in comps.entries)
      LedgerRow(
          main: _componentNames[e.key] ?? e.key,
          trail: '${e.value}',
          bar: ((e.value as num?) ?? 0).toDouble() / 100),
  ];
}

/// Tonnes -> "123k t" for port throughput.
String _kt(Object? v) =>
    '${(((v as num?)?.toDouble() ?? 0) / 1000).toStringAsFixed(0)}k t';

/// One participant's net index-futures stance, day-over-day when we have it.
Widget _poiRow(String who, Map<String, dynamic> r) {
  final net = ((r['net_fut_idx'] ?? 0) as num).toDouble();
  final prev = (r['prev_net_fut_idx'] as num?)?.toDouble();
  final d = prev == null ? null : net - prev;
  final long = ((r['total_long'] ?? 0) as num).toDouble();
  final short = ((r['total_short'] ?? 0) as num).toDouble();
  return LedgerRow(
      lead: who,
      main: 'net index futures',
      trail: '${net >= 0 ? '+' : ''}${fmtNum(net, decimals: 0)}',
      trailColor: net >= 0 ? green : red,
      bar: long + short == 0 ? null : long / (long + short),
      barColor: green,
      barTrack: red.withValues(alpha: 0.35),
      sub: [
        if (d != null) 'Δ ${d >= 0 ? '+' : ''}${fmtNum(d, decimals: 0)} d/d',
        'long ${fmtNum(long, decimals: 0)} · short ${fmtNum(short, decimals: 0)}',
      ].join(' · '));
}

/// IMD departure row: red past -19% (deficient), green past +19% (excess).
Widget _depRow(String name, Map<String, dynamic> r, {bool country = false}) {
  final dep = ((r['dep_pct'] ?? 0) as num).toInt();
  return LedgerRow(
      lead: country ? 'INDIA' : null,
      main: name,
      trail: '${dep >= 0 ? '+' : '−'}${dep.abs()}%',
      trailColor: dep < -19
          ? red
          : dep > 19
              ? green
              : null,
      sub: country && r['actual_mm'] != null
          ? 'actual ${r['actual_mm']} mm · normal ${r['normal_mm']} mm'
          : null);
}

/// Which venues are trading right now; a minute timer keeps the bells honest.
class _Sessions extends StatefulWidget {
  const _Sessions();

  @override
  State<_Sessions> createState() => _SessionsState();
}

class _SessionsState extends State<_Sessions> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LedgerSection('Sessions', children: [
        for (final s in sessionStates(DateTime.now().toUtc()))
          LedgerRow(
              lead: s.name,
              main: s.note,
              trail: '●',
              trailColor: s.open ? green : inkDim),
      ]);
}

Widget _moveRow(Map<String, dynamic> m, String main, {VoidCallback? onTap}) {
  final chg = (m['chg'] as num?)?.toDouble();
  return LedgerRow(
      lead: '${m['symbol'] ?? ''}',
      main: main,
      trail: fmtPct(chg),
      trailColor: chg == null ? null : (chg >= 0 ? green : red),
      onTap: onTap);
}

/// FII/DII cash-market: net in the row, buy vs sell as paired bars. ₹ Cr.
List<Widget> _flowRows(String who, Map<String, dynamic> d, String? date) {
  final net = (d['net'] as num?)?.toDouble() ?? 0;
  final buy = ((d['buy'] ?? 0) as num).toDouble();
  final sell = ((d['sell'] ?? 0) as num).toDouble();
  return [
    LedgerRow(
        lead: who,
        main: 'cash market${date == null ? '' : ' · $date'}',
        trail: '${net >= 0 ? '+' : '−'}₹${fmtNum(net.abs(), decimals: 0)} Cr',
        trailColor: net >= 0 ? green : red),
    Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('buy ₹${fmtNum(buy, decimals: 0)} Cr',
              style: mono.copyWith(fontSize: 10)),
          Text('sell ₹${fmtNum(sell, decimals: 0)} Cr',
              style: mono.copyWith(fontSize: 10)),
        ]),
        const SizedBox(height: 3),
        PairedBar(buy, sell),
      ]),
    ),
  ];
}

/// advances vs declines (or new highs vs lows): counts on the right, the
/// green share of a red track underneath.
Widget _breadthRow(String lead, num adv, num dec,
        {String main = 'advance / decline'}) =>
    LedgerRow(
        lead: lead,
        main: main,
        trail:
            '${adv is int ? adv : adv.toInt()}↑ ${dec is int ? dec : dec.toInt()}↓',
        trailColor: adv >= dec ? green : red,
        bar: adv + dec == 0 ? 0 : adv / (adv + dec),
        barColor: green,
        barTrack: red.withValues(alpha: 0.35));

/// One instrument: name (+ label) left, sparkline, price and % in a fixed
/// 84px column so the section shares one right edge.
class _TickRow extends StatelessWidget {
  const _TickRow(this.t, {this.spark = false});
  final Tick t;
  final bool spark;

  @override
  Widget build(BuildContext context) {
    final color = t.changePct == null ? inkDim : (t.up ? green : red);
    final label = t.meta['label'] as String?;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: border))),
      child: Row(children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: serif.copyWith(fontSize: 15)),
            if (label != null) Text(label, style: mono.copyWith(fontSize: 10)),
          ]),
        ),
        if (spark && t.closes.length > 1)
          SizedBox(width: 80, height: 24, child: Sparkline(t.closes, color)),
        const SizedBox(width: 14),
        SizedBox(
          width: 84,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(fmtMoney(t.price, t.currency),
                maxLines: 1, style: mono.copyWith(fontSize: 14, color: ink)),
            Text(fmtPct(t.changePct),
                style: mono.copyWith(fontSize: 11, color: color)),
          ]),
        ),
      ]),
    );
  }
}

/// Find any covered stock by name or NSE symbol — the labeled door to a
/// company page (the star there follows it). Debounced ilike over
/// `companies`, same source Ask's entity routing uses.
void _openStockSearch(BuildContext context) {
  Timer? debounce;
  var results = const <Company>[];
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: bg,
    shape: const RoundedRectangleBorder(),
    isScrollControlled: true,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheet) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('FIND A STOCK',
                      style: mono.copyWith(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  TextField(
                    autofocus: true,
                    style: mono.copyWith(fontSize: 14),
                    decoration: InputDecoration(
                        hintText: 'name or NSE symbol',
                        hintStyle: mono.copyWith(fontSize: 13, color: inkDim)),
                    onChanged: (q) {
                      // PostgREST or() parses commas/parens — keep it to what
                      // a company name can contain.
                      final query =
                          q.replaceAll(RegExp(r'[^A-Za-z0-9 &.\-]'), '').trim();
                      debounce?.cancel();
                      debounce =
                          Timer(const Duration(milliseconds: 300), () async {
                        if (query.length < 2) {
                          if (sheetCtx.mounted) {
                            setSheet(() => results = const []);
                          }
                          return;
                        }
                        try {
                          final rows = await Supabase.instance.client
                              .from('companies')
                              .select('id,name,nse_symbol')
                              .or('name.ilike.%$query%,nse_symbol.ilike.%$query%')
                              .limit(10);
                          if (!sheetCtx.mounted) return;
                          setSheet(() => results = [
                                for (final r in rows)
                                  Company.fromJson(Map<String, dynamic>.from(r))
                              ]);
                        } catch (_) {
                          // lookup down -> the list just stays as it is
                        }
                      });
                    },
                  ),
                  for (final c in results)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: serif.copyWith(fontSize: 14)),
                      trailing: Text(c.nseSymbol,
                          style: mono.copyWith(fontSize: 11, color: inkDim)),
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => StockScreen(company: c)));
                      },
                    ),
                ]),
          ),
        ),
      ),
    ),
  ).whenComplete(() => debounce?.cancel());
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
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: border))),
        child: Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('\$${c.nseSymbol}',
                  style: mono.copyWith(fontSize: 12, color: ink)),
              Text(c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: serif.copyWith(fontSize: 14)),
            ]),
          ),
          SizedBox(
            width: 84,
            child: t != null
                ? Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(fmtMoney(t!.price, t!.currency),
                        maxLines: 1,
                        style: mono.copyWith(fontSize: 14, color: ink)),
                    Text(fmtPct(t!.changePct),
                        style: mono.copyWith(fontSize: 11, color: color)),
                  ])
                : Text('—',
                    textAlign: TextAlign.end,
                    style: mono.copyWith(fontSize: 13)),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.north_east_rounded, size: 12, color: inkDim),
        ]),
      ),
    );
  }
}

/// A mutual-fund scheme: ★ to follow, NAV and 1-day move, 1-year return.
class _MfRow extends StatelessWidget {
  const _MfRow(this.t, this.followed, this.onFollow);
  final Tick t;
  final bool followed;
  final void Function(int code, bool follow)? onFollow;

  @override
  Widget build(BuildContext context) {
    final color = t.changePct == null ? inkDim : (t.up ? green : red);
    final code = t.meta['scheme_code'];
    final y = (t.meta['ret_1y'] as num?)?.toDouble();
    final cat = (t.meta['category'] as String?)?.split(' - ').last;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: border))),
      child: Row(children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: onFollow == null || code is! int
              ? null
              : () => onFollow!(code, !followed),
          icon: Icon(followed ? Icons.star_rounded : Icons.star_outline_rounded,
              color: followed ? amber : inkDim, size: 20),
          tooltip: followed ? 'Unfollow' : 'Follow',
        ),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: serif.copyWith(fontSize: 14)),
            Text(
                [
                  if (y != null) '1y ${fmtPct(y, decimals: 1)}',
                  if (cat != null && cat.isNotEmpty) cat,
                ].join(' · '),
                style: mono.copyWith(fontSize: 10)),
          ]),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 84,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('₹${fmtNum(t.price, decimals: 2)}',
                maxLines: 1, style: mono.copyWith(fontSize: 13, color: ink)),
            Text(fmtPct(t.changePct),
                style: mono.copyWith(fontSize: 11, color: color)),
          ]),
        ),
      ]),
    );
  }
}

/// A macro series: value in its own units, previous and period underneath.
class _MacroRow extends StatelessWidget {
  const _MacroRow(this.t);
  final Tick t;

  @override
  Widget build(BuildContext context) {
    final units = (t.meta['units'] as String?) ?? '';
    final delta = (t.meta['delta'] as num?)?.toDouble();
    final period = t.meta['period'] as String?;
    String val(double v) => units == '%'
        ? '${v.toStringAsFixed(2)}%'
        : fmtNum(v, indian: units == 'INR');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: border))),
      child: Row(children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.name, style: serif.copyWith(fontSize: 15)),
            Text(
                [
                  if (t.prevClose != null) 'prev ${val(t.prevClose!)}',
                  if (period != null) period,
                ].join(' · '),
                style: mono.copyWith(fontSize: 10)),
          ]),
        ),
        if (t.closes.length > 1)
          SizedBox(
              width: 80,
              height: 24,
              child: Sparkline(t.closes,
                  delta == null ? inkDim : (delta >= 0 ? green : red))),
        const SizedBox(width: 14),
        SizedBox(
          width: 84,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(val(t.price),
                maxLines: 1, style: mono.copyWith(fontSize: 14, color: ink)),
            if (delta != null)
              Text('${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(2)}',
                  style: mono.copyWith(
                      fontSize: 11, color: delta >= 0 ? green : red)),
          ]),
        ),
      ]),
    );
  }
}

/// Tile names must survive a 3-across grid; only the long ones get overrides,
/// the rest just lose their "NIFTY " prefix.
const _shortSector = {
  'FINANCIAL SERVICES': 'FIN SVCS',
  'FINANCIAL SERVICES 25/50': 'FIN SVC 25/50',
  'CONSUMER DURABLES': 'CONS DUR',
  'PRIVATE BANK': 'PVT BANK',
  'MIDSMALL HEALTHCARE': 'MIDSML HLTH',
};

String _sectorName(Map<String, dynamic> s) {
  final n = (s['index'] as String? ?? '')
      .replaceFirst(RegExp(r'^NIFTY\s*'), '')
      .replaceFirst(' INDEX', '');
  return _shortSector[n] ?? n;
}

double? _num(Object? v) => v == null ? null : double.tryParse('$v');

/// One NSE index group inside SECTORS: dim label + heat grid sorted by the
/// chosen horizon. Sectoral opens in full; the other groups start at 6 tiles
/// with a "show all N" expander.
class _HeatGroup extends StatefulWidget {
  const _HeatGroup(this.label, this.rows,
      {this.expanded = false, this.field = 'pct', this.scale = 3});
  final String label;
  final List<Map<String, dynamic>> rows;
  final bool expanded;
  final String field;
  final double scale;

  @override
  State<_HeatGroup> createState() => _HeatGroupState();
}

class _HeatGroupState extends State<_HeatGroup> {
  late bool _all = widget.expanded;

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.rows]..sort((a, b) {
        final va = _num(a[widget.field]), vb = _num(b[widget.field]);
        if (va == null) return vb == null ? 0 : 1;
        if (vb == null) return -1;
        return vb.compareTo(va);
      });
    final tiles = _all ? sorted : sorted.take(6).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 10),
      Text(widget.label, style: mono.copyWith(fontSize: 10, color: inkDim)),
      const SizedBox(height: 6),
      StatGrid([
        for (final s in tiles)
          Builder(builder: (context) {
            final adv = _num(s['advances']), dec = _num(s['declines']);
            final hasBreadth = adv != null && dec != null && adv + dec > 0;
            return HeatCell(_sectorName(s), _num(s[widget.field]),
                scale: widget.scale,
                bar: hasBreadth ? adv / (adv + dec) : null,
                barColor: green,
                barTrack: red.withValues(alpha: 0.35),
                sub: hasBreadth || s['last'] == null
                    ? null
                    : fmtNum(_num(s['last']) ?? 0, decimals: 0),
                onTap: () => _showSectorSheet(context, s));
          }),
      ]),
      if (!_all && widget.rows.length > 6)
        TextButton(
            onPressed: () => setState(() => _all = true),
            child: Text('show all ${widget.rows.length}',
                style: mono.copyWith(fontSize: 12, color: green))),
    ]);
  }
}

/// Everything NSE gives us for one sectoral index — the tile shows two fields,
/// this sheet shows the rest. Values arrive as num or string; parse leniently.
void _showSectorSheet(BuildContext context, Map<String, dynamic> s) {
  Color pctColor(double? v) => v == null ? inkDim : (v >= 0 ? green : red);
  final pct = _num(s['pct']);
  final d30 = _num(s['pct_30d']);
  final y1 = _num(s['pct_1y']);
  final adv = _num(s['advances']);
  final dec = _num(s['declines']);
  final hi = _num(s['year_high']);
  final lo = _num(s['year_low']);
  final pe = _num(s['pe']);
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: surface,
    builder: (_) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${s['index'] ?? ''}'.toUpperCase(), style: monoLabel),
            const SizedBox(height: 6),
            const Divider(height: 1),
            LedgerRow(
                lead: 'TODAY',
                main: _num(s['last']) == null
                    ? 'change'
                    : 'level ${fmtNum(_num(s['last'])!, decimals: 0)}',
                trail: fmtPct(pct),
                trailColor: pctColor(pct)),
            if (pe != null)
              LedgerRow(lead: 'P/E', main: 'valuation', trail: fmtNum(pe)),
            if (adv != null && dec != null) _breadthRow('BREADTH', adv, dec),
            if (d30 != null)
              LedgerRow(
                  lead: '30D',
                  main: 'one month',
                  trail: fmtPct(d30),
                  trailColor: pctColor(d30)),
            if (y1 != null)
              LedgerRow(
                  lead: '1Y',
                  main: 'one year',
                  trail: fmtPct(y1),
                  trailColor: pctColor(y1)),
            if (hi != null && lo != null)
              LedgerRow(
                  lead: '52W',
                  main: 'high / low',
                  trail:
                      '${fmtNum(hi, decimals: 0)} / ${fmtNum(lo, decimals: 0)}'),
          ]),
    ),
  );
}

/// Search mfapi.in (keyless, straight from the phone like Yahoo on the stock
/// page) and pick a scheme to follow. Pops with the scheme code.
class MfSearchSheet extends StatefulWidget {
  const MfSearchSheet({super.key});

  @override
  State<MfSearchSheet> createState() => _MfSearchSheetState();
}

class _MfSearchSheetState extends State<MfSearchSheet> {
  final _ctl = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _hits = const [];
  bool _busy = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (q.trim().length < 3) return setState(() => _hits = const []);
    setState(() => _busy = true);
    try {
      final r = await http
          .get(Uri.parse(
              'https://api.mfapi.in/mf/search?q=${Uri.encodeQueryComponent(q.trim())}'))
          .timeout(const Duration(seconds: 10));
      final all = (jsonDecode(r.body) as List).cast<Map>();
      // Direct-Growth only: the Regular/IDCW variants of one fund are noise here.
      final hits = [
        for (final h in all)
          if (RegExp(r'direct', caseSensitive: false)
                  .hasMatch('${h['schemeName']}') &&
              RegExp(r'growth', caseSensitive: false)
                  .hasMatch('${h['schemeName']}') &&
              !RegExp(r'idcw|dividend', caseSensitive: false)
                  .hasMatch('${h['schemeName']}'))
            Map<String, dynamic>.from(h)
      ];
      if (mounted) setState(() => _hits = hits.take(30).toList());
    } catch (_) {
      if (mounted) setState(() => _hits = const []);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('ADD A FUND', style: monoLabel),
          const SizedBox(height: 12),
          TextField(
            controller: _ctl,
            autofocus: true,
            onChanged: _onChanged,
            style: serif.copyWith(fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Fund name, e.g. Parag Parikh',
              hintStyle: mono.copyWith(fontSize: 13),
              suffixIcon: _busy
                  ? Padding(
                      padding: const EdgeInsets.all(12), child: appSpinner())
                  : null,
              enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: border)),
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final h in _hits)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${h['schemeName']}',
                      style: serif.copyWith(fontSize: 13)),
                  onTap: () =>
                      Navigator.of(context).pop(h['schemeCode'] as int),
                ),
              if (_hits.isEmpty && _ctl.text.trim().length >= 3 && !_busy)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text('No Direct-Growth scheme matches.',
                      style: mono.copyWith(fontSize: 12)),
                ),
            ]),
          ),
        ]),
      );
}
