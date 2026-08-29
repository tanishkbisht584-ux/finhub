import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../theme.dart';
import '../ticks.dart';
import 'feed.dart' show homeTab, marketsTab, filterPill;
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
        for (final r in ((blobs['bulk_deals'] as Map?)?['deals'] as List? ?? const []))
          Map<String, dynamic>.from(r as Map)
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
      .inFilter('kind', ['index', 'fx', 'crypto', 'commodity', 'mf', 'macro']).order('symbol');
  final all = [
    for (final r in rows) Tick.fromJson(Map<String, dynamic>.from(r))
  ];
  var blobs = <String, dynamic>{};
  var blobUpdated = <String, DateTime>{};
  try {
    final bs = await sb.from('market_blobs').select('key,payload,updated_at');
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
  return MarketsData(
      ticks: all,
      watchlist: watch,
      followedMf: followedMf,
      blobs: blobs,
      blobUpdated: blobUpdated);
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
          onRefresh: () => ref.refresh(marketsProvider.future),
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
  final _keys = <String, GlobalKey>{};
  final _active = ValueNotifier<String>('');
  List<String> _ids = const [];
  bool _jumping = false;
  GlobalKey _key(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  @override
  void dispose() {
    _active.dispose();
    super.dispose();
  }

  /// Which section owns the viewport: the last one whose header has scrolled
  /// to within 80px of the top. At the very bottom the last section wins even
  /// if it never reaches the top.
  bool _track(ScrollUpdateNotification n) {
    if (_jumping || n.metrics.axis != Axis.vertical) return false;
    final viewport = n.context?.findRenderObject() as RenderBox?;
    if (viewport == null) return false;
    final threshold = viewport.localToGlobal(Offset.zero).dy + 80;
    String? current;
    for (final id in _ids) {
      final box = _keys[id]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      if (box.localToGlobal(Offset.zero).dy <= threshold) {
        current = id;
      } else {
        break;
      }
    }
    if (n.metrics.pixels >= n.metrics.maxScrollExtent - 4 && _ids.isNotEmpty) {
      current = _ids.last;
    }
    if (current != null && current != _active.value) _active.value = current;
    return false;
  }

  Future<void> _jump(String id) async {
    _active.value = id;
    final ctx = _keys[id]?.currentContext;
    if (ctx == null) return;
    _jumping = true; // don't let en-route sections flicker the ribbon
    await Scrollable.ensureVisible(ctx,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    _jumping = false;
  }

  List<_Sec> _sections() {
    final data = widget.data;
    final onFollowMf = widget.onFollowMf;
    final onAddMf = widget.onAddMf;
    final indices = data.kind('index');
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
    final sectors = [
      for (final s in data.list('nse_indices'))
        if (s['group'] == 'SECTORAL INDICES') s
    ];
    final flows =
        (data.blobs['flows'] as Map?)?.cast<String, dynamic>() ?? const {};
    return [
      if (sectors.isNotEmpty)
        (
          id: 'sectors',
          label: 'SECTORS',
          child: _Section('Sectors', [
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.55,
                children: [for (final s in sectors) _HeatTile(s)],
              ),
            ),
          ], stamp: data.blobUpdated['nse_indices']),
        ),
      (
        id: 'watch',
        label: 'WATCHLIST',
        child: _Section('Watchlist', [
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
                for (final c in watch) _CompanyRow(c, m[c.nseSymbol]),
              ]),
            ),
        ]),
      ),
      if (indices.isNotEmpty)
        (
          id: 'indices',
          label: 'INDICES',
          child: _Section('Indices', [
            for (final t in indices) _TickRow(t, spark: true),
          ]),
        ),
      if (flows.isNotEmpty)
        (
          id: 'flows',
          label: 'FLOWS',
          child: _Section('Flows', [
            for (final side in ['fii', 'dii'])
              if (flows[side] is Map)
                _flowRow(side.toUpperCase(),
                    (flows[side] as Map).cast<String, dynamic>(),
                    flows['date']?.toString()),
            if (flows['pcr'] != null)
              _LineRow(
                  lead: 'NIFTY',
                  main: 'options · exp ${flows['expiry'] ?? ''}',
                  trail: 'PCR ${flows['pcr']}',
                  trailColor:
                      (flows['pcr'] as num) >= 1 ? green : red,
                  sub:
                      'max OI at ${fmtNum(((flows['max_oi_strike'] ?? 0) as num).toDouble(), decimals: 0)} · spot ${fmtNum(((flows['underlying'] ?? 0) as num).toDouble(), decimals: 0)}'),
            if (flows['breadth'] is Map)
              for (final e in (flows['breadth'] as Map).entries)
                _LineRow(
                    lead: e.key.toString().replaceFirst('NIFTY ', 'N'),
                    main: 'advance / decline',
                    trail: '${e.value['adv']}↑ ${e.value['dec']}↓',
                    trailColor: ((e.value['adv'] as num?) ?? 0) >=
                            ((e.value['dec'] as num?) ?? 0)
                        ? green
                        : red),
          ], stamp: data.blobUpdated['flows']),
        ),
      if (data.kind('fx').isNotEmpty)
        (
          id: 'fx',
          label: 'FX',
          child: _Section('FX', [
            for (final t in data.kind('fx')) _TickRow(t, spark: true),
          ]),
        ),
      if (data.kind('crypto').isNotEmpty)
        (
          id: 'crypto',
          label: 'CRYPTO',
          child: _Section('Crypto', [
            for (final t in data.kind('crypto')) _TickRow(t),
          ]),
        ),
      if (data.kind('commodity').isNotEmpty)
        (
          id: 'commodities',
          label: 'COMMODITIES',
          child: _Section('Commodities', [
            for (final t in data.kind('commodity'))
              _TickRow(t, spark: t.closes.length > 1),
          ]),
        ),
      if (mf.isNotEmpty || onAddMf != null)
        (
          id: 'mf',
          label: 'MF',
          child: _Section('MF', [
            for (final t in mf)
              _MfRow(t, data.followedMf.contains(t.meta['scheme_code']),
                  onFollowMf),
          ], action: onAddMf == null
              ? null
              : TextButton(
                  onPressed: onAddMf,
                  child: Text('+ Add fund',
                      style: mono.copyWith(fontSize: 12, color: green)))),
        ),
      if (macro.isNotEmpty)
        (
          id: 'macro',
          label: 'MACRO',
          child: _Section('Macro', [
            for (final t in macro) _MacroRow(t),
          ]),
        ),
      if (results.isNotEmpty)
        (
          id: 'results',
          label: 'RESULTS',
          child: _Section('Results', [
            _Collapsible([
              for (final r in results) _LineRow(
                  lead: r['symbol']?.toString() ?? '',
                  main: r['company']?.toString() ?? '',
                  trail: _dmy(r['date']),
                  sub: r['purpose']?.toString())
            ]),
          ], stamp: data.blobUpdated['results_calendar']),
        ),
      if (deals.isNotEmpty)
        (
          id: 'deals',
          label: 'DEALS',
          child: _Section('Deals', [
            _Collapsible([
              for (final d in deals)
                _LineRow(
                    lead: d['symbol']?.toString() ?? '',
                    main: d['client']?.toString() ?? '',
                    trail: '${d['side']} ₹${_crore(d['value'])}',
                    trailColor: d['side'] == 'BUY' ? green : red,
                    sub:
                        '${d['type']} · ${fmtNum((d['qty'] as num).toDouble(), decimals: 0)} @ ₹${fmtNum((d['price'] as num).toDouble())} · ${d['date'] ?? ''}')
            ]),
          ], stamp: data.blobUpdated['bulk_deals']),
        ),
      if (insider.isNotEmpty)
        (
          id: 'insider',
          label: 'INSIDER',
          child: _Section('Insider', [
            _Collapsible([
              for (final i in insider)
                _LineRow(
                    lead: i['symbol']?.toString() ?? '',
                    main: i['person']?.toString() ?? '',
                    trail: '${i['side'] ?? ''} ${i['qty'] ?? ''}',
                    trailColor: '${i['side']}'.toLowerCase().startsWith('b')
                        ? green
                        : red,
                    sub: '${i['category'] ?? ''} · ${i['mode'] ?? ''} · ${i['date'] ?? ''}')
            ]),
          ], stamp: data.blobUpdated['insider_trades']),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final secs = _sections();
    _ids = [for (final s in secs) s.id];
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
          for (final s in secs) KeyedSubtree(key: _key(s.id), child: s.child),
          const SizedBox(height: 20),
          Text(
              [
                if (data.updatedAt != null)
                  'as of ${_hhmmIst(data.updatedAt!)} IST',
                if (stale) 'stale — pipeline has not refreshed',
                'Yahoo Finance · CoinGecko · mfapi.in · NSE · delayed',
              ].join(' · '),
              style: mono.copyWith(fontSize: 10, color: stale ? amber : inkDim)),
        ],
      ),
    );
    if (secs.length < 2) return scroll;
    return Column(children: [
      _Ribbon([for (final s in secs) (id: s.id, label: s.label)], _active, _jump),
      Expanded(
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: _track,
          child: scroll,
        ),
      ),
    ]);
  }
}

/// The sticky nav under the AppBar: one chip per section, the active one
/// tracks the scroll, tap jumps, the magnifier filters chips by heading.
class _Ribbon extends StatefulWidget {
  const _Ribbon(this.sections, this.active, this.onJump);
  final List<({String id, String label})> sections;
  final ValueNotifier<String> active;
  final void Function(String id) onJump;

  @override
  State<_Ribbon> createState() => _RibbonState();
}

class _RibbonState extends State<_Ribbon> {
  bool _searching = false;
  String _q = '';
  final _chipKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    widget.active.addListener(_follow);
  }

  @override
  void dispose() {
    widget.active.removeListener(_follow);
    super.dispose();
  }

  /// Keep the active chip in view as the page scrolls underneath.
  void _follow() {
    if (!mounted) return;
    setState(() {});
    final ctx = _chipKeys[widget.active.value]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final match = [
      for (final s in widget.sections)
        if (q.isEmpty || s.label.toLowerCase().contains(q)) s
    ];
    // Before any scroll, the first section is the active one.
    final activeId = widget.sections.any((s) => s.id == widget.active.value)
        ? widget.active.value
        : widget.sections.first.id;
    return Container(
      decoration: const BoxDecoration(
          color: bg, border: Border(bottom: BorderSide(color: border))),
      padding: const EdgeInsets.fromLTRB(12, 6, 0, 6),
      child: Row(children: [
        InkWell(
          onTap: () => setState(() {
            _searching = !_searching;
            _q = '';
          }),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(_searching ? Icons.close : Icons.search,
                size: 18, color: inkDim),
          ),
        ),
        if (_searching)
          SizedBox(
            width: 120,
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _q = v),
              style: mono.copyWith(fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'jump to…',
                hintStyle: mono.copyWith(fontSize: 12, color: inkDim),
                enabledBorder:
                    const UnderlineInputBorder(borderSide: BorderSide(color: border)),
                focusedBorder:
                    const UnderlineInputBorder(borderSide: BorderSide(color: green)),
              ),
            ),
          ),
        const SizedBox(width: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(right: 12),
            child: Row(children: [
              for (final s in match)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: KeyedSubtree(
                    key: _chipKeys.putIfAbsent(s.id, GlobalKey.new),
                    child: filterPill(s.label, s.id == activeId, green, () {
                      widget.onJump(s.id);
                      setState(() {
                        _searching = false;
                        _q = '';
                      });
                    }),
                  ),
                ),
            ]),
          ),
        ),
      ]),
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

String _dmy(Object? iso) {
  final d = DateTime.tryParse('$iso');
  if (d == null) return '$iso';
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${m[d.month - 1]}';
}

/// ₹ value -> "24.7 Cr" / "85 L" — deal sizes read in crores here, nowhere else.
String _crore(Object? v) {
  final n = (v as num?)?.toDouble() ?? 0;
  if (n >= 1e7) return '${(n / 1e7).toStringAsFixed(n >= 1e9 ? 0 : 1)} Cr';
  if (n >= 1e5) return '${(n / 1e5).toStringAsFixed(0)} L';
  return fmtNum(n, decimals: 0);
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children, {this.action, this.stamp});
  final String title;
  final List<Widget> children;
  final Widget? action;
  final DateTime? stamp;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 22),
          Row(children: [
            Expanded(child: Text(title.toUpperCase(), style: monoLabel)),
            if (stamp != null)
              Text('NSE · ${_hhmmIst(stamp!)}', style: mono.copyWith(fontSize: 10)),
            if (action != null) action!,
          ]),
          const SizedBox(height: 6),
          const Divider(height: 1),
          ...children,
        ],
      );
}

/// Long lists start at 6 rows; "show all N" expands in place.
class _Collapsible extends StatefulWidget {
  const _Collapsible(this.rows);
  final List<Widget> rows;

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final rows = _all ? widget.rows : widget.rows.take(6).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ...rows,
      if (!_all && widget.rows.length > 6)
        TextButton(
            onPressed: () => setState(() => _all = true),
            child: Text('show all ${widget.rows.length}',
                style: mono.copyWith(fontSize: 12, color: green))),
    ]);
  }
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
          SizedBox(width: 64, height: 22, child: Sparkline(t.closes, color)),
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
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('₹${fmtNum(t.price, decimals: 2)}',
              style: mono.copyWith(fontSize: 13, color: ink)),
          Text(fmtPct(t.changePct),
              style: mono.copyWith(fontSize: 11, color: color)),
        ]),
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
    String val(double v) =>
        units == '%' ? '${v.toStringAsFixed(2)}%' : fmtNum(v, indian: units == 'INR');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: border))),
      child: Row(children: [
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
              width: 64,
              height: 22,
              child: Sparkline(t.closes,
                  delta == null ? inkDim : (delta >= 0 ? green : red))),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(val(t.price), style: mono.copyWith(fontSize: 14, color: ink)),
          if (delta != null)
            Text('${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(2)}',
                style: mono.copyWith(
                    fontSize: 11, color: delta >= 0 ? green : red)),
        ]),
      ]),
    );
  }
}

/// FII/DII cash-market line: net first, buy/sell underneath. Values are ₹ Cr.
Widget _flowRow(String who, Map<String, dynamic> d, String? date) {
  final net = (d['net'] as num?)?.toDouble() ?? 0;
  return _LineRow(
      lead: who,
      main: 'cash market${date == null ? '' : ' · $date'}',
      trail: '${net >= 0 ? '+' : '−'}₹${fmtNum(net.abs(), decimals: 0)} Cr',
      trailColor: net >= 0 ? green : red,
      sub:
          'buy ₹${fmtNum(((d['buy'] ?? 0) as num).toDouble(), decimals: 0)} Cr · sell ₹${fmtNum(((d['sell'] ?? 0) as num).toDouble(), decimals: 0)} Cr');
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

/// Sector heatmap tile: tinted by today's %, tap for the full NSE row.
class _HeatTile extends StatelessWidget {
  const _HeatTile(this.s);
  final Map<String, dynamic> s;

  @override
  Widget build(BuildContext context) {
    final pct = (s['pct'] as num?)?.toDouble();
    final c = pct == null ? inkDim : (pct >= 0 ? green : red);
    final last = (s['last'] as num?)?.toDouble();
    return InkWell(
      onTap: () => _showSectorSheet(context, s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
            color: c.withValues(alpha: (pct?.abs() ?? 0).clamp(0.4, 2.5) / 10),
            border: Border.all(color: c.withValues(alpha: 0.45))),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_sectorName(s),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(fontSize: 10, color: ink)),
              Text(fmtPct(pct), style: mono.copyWith(fontSize: 13, color: c)),
              if (last != null)
                Text(fmtNum(last, decimals: 0),
                    style: mono.copyWith(fontSize: 9)),
            ]),
      ),
    );
  }
}

/// Everything NSE gives us for one sectoral index — the tile shows two fields,
/// this sheet shows the rest. Values arrive as num or string; parse leniently.
void _showSectorSheet(BuildContext context, Map<String, dynamic> s) {
  double? n(Object? v) => v == null ? null : double.tryParse('$v');
  Color pctColor(double? v) => v == null ? inkDim : (v >= 0 ? green : red);
  final pct = n(s['pct']);
  final d30 = n(s['pct_30d']);
  final y1 = n(s['pct_1y']);
  final adv = n(s['advances']);
  final dec = n(s['declines']);
  final hi = n(s['year_high']);
  final lo = n(s['year_low']);
  final pe = n(s['pe']);
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: surface,
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${s['index'] ?? ''}'.toUpperCase(), style: monoLabel),
            const SizedBox(height: 6),
            const Divider(height: 1),
            _LineRow(
                lead: 'TODAY',
                main: n(s['last']) == null
                    ? 'change'
                    : 'level ${fmtNum(n(s['last'])!, decimals: 0)}',
                trail: fmtPct(pct),
                trailColor: pctColor(pct)),
            if (pe != null)
              _LineRow(lead: 'P/E', main: 'valuation', trail: fmtNum(pe)),
            if (adv != null && dec != null)
              _LineRow(
                  lead: 'BREADTH',
                  main: 'advance / decline',
                  trail: '${adv.toInt()}↑ ${dec.toInt()}↓',
                  trailColor: adv >= dec ? green : red),
            if (d30 != null)
              _LineRow(
                  lead: '30D',
                  main: 'one month',
                  trail: fmtPct(d30),
                  trailColor: pctColor(d30)),
            if (y1 != null)
              _LineRow(
                  lead: '1Y',
                  main: 'one year',
                  trail: fmtPct(y1),
                  trailColor: pctColor(y1)),
            if (hi != null && lo != null)
              _LineRow(
                  lead: '52W',
                  main: 'high / low',
                  trail:
                      '${fmtNum(hi, decimals: 0)} / ${fmtNum(lo, decimals: 0)}'),
          ]),
    ),
  );
}

/// Lead (symbol) · main text · trailing value, with a sub-line. Used for the
/// three NSE lists so they all read the same.
class _LineRow extends StatelessWidget {
  const _LineRow(
      {required this.lead,
      required this.main,
      required this.trail,
      this.trailColor,
      this.sub});
  final String lead, main, trail;
  final Color? trailColor;
  final String? sub;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: border))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 86,
              child: Text(lead,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(fontSize: 12, color: ink))),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(main,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: serif.copyWith(fontSize: 13)),
                  if (sub != null && sub!.isNotEmpty)
                    Text(sub!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: mono.copyWith(fontSize: 10)),
                ]),
          ),
          const SizedBox(width: 8),
          Text(trail,
              style: mono.copyWith(fontSize: 12, color: trailColor ?? ink)),
        ]),
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
          .get(Uri.parse('https://api.mfapi.in/mf/search?q=${Uri.encodeQueryComponent(q.trim())}'))
          .timeout(const Duration(seconds: 10));
      final all = (jsonDecode(r.body) as List).cast<Map>();
      // Direct-Growth only: the Regular/IDCW variants of one fund are noise here.
      final hits = [
        for (final h in all)
          if (RegExp(r'direct', caseSensitive: false).hasMatch('${h['schemeName']}') &&
              RegExp(r'growth', caseSensitive: false).hasMatch('${h['schemeName']}') &&
              !RegExp(r'idcw|dividend', caseSensitive: false).hasMatch('${h['schemeName']}'))
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
                  ? Padding(padding: const EdgeInsets.all(12), child: appSpinner())
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
                  onTap: () => Navigator.of(context).pop(h['schemeCode'] as int),
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
