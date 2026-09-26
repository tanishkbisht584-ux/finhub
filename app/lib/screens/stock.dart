import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../analysis.dart';
import '../charts.dart';
import '../follows.dart';
import '../fundamentals.dart';
import '../ledger.dart';
import '../price_chart.dart';
import '../models.dart';
import '../remote_config.dart';
import '../section_ribbon.dart';
import '../theme.dart';
import '../ticks.dart';
import 'alerts.dart';
import 'ask.dart' show AskScreen;
import '../alerts.dart' show loadAlerts;
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
  int _alertCount = 0; // Phase B: this symbol's active price alerts (bell tint)
  bool _togglingFollow = false;
  List<String> _events =
      const []; // NSE results/deals/insider lines (market_blobs)
  Timer? _analysisPoll;
  int _analysisPolls = 0;
  FundamentalsData _fund = FundamentalsData.fromRows(const []);
  Timer? _fundPoll;
  int _fundPolls = 0;
  List<Map<String, dynamic>> _peers = const [];
  String _peerKey = 'sector'; // 'industry' when the symbol has one

  /// The symbol's own screener_metrics row: Stock Analysis columns + `sa`
  /// jsonb (returns, records, street, calendar). Empty until the row has
  /// `sa_price_date`, i.e. the stockanalysis group has covered it.
  Map<String, dynamic> _sa = const {};
  String _range = '1M';
  String _bar = 'D'; // Phase D: bar size, valid pairs in _barsFor
  Bars? _bars; // the range's own OHLCV; header numbers stay on the 1M quote
  Set<ChartLayer> _layers = {ChartLayer.vol};
  Quote? _seasonQ; // Yahoo max/1mo, fetched once: SEASONALITY
  String _swotTab = 's';
  int? _span; // statement tables: null = every period, else the last N
  bool _yoy = true; // EARNINGS: YoY vs QoQ
  String _holderKey = 'promoters'; // SHAREHOLDING trend category
  int _peerMetric = 1; // index into peerMetrics
  bool _peerRadar = true;
  String _delivMode = 'combined'; // DELIVERY: combined / nse / bse (MC's toggle)
  bool _showPe = false;
  bool _heat = false; // statement tables: tint cells by change vs prior period
  final _tracker = SectionTracker();

  // Yahoo chart range per pill; the 1M/D fetch doubles as the quote. 3Y has
  // no Yahoo range value — it fetches 5y and trims client-side. Bars per
  // range are the pairs Yahoo serves (5m/15m ≤ 60 d, 1h ≤ 730 d).
  static const _ranges = {
    '1D': '1d',
    '5D': '5d',
    '1M': '1mo',
    '3M': '3mo',
    '6M': '6mo',
    '1Y': '1y',
    '3Y': '5y',
    '5Y': '5y',
    'MAX': 'max',
  };
  static const _intervals = {'5m': '5m', '15m': '15m', '1h': '1h', 'D': '1d', 'W': '1wk', 'M': '1mo'};
  static List<String> _barsFor(String range) => switch (range) {
        '1D' => const ['5m', '15m'],
        '5D' => const ['15m', '1h'],
        '1M' => const ['1h', 'D'],
        '3M' => const ['D', 'W'],
        _ => const ['D', 'W', 'M'],
      };
  bool get _intraday => _bar == '5m' || _bar == '15m' || _bar == '1h';

  @override
  void initState() {
    super.initState();
    _load();
    _loadFundamentals();
    _loadSeasonality();
    SharedPreferences.getInstance().then((p) {
      final saved = p.getStringList('chart_layers_v1');
      if (saved != null && mounted) {
        setState(() => _layers = {
              for (final s in saved)
                for (final l in ChartLayer.values)
                  if (l.name == s) l
            });
      }
    }).catchError((_) {});
  }

  void _toggleLayer(ChartLayer l) {
    setState(() {
      if (l == ChartLayer.candle) {
        _layers.contains(l) ? _layers.remove(l) : _layers.add(l);
      } else {
        _layers = {..._layers};
        _layers.contains(l) ? _layers.remove(l) : _layers.add(l);
      }
      _layers = {..._layers};
    });
    SharedPreferences.getInstance()
        .then((p) => p.setStringList('chart_layers_v1', [for (final l in _layers) l.name]))
        .then((_) {}, onError: (_) {});
  }

  /// One monthly chart for the whole listing life — seasonality's only input.
  Future<void> _loadSeasonality() async {
    try {
      final r = await http.get(
        Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/'
            '${widget.company.nseSymbol}.NS?range=max&interval=1mo&events=div,splits'),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 12));
      if (!mounted || r.statusCode != 200) return;
      final q = Quote.fromChartJson(jsonDecode(r.body));
      if (mounted && q.closes.length >= 13) setState(() => _seasonQ = q);
    } catch (_) {} // section simply stays absent
  }

  static Color _scoreColor(int s) => s >= 60 ? green : s >= 40 ? amber : red;

  @override
  void dispose() {
    _analysisPoll?.cancel();
    _fundPoll?.cancel();
    _tracker.dispose();
    super.dispose();
  }

  /// Statement history from the `fundamentals` table. Empty or incomplete
  /// (needsDeepRefresh) -> ask the pipeline (same analysis_requests door as
  /// meta.f/t) and poll it in, the exact rhythm of _maybeRequestAnalysis.
  void _loadFundamentals() {
    if (!remoteConfig.screenerPageEnabled) return;
    final sym = widget.company.nseSymbol;
    if (sym.isEmpty) return;
    loadFundamentals(sym).then((d) {
      if (!mounted) return;
      setState(() => _fund = d);
      if (!needsDeepRefresh(d)) return;
      final sb = Supabase.instance.client;
      if (sb.auth.currentUser != null) {
        sb
            .from('analysis_requests')
            .insert({'symbol': sym}).then((_) {}, onError: (_) {});
      }
      _fundPoll ??= Timer.periodic(const Duration(seconds: 75), (t) {
        if (!mounted || ++_fundPolls > 5 || !needsDeepRefresh(_fund)) {
          t.cancel();
          return;
        }
        loadFundamentals(sym).then((d) {
          if (mounted && !d.isEmpty) setState(() => _fund = d);
        });
      });
    });
  }

  /// Same-industry rows from screener_metrics (Screener's peer key; sector
  /// when a symbol has no industry) — the full covered market, not just the
  /// hot quote universe. No metrics row yet just means no section.
  void _loadPeers() {
    if (!remoteConfig.screenerPageEnabled || _peers.isNotEmpty) return;
    final sb = Supabase.instance.client;
    sb
        .from('screener_metrics')
        .select(
            'industry,sector,ret_1w,ret_1m,ret_3m,ret_6m,ret_ytd,ret_1y,ret_3y,ret_5y,'
            'ath_pct,from_atl_pct,days_since_hi52,days_since_lo52,hi52,lo52,mcap_bucket,rel_vol,turnover_cr,sharpe,sortino,atr,graham_upside,f_score,ps,'
            'earnings_yield,fcf_yield,roic,int_cov,ev_ebitda,sector_pe,industry_pe,'
            'shares_yoy,sa,sa_price_date,altman_z,hi52,lo52,ma50,ma200,rsi,trend,tape,fno,tape_bse,roe,mcap_cr')
        .eq('symbol', widget.company.nseSymbol)
        .maybeSingle()
        .then((self) {
      if (!mounted) return;
      if (self?['sa_price_date'] != null) {
        setState(() => _sa = Map<String, dynamic>.from(self!));
      }
      final industry = self?['industry'] as String?;
      final sector = self?['sector'] as String?;
      final (column, value) = industry != null && industry.isNotEmpty
          ? ('industry', industry)
          : ('sector', sector ?? '');
      if (value.isEmpty) return;
      _peerKey = column;
      sb
          .from('screener_metrics')
          .select(
              'symbol,name,price,pe,pb,mcap_cr,roe,roce,de,div_yield,opm,promoter_pct')
          .eq(column, value)
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
  Future<void> _fetchRange(String label, {String? bar}) async {
    final valid = _barsFor(label);
    final b = bar != null && valid.contains(bar)
        ? bar
        : valid.contains(_bar)
            ? _bar
            : valid.first;
    setState(() {
      _range = label;
      _bar = b;
    });
    final rng = _ranges[label]!, iv = _intervals[b]!;
    try {
      final r = await http.get(
        Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/'
            '${widget.company.nseSymbol}.NS?range=$rng&interval=$iv&events=div,splits'),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 10));
      if (!mounted || r.statusCode != 200) return;
      final q = Quote.fromChartJson(jsonDecode(r.body));
      var bars = barsOf(q);
      if (label == '3Y' && bars.t.isNotEmpty) {
        // every series trimmed together — the old code trimmed closes only
        // and CANDLE silently fell back to a line on 3Y
        final cutoff = DateTime.now().subtract(const Duration(days: 3 * 365));
        final from = bars.t.indexWhere((t) => t.isAfter(cutoff));
        if (from > 0) bars = sliceBars(bars, from);
      }
      if (mounted && _range == label && _bar == b && bars.c.isNotEmpty) {
        setState(() => _bars = bars);
      }
    } catch (_) {} // pill just keeps the old chart; retap retries
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
    sb
        .from('analysis_requests')
        .insert({'symbol': sym}).then((_) {}, onError: (_) {});
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
            if (_range == '1M' && _bar == 'D') _bars = barsOf(q);
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
    sb.from('market_blobs').select('key,payload').inFilter('key',
        ['results_calendar', 'bulk_deals', 'insider_trades']).then((rows) {
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
      _loadAlertCount();
    }
  }

  void _loadAlertCount() {
    loadAlerts(symbol: widget.company.nseSymbol).then((a) {
      if (mounted) setState(() => _alertCount = a.where((x) => x.active).length);
    }).catchError((_) {});
  }

  Future<void> _openAlerts() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: bg,
      shape: const RoundedRectangleBorder(),
      isScrollControlled: true,
      builder: (_) => AlertSheet(widget.company.nseSymbol,
          tick: ticks.value[widget.company.nseSymbol]),
    );
    _loadAlertCount();
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

  /// Classic pivot / S1 / R1 from the last session of the 1M daily quote —
  /// the same numbers TECHNICALS prints, so the chart never contradicts it.
  List<(String, double)> _pivotLines(Quote q) {
    if (q.highs.isEmpty || q.lows.isEmpty || q.closes.isEmpty) return const [];
    final p = pivots(q.highs.last, q.lows.last, q.closes.last)['Classic'];
    if (p == null) return const [];
    return [
      for (final k in const ['R1', 'P', 'S1'])
        if (p[k] != null) (k, p[k]!)
    ];
  }

  List<Widget> _priceHeader() {
    final q = _quote;
    final up = q != null && q.price >= q.prevClose;
    final delta = q == null ? '' : (q.price - q.prevClose).toStringAsFixed(2);
    final pct = q == null || q.prevClose == 0
        ? ''
        : ((q.price - q.prevClose) / q.prevClose * 100).toStringAsFixed(2);
    final screener = remoteConfig.screenerPageEnabled;
    final bars = screener && _bars != null ? _bars! : (q == null ? null : barsOf(q));
    final closes = bars?.c ?? const <double>[];
    final pe = _showPe && _fund.quarter.length >= 4 && bars != null
        ? peSeries(closes, bars.t, _fund.quarter)
        : null;
    final peLatest =
        pe?.reversed.firstWhere((v) => v != null, orElse: () => null);
    final meta = _meta;
    final f = (meta['f'] as Map?)?.cast<String, dynamic>() ?? const {};
    final sectorLine =
        [f['sector'], f['industry']].whereType<String>().join(' · ');
    final intraday = _intraday;
    final volLine = q == null
        ? null
        : [
            if (q.volume != null) 'Vol ${fmtNum(q.volume!, decimals: 0)}',
            if (q.asOf != null)
              '${fmtDay(q.asOf!.toIso8601String())} ${hhmmIst(q.asOf!)}',
          ].join(' · ');
    final card = finScore(meta, sa: _sa, summary: _fund.summary);
    return [
      Row(children: [
        Text(widget.company.nseSymbol, style: mono.copyWith(fontSize: 12)),
        if (card != null) ...[
          const SizedBox(width: 8),
          filterPill('SCORE ${card.score}', false, _scoreColor(card.score),
              () => _tracker.jump('insights'),
              fontSize: 9),
        ],
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
        if (volLine != null && volLine.isNotEmpty)
          Text(volLine, style: mono.copyWith(fontSize: 10, color: inkDim)),
        const SizedBox(height: 12),
        if (bars != null && bars.c.length >= 2)
          PriceChart(bars,
              layers: _layers,
              baseline: intraday ? q.prevClose : null,
              pivots: _pivotLines(q),
              dividendDates: [for (final d in q.dividends) d.date],
              secondary: pe,
              intraday: intraday,
              height: 180 +
                  44.0 * [ChartLayer.vol, ChartLayer.rsi, ChartLayer.macd].where(_layers.contains).length)
        else
          const SizedBox(height: 140),
        const SizedBox(height: 10),
        if (peLatest != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
                'P/E ${peLatest.toStringAsFixed(1)} · TTM, quarter-end steps',
                style: mono.copyWith(fontSize: 10, color: amber)),
          ),
        if (screener)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
              for (final label in _ranges.keys)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: filterPill(
                      label, _range == label, green, () => _fetchRange(label),
                      fontSize: 10),
                ),
              const SizedBox(width: 6),
              for (final b in _barsFor(_range))
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: filterPill(b, _bar == b, amber,
                      () => _fetchRange(_range, bar: b),
                      fontSize: 10),
                ),
            ])),
          ),
        if (screener)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
              for (final l in ChartLayer.values)
                if (l != ChartLayer.vwap || intraday)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: filterPill(chartLayerLabel[l]!, _layers.contains(l),
                        l == ChartLayer.candle ? amber : green, () => _toggleLayer(l),
                        fontSize: 9),
                  ),
              if (_fund.quarter.length >= 4)
                filterPill('P/E', _showPe, amber,
                    () => setState(() => _showPe = !_showPe),
                    fontSize: 9),
            ])),
          ),
        Text(
            '${intraday ? 'dotted = previous close · ' : ''}drag to pan · pinch to zoom · hold for values · double-tap resets · Delayed price · Yahoo Finance',
            style: mono.copyWith(fontSize: 10)),
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
        builder: (_, m, __) => build(withScreenerTech(
            m[widget.company.nseSymbol]?.meta ?? const {},
            _sa,
            _quote?.price ?? m[widget.company.nseSymbol]?.price)),
      );

  Widget _stamp(String s) => Text(s, style: mono.copyWith(fontSize: 10));

  /// A Moneycontrol L→H range: the bar, then low · position · high under it.
  List<Widget> _range3(String label, double lo, double hi, double v,
      {List<(double, String)> marks = const []}) {
    if (hi <= lo) return const [];
    return [
      const SizedBox(height: 10),
      Text(label, style: monoLabel),
      const SizedBox(height: 6),
      ScaleBar(v, min: lo, max: hi, marks: marks),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('L  ₹${fmtNum(lo)}', style: mono.copyWith(fontSize: 10, color: red)),
        Text('at ${((v - lo) / (hi - lo) * 100).clamp(0, 100).round()}%',
            style: mono.copyWith(fontSize: 10)),
        Text('₹${fmtNum(hi)}  H',
            style: mono.copyWith(fontSize: 10, color: green)),
      ]),
    ];
  }

  /// OVERVIEW (Phase 2, MC's Overview tab): the day, the ranges, key stats
  /// with verdicts, the returns block, the street.
  Widget _overview() => _onTicks((meta) {
        final q = _quote;
        final t = (meta['t'] as Map?)?.cast<String, dynamic>() ?? const {};
        final sma50 = (t['sma50'] as num?)?.toDouble();
        final sma200 = (t['sma200'] as num?)?.toDouble();
        final sa = (_sa['sa'] as Map?)?.cast<String, dynamic>() ?? const {};
        final avgVol = (_sa['avg_vol'] as num?)?.toDouble();
        final tapeD = ((_sa['tape'] as Map?)?['d'] as List?)?.firstOrNull as Map?;
        final day = q == null
            ? const <Widget>[]
            : [
                if (q.open != null) StatTile('Open', '₹${fmtNum(q.open!)}'),
                StatTile('Prev close', '₹${fmtNum(q.prevClose)}'),
                if (q.dayHigh != null)
                  StatTile('Day high', '₹${fmtNum(q.dayHigh!)}'),
                if (q.dayLow != null) StatTile('Day low', '₹${fmtNum(q.dayLow!)}'),
                if (q.volume != null)
                  StatTile('Volume', fmtNum(q.volume!, decimals: 0),
                      sub: avgVol == null
                          ? null
                          : '${(q.volume! / avgVol).toStringAsFixed(1)}× avg'),
                if (avgVol != null)
                  StatTile('Avg volume', fmtNum(avgVol, decimals: 0),
                      sub: '20-day'),
                if (tapeD?['vwap'] is num)
                  StatTile('VWAP', '₹${fmtNum((tapeD!['vwap'] as num).toDouble())}',
                      sub: 'NSE ${dmy(tapeD['date'])}'),
                if (tapeD?['turnover_cr'] is num)
                  StatTile('Turnover',
                      '₹${fmtNum((tapeD!['turnover_cr'] as num).toDouble(), decimals: 0)} Cr',
                      sub: '${fmtNum(((tapeD['trades'] as num?) ?? 0).toDouble(), decimals: 0)} trades'),
              ];
        final divs = _seasonQ?.dividends ?? const [];
        final ttmDiv = divs
            .where((d) => d.date.isAfter(DateTime.now().subtract(const Duration(days: 365))))
            .fold(0.0, (a, d) => a + d.amount);
        final stats = snapshotStats(meta,
            sectorPe: (_sa['sector_pe'] as num?)?.toDouble(),
            ath: (sa['allTimeHigh'] as num?)?.toDouble(),
            athPct: (_sa['ath_pct'] as num?)?.toDouble(),
            // 20 Sep review: Yahoo's yield read 3.1% for TCS vs MC's 5.23 — the
            // trailing-12-month dividends we already hold give MC's number.
            ttmDivYield: divs.isEmpty || q == null || q.price == 0 ? null : ttmDiv / q.price * 100,
            roeFallback: (_sa['roe'] as num?)?.toDouble());
        final returns = returnsGrid(_sa);
        final hasReturns = returns.any((r) => r.$2 != null);
        final street = streetStats(_sa);
        if (day.isEmpty && stats.isEmpty && !hasReturns && street.isEmpty) {
          return const SizedBox.shrink();
        }
        return LedgerSection('Overview',
            footnote:
                'Yahoo (delayed) · Stock Analysis (S&P Global) · sector = same-sector P/E',
            children: [
              if (day.isNotEmpty) ...[
                const SizedBox(height: 10),
                StatGrid(day),
              ],
              if (q != null && q.dayHigh != null && q.dayLow != null)
                ..._range3('DAY RANGE', q.dayLow!, q.dayHigh!, q.price),
              if (q != null)
                ..._range3('52-WEEK RANGE', q.low52, q.high52, q.price, marks: [
                  if (sma50 != null) (sma50, '50D'),
                  if (sma200 != null) (sma200, '200D'),
                ]),
              if (stats.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('KEY STATS', style: monoLabel),
                const SizedBox(height: 6),
                StatGrid([
                  for (final s in stats)
                    StatTile(s.label, s.value,
                        sub: s.sub,
                        color: s.tone == 0 ? null : KvTable.toneColor(s.tone)),
                ]),
              ],
              if (hasReturns) ...[
                const SizedBox(height: 14),
                Text('RETURNS', style: monoLabel),
                const SizedBox(height: 6),
                for (var i = 0; i < returns.length; i += 3)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      for (var j = i; j < i + 3 && j < returns.length; j++) ...[
                        if (j > i) const SizedBox(width: 6),
                        Expanded(
                          child: HeatCell(returns[j].$1, returns[j].$2,
                              scale: 20,
                              height: 48,
                              pctText: returns[j].$2 == null
                                  ? '—'
                                  : fmtPct(returns[j].$2, decimals: 1)),
                        ),
                      ],
                    ]),
                  ),
              ],
              if (street.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('ANALYSTS', style: monoLabel),
                const SizedBox(height: 6),
                StatGrid([
                  for (final s in street)
                    StatTile(s.label, s.value,
                        sub: s.sub,
                        color: s.tone == 0 ? null : KvTable.toneColor(s.tone)),
                ], columns: 2),
              ],
            ]);
      });

  /// INSIGHTS (Phase 3): the FinFlick score with its parts, SWOT, essentials.
  Widget _insights() => _onTicks((meta) {
        final card = finScore(meta, sa: _sa, summary: _fund.summary);
        final sw = swot(meta, sa: _sa, summary: _fund.summary);
        final ess = essentials(meta, sa: _sa, summary: _fund.summary);
        final measured = ess.where((e) => e.$2 != null).toList();
        final passed = measured.where((e) => e.$2 == true).length;
        final list = switch (_swotTab) {
          'w' => sw.w,
          'o' => sw.o,
          't' => sw.t,
          _ => sw.s,
        };
        if (card == null && sw.s.isEmpty && sw.w.isEmpty && measured.isEmpty) {
          return const SizedBox.shrink();
        }
        return LedgerSection('Insights',
            footnote:
                'FinFlick score = strength 30 · growth 25 · valuation 25 · trend 20, scaled to what is measurable · not advice',
            children: [
              if (card != null) ...[
                const SizedBox(height: 10),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${card.score}',
                      style: serif.copyWith(
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          color: _scoreColor(card.score))),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6, left: 4),
                    child: Text('/100',
                        style: mono.copyWith(fontSize: 12, color: inkDim)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child:
                          Text(card.verdict, style: serif.copyWith(fontSize: 14)),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                ScaleBar(card.score.toDouble(), zones: const [
                  (0, 40, red),
                  (40, 60, amber),
                  (60, 100, green)
                ]),
                for (final p in card.parts)
                  LedgerRow(
                      lead: p.label,
                      main: p.read,
                      trail: '${p.points}/${p.max}',
                      trailColor: _scoreColor((p.points / p.max * 100).round()),
                      bar: p.points / p.max,
                      barColor: _scoreColor((p.points / p.max * 100).round())),
              ],
              const SizedBox(height: 14),
              Text('SWOT', style: monoLabel),
              const SizedBox(height: 6),
              pillRow([
                for (final (k, label, n, tint) in [
                  ('s', 'STRENGTHS', sw.s.length, green),
                  ('w', 'WEAKNESSES', sw.w.length, red),
                  ('o', 'OPPORTUNITIES', sw.o.length, green),
                  ('t', 'THREATS', sw.t.length, amber),
                ])
                  filterPill('$label ($n)', _swotTab == k, tint,
                      () => setState(() => _swotTab = k),
                      fontSize: 9),
              ]),
              const SizedBox(height: 8),
              if (list.isEmpty)
                Text('nothing flagged',
                    style: mono.copyWith(fontSize: 12, color: inkDim))
              else
                for (final line in list)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('•  ',
                              style: serif.copyWith(fontSize: 13, color: inkDim)),
                          Expanded(
                              child: Text(line,
                                  style: serif.copyWith(fontSize: 13))),
                        ]),
                  ),
              if (measured.isNotEmpty) ...[
                const SizedBox(height: 14),
                LedgerRow(
                    lead: 'ESSENTIALS',
                    main: '${measured.length} checks',
                    trail: '${(passed / measured.length * 100).round()}% pass',
                    trailColor:
                        _scoreColor((passed / measured.length * 100).round()),
                    bar: passed / measured.length,
                    barColor: green,
                    barTrack: red.withValues(alpha: 0.35)),
                for (final e in ess)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      SizedBox(
                        width: 18,
                        child: Text(
                            e.$2 == null
                                ? '·'
                                : e.$2!
                                    ? '✓'
                                    : '✗',
                            style: mono.copyWith(
                                fontSize: 12,
                                color: e.$2 == null
                                    ? inkDim
                                    : e.$2!
                                        ? green
                                        : red)),
                      ),
                      Expanded(
                          child: Text(e.$1,
                              style: mono.copyWith(
                                  fontSize: 11,
                                  color: e.$2 == null ? inkDim : ink))),
                    ]),
                  ),
              ],
            ]);
      });

  /// One MC-style vitals card: value box + verdict, zoned bar, plain read.
  List<Widget> _gauge(String title, double v,
      {required double min,
      required double max,
      required List<(double, double, Color)> zones,
      required String value,
      required String verdict,
      required Color tone,
      required String explain}) {
    return [
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: Text(title, style: monoLabel)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: surface, border: Border.all(color: border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(value,
                style: mono.copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
            Text(verdict, style: mono.copyWith(fontSize: 9, color: tone)),
          ]),
        ),
      ]),
      const SizedBox(height: 8),
      ScaleBar(v.clamp(min, max).toDouble(), min: min, max: max, zones: zones),
      const SizedBox(height: 4),
      Text(explain, style: mono.copyWith(fontSize: 10, height: 1.5)),
    ];
  }

  /// VITALS (Phase 3): Altman Z, Piotroski, Graham, DuPont.
  Widget _vitals() => _onTicks((meta) {
        final q = _quote;
        final annualRow = _fund.annual.values.lastOrNull;
        final zSa = (_sa['altman_z'] as num?)?.toDouble();
        final z = zSa ??
            (annualRow == null ? null : altmanZ(annualRow, (_sa['mcap_cr'] as num?)?.toDouble()));
        final fs = (_sa['f_score'] as num?)?.toDouble();
        final sa = (_sa['sa'] as Map?)?.cast<String, dynamic>() ?? const {};
        final graham = (sa['grahamNumber'] as num?)?.toDouble();
        final annual = _fund.annual.values.lastOrNull;
        final dp = annual == null ? null : dupont(annual);
        final peerRoe =
            sectorMedians(_peers, self: widget.company.nseSymbol)['roe'];
        final records = recordRows(_sa);
        final children = <Widget>[
          if (records.isNotEmpty) ...[
            Text('RECORDS', style: monoLabel),
            const SizedBox(height: 4),
            ...records,
            const SizedBox(height: 14),
          ],
          if (z != null)
            ..._gauge('ALTMAN Z-SCORE', z,
                min: 0,
                max: 8,
                zones: const [(0, 1.8, red), (1.8, 3, amber), (3, 8, green)],
                value: z.toStringAsFixed(2),
                verdict: z < 1.8
                    ? 'Distress zone'
                    : z < 3
                        ? 'Grey zone'
                        : 'Safe zone',
                tone: z < 1.8
                    ? red
                    : z < 3
                        ? amber
                        : green,
                explain:
                    'Bankruptcy-risk model from five balance-sheet ratios${zSa == null ? ', computed here from the latest annual report and market cap' : ''}. Above 3 the company has robust financial health and a low chance of distress; below 1.8 it is in the danger zone.'),
          if (fs != null)
            ..._gauge('PIOTROSKI F-SCORE', fs,
                min: 0,
                max: 9,
                zones: const [(0, 3, red), (3, 6, amber), (6, 9, green)],
                value: '${fs.round()}/9',
                verdict: fs >= 7
                    ? 'Strong'
                    : fs >= 4
                        ? 'Middling'
                        : 'Weak',
                tone: fs >= 7
                    ? green
                    : fs >= 4
                        ? amber
                        : red,
                explain:
                    'Nine yes/no accounting checks on profitability, leverage and efficiency. 7 or more is a strong business; 3 or less is a weak one.'),
          if (graham != null && graham > 0 && q != null)
            ..._gauge('GRAHAM NUMBER', q.price / graham,
                min: 0.5,
                max: 1.5,
                zones: const [
                  (0.5, 0.9, green),
                  (0.9, 1.1, amber),
                  (1.1, 1.5, red)
                ],
                value: '₹${fmtNum(graham, decimals: 0)}',
                verdict: q.price > graham ? 'Overvalued' : 'Undervalued',
                tone: q.price > graham * 1.1
                    ? red
                    : q.price < graham * 0.9
                        ? green
                        : amber,
                explain: q.price > graham
                    ? 'The stock trades ${((q.price / graham - 1) * 100).round()}% above its Graham number (√(22.5 × EPS × book value)), the most a defensive investor would pay: the market is pricing in more than the books show.'
                    : 'The stock trades ${((1 - q.price / graham) * 100).round()}% below its Graham number (√(22.5 × EPS × book value)), the most a defensive investor would pay.'),
          if (dp != null && dp.roe != null) ...[
            const SizedBox(height: 14),
            Text('DUPONT · ROE = MARGIN × TURNOVER × LEVERAGE', style: monoLabel),
            const SizedBox(height: 6),
            StatGrid([
              StatTile('Net margin', '${dp.npm!.toStringAsFixed(1)}%',
                  sub: 'profit / sales'),
              StatTile('Asset turnover', '${dp.at!.toStringAsFixed(2)}×',
                  sub: 'sales / assets'),
              StatTile('Leverage', '${dp.em!.toStringAsFixed(2)}×',
                  sub: 'assets / equity'),
            ]),
            const SizedBox(height: 6),
            LedgerRow(
                lead: 'ROE',
                main: peerRoe == null
                    ? 'from the latest annual report'
                    : 'peers\' median ${peerRoe.toStringAsFixed(1)}%',
                trail: '${dp.roe!.toStringAsFixed(1)}%',
                trailColor: peerRoe == null
                    ? ink
                    : dp.roe! >= peerRoe
                        ? green
                        : red),
          ],
        ];
        if (children.isEmpty) return const SizedBox.shrink();
        return LedgerSection('Vitals',
            footnote:
                'Altman Z, Piotroski, Graham: Stock Analysis (S&P Global) · DuPont: latest annual report · peers by industry',
            children: children);
      });

  /// DELIVERY (Phase 4): volume vs delivered quantity, MC's four rows, from
  /// the NSE full bhavcopy the pipeline keeps for 22 sessions.
  Widget _delivery() {
    final tape = (_sa['tape'] as Map?)?.cast<String, dynamic>();
    final bse = (_sa['tape_bse'] as Map?)?.cast<String, dynamic>();
    final mode = bse == null ? 'nse' : _delivMode;
    final rows = deliveryRows(tape, bse: bse, mode: mode);
    if (rows.isEmpty) return const SizedBox.shrink();
    return LedgerSection('Delivery & volume',
        action: _stamp('${mode == 'bse' ? 'BSE' : mode == 'combined' ? 'NSE + BSE' : 'NSE'} · ${dmy((mode == 'bse' ? bse : tape)!['asof'])}'),
        footnote:
            'delivered = shares that changed hands for keeps, not intraday · a rising delivery % on a move is conviction · BSE joined by ISIN',
        children: [
          if (bse != null) ...[
            const SizedBox(height: 8),
            pillRow([
              for (final (k, label) in const [('combined', 'COMBINED'), ('nse', 'NSE'), ('bse', 'BSE')])
                filterPill(label, mode == k, green, () => setState(() => _delivMode = k), fontSize: 9),
            ]),
          ],
          const SizedBox(height: 8),
          for (final r in rows) ...[
            LedgerRow(
                lead: r.label,
                main:
                    'vol ${fmtNum(r.vol, decimals: 0)} · delivered ${fmtNum(r.deliv, decimals: 0)}',
                trail: '${r.pct.toStringAsFixed(1)}%',
                trailColor: r.pct >= 50 ? green : ink),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PairedBar(r.vol, r.deliv, colorA: inkDim, colorB: green),
            ),
          ],
        ]);
  }

  /// F&O (Phase 4): the futures ladder and the nearest-expiry chain around
  /// the underlying, from the NSE F&O bhavcopy.
  Widget _fno() {
    final f = (_sa['fno'] as Map?)?.cast<String, dynamic>();
    if (f == null) return const SizedBox.shrink();
    final futures = [
      for (final x in (f['futures'] as List? ?? const []))
        Map<String, dynamic>.from(x as Map)
    ];
    final chain = [
      for (final x in (f['chain'] as List? ?? const []))
        Map<String, dynamic>.from(x as Map)
    ];
    final pcr = (f['pcr'] as num?)?.toDouble();
    final und = (f['underlying'] as num?)?.toDouble();
    String n0(Object? v) => v is num ? fmtNum(v.toDouble(), decimals: 0) : '—';
    String signed(Object? v) => v is num
        ? '${v >= 0 ? '+' : '−'}${fmtNum(v.abs().toDouble(), decimals: 0)}'
        : '—';
    return LedgerSection('F&O',
        action: _stamp('NSE · ${dmy(f['asof'])}'),
        footnote:
            'end-of-day · OI = open interest, contracts · lot ${n0(futures.firstOrNull?['lot'])} · PCR = put OI ÷ call OI',
        children: [
          if (futures.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('FUTURES', style: monoLabel),
            const SizedBox(height: 6),
            LedgerTable(const [
              LtCol('Expiry', right: false),
              LtCol('Close ₹'),
              LtCol('Chg'),
              LtCol('OI'),
              LtCol('Δ OI'),
              LtCol('Volume'),
            ], [
              for (final x in futures)
                (
                  cells: [
                    dmy(x['expiry']),
                    fmtNum(((x['close'] as num?) ?? 0).toDouble()),
                    fmtPct((x['chg_pct'] as num?)?.toDouble()),
                    n0(x['oi']),
                    signed(x['oi_chg']),
                    n0(x['vol']),
                  ],
                  tone: ((x['chg_pct'] as num?) ?? 0) >= 0 ? 1 : -1,
                  onTap: null,
                ),
            ], toneCol: 2),
          ],
          if (pcr != null) ...[
            const SizedBox(height: 14),
            Text('OPTIONS · ${dmy(f['expiry'])}', style: monoLabel),
            const SizedBox(height: 6),
            StatGrid([
              StatTile('PCR', pcr.toStringAsFixed(2),
                  color: pcr >= 1 ? green : red,
                  sub: pcr >= 1 ? 'puts lead' : 'calls lead'),
              StatTile('Max call OI', '₹${n0(f['max_ce'])}', sub: 'resistance'),
              StatTile('Max put OI', '₹${n0(f['max_pe'])}', sub: 'support'),
              StatTile('Call OI', n0(f['ce_oi'])),
              StatTile('Put OI', n0(f['pe_oi'])),
              if (und != null) StatTile('Underlying', '₹${fmtNum(und)}'),
            ]),
            if (chain.isNotEmpty) ...[
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
                for (final s in chain)
                  (
                    cells: [
                      n0(s['ce_oi']),
                      signed(s['ce_oi_chg']),
                      s['ce_ltp'] is num
                          ? fmtNum((s['ce_ltp'] as num).toDouble())
                          : '—',
                      n0(s['strike']),
                      s['pe_ltp'] is num
                          ? fmtNum((s['pe_ltp'] as num).toDouble())
                          : '—',
                      signed(s['pe_oi_chg']),
                      n0(s['pe_oi']),
                    ],
                    tone: und != null && (s['strike'] as num) >= und ? 1 : -1,
                    onTap: null,
                  ),
              ], toneCol: 3),
            ],
          ],
        ]);
  }

  /// ACTIONS (Phase 4): dividend and split history from Yahoo's events on
  /// the monthly chart call. Bonus / rights need an NSE source (not wired).
  Widget _actions() {
    final q = _seasonQ;
    if (q == null || (q.dividends.isEmpty && q.splits.isEmpty)) {
      return const SizedBox.shrink();
    }
    final year = DateTime.now().year;
    final ttm = q.dividends
        .where((d) => d.date.isAfter(DateTime.now().subtract(const Duration(days: 365))))
        .fold(0.0, (a, d) => a + d.amount);
    return LedgerSection('Corporate actions',
        action: _stamp('Yahoo · per share'),
        footnote:
            'dividends by ex-date · splits by effective date · bonus and rights: source not wired yet',
        children: [
          const SizedBox(height: 8),
          if (q.dividends.isNotEmpty) ...[
            LedgerRow(
                lead: 'DIVIDENDS',
                main: '${q.dividends.length} paid on record',
                trail: 'TTM ₹${fmtNum(ttm)}',
                trailColor: green),
            LedgerTable(const [
              LtCol('Ex-date', right: false),
              LtCol('₹ / share'),
              LtCol('Year'),
            ], [
              for (final d in q.dividends)
                (
                  cells: [
                    dmy(d.date.toIso8601String()),
                    fmtNum(d.amount),
                    '${d.date.year}',
                  ],
                  tone: d.date.year == year ? 1 : 0,
                  onTap: null,
                ),
            ], initial: 8),
          ],
          if (q.splits.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('SPLITS & BONUSES (AS RATIOS)', style: monoLabel),
            const SizedBox(height: 6),
            for (final s in q.splits)
              LedgerRow(
                  lead: dmy(s.date.toIso8601String()),
                  main: 'ratio ${s.ratio}',
                  trail: '${s.date.year}'),
          ],
        ]);
  }

  /// SEASONALITY (Phase 3): year × month returns from the monthly chart.
  Widget _seasonality() {
    final sq = _seasonQ;
    final s = sq == null ? null : seasonality(sq.closes, sq.times);
    if (s == null) return const SizedBox.shrink();
    final m = DateTime.now().month;
    final ms = monthStats(s, m);
    final name = monthAbbr[m - 1];
    Widget cell(double? v, {double width = 50}) => SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.all(1.5),
          child: HeatCell('', v,
              scale: 10,
              height: 30,
              pctText: v == null ? '—' : fmtPct(v, decimals: 1)),
        ));
    Widget lead(String t) => SizedBox(
        width: 44,
        child: Text(t, style: mono.copyWith(fontSize: 10, color: inkDim)));
    return LedgerSection('Seasonality',
        action: _stamp('${s.years.length} years'),
        footnote:
            'month-on-month close · Yahoo monthly · the current month is month-to-date',
        children: [
          const SizedBox(height: 8),
          if (ms.years > 0)
            Text(
                '${ms.negative} of ${ms.years} years ${widget.company.nseSymbol} gave a negative return in $name.',
                style: serif.copyWith(fontSize: 14, height: 1.4)),
          const SizedBox(height: 8),
          if (ms.years > 0)
            StatGrid([
              if (ms.best != null)
                StatTile('Best $name', fmtPct(ms.best!.$2, decimals: 1),
                    sub: '${ms.best!.$1}', color: green),
              if (ms.worst != null)
                StatTile('Worst $name', fmtPct(ms.worst!.$2, decimals: 1),
                    sub: '${ms.worst!.$1}', color: red),
              if (ms.avg != null)
                StatTile('Average $name', fmtPct(ms.avg!, decimals: 1),
                    sub: [
                      if (ms.avgPos != null) 'up ${fmtPct(ms.avgPos!, decimals: 1)}',
                      if (ms.avgNeg != null) 'down ${fmtPct(ms.avgNeg!, decimals: 1)}',
                    ].join(' · ')),
            ]),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                lead('YEAR'),
                for (final mo in monthAbbr)
                  SizedBox(
                      width: 50,
                      child: Text(mo.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: mono.copyWith(fontSize: 9, color: inkDim))),
              ]),
              Row(children: [
                lead('AVG'),
                for (final v in s.avg) cell(v),
              ]),
              for (final y in s.years)
                Row(children: [
                  lead('$y'),
                  for (var mo = 1; mo <= 12; mo++) cell(s.table[y]![mo]),
                ]),
              Row(children: [
                lead('UP %'),
                for (final v in s.posPct)
                  SizedBox(
                      width: 50,
                      child: Text(v == null ? '—' : '${v.round()}%',
                          textAlign: TextAlign.center,
                          style: mono.copyWith(
                              fontSize: 9,
                              color: v == null
                                  ? inkDim
                                  : v >= 50
                                      ? green
                                      : red))),
              ]),
            ]),
          ),
        ]);
  }

  /// FORECAST (Phase 6, MC's Forecast tab): target ladder, EPS / revenue
  /// estimates, consensus by month, hits / misses — Yahoo quoteSummary.
  Widget _forecast() => _onTicks((meta) {
        final f = (meta['f'] as Map?)?.cast<String, dynamic>() ?? const {};
        final st = (f['street'] as Map?)?.cast<String, dynamic>();
        final q = _quote;
        if (st == null) return const SizedBox.shrink();
        final target = (st['target'] as Map?)?.cast<String, dynamic>() ?? const {};
        final est = [for (final e in (st['est'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
        final trend = [for (final t in (st['trend'] as List? ?? const [])) Map<String, dynamic>.from(t as Map)];
        final hist = [for (final h in (st['hist'] as List? ?? const [])) Map<String, dynamic>.from(h as Map)]
          ..sort((a, b) => '${b['q']}'.compareTo('${a['q']}'));
        final hm = hitsMisses(hist);
        double? tn(String k) => (target[k] as num?)?.toDouble();
        final lo = tn('lo'), hi = tn('hi'), mean = tn('mean');
        String n0(Object? v) => v is num ? fmtNum(v.toDouble(), decimals: 0) : '—';
        String n2(Object? v) => v is num ? v.toDouble().toStringAsFixed(2) : '—';
        const monthLabel = {'0m': 'This month', '-1m': '1 month ago', '-2m': '2 months ago', '-3m': '3 months ago'};
        return LedgerSection('Forecast',
            action: _stamp('as of ${fmtDay(meta['f_at'])}'),
            footnote:
                'Yahoo Finance consensus · EPS in ₹, revenue in ₹ Cr · beat / miss = surprise beyond ±2% · not advice',
            children: [
              if (lo != null && hi != null && mean != null && q != null) ...[
                const SizedBox(height: 8),
                Text('PRICE TARGETS · ${n0(target['n'])} ANALYSTS', style: monoLabel),
                const SizedBox(height: 6),
                StatGrid([
                  StatTile('Low', '₹${n0(lo)}', color: red),
                  StatTile('Mean', '₹${n0(mean)}',
                      sub: '${fmtPct((mean / q.price - 1) * 100, decimals: 1)} vs price',
                      color: mean >= q.price ? green : red),
                  StatTile('High', '₹${n0(hi)}', color: green),
                ]),
                const SizedBox(height: 8),
                ScaleBar(q.price,
                    min: lo < q.price ? lo : q.price,
                    max: hi > q.price ? hi : q.price,
                    zones: [(lo, mean, red), (mean, hi, green)],
                    marks: [(mean, 'mean')]),
                Text('marker = current price ₹${fmtNum(q.price)}', style: mono.copyWith(fontSize: 10)),
              ],
              if (est.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('ESTIMATES', style: monoLabel),
                const SizedBox(height: 6),
                LedgerTable(const [
                  LtCol('Period', right: false),
                  LtCol('EPS avg'),
                  LtCol('EPS low'),
                  LtCol('EPS high'),
                  LtCol('Revenue ₹Cr'),
                  LtCol('Growth'),
                  LtCol('Analysts'),
                ], [
                  for (final e in est)
                    (
                      cells: [
                        estimateLabel(e),
                        n2(e['eps']),
                        n2(e['eps_lo']),
                        n2(e['eps_hi']),
                        n0(e['rev_cr']),
                        e['growth'] is num ? fmtPct((e['growth'] as num).toDouble() * 100, decimals: 1) : '—',
                        n0(e['eps_n'] ?? e['rev_n']),
                      ],
                      tone: 0,
                      onTap: null,
                    ),
                ]),
              ],
              if (trend.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('CONSENSUS · ANALYST COUNT BY GRADE', style: monoLabel),
                const SizedBox(height: 6),
                for (final t in trend) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 3),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text(monthLabel[t['period']] ?? '${t['period']}', style: mono.copyWith(fontSize: 10, color: inkDim)),
                      Text('${[for (final k in const ['sb', 'b', 'h', 's', 'ss']) (t[k] as num?) ?? 0].fold<num>(0, (a, b) => a + b)} analysts',
                          style: mono.copyWith(fontSize: 10, color: inkDim)),
                    ]),
                  ),
                  StackedBar([
                    for (final (k, label, c) in [
                      ('sb', 'Strong buy', green),
                      ('b', 'Buy', green.withValues(alpha: 0.6)),
                      ('h', 'Hold', inkDim),
                      ('s', 'Sell', red.withValues(alpha: 0.6)),
                      ('ss', 'Strong sell', red),
                    ])
                      if (((t[k] as num?) ?? 0) > 0)
                        ((t[k] as num).toDouble(), c, '$label ${t[k]}')
                  ]),
                ],
              ],
              if (hist.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('HITS & MISSES · EPS', style: monoLabel),
                const SizedBox(height: 6),
                StatGrid([
                  StatTile('Beats', '${hm.beats}', color: green),
                  StatTile('Misses', '${hm.misses}', color: red),
                  StatTile('In line', '${hm.inline}'),
                ]),
                const SizedBox(height: 8),
                LedgerTable(const [
                  LtCol('Quarter', right: false),
                  LtCol('Actual'),
                  LtCol('Estimate'),
                  LtCol('Surprise'),
                ], [
                  for (final h in hist)
                    (
                      cells: [
                        dmy(h['q']),
                        n2(h['actual']),
                        n2(h['est']),
                        h['surprise'] is num ? fmtPct((h['surprise'] as num).toDouble(), decimals: 1) : '—',
                      ],
                      tone: ((h['surprise'] as num?) ?? 0) > 2
                          ? 1
                          : ((h['surprise'] as num?) ?? 0) < -2
                              ? -1
                              : 0,
                      onTap: null,
                    ),
                ]),
              ],
            ]);
      });

  /// RESEARCH: MC's broker cards. Yahoo's upgrade / downgrade history is empty
  /// for NSE listings (probed 20 Sep) — "coming" until a source is found.
  Widget _research() => LedgerSection('Research',
          footnote: 'broker recommendations · source not wired yet',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                  'Coming. No keyless feed of Indian broker reports has passed a terms check yet; the consensus above is the aggregate view.',
                  style: mono.copyWith(fontSize: 12, height: 1.5, color: inkDim)),
            ),
          ]);

  /// FUNDAMENTALS: the full labelled table against sector medians, then the
  /// eight-quarter sales/profit bars.
  Widget _fundamentals() => _onTicks((meta) {
        final medians = sectorMedians(_peers, self: widget.company.nseSymbol);
        final rows =
            fundamentalRows(meta, medians: medians, summary: _fund.summary);
        if (rows.isEmpty) return const SizedBox.shrink();
        final qs = quarterSeries(_fund.quarter, meta, label: periodLabel);
        final hasBars = qs.sales.any((v) => v != null);
        final nPeers =
            _peers.where((p) => p['symbol'] != widget.company.nseSymbol).length;
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
                  Text(' net profit   (₹ Cr)',
                      style: mono.copyWith(fontSize: 10)),
                ]),
                const SizedBox(height: 6),
                SizedBox(
                    height: 84,
                    child: BarChart(qs.sales,
                        secondary: qs.profit, labels: qs.labels)),
              ],
            ]);
      });

  /// TECHNICALS: three one-word tiles, the MA read, every level against the
  /// close, then pivot levels from the last session (Phase 3).
  Widget _technicals() => _onTicks((meta) {
        final tiles = techStats(meta);
        final q = _quote;
        final rows = technicalRows(meta,
            hi52: q != null && q.high52 > 0 ? q.high52 : null,
            lo52: q != null && q.low52 > 0 ? q.low52 : null);
        final ma = maSignals(meta);
        final pv = q != null && q.highs.isNotEmpty && q.lows.isNotEmpty
            ? pivots(q.highs.last, q.lows.last, q.closes.last)
            : null;
        if (tiles.isEmpty && rows.isEmpty && pv == null) {
          return const SizedBox.shrink();
        }
        return LedgerSection('Technicals',
            action: _stamp((meta['t'] as Map?)?['src'] == 'screener' ? 'screener averages' : '1y daily closes'),
            footnote: (meta['t'] as Map?)?['src'] == 'screener'
                ? '50 & 200-day averages and RSI from Stock Analysis · the pipeline computes the full set on first open · pivots from the last session'
                : 'computed from 1y daily closes · as of ${fmtDay(meta['t_at'])} · pivots from the last session',
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
              if (ma.above.isNotEmpty) ...[
                LedgerRow(
                    lead: 'MOVING AVERAGES',
                    main: [
                      for (final a in ma.above) '${a.$2 ? '▲' : '▼'} ${a.$1}'
                    ].join('  '),
                    trail: '${ma.bull}▲ ${ma.bear}▼',
                    trailColor: ma.bull >= ma.bear ? green : red,
                    bar: ma.bull + ma.bear == 0
                        ? 0
                        : ma.bull / (ma.bull + ma.bear),
                    barColor: green,
                    barTrack: red.withValues(alpha: 0.35)),
                if (ma.crossover != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 10),
                    child: Text(ma.crossover!,
                        style: mono.copyWith(
                            fontSize: 11,
                            color: ma.crossover!.startsWith('Golden')
                                ? green
                                : red)),
                  ),
              ],
              if (rows.isNotEmpty)
                KvTable(const ['INDICATOR', 'LEVEL', 'VS PRICE', 'SIGNAL'], rows),
              if (pv != null) ...[
                const SizedBox(height: 14),
                Text('PIVOT LEVELS', style: monoLabel),
                const SizedBox(height: 6),
                LedgerTable(const [
                  LtCol('Level', right: false),
                  LtCol('Classic'),
                  LtCol('Fibonacci'),
                  LtCol('Camarilla'),
                ], [
                  for (final lvl in const ['R3', 'R2', 'R1', 'P', 'S1', 'S2', 'S3'])
                    (
                      cells: [
                        lvl,
                        for (final m in const ['Classic', 'Fibonacci', 'Camarilla'])
                          fmtNum(pv[m]![lvl]!, decimals: 2),
                      ],
                      tone: lvl.startsWith('R')
                          ? 1
                          : lvl.startsWith('S')
                              ? -1
                              : 0,
                      onTap: null,
                    ),
                ], toneCol: 0),
                const SizedBox(height: 4),
                Text(
                    'last session H ₹${fmtNum(q!.highs.last)} · L ₹${fmtNum(q.lows.last)} · C ₹${fmtNum(q.closes.last)}',
                    style: mono.copyWith(fontSize: 10)),
              ],
            ]);
      });

  /// RETURNS: the Stock Analysis columns of this symbol's screener_metrics
  /// row — returns ladder, records, risk, street view, fair values, dates.
  Widget _returns() => LedgerSection('Risk & street',
          action: _stamp('as of ${dmy(_sa['sa_price_date'])}'),
          footnote: 'Risk, fair values and calendar: Stock Analysis (S&P Global)',
          children: [
            const SizedBox(height: 2),
            KvTable(const ['METRIC', 'VALUE', '', 'READ'], saRows(_sa)),
          ]);

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
                : Text('No tagged stories yet',
                    style: mono.copyWith(fontSize: 13)),
          ),
        for (final s in _stories)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: s.imageUrl == null
                ? null
                : ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      width: 64,
                      height: 48,
                      child: Image.network(s.imageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const ColoredBox(color: surface)),
                    ),
                  ),
            title: Text(s.hook ?? s.headline,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: ink, fontWeight: FontWeight.w600)),
            subtitle: Text(
                [s.sourceName, if (s.publishedAt != null) fmtDay(s.publishedAt!.toIso8601String())].join(' · '),
                style: mono.copyWith(fontSize: 11)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => StoryDetailScreen(storyId: s.id))),
          ),
      ]);

  /// One statement section: heading + HEAT pill + table, Screener order.
  Widget _table(
          String title,
          List<String> periods,
          List<(String, String, CellFmt)> rows,
          Map<String, Map<String, dynamic>> byPeriod,
          {List<Widget> lead = const [], String? note}) =>
      LedgerSection(title,
          action: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final (n, label) in const [(null, 'ALL'), (4, '4'), (2, '2')])
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: filterPill(label, _span == n, green,
                    () => setState(() => _span = n),
                    fontSize: 9),
              ),
            const SizedBox(width: 4),
            filterPill(
                'HEAT', _heat, amber, () => setState(() => _heat = !_heat),
                fontSize: 9),
          ]),
          footnote:
              '${note == null ? '' : '$note · '}₹ Cr · consolidated · ${_heat ? 'tint = change vs previous period · ' : ''}Yahoo Finance + NSE filings + backfill',
          children: [
            ...lead,
            const SizedBox(height: 4),
            StatementTable(
                periods: _span == null || periods.length <= _span!
                    ? periods
                    : periods.sublist(periods.length - _span!),
                rows: rows,
                byPeriod: byPeriod,
                heat: _heat),
          ]);

  /// EARNINGS (Phase 5, MC's Earnings tab): the latest quarter with YoY / QoQ.
  Widget _earnings() {
    final e = earningsRows(_fund.quarter);
    if (e == null || e.lines.isEmpty) return const SizedBox.shrink();
    final base = _yoy ? e.yearAgo : e.prevPeriod;
    return LedgerSection('Earnings',
        action: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (v, label) in const [(true, 'YOY'), (false, 'QOQ')])
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: filterPill(label, _yoy == v, green,
                  () => setState(() => _yoy = v),
                  fontSize: 9),
            ),
        ]),
        footnote:
            '₹ Cr, EPS in ₹ · ${_yoy ? 'YoY = vs the same quarter last year' : 'QoQ = vs the previous quarter'} · NSE filings + Yahoo',
        children: [
          const SizedBox(height: 8),
          LedgerRow(
              lead: 'LAST RESULTS',
              main: base == null
                  ? 'quarter ended ${periodLabel(e.period)}'
                  : 'quarter ended ${periodLabel(e.period)} · vs ${periodLabel(base)}',
              trail: periodLabel(e.period)),
          for (final l in e.lines)
            LedgerRow(
                lead: l.label,
                main: l.money
                    ? '₹${fmtNum(l.value, decimals: 0)} Cr'
                    : '₹${l.value.toStringAsFixed(2)}',
                trail: fmtPct(_yoy ? l.yoy : l.qoq, decimals: 1).isEmpty
                    ? '—'
                    : fmtPct(_yoy ? l.yoy : l.qoq, decimals: 1),
                trailColor: ((_yoy ? l.yoy : l.qoq) ?? 0) >= 0 ? green : red),
        ]);
  }

  /// INFO (Phase 5): company facts. Directors and address need the Yahoo
  /// profile parse (Phase 6) — not wired yet.
  Widget _info() => _onTicks((meta) {
        final rows = infoRows(meta, _sa);
        final f = (meta['f'] as Map?)?.cast<String, dynamic>() ?? const {};
        final pr = (f['profile'] as Map?)?.cast<String, dynamic>() ?? const {};
        final officers = [for (final o in (pr['officers'] as List? ?? const [])) Map<String, dynamic>.from(o as Map)];
        if (rows.isEmpty && pr.isEmpty) return const SizedBox.shrink();
        return LedgerSection('Info & management',
            footnote: 'Stock Analysis + Yahoo Finance profile',
            children: [
              if (pr['summary'] != null) ...[
                const SizedBox(height: 8),
                Text('${pr['summary']}', style: serif.copyWith(fontSize: 13, height: 1.45)),
              ],
              const SizedBox(height: 6),
              for (final (k, v) in rows)
                k == 'Website'
                    ? InkWell(
                        onTap: () => openExternal(
                            context, v.startsWith('http') ? v : 'https://$v'),
                        child: LedgerRow(lead: k, main: '', trail: v, trailColor: green),
                      )
                    : LedgerRow(lead: k, main: '', trail: v),
              if (officers.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('MANAGEMENT', style: monoLabel),
                const SizedBox(height: 4),
                for (final o in officers)
                  LedgerRow(
                      lead: '${o['name']}',
                      main: '${o['title'] ?? ''}',
                      trail: o['age'] == null ? '' : '${o['age']}'),
              ],
              if (pr['address'] != null || pr['phone'] != null) ...[
                const SizedBox(height: 12),
                Text('REGISTERED OFFICE', style: monoLabel),
                const SizedBox(height: 4),
                if (pr['address'] != null)
                  Text('${pr['address']}', style: mono.copyWith(fontSize: 12, height: 1.4)),
                if (pr['phone'] != null)
                  Text('${pr['phone']}', style: mono.copyWith(fontSize: 12, color: inkDim)),
              ],
            ]);
      });

  /// Latest quarter's holders as a donut with legend (MC's pie), then the
  /// quarterly trend of one category as bars (Phase 5).
  List<Widget> _holdersBar() {
    final f = _fund;
    if (f.shareholding.isEmpty) return const [];
    final periods = f.shareholding.keys.toList();
    final latest = f.shareholding[periods.last]!;
    const parts = [
      ('promoters', 'Promoters', 0.85),
      ('fiis', 'FIIs', 0.65),
      ('diis', 'DIIs', 0.48),
      ('govt', 'Govt', 0.34),
      ('public', 'Public', 0.22),
      ('employee_trusts', 'Trusts', 0.12),
    ];
    final segs = [
      for (final (k, label, a) in parts)
        if (latest[k] is num && (latest[k] as num) > 0)
          (
            (latest[k] as num) / 100,
            ink.withValues(alpha: a),
            '$label ${fmtCell(latest[k] as num, CellFmt.pct)}'
          )
    ];
    if (segs.isEmpty) return const [];
    final trend = [
      for (final p in periods)
        (f.shareholding[p]?[_holderKey] as num?)?.toDouble()
    ];
    final hasTrend = trend.where((v) => v != null).length >= 2;
    return [
      const SizedBox(height: 12),
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Donut(segs, center: periodLabel(periods.last)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final s in segs)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  SizedBox(width: 8, height: 8, child: ColoredBox(color: s.$2)),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(s.$3,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono.copyWith(fontSize: 11))),
                ]),
              ),
          ]),
        ),
      ]),
      if (hasTrend) ...[
        const SizedBox(height: 14),
        pillRow([
          for (final (k, label, _) in parts)
            if (periods.any((p) => f.shareholding[p]?[k] is num))
              filterPill(label.toUpperCase(), _holderKey == k, green,
                  () => setState(() => _holderKey = k),
                  fontSize: 9),
        ]),
        const SizedBox(height: 8),
        SizedBox(
            height: 72,
            child: BarChart(trend,
                labels: [for (final p in periods) periodLabel(p)])),
        const SizedBox(height: 4),
        Text(
            'holding % by quarter · ${trend.whereType<double>().isEmpty ? '' : 'latest ${fmtCell(trend.last, CellFmt.pct)}'}',
            style: mono.copyWith(fontSize: 10)),
      ],
      const SizedBox(height: 8),
    ];
  }

  List<({String id, String label, Widget child})> _sections() {
    final f = _fund;
    final cagr =
        (f.summary['cagr'] as Map?)?.cast<String, dynamic>() ?? const {};
    Widget col(List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children);
    return [
      (id: 'chart', label: 'CHART', child: col(_priceHeader())),
      (id: 'overview', label: 'OVERVIEW', child: _overview()),
      (id: 'insights', label: 'INSIGHTS', child: _insights()),
      if ((_meta['f'] as Map?)?['street'] != null)
        (id: 'forecast', label: 'FORECAST', child: _forecast()),
      (id: 'technicals', label: 'TECHNICALS', child: _technicals()),
      if (_sa['tape'] != null)
        (id: 'delivery', label: 'DELIVERY', child: _delivery()),
      if (_sa['fno'] != null) (id: 'fno', label: 'F&O', child: _fno()),
      (id: 'vitals', label: 'VITALS', child: _vitals()),
      if (_seasonQ != null &&
          (_seasonQ!.dividends.isNotEmpty || _seasonQ!.splits.isNotEmpty))
        (id: 'actions', label: 'ACTIONS', child: _actions()),
      (id: 'fundamentals', label: 'FUNDAMENTALS', child: _fundamentals()),
      if (_sa.isNotEmpty) (id: 'returns', label: 'STREET', child: _returns()),
      (id: 'research', label: 'RESEARCH', child: _research()),
      if (_seasonQ != null)
        (id: 'seasonality', label: 'SEASONALITY', child: _seasonality()),
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
              action: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final (radar, label) in const [(true, 'CHART'), (false, 'LIST')])
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: filterPill(label, _peerRadar == radar, green,
                        () => setState(() => _peerRadar = radar),
                        fontSize: 9),
                  ),
              ]),
              footnote:
                  'same $_peerKey · by market cap · radar spoke = ${peerMetrics[_peerMetric].$2} vs the largest · bar = market cap vs largest',
              children: [
                const SizedBox(height: 8),
                pillRow([
                  for (var i = 0; i < peerMetrics.length; i++)
                    filterPill(peerMetrics[i].$2, _peerMetric == i, amber,
                        () => setState(() => _peerMetric = i),
                        fontSize: 9),
                ]),
                if (_peerRadar) ...[
                  const SizedBox(height: 8),
                  Center(child: Radar([
                    for (final p in _peers.take(8))
                      ('${p['symbol']}', (p[peerMetrics[_peerMetric].$1] as num?)?.toDouble())
                  ], highlight: _peers.take(8).toList().indexWhere((p) => p['symbol'] == widget.company.nseSymbol))),
                ],
                PeersTable(_peers,
                    self: widget.company.nseSymbol,
                    metric: peerMetrics[_peerMetric]),
              ])
        ),
      if (f.quarter.isNotEmpty)
        (id: 'earnings', label: 'EARNINGS', child: _earnings()),
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
          child:
              _table('Profit & loss', f.annual.keys.toList(), pnlRows, f.annual)
        ),
        (
          id: 'bs',
          label: 'BALANCE SHEET',
          child:
              _table('Balance sheet', f.annual.keys.toList(), bsRows, f.annual)
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
              shareholdingRows, withOthers(f.shareholding),
              lead: _holdersBar(),
              note: 'a dash = that quarter\'s FII / DII split is not filed in our copy yet; it back-fills quarter by quarter')
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
      (id: 'info', label: 'INFO', child: _info()),
      (id: 'stories', label: 'NEWS', child: _storyList()),
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
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AskScreen(
                        symbol: widget.company.nseSymbol,
                        contextLabel: widget.company.name))),
                icon: const Icon(Icons.question_answer_outlined, color: inkDim),
                tooltip: 'Ask about ${widget.company.nseSymbol}',
              ),
              IconButton(
                onPressed: _openAlerts,
                icon: Icon(
                    _alertCount > 0
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                    color: _alertCount > 0 ? amber : inkDim),
                tooltip: 'Price alerts',
              ),
              IconButton(
                onPressed: _toggleFollow,
                icon: Icon(
                    _following
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
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
          _overview(),
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
                  const HintBar('stock_hints_v1', [
                    ('chips up top', 'jump to any section · 🔍 filters them'),
                    ('1D · 5D', 'intraday · CANDLE flips the chart'),
                    ('SCORE pill', 'opens INSIGHTS with the working shown'),
                    ('dotted words', 'tap for a plain-English definition'),
                    ('every number', 'says where it came from in the footnote'),
                  ]),
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
