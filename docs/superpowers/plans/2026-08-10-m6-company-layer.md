# M6: Company Layer — Seed, Stock Page, Entity Routing, Watchlist, Onboarding

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the dead company layer to life — the M4 leftovers the spec gates "before closed beta widens": seeded `companies`, stock page (§8 screen 4), entity routing in Ask (screen 3), watchlist (screen 5), onboarding interest picker (screen 1).

**Architecture:** The pipeline already extracts companies per card (`story_v1.txt`) and `insert_story` already writes `story_companies` — everything is dead only because `companies` has 0 rows. Task 1 seeds it from the NSE equity master and tagging starts working with zero pipeline changes. The app then reads that layer: company chips on cards, a stock page fed by Yahoo's keyless v8 chart endpoint, entity routing in Ask, a watchlist on `follows`, and a first-run interest picker writing category follows.

**Tech Stack:** Existing Flutter/Riverpod/Supabase app, `http` (new dep) for Yahoo, Python + REST (service key) for the seed. No new pipeline code.

## Global Constraints

- ₹0 stack: free tiers only, no keys in the app binary. Yahoo v8 chart endpoint is keyless.
- RLS stays intact: `companies`/`story_companies` already have authenticated-read policies (`002_security.sql`); `follows` has owner-only read/write (`003_users.sql:50`). No policy changes anywhere in this plan.
- App version bumps to `0.9.0+17` in the release task; APK lands at `C:\Users\Tanis\Desktop\finswipe-v0.9.0.apk` (bump every build — Tanis must be able to read the version off Profile).
- Categories are the pipeline's validated enum, exactly: `Markets, Economy, IPO, Global, Commodities, Corporate, Policy, Geopolitics` (`ai.py:43`).
- Supabase reads from Python go through `run.py`'s `sb()` (it pages past PostgREST's 1000-row cap — never hand-roll a reader).
- Dark theme constants from `app/lib/theme.dart`: `bg, surface, border, ink, inkDim, green, red, amber, serif, mono`.
- Human-only steps are marked **[HUMAN]**. None block Tasks 1–8 — this whole phase is account-free.

---

### Task 1: Seed the companies table from the NSE equity master

**Files:**
- Create: `pipeline/seed/companies_seed.py`

**Interfaces:**
- Consumes: `sb()` from `pipeline/run.py`; NSE master CSV `https://nsearchives.nseindia.com/content/equities/EQUITY_L.csv` (columns `SYMBOL`, `NAME OF COMPANY`, `SERIES`, ...).
- Produces: ~2000 `companies` rows: `name` = short display name ("Mahindra & Mahindra"), `nse_symbol` = "M&M", `aliases` = [full legal name, casefolded]. The pipeline's `companies_by_key` (run.py:681-687) matches AI output by symbol upper, name casefold, and alias casefold — so both the AI's "Reliance Industries" and its `nse_symbol: RELIANCE` hit.

- [ ] **Step 1: Write `pipeline/seed/companies_seed.py`**

```python
"""Seed companies from the NSE equity master (spec §6: "seeded from NSE/BSE
listings"). The pipeline has tagged companies per card since M1 — insert_story
matches card["companies"] against this table — but the table was never seeded,
so no story has ever been tagged. Idempotent: upserts on nse_symbol.

Run:  cd pipeline && python seed/companies_seed.py
"""
import io
import csv
import re
import sys
import pathlib

import requests

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from run import load_env, sb

CSV_URL = "https://nsearchives.nseindia.com/content/equities/EQUITY_L.csv"
# The archives host serves plain requests; the UA only guards against the
# no-header bot filter. ponytail: if NSE ever blocks this, the CSV is mirrored
# widely — swap the URL, the format is stable.
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}

LEGAL_TAIL = re.compile(r"\s+(limited|ltd\.?)$", re.I)


def display_name(legal):
    """'MAHINDRA & MAHINDRA LIMITED' -> 'Mahindra & Mahindra' — chips and the
    stock page header want the name people say, not the registrar's."""
    return LEGAL_TAIL.sub("", legal.strip()).title()


def main():
    load_env()
    r = requests.get(CSV_URL, headers=UA, timeout=60)
    r.raise_for_status()
    rows = []
    for rec in csv.DictReader(io.StringIO(r.text)):
        symbol = rec["SYMBOL"].strip()
        legal = rec["NAME OF COMPANY"].strip()
        if rec.get("SERIES", "EQ").strip() not in ("EQ", "BE"):
            continue  # only regular equity; no ETFs/partly-paid/warrants
        name = display_name(legal)
        aliases = sorted({legal.casefold(), name.casefold()} - {name.casefold()})
        rows.append({"name": name, "nse_symbol": symbol, "aliases": aliases})
    print(f"{len(rows)} equities parsed")
    if len(rows) < 1500:  # the master lists ~2000; a short file is a bad fetch
        raise SystemExit(f"only {len(rows)} rows — refusing to seed from a truncated CSV")
    for i in range(0, len(rows), 500):
        sb("POST", "companies?on_conflict=nse_symbol", json=rows[i:i + 500],
           headers={"Prefer": "resolution=merge-duplicates"})
    total = sb("GET", "companies?select=id")
    print(f"companies table now holds {len(total)} rows")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it**

```bash
cd c:/Users/Tanis/Desktop/finhub/pipeline && python seed/companies_seed.py
```
Expected: `~2000 equities parsed`, `companies table now holds ~2000 rows`. If the CSV fetch 403s, retry once with `https://archives.nseindia.com/content/equities/EQUITY_L.csv` (older mirror host).

- [ ] **Step 3: Verify a story actually gets tagged**

Tagging only happens at insert time, so check after the resident pipeline's next batch (runs every 45 s; give it ~10 min of market-hours news), or verify the matching logic directly:

```bash
cd c:/Users/Tanis/Desktop/finhub/pipeline && python - <<'EOF'
from run import load_env, sb
load_env()
links = sb("GET", "story_companies?select=story_id,companies(name,nse_symbol)&limit=5")
print(links if links else "no links yet — check again after the next pipeline batch")
rel = sb("GET", "companies?select=id,name,aliases&nse_symbol=eq.RELIANCE")
print(rel)
EOF
```
Expected: the RELIANCE row exists with alias `reliance industries limited`; links appear once fresh stories flow.

- [ ] **Step 4: Commit**

```bash
git add pipeline/seed/companies_seed.py
git commit -m "M6: seed companies from NSE equity master — tagging goes live"
```

---

### Task 2: Company + Quote models (Yahoo chart parsing)

**Files:**
- Modify: `app/lib/models.dart` (append `Company`, `Quote`)
- Test: `app/test/quote_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Company.fromJson({id,name,nse_symbol})` with fields `id (int), name (String), nseSymbol (String)`. `Quote.fromChartJson(Map)` with fields `price, prevClose, high52, low52 (double), closes (List<double>)` parsed from Yahoo's `/v8/finance/chart/` response shape. Tasks 3–6 use both.

- [ ] **Step 1: Write the failing test `app/test/quote_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/models.dart';

// The exact envelope Yahoo's keyless chart endpoint returns:
// GET query1.finance.yahoo.com/v8/finance/chart/RELIANCE.NS?range=1mo&interval=1d
Map<String, dynamic> yahoo({List<double?> closes = const [100.0, 101.5]}) => {
      'chart': {
        'result': [
          {
            'meta': {
              'regularMarketPrice': 101.5,
              'chartPreviousClose': 99.0,
              'fiftyTwoWeekHigh': 120.0,
              'fiftyTwoWeekLow': 80.0,
            },
            'indicators': {
              'quote': [
                {'close': closes}
              ]
            },
          }
        ]
      }
    };

void main() {
  test('Quote parses the Yahoo chart envelope', () {
    final q = Quote.fromChartJson(yahoo());
    expect(q.price, 101.5);
    expect(q.prevClose, 99.0);
    expect(q.high52, 120.0);
    expect(q.low52, 80.0);
    expect(q.closes, [100.0, 101.5]);
  });

  test('Quote drops the nulls Yahoo pads holidays with', () {
    final q = Quote.fromChartJson(yahoo(closes: [100.0, null, 101.5]));
    expect(q.closes, [100.0, 101.5]);
  });

  test('Company parses a companies row', () {
    final c = Company.fromJson({'id': 7, 'name': 'Reliance Industries', 'nse_symbol': 'RELIANCE'});
    expect(c.id, 7);
    expect(c.nseSymbol, 'RELIANCE');
  });
}
```

- [ ] **Step 2: Run — expect FAIL (Quote undefined)**

```bash
cd app && flutter test test/quote_test.dart
```

- [ ] **Step 3: Append to `app/lib/models.dart`**

```dart
class Company {
  final int id;
  final String name;
  final String nseSymbol;
  Company.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'] ?? '',
        nseSymbol = j['nse_symbol'] ?? '';
}

/// Parsed from Yahoo's keyless /v8/finance/chart/ endpoint. Deliberately only
/// what that one endpoint carries: price, previous close, 52-wk range, closes
/// for the sparkline. ponytail: market cap and P/E live behind Yahoo's
/// crumb-gated quoteSummary — add a scraping dance only if beta users ask.
class Quote {
  final double price;
  final double prevClose;
  final double high52;
  final double low52;
  final List<double> closes;

  Quote.fromChartJson(Map<String, dynamic> j)
      : this._(Map<String, dynamic>.from(j['chart']['result'][0]));

  Quote._(Map<String, dynamic> r)
      : price = (r['meta']['regularMarketPrice'] as num).toDouble(),
        prevClose = (r['meta']['chartPreviousClose'] as num).toDouble(),
        high52 = (r['meta']['fiftyTwoWeekHigh'] as num?)?.toDouble() ?? 0,
        low52 = (r['meta']['fiftyTwoWeekLow'] as num?)?.toDouble() ?? 0,
        closes = [
          for (final c in (r['indicators']['quote'][0]['close'] as List? ?? const []))
            if (c != null) (c as num).toDouble()
        ];
}
```

- [ ] **Step 4: Run — expect PASS** (`cd app && flutter test test/quote_test.dart`)

- [ ] **Step 5: Commit**

```bash
git add app/lib/models.dart app/test/quote_test.dart
git commit -m "M6: Company + Quote models — Yahoo chart envelope parsing"
```

---

### Task 3: Stock page

**Files:**
- Modify: `app/pubspec.yaml` (add `http`)
- Create: `app/lib/screens/stock.dart`
- Test: `app/test/stock_test.dart`

**Interfaces:**
- Consumes: `Company`, `Quote` (Task 2); `Story`/`StoryCard` (feed.dart); `follows` table.
- Produces: `StockScreen({required Company company})` — price + day change, 1-month sparkline, 52-wk range, follow star (writes `follows` row `{target_type: 'company', target_id: '<id>'}`), recent related stories. `Sparkline` widget (exported for test). Tasks 4, 5, 6 navigate here.

- [ ] **Step 1: Add the dep**

```bash
cd app && flutter pub add http
```

- [ ] **Step 2: Write `app/lib/screens/stock.dart`**

```dart
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
```

- [ ] **Step 3: Write the widget test `app/test/stock_test.dart`**

The network paths need Supabase/Yahoo, so the test pins what renders without them: the sparkline geometry and the screen scaffold. (Same approach as `story_detail_test.dart`.)

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/screens/stock.dart';

void main() {
  testWidgets('Sparkline paints without error for flat and normal series',
      (tester) async {
    for (final series in [<double>[100, 100, 100], <double>[95, 103, 99, 110]]) {
      await tester.pumpWidget(MaterialApp(
          home: SizedBox(width: 200, height: 64,
              child: Sparkline(series, const Color(0xFF3ECF8E)))));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Sparkline with a single point renders empty, no crash',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: SizedBox(width: 200, height: 64,
            child: Sparkline(const [100], Color(0xFF3ECF8E)))));
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 4: Run — expect PASS** (`cd app && flutter test test/stock_test.dart`)

- [ ] **Step 5: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/screens/stock.dart app/test/stock_test.dart
git commit -m "M6: stock page — delayed price, sparkline, 52-wk range, follow, related stories"
```

---

### Task 4: Company chips on feed cards

**Files:**
- Modify: `app/lib/models.dart` (Story gains `companies`)
- Modify: `app/lib/screens/feed.dart` (attach + render chips)
- Test: modify `app/test/outlets_test.dart` sibling-style — new file `app/test/company_chips_test.dart`

**Interfaces:**
- Consumes: `Company` (Task 2), `StockScreen` (Task 3), `story_companies` (authenticated-read per 002).
- Produces: `Story.companies (List<Company>)`, populated by the feed query and carried through the offline cache exactly like `outlets`. Company chips render above sector chips; tapping one pushes `StockScreen`.

- [ ] **Step 1: Write the failing test `app/test/company_chips_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/models.dart';

void main() {
  test('Story carries companies attached by the feed query', () {
    final s = Story.fromJson({
      'id': 1, 'headline': 'h', 'source_name': 'ET', 'source_url': 'u',
      'companies': [
        {'id': 7, 'name': 'Reliance Industries', 'nse_symbol': 'RELIANCE'}
      ],
    });
    expect(s.companies.single.nseSymbol, 'RELIANCE');
  });

  test('Story without companies key parses to empty list', () {
    final s = Story.fromJson(
        {'id': 1, 'headline': 'h', 'source_name': 'ET', 'source_url': 'u'});
    expect(s.companies, isEmpty);
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`cd app && flutter test test/company_chips_test.dart`)

- [ ] **Step 3: Add the field to `Story` in `app/lib/models.dart`**

After the `outlets` field declaration add:

```dart
  /// Companies the pipeline tagged on this story — attached by the feed query
  /// (one batched query per page, like outlets) and cached with the card.
  final List<Company> companies;
```

and in the initializer list, after the `outlets = [...]` entry:

```dart
        companies = [
          for (final c in (j['companies'] as List? ?? const []))
            Company.fromJson(Map<String, dynamic>.from(c))
        ];
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Attach companies in the feed query**

In `app/lib/screens/feed.dart`, add after `_attachOutlets` (feed.dart:61-95), mirroring its shape and its "attribution is a bonus" failure stance:

```dart
/// Attach tagged companies to each row — one query for the whole page.
Future<List<Map<String, dynamic>>> _attachCompanies(
    List<Map<String, dynamic>> rows) async {
  final ids = [for (final r in rows) r['id']];
  if (ids.isEmpty) return rows;
  try {
    final links = await Supabase.instance.client
        .from('story_companies')
        .select('story_id, companies(id,name,nse_symbol)')
        .inFilter('story_id', ids);
    final byStory = <int, List<Map<String, dynamic>>>{};
    for (final l in links.cast<Map<String, dynamic>>()) {
      (byStory[l['story_id'] as int] ??= [])
          .add(Map<String, dynamic>.from(l['companies']));
    }
    for (final row in rows) {
      row['companies'] = byStory[row['id']] ?? const [];
    }
  } catch (_) {
    // Chips are a bonus, never a reason to lose the feed.
  }
  return rows;
}
```

In `storiesProvider` (feed.dart:37), chain it:

```dart
    final withOutlets = await _attachOutlets(rows.cast<Map<String, dynamic>>());
    final withCompanies = await _attachCompanies(withOutlets);
    await FeedCache.save(withCompanies);
    ref.read(servingCacheProvider.notifier).state = null;
    return withCompanies.map(Story.fromJson).toList();
```

- [ ] **Step 6: Render the chips**

In `StoryCard`'s build, directly above the sectors block (feed.dart:474 `if (story.sectors.isNotEmpty) ...[`), insert:

```dart
                    if (story.companies.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: story.companies
                            .map((c) => GestureDetector(
                                  onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              StockScreen(company: c))),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                        color: surface,
                                        border: Border.all(color: border)),
                                    child: Text('\$${c.nseSymbol}',
                                        style: mono.copyWith(
                                            fontSize: 12, color: ink)),
                                  ),
                                ))
                            .toList(),
                      ),
                    ],
```

Add `import 'stock.dart';` with the other imports. Visual difference from sector chips (border-only): company chips get the `surface` fill — tappable things should look different from labels.

- [ ] **Step 7: Full app test run — expect all PASS** (`cd app && flutter test`)

- [ ] **Step 8: Commit**

```bash
git add app/lib/models.dart app/lib/screens/feed.dart app/test/company_chips_test.dart
git commit -m "M6: company chips on cards — tap opens the stock page"
```

---

### Task 5: Entity routing in Ask

**Files:**
- Modify: `app/lib/screens/ask.dart`
- Test: `app/test/entity_routing_test.dart`

**Interfaces:**
- Consumes: `companies` table (authenticated read), `StockScreen` (Task 3), existing `_ask` (ask.dart:33).
- Produces: `looksLikeQuestion(String) -> bool` (top-level, exported for test). Submit flow: entity-looking queries try a company match first — exactly one hit routes to `StockScreen`; everything else falls through to Q&A unchanged (the plan's M5 out-of-scope note: entity queries already "degrade gracefully" through Q&A, so routing only has to catch the obvious ones).

- [ ] **Step 1: Write the failing test `app/test/entity_routing_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/screens/ask.dart';

void main() {
  test('questions never route to a stock page', () {
    for (final q in [
      'Why is the NIFTY falling today?',
      'what did RBI decide',
      'Should I buy Reliance shares right now',
      'how is tata motors doing',
      'is the market open tomorrow',
    ]) {
      expect(looksLikeQuestion(q), isTrue, reason: q);
    }
  });

  test('bare entity queries are candidates for routing', () {
    for (final q in ['Tata Motors', 'RELIANCE', 'hdfc bank', 'M&M']) {
      expect(looksLikeQuestion(q), isFalse, reason: q);
    }
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`cd app && flutter test test/entity_routing_test.dart`)

- [ ] **Step 3: Implement in `app/lib/screens/ask.dart`**

Top-level, above `AskScreen`:

```dart
/// Spec §8 screen 3 — one box, two behaviors. A question goes to Q&A; a bare
/// entity ("Tata Motors") goes to the stock page. Interrogatives and length
/// separate them: nobody types a seven-word company name, and nobody asks a
/// question without a question word — and when this guess is wrong, Q&A
/// answers the entity query with sources anyway, so a miss costs nothing.
const _questionWords = {
  'why', 'what', 'how', 'when', 'where', 'who', 'which', 'is', 'are', 'was',
  'will', 'should', 'can', 'could', 'does', 'did', 'do', 'explain', 'tell',
};

bool looksLikeQuestion(String q) {
  final words = q.trim().toLowerCase().split(RegExp(r'\s+'));
  if (words.length > 4) return true;
  return q.contains('?') || words.any(_questionWords.contains);
}
```

In `_AskScreenState._ask`, before `setState({_loading = true; ...})`, insert the routing attempt:

```dart
    if (!looksLikeQuestion(question)) {
      try {
        final term = question.trim();
        final rows = await Supabase.instance.client
            .from('companies')
            .select('id,name,nse_symbol')
            .or('nse_symbol.ilike.$term,name.ilike.$term%')
            .limit(2);
        if (rows.length == 1 && mounted) {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => StockScreen(
                  company: Company.fromJson(
                      Map<String, dynamic>.from(rows.single)))));
          return;
        }
      } catch (_) {
        // company lookup down -> just ask; Q&A handles entities with sources
      }
    }
```

Add imports `import 'stock.dart';` (Company is already imported via `../models.dart`).

- [ ] **Step 4: Run the routing test + full suite — expect PASS** (`cd app && flutter test`)

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/ask.dart app/test/entity_routing_test.dart
git commit -m "M6: Ask routes bare entity queries to the stock page"
```

---

### Task 6: Watchlist

**Files:**
- Create: `app/lib/screens/watchlist.dart`
- Modify: `app/lib/share_palette.dart:232-235` (ribbon gains a Watchlist tile)
- Modify: `app/lib/main.dart:112-128` (`_close` routes the new tile)
- Test: `app/test/watchlist_test.dart`

**Interfaces:**
- Consumes: `follows` (owner-read RLS), `companies`, `story_companies`, `Story`, `Company`, `StockScreen`, `StoryDetailScreen`; `ribbonTargets`/`ShareTarget` (share_palette.dart).
- Produces: `WatchlistScreen` — followed companies (tap → stock page) above a feed of stories tagged with any of them (tap → story detail). Reached the same way as Saved: long-press the News tab, slide.

- [ ] **Step 1: Write `app/lib/screens/watchlist.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import '../theme.dart';
import 'stock.dart';
import 'story_detail.dart';

/// Spec §8 screen 5: followed entities + filtered feed. Category/sector
/// follows shape the main feed's future ranking; this screen shows the
/// company follows, where "did my stock do something today" lives.
class WatchlistScreen extends StatefulWidget {
  const WatchlistScreen({super.key});
  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  List<Company>? _companies; // null = loading
  List<Story> _stories = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    if (uid == null) return setState(() => _companies = const []);
    try {
      final follows = await sb.from('follows')
          .select('target_id')
          .eq('user_id', uid)
          .eq('target_type', 'company');
      final ids = [for (final f in follows) int.parse(f['target_id'])];
      if (ids.isEmpty) return setState(() => _companies = const []);
      final companies = await sb.from('companies')
          .select('id,name,nse_symbol')
          .inFilter('id', ids);
      final links = await sb.from('story_companies')
          .select('story_id')
          .inFilter('company_id', ids)
          .limit(200);
      final storyIds =
          {for (final l in links) l['story_id']}.toList();
      final stories = storyIds.isEmpty
          ? const <Map<String, dynamic>>[]
          : await sb.from('stories')
              .select()
              .inFilter('id', storyIds)
              .eq('status', 'approved')
              .order('published_at', ascending: false)
              .limit(30);
      if (!mounted) return;
      setState(() {
        _companies = [
          for (final c in companies)
            Company.fromJson(Map<String, dynamic>.from(c))
        ];
        _stories = [
          for (final s in stories) Story.fromJson(Map<String, dynamic>.from(s))
        ];
      });
    } catch (_) {
      if (mounted) setState(() => _companies ??= const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final companies = _companies;
    if (companies == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (companies.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing followed yet.\nOpen a company from any card and tap the star.',
            textAlign: TextAlign.center,
            style: mono.copyWith(fontSize: 13, height: 1.6),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in companies)
              ActionChip(
                backgroundColor: surface,
                side: const BorderSide(color: border),
                label: Text(c.nseSymbol, style: mono.copyWith(color: ink)),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => StockScreen(company: c))),
              ),
          ],
        ),
        const Divider(height: 32),
        if (_stories.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('No stories on your companies yet',
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
    );
  }
}
```

- [ ] **Step 2: Add the ribbon tile in `app/lib/share_palette.dart`**

The ribbon's own comment reserves this room ("a menu of one today, with room for shelves and filters later"). Change `ribbonTargets` (share_palette.dart:232) to:

```dart
const ribbonTargets = <ShareTarget>[
  ShareTarget('cancel', 'Cancel', Icons.close_rounded, red),
  ShareTarget('watchlist', 'Watchlist', Icons.star_rounded, amber),
  ShareTarget('saved', 'Saved', Icons.bookmarks_rounded, green),
];
```

(`defaultRibbonTarget` already finds `'saved'` by id — the thumb still opens on Saved, one step up reaches Watchlist, two reaches Cancel.)

- [ ] **Step 3: Route it in `app/lib/main.dart`**

Replace the two lines in `_close` (main.dart:118-127):

```dart
    if (ribbonTargets[chosen].id != 'saved') return;
    Navigator.of(context).push(MaterialPageRoute(
```

with:

```dart
    final id = ribbonTargets[chosen].id;
    if (id != 'saved' && id != 'watchlist') return;
    Navigator.of(context).push(MaterialPageRoute(
```

and make the pushed body conditional — the `Scaffold`'s `body:` becomes:

```dart
              body: id == 'saved' ? const SavedScreen() : const WatchlistScreen(),
```

Add `import 'screens/watchlist.dart';` with the other screen imports.

- [ ] **Step 4: Write the test `app/test/watchlist_test.dart`**

The ribbon's selection maths is already pinned by `share_gesture_test.dart`; what this task can break is the target list and the empty state:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/share_palette.dart';

void main() {
  test('ribbon holds cancel/watchlist/saved and still opens on Saved', () {
    expect([for (final t in ribbonTargets) t.id],
        ['cancel', 'watchlist', 'saved']);
    expect(ribbonTargets[defaultRibbonTarget].id, 'saved');
  });
}
```

(WatchlistScreen itself hits Supabase in initState, so its render paths are covered by the manual pass — same stance as SavedScreen, which has no widget test either.)

- [ ] **Step 5: Run full suite — expect PASS** (`cd app && flutter test`)

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/watchlist.dart app/lib/share_palette.dart app/lib/main.dart app/test/watchlist_test.dart
git commit -m "M6: watchlist — followed companies + their stories, on the News-tab ribbon"
```

---

### Task 7: Onboarding interest picker

**Files:**
- Create: `app/lib/screens/interests.dart`
- Modify: `app/lib/main.dart:38-66` (AuthGate routes first-run users)
- Test: `app/test/interests_test.dart`

**Interfaces:**
- Consumes: `follows` (category rows), `CATEGORIES` enum copied verbatim from `ai.py:43`.
- Produces: `InterestsScreen({required VoidCallback onDone})` — pick ≥3 categories, one insert, then `onDone`. `kCategories` const (exported for test). AuthGate shows it when the signed-in user has zero follows; the check runs once per app start.

- [ ] **Step 1: Write the failing test `app/test/interests_test.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/screens/interests.dart';

void main() {
  test('categories match the pipeline enum exactly', () {
    expect(kCategories, [
      'Markets', 'Economy', 'IPO', 'Global',
      'Commodities', 'Corporate', 'Policy', 'Geopolitics',
    ]);
  });

  testWidgets('Continue stays disabled until three picks', (tester) async {
    await tester.pumpWidget(MaterialApp(home: InterestsScreen(onDone: () {})));
    final button = () => tester
        .widget<FilledButton>(find.byType(FilledButton));
    expect(button().onPressed, isNull);
    for (final c in ['Markets', 'Economy', 'IPO']) {
      await tester.tap(find.text(c));
      await tester.pump();
    }
    expect(button().onPressed, isNotNull);
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`cd app && flutter test test/interests_test.dart`)

- [ ] **Step 3: Write `app/lib/screens/interests.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';

/// Spec §8 screen 1: sign-in -> pick >=3 interests -> feed, under 60 seconds.
/// The pipeline's category enum verbatim (ai.py CATEGORIES) — a follow row on
/// a category the pipeline never emits would be a dead filter.
const kCategories = [
  'Markets', 'Economy', 'IPO', 'Global',
  'Commodities', 'Corporate', 'Policy', 'Geopolitics',
];

class InterestsScreen extends StatefulWidget {
  const InterestsScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<InterestsScreen> createState() => _InterestsScreenState();
}

class _InterestsScreenState extends State<InterestsScreen> {
  final _picked = <String>{};
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    try {
      if (uid != null) {
        await sb.from('follows').upsert([
          for (final c in _picked)
            {'user_id': uid, 'target_type': 'category', 'target_id': c}
        ]);
      }
    } catch (_) {
      // The feed must never be gated on this write landing — interests can
      // be re-derived from behavior later; a stuck onboarding cannot.
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text('What do you care about?',
                  style: serif.copyWith(fontSize: 28, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('Pick at least three — your alerts and feed learn from this.',
                  style: mono.copyWith(fontSize: 13)),
              const SizedBox(height: 24),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in kCategories)
                    FilterChip(
                      label: Text(c),
                      selected: _picked.contains(c),
                      backgroundColor: surface,
                      selectedColor: green.withValues(alpha: 0.18),
                      checkmarkColor: green,
                      side: BorderSide(
                          color: _picked.contains(c) ? green : border),
                      labelStyle: TextStyle(
                          color: _picked.contains(c) ? green : ink),
                      onSelected: (_) => setState(() => _picked.contains(c)
                          ? _picked.remove(c)
                          : _picked.add(c)),
                    ),
                ],
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _picked.length >= 3 && !_saving ? _save : null,
                  child: Text(_saving
                      ? 'Saving…'
                      : 'Continue (${_picked.length}/3)'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Route first-run users in `app/lib/main.dart`**

`AuthGate` is a StatelessWidget (main.dart:38); it becomes stateful so the follows check runs once, not per auth event:

```dart
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  /// null = unknown yet; checked once per app start. Errors count as "has
  /// interests" — a flaky network must never re-run onboarding.
  bool? _needsInterests;

  Future<void> _ensureProfile(User user) async {
    try {
      await Supabase.instance.client.from('profiles').upsert({
        'id': user.id,
        'display_name': user.userMetadata?['full_name'] ?? user.email,
      }, onConflict: 'id');
    } catch (_) {
      // offline or transient: saves retry the upsert themselves
    }
  }

  Future<void> _checkInterests(User user) async {
    if (_needsInterests != null) return;
    try {
      final rows = await Supabase.instance.client
          .from('follows')
          .select('target_id')
          .eq('user_id', user.id)
          .limit(1);
      if (mounted) setState(() => _needsInterests = rows.isEmpty);
    } catch (_) {
      if (mounted) setState(() => _needsInterests = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session == null) return const SignInScreen();
        _ensureProfile(session.user);
        _checkInterests(session.user);
        if (_needsInterests == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (_needsInterests == true) {
          return InterestsScreen(
              onDone: () => setState(() => _needsInterests = false));
        }
        return const HomeShell();
      },
    );
  }
}
```

Add `import 'screens/interests.dart';` with the other screen imports.

- [ ] **Step 5: Run full suite — expect PASS** (`cd app && flutter test`)

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/interests.dart app/lib/main.dart app/test/interests_test.dart
git commit -m "M6: onboarding interest picker — >=3 categories into follows"
```

---

### Task 8: Release v0.9.0

**Files:**
- Modify: `app/pubspec.yaml` (version `0.9.0+17`)

**Interfaces:**
- Consumes: everything above, green.
- Produces: `C:\Users\Tanis\Desktop\finswipe-v0.9.0.apk`, version readable on Profile.

- [ ] **Step 1: Bump** — `app/pubspec.yaml:4` → `version: 0.9.0+17`

- [ ] **Step 2: Full sweep**

```bash
cd c:/Users/Tanis/Desktop/finhub/pipeline && python -m pytest test_pipeline.py -q
cd ../app && flutter test
```
Expected: all green. Anything red stops the release.

- [ ] **Step 3: Build with the version on Profile**

```bash
cd c:/Users/Tanis/Desktop/finhub/app && flutter build apk --release \
  --dart-define=SUPABASE_URL=https://hdgfdswzymfqgjqzqqve.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<key from previous build command in shell history / CI> \
  --dart-define=APP_VERSION=0.9.0
cp build/app/outputs/flutter-apk/app-release.apk C:/Users/Tanis/Desktop/finswipe-v0.9.0.apk
```

- [ ] **Step 4: Commit + tag**

```bash
git add app/pubspec.yaml
git commit -m "M6: v0.9.0 — company layer: stock page, entity routing, watchlist, onboarding"
git tag v0.9.0
```

- [ ] **Step 5 [HUMAN]: Install `finswipe-v0.9.0.apk`, confirm Profile reads 0.9.0**

Then one pass: card shows a `$TICKER` chip → tap → price + sparkline → star it → long-press News tab → slide to Watchlist → the company and its story are there. Type "Tata Motors" in Ask → stock page; type "why is nifty falling" → Q&A.

---

## Out of scope (explicit)

- **Personalized alert send** (spec §7: impact ≥ 6 on a followed stock, 5/day/user): the send side needs Firebase (M5 Task 6 **[HUMAN]**, still blocked) and per-user FCM tokens. The `follows` rows this phase creates are its data feed — add it in the same task that unblocks FCM receive.
- **Backfilling story_companies for old stories**: raw AI company output isn't stored per story, so backfill means re-running AI over history. Tagging starts working going forward; old stories age out of the 48h feed window in two days anyway.
- **Market cap / P/E on the stock page** (spec §8 screen 4 names them): they live behind Yahoo's crumb-gated quoteSummary endpoint, not the keyless chart one. Price, change, chart, and 52-wk range ship now; add the crumb dance only if beta users ask where the P/E went.
- **Sector follow chips / sector pages**: sectors on cards stay labels. Company follows and category interests cover the spec's follow model; a sector page is a new screen with no spec definition.
- **Feed ranking by interests**: follows are collected, not yet consumed by ranking — the rec engine is Phase 2+ per spec §2. Watchlist is where follows pay off today.

## Self-review notes

- Spec coverage: §8 screen 1 (Task 7), screen 2's company chips (Task 4), screen 3 (Task 5), screen 4 (Tasks 2–3), screen 5 (Task 6); §6 companies "seeded from NSE listings" (Task 1). Screens 6–8 shipped in M4/M5.
- Contract consistency: `Company.fromJson` keys (`id,name,nse_symbol`) match Task 1's seed columns, Task 4's embed select, Task 5's routing select, and Task 6's watchlist select. `follows.target_id` is text (003_users.sql:15) — company ids stored as `'${company.id}'`, parsed back with `int.parse` in Task 6.
- `Quote.fromChartJson` field names match the real Yahoo envelope (verified shape in Task 2's test fixture); nulls-in-closes handled because Yahoo pads market holidays with null.
- RLS: every table the app newly reads (`companies`, `story_companies`) already has an authenticated-read policy from 002 — verified in this session, not assumed.
