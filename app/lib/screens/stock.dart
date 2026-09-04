import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../analysis.dart';
import '../charts.dart';
import '../follows.dart';
import '../fundamentals.dart';
import '../ledger.dart';
import '../models.dart';
import '../remote_config.dart';
import '../section_ribbon.dart';
import '../theme.dart';
import '../ticks.dart';
import 'feed.dart' show filterPill;
import 'stock_sections.dart';
import 'story_detail.dart';

// Sparkline lived here before charts.dart; tests and markets.dart still find it.
export '../charts.dart' show Sparkline;

/// Spec §8 screen 4: delayed price + light line chart + 52-wk range + related
/// story cards. "Nothing more, by design."
class StockScreen extends StatefulWidget {
  const StockScreen({super.key, required this.company});
  final Company company;

  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  Quote? _quote;
  bool _quoteFailed = false;
  List<Story> _stories = const [];
  bool _storiesFailed = false;
  bool _following = false;
  bool _togglingFollow = false;
  List<String> _events = const []; // NSE results/deals/insider lines (market_blobs)
  Timer? _analysisPoll;
  int _analysisPolls = 0;
  FundamentalsData _fund = FundamentalsData.fromRows(const []);
  Timer? _fundPoll;
  int _fundPolls = 0;
  List<Map<String, dynamic>> _peers = const [];
  String _range = '1M';
  List<double> _chartCloses = const [];
  List<DateTime> _chartTimes = const [];
  bool _showPe = false;
  bool _heat = false; // statement tables: tint cells by change vs prior period
  final _tracker = SectionTracker();

  // Yahoo chart range/interval per pill; the 1M fetch doubles as the quote.
  // 3Y has no Yahoo range value — it fetches 5y and trims client-side.
  static const _ranges = {'1M': ('1mo', '1d'), '6M': ('6mo', '1d'),
                          '1Y': ('1y', '1d'), '3Y': ('5y', '1wk'),
                          '5Y': ('5y', '1wk'), '10Y': ('10y', '1mo'),
                          'MAX': ('max', '1mo')};

  @override
  void initState() {
    super.initState();
    _load();
    _loadFundamentals();
  }

  @override
  void dispose() {
    _analysisPoll?.cancel();
    _fundPoll?.cancel();
    _tracker.dispose();
    super.dispose();
  }

  /// Statement history from the `fundamentals` table. Empty -> ask the
  /// pipeline (same analysis_requests door as meta.f/t) and poll it in, the
  /// exact rhythm of _maybeRequestAnalysis.
  void _loadFundamentals() {
    if (!remoteConfig.screenerPageEnabled) return;
    final sym = widget.company.nseSymbol;
    if (sym.isEmpty) return;
    loadFundamentals(sym).then((d) {
      if (!mounted) return;
      setState(() => _fund = d);
      if (d.summary.isNotEmpty) return;
      final sb = Supabase.instance.client;
      if (sb.auth.currentUser != null) {
        sb.from('analysis_requests').insert({'symbol': sym}).then((_) {}, onError: (_) {});
      }
      _fundPoll ??= Timer.periodic(const Duration(seconds: 75), (t) {
        if (!mounted || ++_fundPolls > 5 || _fund.summary.isNotEmpty) {
          t.cancel();
          return;
        }
        loadFundamentals(sym).then((d) {
          if (mounted && !d.isEmpty) setState(() => _fund = d);
        });
      });
    });
  }

  /// Same-sector rows from screener_metrics — the full covered market, not
  /// just the hot quote universe. No metrics row yet just means no section.
  void _loadPeers() {
    if (!remoteConfig.screenerPageEnabled || _peers.isNotEmpty) return;
    final sb = Supabase.instance.client;
    sb
        .from('screener_metrics')
        .select('sector')
        .eq('symbol', widget.company.nseSymbol)
        .maybeSingle()
        .then((self) {
      final sector = self?['sector'] as String?;
      if (sector == null || sector.isEmpty || !mounted) return;
      sb
          .from('screener_metrics')
          .select('symbol,name,price,pe,pb,mcap_cr,roe,roce,de,div_yield,opm,promoter_pct')
          .eq('sector', sector)
          .order('mcap_cr', ascending: false)
          .limit(11)
          .then((rows) {
        if (!mounted) return;
        setState(() =>
            _peers = [for (final r in rows) Map<String, dynamic>.from(r)]);
      });
    }).catchError((_) {});
  }

  /// Re-fetch the chart at a pill's range; the header quote stays on the
  /// 1M/1d numbers from _load.
  Future<void> _fetchRange(String label) async {
    setState(() => _range = label);
    final (rng, iv) = _ranges[label]!;
    try {
      final r = await http
          .get(
            Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/'
                '${widget.company.nseSymbol}.NS?range=$rng&interval=$iv'),
            headers: {'User-Agent': 'Mozilla/5.0'},
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted || r.statusCode != 200) return;
      final q = Quote.fromChartJson(jsonDecode(r.body));
      var closes = q.closes, times = q.times;
      if (label == '3Y' && times.isNotEmpty) {
        final cutoff = DateTime.now().subtract(const Duration(days: 3 * 365));
        final from = times.indexWhere((t) => t.isAfter(cutoff));
        if (from > 0) {
          closes = closes.sublist(from);
          times = times.sublist(from);
        }
      }
      if (mounted && _range == label && closes.isNotEmpty) {
        setState(() {
          _chartCloses = closes;
          _chartTimes = times;
        });
      }
    } catch (_) {} // pill just keeps the old line; retap retries
  }

  /// Out-of-universe stock: no meta.f/meta.t yet. Ask the pipeline to backfill
  /// (fire-and-forget, like _logView — a duplicate-key "already requested"
  /// error is as ignorable as a network one), then re-read ticks a few times so
  /// the strips appear without reopening the page (they're a
  /// ValueListenableBuilder on ticks).
  void _maybeRequestAnalysis() {
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    final sym = widget.company.nseSymbol;
    if (uid == null || sym.isEmpty) return;
    if (!needsAnalysisRequest(ticks.value[sym]?.meta ?? const {})) return;
    sb.from('analysis_requests').insert({'symbol': sym}).then((_) {}, onError: (_) {});
    _analysisPoll ??= Timer.periodic(const Duration(seconds: 75), (t) {
      if (!mounted ||
          ++_analysisPolls > 5 ||
          !needsAnalysisRequest(ticks.value[sym]?.meta ?? const {})) {
        t.cancel();
        return;
      }
      loadTicks([sym]);
    });
  }

  Future<void> _load() async {
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    setState(() {
      _quoteFailed = false;
      _storiesFailed = false;
    });
    // The pipeline's cached quote paints the header instantly (and survives a
    // Yahoo failure); the chart fetch below replaces it with the fuller Quote.
    final sym = widget.company.nseSymbol;
    void seed() {
      final t = ticks.value[sym];
      if (t != null && _quote == null && mounted) {
        setState(() => _quote = Quote.seed(t.price, t.prevClose ?? t.price));
      }
      _loadPeers();
    }

    if (ticks.value[sym] != null) {
      seed();
      _maybeRequestAnalysis();
    } else {
      unawaited(loadTicks([sym]).then((_) {
        seed();
        _maybeRequestAnalysis();
      }));
    }
    // Three independent fetches; each failure degrades its own section only.
    http
        .get(
          Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/'
              '${widget.company.nseSymbol}.NS?range=1mo&interval=1d'),
          headers: {'User-Agent': 'Mozilla/5.0'},
        )
        .timeout(const Duration(seconds: 10))
        .then((r) {
          if (!mounted) return;
          if (r.statusCode != 200) return setState(() => _quoteFailed = true);
          final q = Quote.fromChartJson(jsonDecode(r.body));
          setState(() {
            _quote = q;
            if (_range == '1M') {
              _chartCloses = q.closes;
              _chartTimes = q.times;
            }
          });
        })
        .catchError((_) {
          if (mounted) setState(() => _quoteFailed = true);
        });
    // Two steps, not an embedded join: ordering by a referenced table's column
    // through PostgREST embeds is where the Q&A tier-1 bug came from.
    sb
        .from('story_companies')
        .select('story_id')
        .eq('company_id', widget.company.id)
        .order('story_id', ascending: false)
        .limit(100)
        .then((links) async {
      final ids = [for (final l in links) l['story_id']];
      if (ids.isEmpty || !mounted) return;
      final rows = await sb
          .from('stories')
          .select(storyCols)
          .inFilter('id', ids)
          .eq('status', 'approved')
          .order('published_at', ascending: false)
          .limit(15);
      if (!mounted) return;
      setState(() => _stories = [
            for (final r in rows) Story.fromJson(Map<String, dynamic>.from(r))
          ]);
    }).catchError((_) {
      // A network blip must not read as "this company has no coverage".
      if (mounted) setState(() => _storiesFailed = true);
    });
    // Smart-money lines for this symbol from the pipeline's NSE blobs. A miss
    // just hides the section.
    sb
        .from('market_blobs')
        .select('key,payload')
        .inFilter('key', ['results_calendar', 'bulk_deals', 'insider_trades'])
        .then((rows) {
      if (!mounted) return;
      final blobs = {for (final r in rows) r['key'] as String: r['payload']};
      setState(() => _events = companyEventLines(blobs, sym));
    }).catchError((_) {});
    // Best-effort by design: worst case the star shows unfollowed and the
    // toggle's upsert is a safe no-op re-follow.
    if (uid != null) {
      sb
          .from('follows')
          .select('target_id')
          .eq('user_id', uid)
          .eq('target_type', 'company')
          .eq('target_id', '${widget.company.id}')
          .maybeSingle()
          .then((row) {
        if (mounted) setState(() => _following = row != null);
      }).catchError((_) {});
    }
  }

  Future<void> _toggleFollow() async {
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    if (uid == null) return;
    // A fast double-tap fired upsert and delete concurrently; last to land
    // won on the server while the UI showed the second tap's guess.
    if (_togglingFollow) return;
    _togglingFollow = true;
    final was = _following;
    setState(() => _following = !was); // optimistic, like save
    // Mirror into the feed's watchlist set the same optimistic way.
    final next = {...followedCompanyIds.value};
    was ? next.remove(widget.company.id) : next.add(widget.company.id);
    followedCompanyIds.value = next;
    try {
      if (was) {
        await sb.from('follows').delete().match({
          'user_id': uid,
          'target_type': 'company',
          'target_id': '${widget.company.id}',
        });
      } else {
        await sb.from('follows').upsert({
          'user_id': uid,
          'target_type': 'company',
          'target_id': '${widget.company.id}',
        });
      }
    } catch (_) {
      if (mounted) setState(() => _following = was);
      final undo = {...followedCompanyIds.value};
      was ? undo.add(widget.company.id) : undo.remove(widget.company.id);
      followedCompanyIds.value = undo;
    } finally {
      _togglingFollow = false;
    }
  }

  Map<String, dynamic> get _meta =>
      ticks.value[widget.company.nseSymbol]?.meta ?? const {};

  List<Widget> _priceHeader() {
    final q = _quote;
    final up = q != null && q.price >= q.prevClose;
    final delta = q == null ? '' : (q.price - q.prevClose).toStringAsFixed(2);
    final pct = q == null || q.prevClose == 0
        ? ''
        : ((q.price - q.prevClose) / q.prevClose * 100).toStringAsFixed(2);
    final screener = remoteConfig.screenerPageEnabled;
    final closes =
        screener && _chartCloses.isNotEmpty ? _chartCloses : q?.closes ?? const <double>[];
    final pe = _showPe && _fund.quarter.length >= 4
        ? peSeries(closes, _chartTimes, _fund.quarter)
        : null;
    final peLatest = pe?.reversed.firstWhere((v) => v != null, orElse: () => null);
    final meta = _meta;
    final f = (meta['f'] as Map?)?.cast<String, dynamic>() ?? const {};
    final t = (meta['t'] as Map?)?.cast<String, dynamic>() ?? const {};
    final sectorLine =
        [f['sector'], f['industry']].whereType<String>().join(' · ');
    final sma50 = (t['sma50'] as num?)?.toDouble();
    final sma200 = (t['sma200'] as num?)?.toDouble();
    return [
      Row(children: [
        Text(widget.company.nseSymbol, style: mono.copyWith(fontSize: 12)),
        if (sectorLine.isNotEmpty) ...[
          const SizedBox(width: 10),
          Expanded(
              child: Text(sectorLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(fontSize: 12))),
        ],
      ]),
      const SizedBox(height: 8),
      if (q != null) ...[
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('₹${q.price.toStringAsFixed(2)}',
              style: serif.copyWith(fontSize: 34, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('${up ? '+' : ''}$delta ($pct%)',
                style: mono.copyWith(fontSize: 13, color: up ? green : red)),
          ),
        ]),
        const SizedBox(height: 16),
        SizedBox(height: 96, child: Sparkline(closes, up ? green : red, secondary: pe)),
        const SizedBox(height: 10),
        if (peLatest != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('P/E ${peLatest.toStringAsFixed(1)} · TTM, quarter-end steps',
                style: mono.copyWith(fontSize: 10, color: amber)),
          ),
        if (screener)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              for (final label in _ranges.keys)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: filterPill(label, _range == label, green,
                      () => _fetchRange(label), fontSize: 10),
                ),
              if (_fund.quarter.length >= 4)
                filterPill('P/E', _showPe, amber,
                    () => setState(() => _showPe = !_showPe), fontSize: 10),
            ]),
          ),
        if (q.high52 > q.low52) ...[
          const SizedBox(height: 12),
          ScaleBar(q.price, min: q.low52, max: q.high52, marks: [
            if (sma50 != null) (sma50, '50D'),
            if (sma200 != null) (sma200, '200D'),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('52-wk  ₹${q.low52.toStringAsFixed(0)}', style: mono.copyWith(fontSize: 10)),
            Text('at ${((q.price - q.low52) / (q.high52 - q.low52) * 100).round()}%',
                style: mono.copyWith(fontSize: 10)),
            Text('₹${q.high52.toStringAsFixed(0)}', style: mono.copyWith(fontSize: 10)),
          ]),
          const SizedBox(height: 6),
        ],
        Text('Delayed price · Yahoo Finance', style: mono.copyWith(fontSize: 10)),
      ] else if (_quoteFailed)
        GestureDetector(
          onTap: _load,
          child: Text('Price unavailable — tap to retry',
              style: mono.copyWith(fontSize: 13)),
        )
      else
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(child: appSpinner()),
        ),
    ];
  }

  Widget _onTicks(Widget Function(Map<String, dynamic> meta) build) =>
      ValueListenableBuilder<Map<String, Tick>>(
        valueListenable: ticks,
        builder: (_, m, __) =>
            build(m[widget.company.nseSymbol]?.meta ?? const {}),
      );

  Widget _stamp(String s) => Text(s, style: mono.copyWith(fontSize: 10));

  /// SNAPSHOT: six headline ratios as tiles.
  Widget _snapshot() => _onTicks((meta) {
        final tiles = snapshotStats(meta);
        if (tiles.isEmpty) return const SizedBox.shrink();
        return LedgerSection('Snapshot', children: [
          const SizedBox(height: 10),
          StatGrid([for (final t in tiles) StatTile(t.label, t.value, sub: t.sub)]),
        ]);
      });

  /// FUNDAMENTALS: the full labelled table against sector medians, then the
  /// eight-quarter sales/profit bars.
  Widget _fundamentals() => _onTicks((meta) {
        final medians = sectorMedians(_peers, self: widget.company.nseSymbol);
        final rows = fundamentalRows(meta, medians: medians, summary: _fund.summary);
        if (rows.isEmpty) return const SizedBox.shrink();
        final qs = quarterSeries(_fund.quarter, meta, label: periodLabel);
        final hasBars = qs.sales.any((v) => v != null);
        final nPeers = _peers.where((p) => p['symbol'] != widget.company.nseSymbol).length;
        Widget swatch(Color c) =>
            SizedBox(width: 8, height: 8, child: ColoredBox(color: c));
        return LedgerSection('Fundamentals',
            action: nPeers == 0 ? null : _stamp('vs $nPeers sector peers'),
            footnote:
                'SECTOR = median of same-sector peers · Yahoo Finance · as of ${fmtDay(meta['f_at'])}',
            children: [
              const SizedBox(height: 2),
              KvTable(const ['METRIC', 'VALUE', 'SECTOR', 'READ'], rows),
              if (hasBars) ...[
                const SizedBox(height: 16),
                Row(children: [
                  Text('QUARTERLY · ', style: mono.copyWith(fontSize: 10)),
                  swatch(green.withValues(alpha: 0.55)),
                  Text(' sales   ', style: mono.copyWith(fontSize: 10)),
                  swatch(amber),
                  Text(' net profit   (₹ Cr)', style: mono.copyWith(fontSize: 10)),
                ]),
                const SizedBox(height: 6),
                SizedBox(
                    height: 84,
                    child: BarChart(qs.sales, secondary: qs.profit, labels: qs.labels)),
              ],
            ]);
      });

  /// TECHNICALS: three one-word tiles, then every level against the close.
  Widget _technicals() => _onTicks((meta) {
        final tiles = techStats(meta);
        final rows = technicalRows(meta);
        if (tiles.isEmpty && rows.isEmpty) return const SizedBox.shrink();
        return LedgerSection('Technicals',
            action: _stamp('1y daily closes'),
            footnote: 'computed from 1y daily closes · as of ${fmtDay(meta['t_at'])}',
            children: [
              if (tiles.isNotEmpty) ...[
                const SizedBox(height: 10),
                StatGrid([
                  for (final t in tiles)
                    StatTile(t.label, t.value,
                        sub: t.sub, color: KvTable.toneColor(t.tone)),
                ]),
                const SizedBox(height: 14),
              ],
              KvTable(const ['INDICATOR', 'LEVEL', 'VS PRICE', 'SIGNAL'], rows),
            ]);
      });

  Widget _tape() => LedgerSection('On the tape',
      footnote: 'NSE · board meetings, bulk/block deals, insider filings',
      children: [
        const SizedBox(height: 6),
        for (final e in _events.take(8))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(e, style: mono.copyWith(fontSize: 12, height: 1.4)),
          ),
      ]);

  Widget _storyList() => LedgerSection('Recent stories', children: [
        if (_stories.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: _storiesFailed
                ? GestureDetector(
                    onTap: _load,
                    child: Text("Couldn't load stories — tap to retry",
                        style: mono.copyWith(fontSize: 13)),
                  )
                : Text('No tagged stories yet', style: mono.copyWith(fontSize: 13)),
          ),
        for (final s in _stories)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.hook ?? s.headline,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: ink, fontWeight: FontWeight.w600)),
            subtitle: Text(s.sourceName, style: mono.copyWith(fontSize: 11)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => StoryDetailScreen(storyId: s.id))),
          ),
      ]);

  /// One statement section: heading + HEAT pill + table, Screener order.
  Widget _table(String title, List<String> periods,
          List<(String, String, CellFmt)> rows,
          Map<String, Map<String, dynamic>> byPeriod,
          {List<Widget> lead = const []}) =>
      LedgerSection(title,
          action: filterPill('HEAT', _heat, amber,
              () => setState(() => _heat = !_heat), fontSize: 10),
          footnote:
              '₹ Cr · ${_heat ? 'tint = change vs previous period · ' : ''}Yahoo Finance + backfill',
          children: [
            ...lead,
            const SizedBox(height: 4),
            StatementTable(periods: periods, rows: rows, byPeriod: byPeriod, heat: _heat),
          ]);

  /// Latest quarter's holders as one 100% bar, ink alphas only (no
  /// direction to colour).
  List<Widget> _holdersBar() {
    final f = _fund;
    if (f.shareholding.isEmpty) return const [];
    final latest = f.shareholding[f.shareholding.keys.last]!;
    const parts = [
      ('promoters', 'Promoters', 0.8), ('fiis', 'FIIs', 0.6), ('diis', 'DIIs', 0.45),
      ('govt', 'Govt', 0.3), ('public', 'Public', 0.2), ('employee_trusts', 'Trusts', 0.12),
    ];
    final segs = [
      for (final (k, label, a) in parts)
        if (latest[k] is num && (latest[k] as num) > 0)
          ((latest[k] as num) / 100, ink.withValues(alpha: a),
              '$label ${fmtCell(latest[k] as num, CellFmt.pct)}')
    ];
    if (segs.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: StackedBar(segs)),
      ]),
      const SizedBox(height: 4),
      _stamp(periodLabel(f.shareholding.keys.last)),
      const SizedBox(height: 8),
    ];
  }

  List<({String id, String label, Widget child})> _sections() {
    final f = _fund;
    final cagr = (f.summary['cagr'] as Map?)?.cast<String, dynamic>() ?? const {};
    Widget col(List<Widget> children) =>
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
    return [
      (id: 'chart', label: 'CHART', child: col(_priceHeader())),
      (id: 'snapshot', label: 'SNAPSHOT', child: _snapshot()),
      (id: 'fundamentals', label: 'FUNDAMENTALS', child: _fundamentals()),
      (id: 'technicals', label: 'TECHNICALS', child: _technicals()),
      if ((f.summary['pros'] as List?)?.isNotEmpty == true ||
          (f.summary['cons'] as List?)?.isNotEmpty == true)
        (
          id: 'proscons',
          label: 'PROS·CONS',
          child: LedgerSection('Pros · Cons', children: [
            const SizedBox(height: 8),
            ProsCons(f.summary),
          ])
        ),
      if (cagr.isNotEmpty)
        (
          id: 'growth',
          label: 'GROWTH',
          child: LedgerSection('Growth',
              action: _stamp('CAGR'),
              footnote: 'compounded growth · ₹ Cr basis',
              children: [const SizedBox(height: 10), growthGrid(cagr)])
        ),
      if (_peers.isNotEmpty)
        (
          id: 'peers',
          label: 'PEERS',
          child: LedgerSection('Peers',
              action: _stamp('same sector · by mkt cap'),
              footnote: 'bar = market cap vs largest · screener_metrics',
              children: [PeersTable(_peers, self: widget.company.nseSymbol)])
        ),
      if (f.quarter.isNotEmpty)
        (
          id: 'quarters',
          label: 'QUARTERS',
          child: _table('Quarterly results', f.quarter.keys.toList(),
              quarterRows, f.quarter)
        ),
      if (f.annual.isNotEmpty) ...[
        (
          id: 'pnl',
          label: 'P&L',
          child: _table('Profit & loss', f.annual.keys.toList(), pnlRows, f.annual)
        ),
        (
          id: 'bs',
          label: 'BALANCE SHEET',
          child: _table('Balance sheet', f.annual.keys.toList(), bsRows, f.annual)
        ),
        (
          id: 'cf',
          label: 'CASH FLOW',
          child: _table('Cash flow', f.annual.keys.toList(), cfRows, f.annual)
        ),
        (
          id: 'trend',
          label: 'RATIO TREND',
          child: _table('Ratios', f.annual.keys.toList(), ratioRows, f.annual)
        ),
      ],
      if (f.shareholding.isNotEmpty)
        (
          id: 'holders',
          label: 'SHAREHOLDING',
          child: _table('Shareholding pattern', f.shareholding.keys.toList(),
              shareholdingRows, f.shareholding, lead: _holdersBar())
        ),
      if (f.docs.isNotEmpty)
        (
          id: 'docs',
          label: 'DOCS',
          child: LedgerSection('Documents', children: [
            const SizedBox(height: 8),
            DocsSection(f.docs),
          ])
        ),
      if (_events.isNotEmpty) (id: 'tape', label: 'TAPE', child: _tape()),
      (id: 'stories', label: 'STORIES', child: _storyList()),
    ];
  }

  @override
  Widget build(BuildContext context) {
    Scaffold scaffold({required Widget body}) => Scaffold(
          backgroundColor: bg,
          appBar: AppBar(
            leading: const BackButton(),
            title: Text(widget.company.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: serif.copyWith(fontSize: 18)),
            actions: [
              IconButton(
                onPressed: _toggleFollow,
                icon: Icon(
                    _following ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: _following ? amber : inkDim),
                tooltip: _following ? 'Unfollow' : 'Follow',
              ),
            ],
          ),
          body: body,
        );
    if (!remoteConfig.screenerPageEnabled) {
      return scaffold(
        body: ListView(padding: const EdgeInsets.all(20), children: [
          ..._priceHeader(),
          _snapshot(),
          _fundamentals(),
          _technicals(),
          if (_events.isNotEmpty) _tape(),
          _storyList(),
        ]),
      );
    }
    final secs = _sections();
    _tracker.ids = [for (final s in secs) s.id];
    // Eager layout (SingleChildScrollView, not ListView) so every section
    // RenderBox exists for ribbon jump + scroll tracking — same trade as the
    // Markets tab; the tables are bounded, this stays cheap.
    return scaffold(
      body: Column(children: [
        SectionRibbon([for (final s in secs) (id: s.id, label: s.label)],
            _tracker.active, _tracker.jump),
        Expanded(
          child: NotificationListener<ScrollUpdateNotification>(
            onNotification: _tracker.track,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final s in secs)
                    KeyedSubtree(key: _tracker.key(s.id), child: s.child),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
