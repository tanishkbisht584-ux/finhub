import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../analysis.dart';
import '../follows.dart';
import '../models.dart';
import '../theme.dart';
import '../ticks.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _analysisPoll?.cancel();
    super.dispose();
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
          setState(() => _quote = Quote.fromChartJson(jsonDecode(r.body)));
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

  @override
  Widget build(BuildContext context) {
    final q = _quote;
    final up = q != null && q.price >= q.prevClose;
    final delta = q == null ? '' : (q.price - q.prevClose).toStringAsFixed(2);
    final pct = q == null || q.prevClose == 0
        ? ''
        : ((q.price - q.prevClose) / q.prevClose * 100).toStringAsFixed(2);
    return Scaffold(
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
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(widget.company.nseSymbol, style: mono.copyWith(fontSize: 12)),
          const SizedBox(height: 8),
          if (q != null) ...[
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('₹${q.price.toStringAsFixed(2)}',
                  style: serif.copyWith(
                      fontSize: 34, fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('${up ? '+' : ''}$delta ($pct%)',
                    style:
                        mono.copyWith(fontSize: 13, color: up ? green : red)),
              ),
            ]),
            const SizedBox(height: 16),
            SizedBox(height: 64, child: Sparkline(q.closes, up ? green : red)),
            const SizedBox(height: 10),
            if (q.high52 > 0)
              Text(
                  '52-wk  ₹${q.low52.toStringAsFixed(0)} – ₹${q.high52.toStringAsFixed(0)}',
                  style: mono.copyWith(fontSize: 12)),
            Text('Delayed price · Yahoo Finance',
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
          ValueListenableBuilder<Map<String, Tick>>(
            valueListenable: ticks,
            builder: (_, m, __) {
              final meta = m[widget.company.nseSymbol]?.meta ?? const {};
              final fund = fundamentalLines(meta);
              final tech = technicalLines(meta);
              if (fund.isEmpty && tech.isEmpty) return const SizedBox.shrink();
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (fund.isNotEmpty) ...[
                      const Divider(height: 40),
                      Text('FUNDAMENTALS', style: monoLabel),
                      const SizedBox(height: 8),
                      for (final (k, v) in fund) _kv(k, v),
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
          ),
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
                  : Text('No tagged stories yet',
                      style: mono.copyWith(fontSize: 13)),
            ),
          for (final s in _stories)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.hook ?? s.headline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: ink, fontWeight: FontWeight.w600)),
              subtitle: Text(s.sourceName, style: mono.copyWith(fontSize: 11)),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => StoryDetailScreen(storyId: s.id))),
            ),
        ],
      ),
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
  const Sparkline(this.values, this.color, {super.key});
  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.infinite, painter: _SparkPainter(values, color));
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color);
  final List<double> values;
  final Color color;

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
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.color != color;
}
