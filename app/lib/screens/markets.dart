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
import 'alerts.dart';
import 'portfolio.dart';
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

  /// Region tabs (Moneycontrol's Markets top row, Tanis's order). SESSIONS and
  /// SECTORS stay above the tabs whatever is picked; every other section
  /// belongs to one region — INDIA unless listed in [_regionOf].
  static const regions = [
    'INDIA',
    'MF',
    'BONDS',
    'IPO',
    'UNLISTED',
    'CRYPTO',
    'US'
  ];
  static const _pinned = {'sessions', 'sectors'};
  static const _regionOf = {
    'mf': 'MF',
    'bonds': 'BONDS',
    'ipos': 'IPO',
    'unlisted': 'UNLISTED',
    'crypto': 'CRYPTO',
    'global': 'US',
    'movers': 'US',
    'odds': 'US',
  };

  /// INDIA reads like MC's page: indices, trends, OI, top movers, then the
  /// rest in the old order; ids missing here keep their build order after.
  static const _order = [
    'sessions',
    'sectors',
    'portfolio',
    'indices',
    'trends',
    'oi',
    'top',
    'records',
    'moves',
    'watch',
    'screens',
    'flows',
    'today',
    'mood',
    'calendar',
    'results',
    'earnings',
    'positioning',
    'fx',
    'commodities',
    'macro',
    'shipping',
    'monsoon',
    'quakes',
    'deals',
    'insider',
  ];
  String _region = 'INDIA';

  /// TRENDS bucket (blob key -> chip label).
  static const _buckets = [
    ('bullish', 'BULLISH'),
    ('turning_bullish', 'TURNING BULLISH'),
    ('bearish', 'BEARISH'),
    ('turning_bearish', 'TURNING BEARISH'),
  ];
  String _bucket = 'bullish';

  /// US MARKET MOVERS: index filter + list (MC's chips).
  static const _usIdx = ['ALL', 'DOW', 'NASDAQ'];
  static const _usLists = [
    ('top', 'TOP'),
    ('gainers', 'GAINERS'),
    ('losers', 'LOSERS'),
    ('hi52', '52W HIGH'),
  ];
  String _usIndex = 'ALL';
  String _usList = 'top';

  /// CRYPTO quote currency (MC's USD ⇄ INR switch). Session-only.
  bool _cryptoUsd = false;

  /// UNLISTED search (client-side filter over the blob).
  String _unlistedQ = '';

  /// A symbol from a blob row -> its stock page (same lookup as SCREENS).
  Future<void> _openSymbol(String symbol) async {
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

  /// One explained mover: the story (tap -> feed) or the NSE filing (tap ->
  /// the PDF) that is the reason, its impact, and where it was first reported.
  LtRow _moveRow(Map<String, dynamic> m) {
    final storyId = (m['story_id'] as num?)?.toInt();
    final url = m['url'] as String?;
    final impact = m['impact'];
    return (
      cells: [
        '${m['symbol'] ?? ''}',
        fmtPct((m['chg'] as num?)?.toDouble()),
        _rs(m['ltp']),
        impact != null
            ? '$impact/10'
            : m['reason'] != null
                ? 'filing'
                : '—',
        '${m['title'] ?? m['reason'] ?? ''}',
        '${m['source'] ?? ''}',
        _when(m['at']),
      ],
      tone: 0,
      onTap: storyId != null
          ? () {
              homeTab.value = 0;
              pendingStory.value = storyId;
            }
          : url != null && url.isNotEmpty
              ? () => openExternal(context, url)
              : null,
    );
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
        if (t.meta['global'] == true &&
            t.meta['adr'] != true &&
            t.meta['us'] != true)
          t
    ];
    // US stocks (market.py US_STOCKS): roster order = mcap-ish = MC's "top".
    final usAll = [
      for (final t in allIdx)
        if (t.meta['us'] == true &&
            (_usIndex == 'ALL' ||
                ((t.meta['idx'] as List?) ?? const []).contains(_usIndex)))
          t
    ];
    final usRows = switch (_usList) {
      'gainers' => [...usAll]
        ..sort((a, b) => (b.changePct ?? 0).compareTo(a.changePct ?? 0)),
      'losers' => [...usAll]
        ..sort((a, b) => (a.changePct ?? 0).compareTo(b.changePct ?? 0)),
      'hi52' => [
          for (final t in usAll)
            if (t.meta['hi52'] is num &&
                t.price >= (t.meta['hi52'] as num) * 0.98)
              t
        ],
      _ => usAll,
    };
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
    // Stock Analysis (S&P Global) blobs, pipeline/stockanalysis.py
    final earnings = data.list('earnings_calendar');
    final records =
        (data.blobs['records'] as Map?)?.cast<String, dynamic>() ?? const {};
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
    // Unlisted / pre-IPO indicative prices (market.refresh_unlisted).
    final unlisted =
        (data.blobs['unlisted'] as Map?)?.cast<String, dynamic>() ?? const {};
    final uq = _unlistedQ.trim().toLowerCase();
    final unlistedRows = [
      for (final r in _l(unlisted['rows']))
        if (uq.isEmpty || '${r['name']}'.toLowerCase().contains(uq) ||
            '${r['sector'] ?? ''}'.toLowerCase().contains(uq))
          r
    ];
    // 024: universe trend state from stockanalysis.py (bullish / turning …).
    final trends =
        (data.blobs['trends'] as Map?)?.cast<String, dynamic>() ?? const {};
    final trendRows = _l(trends[_bucket]);
    final bonds = _l((data.blobs['bonds'] as Map?)?['yields']);
    final ipoBlob =
        (data.blobs['ipos'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ipos = [..._l(ipoBlob['current']), ..._l(ipoBlob['upcoming'])];
    // Sentiment + signals (pipeline market.refresh_sentiment / signals.py).
    final summary =
        '${(data.blobs['market_summary'] as Map?)?['text'] ?? ''}'.trim();
    final summaryLines = [
      for (final l
          in (data.blobs['market_summary'] as Map?)?['lines'] as List? ??
              (summary.isEmpty ? const [] : summary.split(' · ')))
        '$l'
    ];
    final fg = (data.blobs['fear_greed'] as Map?)?.cast<String, dynamic>();
    final risk = (data.blobs['risk_index'] as Map?)?.cast<String, dynamic>();
    final corr = (data.blobs['correlation'] as Map?)?.cast<String, dynamic>();
    final moves =
        (data.blobs['move_context'] as Map?)?.cast<String, dynamic>() ??
            const {};
    final explained = _l(moves['explained']);
    final unexplained = _l(moves['unexplained']);
    final unexplainedN =
        (moves['unexplained_n'] as num?)?.toInt() ?? unexplained.length;
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
    final freight =
        _l(((data.blobs['freight'] as Map?) ?? const {})['indices']);
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
      // Phase A (26 Sep): the holdings strip sits above the watchlist — the
      // one question a holder has on opening Markets is "how am I doing".
      (id: 'portfolio', label: 'PORTFOLIO', child: const PortfolioSummary()),
      (
        id: 'watch',
        label: 'WATCHLIST',
        child: LedgerSection('Watchlist',
            action: Builder(
                builder: (context) => Row(mainAxisSize: MainAxisSize.min, children: [
                      filterPill(
                          'ALERTS',
                          false,
                          green,
                          () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const AlertsScreen())),
                          fontSize: 10),
                      const SizedBox(width: 6),
                      filterPill('SEARCH', false, green,
                          () => _openStockSearch(context),
                          fontSize: 10),
                    ])),
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
                      pillRow([
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
      // Today: one bullet per fact (index moves, FII/DII, top mover, mood) from
      // market_summary.lines — no AI, the headline whole.
      if (summaryLines.isNotEmpty)
        (
          id: 'today',
          label: 'TODAY',
          child: LedgerSection('Today',
              stamp: data.blobUpdated['market_summary'],
              children: [
                const SizedBox(height: 6),
                for (final l in summaryLines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('•  ',
                              style:
                                  serif.copyWith(fontSize: 14, color: inkDim)),
                          Expanded(
                              child:
                                  Text(l, style: serif.copyWith(fontSize: 14))),
                        ]),
                  ),
              ]),
        ),
      if (calendar.isNotEmpty)
        (
          id: 'calendar',
          label: 'CALENDAR',
          child: LedgerSection('Calendar',
              footnote: 'next 45 days · RBI/MOSPI rule + FRED release dates',
              children: [
                LedgerTable(const [
                  LtCol('Date', right: false),
                  LtCol('In'),
                  LtCol('Region', right: false),
                  LtCol('Time', right: false),
                  LtCol('Event', right: false, text: true),
                ], [
                  for (final e in calendar)
                    (
                      cells: [
                        dmy(e['date']),
                        _daysAway(e['date']),
                        '${e['region'] ?? ''}',
                        '${e['time'] ?? ''}',
                        '${e['name'] ?? ''}',
                      ],
                      tone: 0,
                      onTap: null,
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
                if (corr != null) ...[
                  const SizedBox(height: 12),
                  _groupLabel('CROSS-ASSET · 1M'),
                  _corrGrid(corr),
                ],
              ]),
        ),
      // Moves: every explained 3%+ equity move with the story or NSE filing
      // behind it, where it was first reported, and the news impact.
      if (explained.isNotEmpty)
        (
          id: 'moves',
          label: 'MOVES',
          child: LedgerSection('Moves',
              stamp: data.blobUpdated['move_context'],
              footnote: [
                'equities that moved 3%+ · WHY = the story or NSE filing behind it · tap a row to read it',
                if (unexplainedN > 0)
                  '$unexplainedN more moved with no story or filing we carry',
              ].join(' · '),
              children: [
                LedgerTable(const [
                  LtCol('Symbol', right: false),
                  LtCol('Move'),
                  LtCol('LTP ₹'),
                  LtCol('Impact'),
                  LtCol('Why', right: false, text: true),
                  LtCol('Source', right: false, text: true),
                  LtCol('When', right: false),
                ], [
                  for (final m in explained) _moveRow(m),
                ], wrap: 260, initial: 10),
              ]),
        ),
      if (trends.isNotEmpty)
        (
          id: 'trends',
          label: 'TRENDS',
          child: LedgerSection('Trends',
              stamp: data.blobUpdated['trends'],
              footnote:
                  'price vs 50 & 200-day averages · turning = flipped within 7 days · tap a row for the stock · Stock Analysis · as of ${dmy(trends['asof'])}',
              children: [
                const SizedBox(height: 8),
                pillRow([
                  for (final (key, label) in _buckets)
                    filterPill(
                        label,
                        _bucket == key,
                        key.endsWith('bullish') ? green : red,
                        () => setState(() => _bucket = key),
                        fontSize: 9),
                ]),
                const SizedBox(height: 10),
                if (trendRows.isEmpty)
                  Text('none in this bucket',
                      style: mono.copyWith(fontSize: 12))
                else
                  LedgerTable(const [
                    LtCol('Symbol', right: false),
                    LtCol('LTP ₹'),
                    LtCol('Day'),
                    LtCol('Since', right: false),
                    LtCol('@ ₹'),
                    LtCol('Was', right: false),
                    LtCol('Move'),
                  ], [
                    for (final e in trendRows)
                      (
                        cells: [
                          '${e['symbol']}',
                          _rs(e['price']),
                          fmtPct((e['chg'] as num?)?.toDouble()),
                          dmy(e['since']),
                          _rs(e['since_price']),
                          '${e['prev'] ?? '—'}',
                          fmtPct((e['perf'] as num?)?.toDouble()),
                        ],
                        tone: ((e['perf'] as num?) ?? 0) >= 0 ? 1 : -1,
                        onTap: () => _openSymbol('${e['symbol']}'),
                      ),
                  ], initial: 12),
              ]),
        ),
      if (fno.isNotEmpty)
        (
          id: 'top',
          label: 'TOP',
          child: LedgerSection('Top',
              stamp: data.blobUpdated['fno'],
              footnote:
                  'NSE F&O universe · biggest moves and new 52-week highs / lows',
              children: [
                if (fno['hi52'] != null || fno['lo52'] != null)
                  _breadthRow('52W', (fno['hi52'] as num?) ?? 0,
                      (fno['lo52'] as num?) ?? 0,
                      main: 'new highs / lows'),
                for (final (key, label) in const [
                  ('gainers', 'TOP GAINERS'),
                  ('losers', 'TOP LOSERS')
                ])
                  if (_l(fno[key]).isNotEmpty) ...[
                    _groupLabel(label),
                    LedgerTable(const [
                      LtCol('Symbol', right: false),
                      LtCol('LTP ₹'),
                      LtCol('Change'),
                    ], [
                      for (final r in _l(fno[key]))
                        (
                          cells: [
                            '${r['symbol']}',
                            _rs(r['ltp']),
                            fmtPct((r['pct'] as num?)?.toDouble()),
                          ],
                          tone: 0,
                          onTap: () => _openSymbol('${r['symbol']}'),
                        ),
                    ]),
                  ],
              ]),
        ),
      if (fno.isNotEmpty || flows['pcr'] != null)
        (
          id: 'oi',
          label: 'OI TRENDS',
          child: LedgerSection('OI trends',
              stamp: data.blobUpdated['fno'],
              footnote:
                  'NIFTY options at the nearest expiry · OI = open interest, contracts · read = price × OI direction',
              children: [
                if (flows['pcr'] != null) ...[
                  _groupLabel('NIFTY OPTIONS'),
                  StatGrid([
                    StatTile('NIFTY PCR', '${flows['pcr']}',
                        color: (flows['pcr'] as num) >= 1 ? green : red,
                        sub: (flows['pcr'] as num) >= 1
                            ? 'puts lead'
                            : 'calls lead'),
                    StatTile('Expiry', dmy(flows['expiry'])),
                    StatTile('Spot', _n0(flows['underlying'])),
                    StatTile('Max OI strike', _n0(flows['max_oi_strike'])),
                    if (flows['ce_oi'] != null)
                      StatTile('Call OI', _n0(flows['ce_oi'])),
                    if (flows['pe_oi'] != null)
                      StatTile('Put OI', _n0(flows['pe_oi'])),
                  ]),
                  const SizedBox(height: 8),
                  ScaleBar((flows['pcr'] as num).toDouble(),
                      min: 0.5, max: 1.5, marks: const [(1.0, '1.0')]),
                  const SizedBox(height: 6),
                ],
                for (final (key, label) in const [
                  ('oi_gainers', 'OI BUILD-UP'),
                  ('oi_losers', 'OI UNWINDING')
                ])
                  if (_l(fno[key]).isNotEmpty) ...[
                    _groupLabel(label),
                    LedgerTable(const [
                      LtCol('Symbol', right: false),
                      LtCol('LTP ₹'),
                      LtCol('Price'),
                      LtCol('OI chg'),
                      LtCol('OI'),
                      LtCol('Δ OI'),
                      LtCol('Volume'),
                      LtCol('Read', right: false),
                    ], [
                      for (final r in _l(fno[key]))
                        _oiRow(r, key == 'oi_gainers'),
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
                  'NSE participant-wise F&O open interest · contracts · ${dmy(poiBlob['date'])} · net = index futures long − short',
              children: [
                LedgerTable(const [
                  LtCol('Participant', right: false),
                  LtCol('Net idx fut'),
                  LtCol('Δ d/d'),
                  LtCol('Fut long'),
                  LtCol('Fut short'),
                  LtCol('Call long'),
                  LtCol('Call short'),
                  LtCol('Put long'),
                  LtCol('Put short'),
                  LtCol('Total long'),
                  LtCol('Total short'),
                ], [
                  for (final who in const ['FII', 'DII', 'Pro', 'Client'])
                    if (poi[who] is Map)
                      _poiRow(who, (poi[who] as Map).cast<String, dynamic>()),
                ], toneCol: 1),
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
      (
        id: 'unlisted',
        label: 'UNLISTED',
        child: unlistedRows.isEmpty && _unlistedQ.isEmpty
            ? LedgerSection('Unlisted shares',
                footnote: 'pre-IPO names · fills after the first daily pull',
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text('No list yet — the pipeline pulls it once a day at 20:30 IST.',
                        style: mono.copyWith(fontSize: 12, height: 1.5, color: inkDim)),
                  ),
                ])
            : LedgerSection('Unlisted shares',
                stamp: data.blobUpdated['unlisted'],
                stampPrefix: 'UnlistedZone',
                footnote:
                    'indicative dealer prices, not exchange quotes · ₹ per share · tap a row for the UnlistedZone page · as of ${dmy(unlisted['asof'])}',
                children: [
                  const SizedBox(height: 8),
                  TextField(
                    onChanged: (v) => setState(() => _unlistedQ = v),
                    style: mono.copyWith(fontSize: 12),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'search ${unlisted['rows'] is List ? (unlisted['rows'] as List).length : ''} names…',
                      hintStyle: mono.copyWith(fontSize: 12, color: inkDim),
                      prefixIcon: const Icon(Icons.search, size: 16, color: inkDim),
                      enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: border)),
                      focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: green)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (unlistedRows.isEmpty)
                    Text('no match', style: mono.copyWith(fontSize: 12, color: inkDim))
                  else
                    LedgerTable(const [
                      LtCol('Company', right: false, text: true),
                      LtCol('LTP ₹'),
                      LtCol('Chg'),
                      LtCol('Sector', right: false, text: true),
                      LtCol('Lot'),
                    ], [
                      for (final r in unlistedRows)
                        (
                          cells: [
                            '${r['name']}',
                            _rs(r['price']),
                            fmtPct((r['chg_pct'] as num?)?.toDouble()),
                            '${r['sector'] ?? '—'}',
                            r['lot'] is num ? fmtNum((r['lot'] as num).toDouble(), decimals: 0) : '—',
                          ],
                          tone: r['chg_pct'] == null ? 0 : ((r['chg_pct'] as num) >= 0 ? 1 : -1),
                          onTap: r['link'] == null ? null : () => openExternal(context, '${r['link']}'),
                        ),
                    ], wrap: 150, toneCol: 2, initial: 25),
                ]),
      ),
      if (data.kind('crypto').isNotEmpty)
        (
          id: 'crypto',
          label: 'CRYPTO',
          child: LedgerSection('Crypto',
              action: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final usd in const [false, true])
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: filterPill(usd ? 'USD' : 'INR', _cryptoUsd == usd,
                          green, () => setState(() => _cryptoUsd = usd),
                          fontSize: 9),
                    ),
                ]),
              ),
              footnote: 'CoinGecko · 24h change and volume · stablecoin rows show the ₹ on-ramp price',
              children: [
                LedgerTable(const [
                  LtCol('Coin', right: false),
                  LtCol('Price'),
                  LtCol('24h chg'),
                  LtCol('24h vol'),
                  LtCol('Chg'),
                ], [
                  for (final t in data.kind('crypto'))
                    (
                      cells: [
                        t.name,
                        _cryptoPx(t, _cryptoUsd),
                        _cryptoAbs(t, _cryptoUsd),
                        _cryptoVol(t, _cryptoUsd),
                        fmtPct(t.changePct),
                      ],
                      tone: t.changePct == null ? 0 : (t.up ? 1 : -1),
                      onTap: null,
                    ),
                ], initial: 8),
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
      if (usAll.isNotEmpty || _usIndex != 'ALL')
        (
          id: 'movers',
          label: 'MARKET MOVERS',
          child: LedgerSection('Market movers',
              footnote:
                  'Dow 30 + Nasdaq heavyweights · trend = price vs 50 & 200-day averages · Yahoo · delayed',
              children: [
                const SizedBox(height: 8),
                pillRow([
                  for (final i in _usIdx)
                    filterPill(i, _usIndex == i, amber,
                        () => setState(() => _usIndex = i),
                        fontSize: 9),
                  for (final (key, label) in _usLists)
                    filterPill(label, _usList == key, green,
                        () => setState(() => _usList = key),
                        fontSize: 9),
                ]),
                const SizedBox(height: 10),
                if (usRows.isEmpty)
                  Text('none right now', style: mono.copyWith(fontSize: 12))
                else
                  LedgerTable(const [
                    LtCol('Company', right: false, text: true),
                    LtCol('Trend', right: false),
                    LtCol('Value \$'),
                    LtCol('Chg \$'),
                    LtCol('Chg'),
                  ], [
                    for (final t in usRows)
                      (
                        cells: [
                          t.name,
                          '${t.meta['trend'] ?? '—'}',
                          fmtNum(t.price, indian: false, decimals: 2),
                          t.prevClose == null
                              ? '—'
                              : '${t.price - t.prevClose! >= 0 ? '+' : '−'}${(t.price - t.prevClose!).abs().toStringAsFixed(2)}',
                          fmtPct(t.changePct),
                        ],
                        tone: t.changePct == null ? 0 : (t.up ? 1 : -1),
                        onTap: null,
                      ),
                  ], wrap: 140, initial: 15),
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
                          : 'resolves ${dmy(m['end'])}'),
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
      if (chokes.isNotEmpty || ports.isNotEmpty || freight.isNotEmpty)
        (
          id: 'shipping',
          label: 'SHIPPING',
          child: LedgerSection('Shipping',
              footnote:
                  'IMF PortWatch ~5d behind · SCFI/CCFI weekly, Shanghai Shipping Exchange',
              children: [
                if (freight.isNotEmpty) ...[
                  for (final f in freight)
                    LedgerRow(
                        lead: '${f['name'] ?? ''}',
                        main: 'Container freight',
                        trail: '${f['value'] ?? ''}',
                        trailColor: f['pct'] == null
                            ? null
                            : ((f['pct'] as num) >= 0 ? green : red),
                        sub: f['pct'] == null
                            ? dmy(f['date'])
                            : 'w/w ${(f['pct'] as num) >= 0 ? '+' : '−'}${(f['pct'] as num).abs()}% · ${dmy(f['date'])}'),
                ],
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
              stampPrefix: 'RBI',
              footnote:
                  'benchmark G-Secs · falling yield = green${rbi['asof'] == null ? '' : ' · RBI as of ${dmy(rbi['asof'])}'}',
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
                LedgerTable(const [
                  LtCol('Tenor', right: false),
                  LtCol('Yield'),
                  LtCol('Δ bp'),
                  LtCol('Prev'),
                  LtCol('Series', right: false),
                  LtCol('As of', right: false),
                ], [
                  for (final b in bonds)
                    (
                      cells: [
                        '${b['tenor'] ?? ''}',
                        '${fmtNum(((b['yield'] ?? 0) as num).toDouble())}%',
                        _sgn(b['chg_bp'], decimals: 1),
                        b['prev'] == null
                            ? '—'
                            : '${fmtNum((b['prev'] as num).toDouble())}%',
                        '${b['name'] ?? 'G-Sec'}',
                        dmy(b['date']),
                      ],
                      // Falling yield = rising bond prices, so down is green here.
                      tone: b['chg_bp'] == null
                          ? 0
                          : ((b['chg_bp'] as num) <= 0 ? 1 : -1),
                      onTap: null,
                    ),
                ], toneCol: 2),
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
                                '${key == 'XM' ? 'EU' : key} · ${dmy((cb[key] as Map)['asof'])}'),
                  ]),
                ],
              ]),
        ),
      if (ipos.isNotEmpty)
        (
          id: 'ipos',
          label: 'IPO',
          child: LedgerSection('IPO',
              stamp: data.blobUpdated['ipos'],
              footnote: 'NSE mainboard + SME · size = shares offered',
              children: [
                for (final (key, label) in const [
                  ('current', 'OPEN NOW'),
                  ('upcoming', 'UPCOMING')
                ])
                  if (_l(ipoBlob[key]).isNotEmpty) ...[
                    _groupLabel(label),
                    LedgerTable(const [
                      LtCol('Symbol', right: false),
                      LtCol('Company', right: false, text: true),
                      LtCol('Band ₹'),
                      LtCol('Opens', right: false),
                      LtCol('Closes', right: false),
                      LtCol('Size'),
                      LtCol('Status', right: false),
                    ], [
                      for (final i in _l(ipoBlob[key]))
                        (
                          cells: [
                            '${i['symbol'] ?? ''}',
                            '${i['company'] ?? ''}',
                            _band(i['band']),
                            dmy(i['open']),
                            dmy(i['close']),
                            _shares(i['size']),
                            '${i['status'] ?? ''}',
                          ],
                          tone: const {'open', 'active'}
                                  .contains('${i['status']}'.toLowerCase())
                              ? 1
                              : 0,
                          onTap: null,
                        ),
                    ]),
                  ],
              ]),
        ),
      if (macro.isNotEmpty || wb.isNotEmpty)
        (
          id: 'macro',
          label: 'MACRO',
          child: LedgerSection('Macro', children: [
            for (final t in macro) _MacroRow(t),
            // Annual frame from the World Bank: one row per series.
            if (wb.values.any((v) => v is Map && v['value'] != null)) ...[
              _groupLabel('ANNUAL · WORLD BANK'),
              LedgerTable(const [
                LtCol('Series', right: false),
                LtCol('Value'),
                LtCol('Year'),
                LtCol('Prior'),
                LtCol('Prior yr'),
                LtCol('Units', right: false),
              ], [
                for (final e in wb.entries)
                  if (e.value is Map && (e.value as Map)['value'] != null)
                    (
                      cells: [
                        '${(e.value as Map)['name'] ?? e.key}',
                        _wbv((e.value as Map)['value'],
                            (e.value as Map)['units']),
                        '${(e.value as Map)['year'] ?? ''}',
                        _wbv((e.value as Map)['prev'],
                            (e.value as Map)['units']),
                        '${(e.value as Map)['prev_year'] ?? ''}',
                        '${(e.value as Map)['units'] ?? ''}',
                      ],
                      tone: 0,
                      onTap: null,
                    ),
              ]),
            ],
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
                LedgerTable(const [
                  LtCol('Mag', right: false),
                  LtCol('Date', right: false),
                  LtCol('Time IST', right: false),
                  LtCol('Place', right: false, text: true),
                ], [
                  for (final q in quakes)
                    (
                      cells: [
                        'M${q['mag']}',
                        dmy(q['time']),
                        _hhmm(q['time']),
                        '${q['place'] ?? ''}',
                      ],
                      tone: ((q['mag'] as num?) ?? 0) >= 6 ? -1 : 0,
                      onTap: null,
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
              footnote: 'NSE board meetings and results dates',
              children: [
                LedgerTable(const [
                  LtCol('Symbol', right: false),
                  LtCol('Date', right: false),
                  LtCol('Company', right: false, text: true),
                  LtCol('Purpose', right: false, text: true),
                ], [
                  for (final r in results)
                    (
                      cells: [
                        r['symbol']?.toString() ?? '',
                        dmy(r['date']),
                        '${r['company'] ?? ''}',
                        '${r['purpose'] ?? ''}',
                      ],
                      tone: 0,
                      onTap: null,
                    ),
                ], initial: 12),
              ]),
        ),
      if (earnings.isNotEmpty)
        (
          id: 'earnings',
          label: 'EARNINGS',
          child: LedgerSection('Earnings ahead',
              stamp: data.blobUpdated['earnings_calendar'],
              footnote: 'next 14 days, every NSE stock · Stock Analysis (S&P Global)',
              children: [
                LedgerTable(const [
                  LtCol('Symbol', right: false),
                  LtCol('Date', right: false),
                  LtCol('Company', right: false, text: true),
                ], [
                  for (final r in earnings)
                    (
                      cells: [
                        r['symbol']?.toString() ?? '',
                        dmy(r['date']),
                        '${r['name'] ?? ''}',
                      ],
                      tone: 0,
                      onTap: null,
                    ),
                ], initial: 12),
              ]),
        ),
      if (records.isNotEmpty)
        (
          id: 'records',
          label: 'RECORDS',
          child: LedgerSection('Records',
              stamp: data.blobUpdated['records'],
              footnote: 'NSE stocks at or near their all-time high · Stock Analysis '
                  '(S&P Global) · as of ${dmy(records['asof'])}',
              children: [
                Text(
                    '${records['near_ath_pct'] ?? '—'}% within 5% of all-time high · '
                    '${records['up_1y_pct'] ?? '—'}% up over 1 year',
                    style: mono.copyWith(fontSize: 12)),
                const SizedBox(height: 8),
                LedgerTable(const [
                  LtCol('At all-time high', right: false),
                ], [
                  for (final s in (records['ath'] as List?) ?? const [])
                    (cells: ['$s'], tone: 1, onTap: null),
                ], initial: 10),
              ]),
        ),
      if (deals.isNotEmpty)
        (
          id: 'deals',
          label: 'DEALS',
          child: LedgerSection('Deals',
              stamp: data.blobUpdated['bulk_deals'],
              footnote:
                  'NSE bulk (>0.5% of equity in a day) and block (negotiated window) deals · value in ₹',
              children: [
                LedgerTable(const [
                  LtCol('Symbol', right: false),
                  LtCol('Side', right: false),
                  LtCol('Qty'),
                  LtCol('Price ₹'),
                  LtCol('Value'),
                  LtCol('Type', right: false),
                  LtCol('Client', right: false, text: true),
                  LtCol('Company', right: false, text: true),
                  LtCol('Date', right: false),
                ], [
                  for (final d in deals)
                    (
                      cells: [
                        d['symbol']?.toString() ?? '',
                        '${d['side'] ?? ''}',
                        _n0(d['qty']),
                        fmtNum(((d['price'] ?? 0) as num).toDouble()),
                        '₹${_crore(d['value'])}',
                        '${d['type'] ?? ''}',
                        '${d['client'] ?? ''}',
                        '${d['name'] ?? ''}',
                        dmy(d['date']),
                      ],
                      tone: d['side'] == 'BUY' ? 1 : -1,
                      onTap: null,
                    ),
                ], toneCol: 1, initial: 12),
              ]),
        ),
      if (insider.isNotEmpty)
        (
          id: 'insider',
          label: 'INSIDER',
          child: LedgerSection('Insider',
              stamp: data.blobUpdated['insider_trades'],
              footnote:
                  'NSE insider-trading disclosures (SEBI PIT), last 7 days · value in ₹',
              children: [
                LedgerTable(const [
                  LtCol('Symbol', right: false),
                  LtCol('Side', right: false),
                  LtCol('Qty'),
                  LtCol('Value ₹'),
                  LtCol('Person', right: false, text: true),
                  LtCol('Category', right: false),
                  LtCol('Mode', right: false),
                  LtCol('Company', right: false, text: true),
                  LtCol('Traded', right: false),
                  LtCol('Intimated', right: false),
                ], [
                  for (final i in insider)
                    (
                      cells: [
                        i['symbol']?.toString() ?? '',
                        '${i['side'] ?? ''}'.toUpperCase(),
                        _n0(i['qty']),
                        _money(i['value']),
                        '${i['person'] ?? ''}',
                        '${i['category'] ?? ''}',
                        '${i['mode'] ?? ''}',
                        '${i['company'] ?? ''}',
                        dmy(i['date']),
                        i['intimated'] == null ? '—' : dmy(i['intimated']),
                      ],
                      tone:
                          '${i['side']}'.toLowerCase().startsWith('b') ? 1 : -1,
                      onTap: null,
                    ),
                ], toneCol: 1, initial: 12),
              ]),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final all = _sections();
    int rank(_Sec s) {
      final i = _order.indexOf(s.id);
      return i < 0 ? _order.length : i;
    }

    final pinned = [
      for (final s in all)
        if (_pinned.contains(s.id)) s
    ];
    final regional = [
      for (final s in all)
        if (!_pinned.contains(s.id) &&
            (_regionOf[s.id] ?? 'INDIA') == _region)
          s
    ]..sort((a, b) => rank(a) - rank(b));
    final secs = [...pinned, ...regional];
    _tracker.ids = [for (final s in secs) s.id];
    final regionRow = Padding(
      key: const Key('marketsRegions'),
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final r in regions)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: filterPill(
                  r, _region == r, green, () => setState(() => _region = r),
                  fontSize: 10),
            ),
        ]),
      ),
    );
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
          for (final s in pinned)
            KeyedSubtree(key: _tracker.key(s.id), child: s.child),
          regionRow,
          const HintBar('markets_hints_v1', [
            ('INDIA · MF · … · US', 'pick a market; sessions and sectors stay on top'),
            ('TRENDS', 'bullish / bearish by the 50 & 200-day stack; turning = flipped this week'),
            ('any table row', 'tap to open the stock'),
            ('chips up top', 'jump to a section'),
          ]),
          for (final s in regional)
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

/// A number whether the blob sent it as a number or an NSE string ("7,500").
double? _numOf(Object? v) => v is num
    ? v.toDouble()
    : v == null
        ? null
        : double.tryParse('$v'.replaceAll(',', '').trim());

String _rs(Object? v) => _numOf(v) == null ? '—' : '₹${fmtNum(_numOf(v)!)}';

/// Crypto cells in the picked quote currency. USD comes from meta.usd (same
/// CoinGecko call); the USD/INR rate implied by the two prices converts the
/// ₹ volume and the ₹ 24h move.
double? _usdInr(Tick t) {
  final usd = (t.meta['usd'] as num?)?.toDouble();
  return usd == null || usd == 0 ? null : t.price / usd;
}

String _cryptoPx(Tick t, bool usd) {
  if (!usd) return '₹${fmtNum(t.price)}';
  final u = (t.meta['usd'] as num?)?.toDouble();
  return u == null ? '—' : '\$${fmtNum(u, indian: false)}';
}

String _cryptoAbs(Tick t, bool usd) {
  final prev = t.prevClose;
  if (prev == null) return '—';
  var d = t.price - prev;
  final rate = _usdInr(t);
  if (usd) {
    if (rate == null) return '—';
    d /= rate;
  }
  final s = fmtNum(d.abs(), indian: !usd);
  return '${d >= 0 ? '+' : '−'}$s';
}

/// ₹4,00,565 Cr / \$47.5B — volumes are too long for grouped digits.
String _cryptoVol(Tick t, bool usd) {
  var v = (t.meta['vol_24h'] as num?)?.toDouble();
  if (v == null) return '—';
  if (usd) {
    final rate = _usdInr(t);
    if (rate == null) return '—';
    v /= rate;
    return v >= 1e9
        ? '\$${(v / 1e9).toStringAsFixed(1)}B'
        : '\$${(v / 1e6).toStringAsFixed(0)}M';
  }
  return '₹${fmtNum(v / 1e7, decimals: 0)} Cr';
}

String _n0(Object? v) =>
    _numOf(v) == null ? '—' : fmtNum(_numOf(v)!, decimals: 0);

String _money(Object? v) => _numOf(v) == null ? '—' : '₹${_crore(_numOf(v))}';

/// Signed with the typographic minus the tables colour by.
String _sgn(Object? v, {int decimals = 2, String unit = ''}) {
  final n = _numOf(v);
  if (n == null) return '—';
  return '${n >= 0 ? '+' : '−'}${fmtNum(n.abs(), decimals: decimals)}$unit';
}

String _wbv(Object? v, Object? units) => _numOf(v) == null
    ? '—'
    : '${fmtNum(_numOf(v)!, decimals: 2)}${units == '%' ? '%' : ''}';

/// "Rs.40 to Rs.43" (NSE) -> "40–43".
String _band(Object? v) => v == null
    ? '—'
    : '$v'
        .replaceAll(RegExp(r'Rs\.?\s*'), '')
        .replaceAll(RegExp(r'\s+to\s+'), '–');

/// NSE issue size is a share count string ("37636363") -> "3.76 Cr sh";
/// anything non-numeric ("1,200 Cr") is shown as sent.
String _shares(Object? v) {
  final n = _numOf(v);
  if (v == null) return '—';
  if (n == null) return '$v';
  if (n >= 1e7) return '${(n / 1e7).toStringAsFixed(2)} Cr sh';
  if (n >= 1e5) return '${(n / 1e5).toStringAsFixed(1)} L sh';
  return '${fmtNum(n, decimals: 0)} sh';
}

/// Calendar distance: "today" / "tomorrow" / "12 d" / "3 d ago".
String _daysAway(Object? d) {
  final t = parseDate(d);
  if (t == null) return '';
  final now = DateTime.now();
  final n = DateTime(t.year, t.month, t.day)
      .difference(DateTime(now.year, now.month, now.day))
      .inDays;
  return n == 0
      ? 'today'
      : n == 1
          ? 'tomorrow'
          : n < 0
              ? '${-n} d ago'
              : '$n d';
}

/// IST clock of a timestamp; empty when the value carries no time.
String _hhmm(Object? at) {
  final t = parseDate(at);
  return t == null || !'$at'.contains(':') ? '' : hhmmIst(t);
}

String _when(Object? at) {
  final t = parseDate(at);
  if (t == null) return '';
  final hh = _hhmm(at);
  return hh.isEmpty ? dmy(at) : '${dmy(at)} $hh';
}

/// One OI-spurt row: price × OI direction is the F&O desk's read; older
/// blobs without `read` fall back to the OI direction alone.
LtRow _oiRow(Map<String, dynamic> r, bool gainer) {
  final pct = (r['pct'] as num?)?.toDouble();
  final read = '${r['read'] ?? (gainer ? 'OI up' : 'OI down')}';
  final bullish = read == 'long build-up' || read == 'short covering';
  final bearish = read == 'short build-up' || read == 'long unwinding';
  return (
    cells: [
      '${r['symbol']}',
      _rs(r['ltp']),
      pct == null ? '—' : fmtPct(pct),
      _sgn(r['oi_pct'], decimals: 1, unit: '%'),
      _n0(r['oi']),
      _sgn(r['oi_chg'], decimals: 0),
      _n0(r['volume']),
      read,
    ],
    tone: bullish
        ? 1
        : bearish
            ? -1
            : 0,
    onTap: null,
  );
}

/// One participant's F&O book, day-over-day on the index-futures net.
LtRow _poiRow(String who, Map<String, dynamic> r) {
  final net = ((r['net_fut_idx'] ?? 0) as num).toDouble();
  final prev = (r['prev_net_fut_idx'] as num?)?.toDouble();
  return (
    cells: [
      who,
      _sgn(net, decimals: 0),
      prev == null ? '—' : _sgn(net - prev, decimals: 0),
      _n0(r['fut_idx_long']),
      _n0(r['fut_idx_short']),
      _n0(r['opt_idx_call_long']),
      _n0(r['opt_idx_call_short']),
      _n0(r['opt_idx_put_long']),
      _n0(r['opt_idx_put_short']),
      _n0(r['total_long']),
      _n0(r['total_short']),
    ],
    tone: net >= 0 ? 1 : -1,
    onTap: null,
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
  // fear&greed v2 (pipeline FG_VERSION 2)
  'pcr': 'Put/call ratio',
  'fii_pos': 'FII index futures',
  'nifty_gold': 'NIFTY vs gold',
};

/// Cross-asset correlation heat grid from the `correlation` blob: labelled
/// rows × columns of Pearson r over ~1 month of daily returns.
Widget _corrGrid(Map<String, dynamic> corr) {
  final names = (corr['assets'] as List?)?.cast<String>() ?? const [];
  final matrix = (corr['matrix'] as List?) ?? const [];
  if (names.length < 2 || matrix.length != names.length) {
    return const SizedBox.shrink();
  }
  return Column(children: [
    const SizedBox(height: 6),
    Row(children: [
      const SizedBox(width: 56),
      for (final n in names) ...[
        const SizedBox(width: 6),
        Expanded(
            child: Text(n,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(fontSize: 9))),
      ],
    ]),
    const SizedBox(height: 6),
    for (var i = 0; i < names.length; i++) ...[
      Row(children: [
        SizedBox(
            width: 56,
            child: Text(names[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(fontSize: 10))),
        for (var j = 0; j < names.length; j++) ...[
          const SizedBox(width: 6),
          Expanded(child: Builder(builder: (_) {
            final r = ((matrix[i] as List?)?[j] as num?)?.toDouble();
            return HeatCell('', r,
                scale: 1,
                height: 28,
                pctText: r == null ? '—' : r.toStringAsFixed(2));
          })),
        ],
      ]),
      const SizedBox(height: 6),
    ],
  ]);
}

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
