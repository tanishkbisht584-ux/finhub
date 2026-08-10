import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../theme.dart';
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
  bool _following = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    // Three independent fetches; each failure degrades its own section only.
    http.get(
      Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/'
          '${widget.company.nseSymbol}.NS?range=1mo&interval=1d'),
      headers: {'User-Agent': 'Mozilla/5.0'},
    ).then((r) {
      if (!mounted) return;
      if (r.statusCode != 200) return setState(() => _quoteFailed = true);
      setState(() => _quote = Quote.fromChartJson(jsonDecode(r.body)));
    }).catchError((_) {
      if (mounted) setState(() => _quoteFailed = true);
    });
    // Two steps, not an embedded join: ordering by a referenced table's column
    // through PostgREST embeds is where the Q&A tier-1 bug came from.
    sb.from('story_companies')
        .select('story_id')
        .eq('company_id', widget.company.id)
        .limit(100)
        .then((links) async {
      final ids = [for (final l in links) l['story_id']];
      if (ids.isEmpty || !mounted) return;
      final rows = await sb.from('stories')
          .select()
          .inFilter('id', ids)
          .eq('status', 'approved')
          .order('published_at', ascending: false)
          .limit(15);
      if (!mounted) return;
      setState(() => _stories =
          [for (final r in rows) Story.fromJson(Map<String, dynamic>.from(r))]);
    }).catchError((_) {});
    if (uid != null) {
      sb.from('follows')
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
    final was = _following;
    setState(() => _following = !was); // optimistic, like save
    try {
      if (was) {
        await sb.from('follows').delete().match({
          'user_id': uid, 'target_type': 'company',
          'target_id': '${widget.company.id}',
        });
      } else {
        await sb.from('follows').upsert({
          'user_id': uid, 'target_type': 'company',
          'target_id': '${widget.company.id}',
        });
      }
    } catch (_) {
      if (mounted) setState(() => _following = was);
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
        backgroundColor: bg, surfaceTintColor: bg, elevation: 0,
        leading: const BackButton(color: ink),
        title: Text(widget.company.name, style: serif.copyWith(fontSize: 18)),
        actions: [
          IconButton(
            onPressed: _toggleFollow,
            icon: Icon(_following ? Icons.star_rounded : Icons.star_outline_rounded,
                color: _following ? amber : inkDim),
            tooltip: _following ? 'Unfollow' : 'Follow',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
            SizedBox(height: 64, child: Sparkline(q.closes, up ? green : red)),
            const SizedBox(height: 10),
            Text('52-wk  ₹${q.low52.toStringAsFixed(0)} – ₹${q.high52.toStringAsFixed(0)}',
                style: mono.copyWith(fontSize: 12)),
            Text('Delayed price · Yahoo Finance', style: mono.copyWith(fontSize: 10)),
          ] else if (_quoteFailed)
            Text('Price unavailable right now', style: mono.copyWith(fontSize: 13))
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
          const Divider(height: 40),
          Text('RECENT STORIES',
              style: mono.copyWith(fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (_stories.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('No tagged stories yet',
                  style: mono.copyWith(fontSize: 13)),
            ),
          for (final s in _stories)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.hook ?? s.headline,
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: ink, fontWeight: FontWeight.w600)),
              subtitle: Text(s.sourceName, style: mono.copyWith(fontSize: 11)),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => StoryDetailScreen(storyId: s.id))),
            ),
        ],
      ),
    );
  }
}

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
