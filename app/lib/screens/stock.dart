import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../analysis.dart';
import '../follows.dart';
import '../fundamentals.dart';
import '../models.dart';
import '../remote_config.dart';
import '../section_ribbon.dart';
import '../theme.dart';
import '../ticks.dart';
import 'feed.dart' show filterPill;
import 'stock_sections.dart';
import 'story_detail.dart';

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
  List<Tick> _peers = const [];
  String _range = '1M';
  List<double> _chartCloses = const [];
  List<DateTime> _chartTimes = const [];
  bool _showPe = false;
  final _tracker = SectionTracker();

  // Yahoo chart range/interval per pill; the 1M fetch doubles as the quote.
  static const _ranges = {'1M': ('1mo', '1d'), '6M': ('6mo', '1d'),
                          '1Y': ('1y', '1d'), '5Y': ('5y', '1wk'),
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

  /// Same-Yahoo-sector rows from the hot quote universe — the PEERS table.
  /// No sector in meta yet (analysis pending) just means no section.
  void _loadPeers() {
    if (!remoteConfig.screenerPageEnabled || _peers.isNotEmpty) return;
    final meta = ticks.value[widget.company.nseSymbol]?.meta;
    final sector = ((meta?['f'] as Map?)?['sector'] as String?) ?? '';
    if (sector.isEmpty) return;
    Supabase.instance.client
        .from('quotes')
        .select(tickCols)
        .eq('kind', 'equity')
        .filter('meta->f->>sector', 'eq', sector)
        .limit(30)
        .then((rows) {
      if (!mounted) return;
      setState(() => _peers = [
            for (final r in rows) Tick.fromJson(Map<String, dynamic>.from(r))
          ]);
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
      if (mounted && _range == label && q.closes.isNotEmpty) {
        setState(() {
          _chartCloses = q.closes;
          _chartTimes = q.times;
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
    return [
      Text(widget.company.nseSymbol, style: mono.copyWith(fontSize: 12)),
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
        SizedBox(height: 64, child: Sparkline(closes, up ? green : red, secondary: pe)),
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
        if (q.high52 > 0)
          Text('52-wk  ₹${q.low52.toStringAsFixed(0)} – ₹${q.high52.toStringAsFixed(0)}',
              style: mono.copyWith(fontSize: 12)),
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

  Widget _analysisStrips() => ValueListenableBuilder<Map<String, Tick>>(
        valueListenable: ticks,
        builder: (_, m, __) {
          final meta = m[widget.company.nseSymbol]?.meta ?? const {};
          final fund = fundamentalLines(meta);
          final tech = technicalLines(meta);
          final s = _fund.summary;
          if (fund.isEmpty && tech.isEmpty) return const SizedBox.shrink();
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (fund.isNotEmpty) ...[
              const Divider(height: 40),
              Text('FUNDAMENTALS', style: monoLabel),
              const SizedBox(height: 8),
              for (final (k, v) in fund) _kv(k, v),
              if (s['roce'] != null)
                _kv('ROCE', fmtCell(s['roce'] as num?, CellFmt.pct)),
              if (s['book_value'] != null)
                _kv('Book value', '₹${fmtCell(s['book_value'] as num?, CellFmt.num2)}'),
              Text('Yahoo Finance · as of ${fmtDay(meta['f_at'])}',
                  style: mono.copyWith(fontSize: 10)),
            ],
            if (tech.isNotEmpty) ...[
              const Divider(height: 40),
              Text('TECHNICALS', style: monoLabel),
              const SizedBox(height: 8),
              for (final (k, v) in tech) _kv(k, v),
              Text('computed from 1y daily closes · as of ${fmtDay(meta['t_at'])}',
                  style: mono.copyWith(fontSize: 10)),
            ],
          ]);
        },
      );

  List<Widget> _tape() => [
        if (_events.isNotEmpty) ...[
          const Divider(height: 40),
          Text('ON THE TAPE', style: monoLabel),
          const SizedBox(height: 8),
          for (final e in _events.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(e, style: mono.copyWith(fontSize: 12, height: 1.4)),
            ),
          Text('NSE · board meetings, bulk/block deals, insider filings',
              style: mono.copyWith(fontSize: 10)),
        ],
      ];

  List<Widget> _storyList() => [
        const Divider(height: 40),
        Text('RECENT STORIES', style: monoLabel),
        const SizedBox(height: 8),
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
      ];

  /// One statement section: heading + divider + table, Screener order.
  List<Widget> _table(String title, List<String> periods,
          List<(String, String, CellFmt)> rows,
          Map<String, Map<String, dynamic>> byPeriod) =>
      [
        const Divider(height: 40),
        Text(title, style: monoLabel),
        const SizedBox(height: 8),
        StatementTable(periods: periods, rows: rows, byPeriod: byPeriod),
        Text('₹ Cr · Yahoo Finance + backfill', style: mono.copyWith(fontSize: 10)),
      ];

  List<({String id, String label, Widget child})> _sections() {
    final f = _fund;
    final cagr = (f.summary['cagr'] as Map?)?.cast<String, dynamic>() ?? const {};
    Map<String, dynamic> block(String k) =>
        (cagr[k] as Map?)?.cast<String, dynamic>() ?? const {};
    Widget col(List<Widget> children) =>
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
    return [
      (id: 'chart', label: 'CHART', child: col(_priceHeader())),
      (id: 'ratios', label: 'RATIOS', child: _analysisStrips()),
      if ((f.summary['pros'] as List?)?.isNotEmpty == true ||
          (f.summary['cons'] as List?)?.isNotEmpty == true)
        (
          id: 'proscons',
          label: 'PROS·CONS',
          child: col([
            const Divider(height: 40),
            Text('ANALYSIS', style: monoLabel),
            const SizedBox(height: 8),
            ProsCons(f.summary),
          ])
        ),
      if (cagr.isNotEmpty)
        (
          id: 'growth',
          label: 'GROWTH',
          child: col([
            const Divider(height: 40),
            Text('GROWTH', style: monoLabel),
            const SizedBox(height: 8),
            CagrStrip('Compounded Sales Growth', block('sales')),
            CagrStrip('Compounded Profit Growth', block('profit')),
            CagrStrip('Stock Price CAGR', block('price')),
            CagrStrip('Return on Equity', block('roe')),
          ])
        ),
      if (_peers.isNotEmpty)
        (
          id: 'peers',
          label: 'PEERS',
          child: col([
            const Divider(height: 40),
            Text('PEERS', style: monoLabel),
            const SizedBox(height: 8),
            PeersTable(_peers, self: widget.company.nseSymbol),
            Text('same Yahoo sector · tracked stocks only',
                style: mono.copyWith(fontSize: 10)),
          ])
        ),
      if (f.quarter.isNotEmpty)
        (
          id: 'quarters',
          label: 'QUARTERS',
          child: col(_table('QUARTERLY RESULTS', f.quarter.keys.toList(),
              quarterRows, f.quarter))
        ),
      if (f.annual.isNotEmpty) ...[
        (
          id: 'pnl',
          label: 'P&L',
          child: col(
              _table('PROFIT & LOSS', f.annual.keys.toList(), pnlRows, f.annual))
        ),
        (
          id: 'bs',
          label: 'BALANCE SHEET',
          child: col(
              _table('BALANCE SHEET', f.annual.keys.toList(), bsRows, f.annual))
        ),
        (
          id: 'cf',
          label: 'CASH FLOW',
          child:
              col(_table('CASH FLOW', f.annual.keys.toList(), cfRows, f.annual))
        ),
        (
          id: 'trend',
          label: 'RATIO TREND',
          child: col(
              _table('RATIOS', f.annual.keys.toList(), ratioRows, f.annual))
        ),
      ],
      if (f.shareholding.isNotEmpty)
        (
          id: 'holders',
          label: 'SHAREHOLDING',
          child: col(_table('SHAREHOLDING PATTERN',
              f.shareholding.keys.toList(), shareholdingRows, f.shareholding))
        ),
      if (f.docs.isNotEmpty)
        (
          id: 'docs',
          label: 'DOCS',
          child: col([
            const Divider(height: 40),
            Text('DOCUMENTS', style: monoLabel),
            const SizedBox(height: 8),
            DocsSection(f.docs),
          ])
        ),
      if (_events.isNotEmpty) (id: 'tape', label: 'TAPE', child: col(_tape())),
      (id: 'stories', label: 'STORIES', child: col(_storyList())),
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
          _analysisStrips(),
          ..._tape(),
          ..._storyList(),
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

/// Fundamentals/Technicals line: label left, value right, both mono.
Widget _kv(String k, String v) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 110,
            child: Text(k, style: mono.copyWith(fontSize: 12))),
        Expanded(
            child: Text(v,
                style: mono.copyWith(fontSize: 12, color: ink, height: 1.3))),
      ]),
    );

/// One polyline, no chart package: the spec asks for a "light line chart" and
/// a painter is 20 lines against a dependency.
class Sparkline extends StatelessWidget {
  const Sparkline(this.values, this.color, {super.key, this.secondary});
  final List<double> values;
  final Color color;

  /// Optional overlay (the P/E line): aligned with [values], nulls break the
  /// line, normalized on its own scale, drawn thin in amber.
  final List<double?>? secondary;

  @override
  Widget build(BuildContext context) => CustomPaint(
      size: Size.infinite, painter: _SparkPainter(values, color, secondary));
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color, [this.secondary]);
  final List<double> values;
  final Color color;
  final List<double?>? secondary;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo) == 0 ? 1.0 : hi - lo;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final y = size.height - (values[i] - lo) / span * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color);
    final sec = secondary;
    if (sec == null) return;
    final vals = [for (final v in sec) if (v != null) v];
    if (vals.length < 2) return;
    final slo = vals.reduce((a, b) => a < b ? a : b);
    final shi = vals.reduce((a, b) => a > b ? a : b);
    final sspan = (shi - slo) == 0 ? 1.0 : shi - slo;
    final spath = Path();
    var pen = false;
    final n = sec.length < values.length ? sec.length : values.length;
    for (var i = 0; i < n; i++) {
      final v = sec[i];
      if (v == null) {
        pen = false;
        continue;
      }
      final x = i / (values.length - 1) * size.width;
      final y = size.height - (v - slo) / sspan * size.height;
      pen ? spath.lineTo(x, y) : spath.moveTo(x, y);
      pen = true;
    }
    canvas.drawPath(
        spath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = amber);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.color != color || old.secondary != secondary;
}
