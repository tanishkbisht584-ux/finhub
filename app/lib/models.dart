/// One outlet that carried this story. The pipeline keeps every outlet's row
/// in the cluster, so a card can credit all of them instead of the pipeline
/// silently picking one and discarding the rest.
class Outlet {
  final String name;
  final String url;
  final DateTime? publishedAt;

  /// The outlet's own wording — carried since the story-so-far timeline
  /// (2026-08-28); null on rows cached before it shipped.
  final String? headline;

  Outlet.fromJson(Map<String, dynamic> j)
      : name = j['source_name'] ?? '',
        url = j['source_url'] ?? '',
        publishedAt = DateTime.tryParse(j['published_at'] ?? ''),
        headline = j['headline'];
}

/// "The story so far": the cluster's episodes, oldest first, deduped by
/// HEADLINE (not newsroom — the same paper legitimately files successive
/// developments; identical wording via two feeds is one episode). Entries
/// without a headline (pre-2026-08-28 cache) can't tell a story — dropped.
List<Outlet> storyTimeline(List<Outlet> group) {
  final sorted = [...group]..sort((a, b) =>
      (a.publishedAt ?? DateTime(0)).compareTo(b.publishedAt ?? DateTime(0)));
  final seen = <String>{};
  return [
    for (final o in sorted)
      if ((o.headline ?? '').isNotEmpty &&
          seen.add(o.headline!.toLowerCase().trim()))
        o
  ];
}

/// Glossary terms the app highlights on card summaries. A COPY — the qa edge
/// function's DEFINE_TERMS set is canonical; a term missing there just 400s
/// and the sheet shows nothing. Longest-first so "reverse repo" wins over
/// "repo rate"'s prefix.
const glossaryTerms = [
  'reverse repo',
  'repo rate',
  'basis points',
  'rights issue',
  'bonus issue',
  'stock split',
  'open offer',
  'anchor investor',
  'green shoe',
  'listing gains',
  'promoter holding',
  'promoter pledge',
  'stake sale',
  'upper circuit',
  'lower circuit',
  'circuit filter',
  'margin call',
  'market cap',
  'pe ratio',
  'book value',
  'face value',
  'dividend yield',
  'open interest',
  'golden cross',
  'death cross',
  'advance decline',
  'grey market',
  'bulk deal',
  'block deal',
  'oversubscription',
  'delisting',
  'buyback',
  'pledge',
  'arbitrage',
  'lock-in',
  'breadth',
  'crr',
  'slr',
  'mclr',
  'qip',
  'ofs',
  'fpo',
  'gmp',
  'fii',
  'dii',
  'nbfc',
  'npa',
  'casa',
  'ebitda',
  'pat',
  'yoy',
  'qoq',
  'capex',
  'f&o',
  'derivatives',
  'sip',
  'elss',
  'reit',
  'invit',
  'esop',
  'pcr',
  'oi',
  'g-sec',
  't-bill',
  'roce',
  'roe',
  'opm',
  'rsi',
  'macd',
  'sma',
  'beta',
  'cagr',
  'vix',
  'lpr',
  'p/e',
  'p/b',
  'p/s',
  'sharpe',
  'sortino',
  'atr',
  'piotroski',
  'graham number',
  'ev/ebitda',
  'roic',
  'interest cover',
  'fcf yield',
  'earnings yield',
  'all-time high',
  // Phase 8 (20 Sep): every term the MC-depth sections introduced.
  'altman z',
  'z-score',
  'dupont',
  'net margin',
  'asset turnover',
  'leverage',
  'pivot',
  'camarilla',
  'fibonacci',
  'moving average',
  'dma',
  'vwap',
  'delivery',
  'turnover',
  'lot size',
  'strike',
  'put/call ratio',
  'consensus',
  'price target',
  'surprise',
  'seasonality',
  'sector pe',
  'ttm',
  'eps',
  'fwd pe',
  'oi build-up',
  'short covering',
  'long build-up',
  'turning bullish',
  'turning bearish',
  '52-week',
  'ex-date',
  'promoter',
];

/// Split [text] into segments, marking case-insensitive whole-word hits of
/// [terms]. Pure so it's directly testable; the card maps segments to
/// TextSpans and owns the recognizers.
List<({String text, bool isTerm})> glossarySegments(String text,
    [List<String> terms = glossaryTerms]) {
  if (text.isEmpty) return const [];
  final pattern = RegExp(
      '(?<![A-Za-z0-9])(${terms.map(RegExp.escape).join('|')})(?![A-Za-z0-9])',
      caseSensitive: false);
  final out = <({String text, bool isTerm})>[];
  var at = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > at) {
      out.add((text: text.substring(at, m.start), isTerm: false));
    }
    out.add((text: text.substring(m.start, m.end), isTerm: true));
    at = m.end;
  }
  if (at < text.length) out.add((text: text.substring(at), isTerm: false));
  return out;
}

/// Exactly the columns Story.fromJson reads. `select()` was shipping the
/// whole row — including the multi-page `deep_read` jsonb and the `fts`
/// tsvector — making every feed page ~5x its useful size, then paying for it
/// again in jsonDecode, the offline-cache encode, and the prefs blob.
const storyCols = 'id,hook,headline,summary,impact_direction,impact_strength,'
    'impact_horizon,impact_score,severity_level,confidence,source_name,'
    'source_url,category,sectors,image_url,video_url,published_at,cluster_id,'
    'why_it_matters,winners_losers,whats_next,claim_status,is_featured';

class Story {
  final int id;
  final String? hook;
  final String headline;
  final String? summary;
  final String? impactDirection;
  final int? impactStrength;
  final String? impactHorizon;
  final int? impactScore;
  final int? severityLevel;
  final String? confidence;
  final String sourceName;
  final String sourceUrl;
  final String? category;
  final List<String> sectors;
  final String? imageUrl;
  final String? videoUrl;

  /// Pipeline event cluster. Approved siblings can ship (the collapse is
  /// best-effort server-side); the feed keeps one card per cluster.
  final String? clusterId;

  /// Pagination cursor for the infinite feed — the feed is ordered on it.
  final DateTime? publishedAt;

  /// Every outlet that ran this story, earliest first — so the card can credit
  /// whoever broke it rather than whichever copy the pipeline happened to
  /// process. Empty when no other outlet carried it.
  final List<Outlet> outlets;

  /// The cluster's raw episode rows (pre-newsroom-dedupe, with headlines) —
  /// the story-so-far page derives from it via [storyTimeline]. Attached and
  /// cached beside outlets; empty on rows cached before 2026-08-28.
  final List<Outlet> timeline;

  /// Companies the pipeline tagged on this story — attached by the feed query
  /// (one batched query per page, like outlets) and cached with the card.
  final List<Company> companies;

  /// Glance lines (migration 014). NULL on stories scored before they shipped
  /// and whenever a weak AI lane omitted them — the card renders nothing then.
  final String? whyItMatters;
  final String? winnersLosers;
  final String? whatsNext;
  final String? claimStatus; // confirmed | reported | rumour

  /// The chief editor's one top pick per run (admin can also set it).
  /// Absent key (old cache rows) = false.
  final bool isFeatured;

  Story.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        hook = j['hook'],
        headline = j['headline'] ?? '',
        summary = j['summary'],
        impactDirection = j['impact_direction'],
        impactStrength = j['impact_strength'],
        impactHorizon = j['impact_horizon'],
        impactScore = j['impact_score'],
        severityLevel = j['severity_level'],
        confidence = j['confidence'],
        // '' not null: one bad row must not take down Story.fromJson for the
        // whole page (a null source_url did exactly that pre-0.17.1).
        sourceName = j['source_name'] ?? '',
        sourceUrl = j['source_url'] ?? '',
        category = j['category'],
        sectors = List<String>.from(j['sectors'] ?? const []),
        imageUrl = j['image_url'],
        videoUrl = j['video_url'],
        clusterId = j['cluster_id'],
        publishedAt = DateTime.tryParse(j['published_at'] ?? ''),
        // Attached by the feed query and carried into the offline cache, so a
        // cached card keeps its outlet list too.
        outlets = [
          for (final o in (j['outlets'] as List? ?? const []))
            Outlet.fromJson(Map<String, dynamic>.from(o))
        ],
        timeline = [
          for (final o in (j['timeline'] as List? ?? const []))
            Outlet.fromJson(Map<String, dynamic>.from(o))
        ],
        companies = [
          for (final c in (j['companies'] as List? ?? const []))
            Company.fromJson(Map<String, dynamic>.from(c))
        ],
        whyItMatters = j['why_it_matters'],
        winnersLosers = j['winners_losers'],
        whatsNext = j['whats_next'],
        claimStatus = j['claim_status'],
        isFeatured = j['is_featured'] == true;
}

class QaSource {
  final String title;
  final String url;
  final String sourceName;
  QaSource.fromJson(Map<String, dynamic> j)
      : title = j['title'] ?? '',
        url = j['url'] ?? '',
        sourceName = j['source_name'] ?? '';
}

/// Q&A answer contract from the `qa` Edge Function. Every field defaults, so a
/// truncated provider response degrades to a partial card instead of throwing.
class QaAnswer {
  final String whatsHappening;
  final String why;
  final String whoIsAffected;
  final String whatToWatch;
  final String confidence;
  final List<QaSource> sources;
  final List<String> followups;
  final bool refused;

  /// Explainer answers ("what is a CAS?") come back as a free-form section list
  /// instead of the four fixed news fields — a concept needs as many headings as
  /// it needs. Empty on a news answer, which is also how the screen knows which
  /// disclaimer to print.
  final List<({String heading, String body})> sections;

  QaAnswer.fromJson(Map<String, dynamic> j)
      : whatsHappening = j['whats_happening'] ?? '',
        why = j['why'] ?? '',
        whoIsAffected = j['who_is_affected'] ?? '',
        whatToWatch = j['what_to_watch'] ?? '',
        confidence = j['confidence'] ?? 'low',
        sources = ((j['sources'] ?? const []) as List)
            .map((s) => QaSource.fromJson(Map<String, dynamic>.from(s)))
            .toList(),
        followups = List<String>.from(j['followups'] ?? const []),
        sections = [
          for (final s in (j['sections'] ?? const []) as List)
            if ((s['body'] ?? '') != '')
              (
                heading: (s['heading'] ?? '') as String,
                body: s['body'] as String
              )
        ],
        refused = j['refused'] == true;

  /// A 200 whose body defaulted to nothing everywhere. Rendering it would be a
  /// bare divider and a disclaimer — treat it as a failure upstream instead.
  bool get isBlank =>
      !refused &&
      whatsHappening.isEmpty &&
      why.isEmpty &&
      whoIsAffected.isEmpty &&
      whatToWatch.isEmpty &&
      sections.isEmpty;
}

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
  final List<DateTime> times; // aligned with closes (nulls dropped from both)

  // Phase 2 (20 Sep): the day (open / high / low / volume / as-of) from the
  // same meta, and OHLC aligned with [closes] for candles. All optional —
  // Quote.seed and old fixtures leave them empty.
  final double? open, dayHigh, dayLow, volume;
  final DateTime? asOf;
  final List<double> opens, highs, lows;

  /// Phase D: per-bar volume aligned with [closes] (0 where Yahoo has none).
  final List<double> volumes;

  /// Phase 4: corporate actions from the same call with `events=div,splits`
  /// (newest first). Empty unless the caller asked for events.
  final List<({DateTime date, double amount})> dividends;
  final List<({DateTime date, String ratio})> splits;

  factory Quote.fromChartJson(Map<String, dynamic> j) =>
      Quote._(Map<String, dynamic>.from(j['chart']['result'][0]));

  /// Header-only quote from the pipeline's `quotes` row: no 52-wk range, no
  /// closes. The stock page paints this first, then swaps in the chart fetch.
  Quote.seed(this.price, this.prevClose)
      : high52 = 0,
        low52 = 0,
        closes = const [],
        times = const [],
        open = null,
        dayHigh = null,
        dayLow = null,
        volume = null,
        asOf = null,
        opens = const [],
        highs = const [],
        lows = const [],
        volumes = const [],
        dividends = const [],
        splits = const [];

  factory Quote._(Map<String, dynamic> r) {
    final q = Map<String, dynamic>.from(r['indicators']['quote'][0] as Map);
    final rawCloses = q['close'] as List? ?? const [];
    final rawTimes = r['timestamp'] as List? ?? const [];
    List rawOf(String k) => q[k] as List? ?? const [];
    final rawO = rawOf('open'), rawH = rawOf('high'), rawL = rawOf('low');
    final rawV = rawOf('volume');
    final closes = <double>[], opens = <double>[], highs = <double>[];
    final lows = <double>[], volumes = <double>[];
    final times = <DateTime>[];
    for (var i = 0; i < rawCloses.length; i++) {
      final c = rawCloses[i];
      if (c == null) continue;
      final close = (c as num).toDouble();
      closes.add(close);
      // A bar with a close but no OHLC (older fixtures) degrades to a doji.
      double bar(List l) =>
          i < l.length && l[i] != null ? (l[i] as num).toDouble() : close;
      opens.add(bar(rawO));
      highs.add(bar(rawH));
      lows.add(bar(rawL));
      volumes.add(i < rawV.length && rawV[i] != null ? (rawV[i] as num).toDouble() : 0);
      times.add(i < rawTimes.length
          ? DateTime.fromMillisecondsSinceEpoch(
              (rawTimes[i] as num).toInt() * 1000)
          : DateTime.fromMillisecondsSinceEpoch(0));
    }
    final m = Map<String, dynamic>.from(r['meta'] as Map);
    double? d(String k) => (m[k] as num?)?.toDouble();
    final t = (m['regularMarketTime'] as num?)?.toInt();
    final ev = (r['events'] as Map?)?.cast<String, dynamic>() ?? const {};
    DateTime at(Map e) => DateTime.fromMillisecondsSinceEpoch(
        ((e['date'] as num?)?.toInt() ?? 0) * 1000,
        isUtc: true);
    final dividends = [
      for (final e in ((ev['dividends'] as Map?)?.values ?? const []))
        if (e is Map && e['amount'] is num)
          (date: at(e), amount: (e['amount'] as num).toDouble())
    ]..sort((a, b) => b.date.compareTo(a.date));
    final splits = [
      for (final e in ((ev['splits'] as Map?)?.values ?? const []))
        if (e is Map) (date: at(e), ratio: '${e['splitRatio'] ?? ''}')
    ]..sort((a, b) => b.date.compareTo(a.date));
    return Quote._fields(
        d('regularMarketPrice')!,
        // previousClose is yesterday's close on every range; chartPreviousClose
        // is the close before the range (5 days ago on 5d).
        d('previousClose') ?? d('chartPreviousClose')!,
        d('fiftyTwoWeekHigh') ?? 0,
        d('fiftyTwoWeekLow') ?? 0,
        closes,
        times,
        open: d('regularMarketOpen') ?? (opens.isEmpty ? null : opens.first),
        dayHigh: d('regularMarketDayHigh'),
        dayLow: d('regularMarketDayLow'),
        volume: d('regularMarketVolume'),
        asOf: t == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true),
        opens: opens,
        highs: highs,
        lows: lows,
        volumes: volumes,
        dividends: dividends,
        splits: splits);
  }

  Quote._fields(this.price, this.prevClose, this.high52, this.low52,
      this.closes, this.times,
      {this.open,
      this.dayHigh,
      this.dayLow,
      this.volume,
      this.asOf,
      this.opens = const [],
      this.highs = const [],
      this.lows = const [],
      this.volumes = const [],
      this.dividends = const [],
      this.splits = const []});
}

/// One newspaper page of a deep read (spec 2026-08-16).
class DeepPage {
  final String? heading;
  final String body;
  DeepPage(this.heading, this.body);
}

/// The AI-written whole story. Every field defaults so a refusal, a truncated
/// payload, or a pre-2026-08-28 cached row (pages only) degrades gracefully.
class DeepRead {
  final List<DeepPage> pages;

  /// Structured extras (2026-08-28) — optional forever: old cached rows and
  /// weak lanes omit them and the reader renders nothing.
  final List<({String term, String definition})> glossary;
  final ({String value, String label})? keyStat;

  DeepRead(this.pages, {this.glossary = const [], this.keyStat});
  bool get hasContent => pages.isNotEmpty;

  factory DeepRead.fromJson(Map<String, dynamic>? j) {
    final raw = j?['pages'];
    if (raw is! List) return DeepRead(const []);
    final g = j?['glossary'];
    final ks = j?['key_stat'];
    return DeepRead(
      [
        for (final p in raw)
          if (p is Map &&
              (p['body'] is String) &&
              (p['body'] as String).trim().isNotEmpty)
            DeepPage(p['heading'] as String?, p['body'] as String)
      ],
      glossary: [
        if (g is List)
          for (final e in g)
            if (e is Map && e['term'] is String && e['definition'] is String)
              (term: e['term'] as String, definition: e['definition'] as String)
      ],
      keyStat: ks is Map && ks['value'] is String && ks['label'] is String
          ? (value: ks['value'] as String, label: ks['label'] as String)
          : null,
    );
  }
}

/// One row of the pipeline's `quotes` table (pipeline/market.py): an equity,
/// index, FX pair, crypto, commodity, MF scheme or macro series. Read-only on
/// the phone. Price and % are what the chips show; `closes` (indices/FX/
/// commodities/MF only) feeds a sparkline.
class Tick {
  final String symbol;
  final String kind;
  final String name;
  final double price;
  final double? prevClose;
  final double? changePct;
  final String currency;
  final List<double> closes;
  final DateTime? asOf;
  final DateTime? updatedAt;
  final Map<String, dynamic> meta;

  Tick.fromJson(Map<String, dynamic> j)
      : symbol = j['symbol'] ?? '',
        kind = j['kind'] ?? '',
        name = j['name'] ?? '',
        price = (j['price'] as num?)?.toDouble() ?? 0,
        prevClose = (j['prev_close'] as num?)?.toDouble(),
        changePct = (j['change_pct'] as num?)?.toDouble(),
        currency = j['currency'] ?? 'INR',
        closes = [
          for (final c in (j['closes'] as List? ?? const []))
            if (c != null) (c as num).toDouble()
        ],
        asOf = DateTime.tryParse(j['as_of'] ?? ''),
        updatedAt = DateTime.tryParse(j['updated_at'] ?? ''),
        meta = Map<String, dynamic>.from(j['meta'] as Map? ?? const {});

  bool get up => (changePct ?? 0) >= 0;
}

/// Selected columns for any `quotes` read — the whole row is small, but the
/// 1-month `closes` array is only wanted where a sparkline is drawn.
const tickCols = 'symbol,kind,name,price,prev_close,change_pct,currency,'
    'as_of,updated_at,meta';
const tickColsWithCloses = '$tickCols,closes';

/// "▲1.23%" / "▼0.80%" / '' when unknown. The arrow carries direction so the
/// number never needs a sign and colour is never the only cue.
String fmtPct(double? p, {int decimals = 2}) => p == null
    ? ''
    : '${p >= 0 ? '▲' : '▼'}${p.abs().toStringAsFixed(decimals)}%';

/// Indian grouping for rupee amounts (1,42,290 · 73,95,017), western for the
/// rest. Decimals scale with magnitude: 0.6018 · 95.71 · 24,252 · 1,42,290.
String fmtNum(double v, {bool indian = true, int? decimals}) {
  final a = v.abs();
  final d = decimals ??
      (a < 1
          ? 4
          : a >= 10000
              ? 0
              : 2);
  final fixed = a.toStringAsFixed(d);
  final dot = fixed.indexOf('.');
  final whole = dot < 0 ? fixed : fixed.substring(0, dot);
  final frac = dot < 0 ? '' : fixed.substring(dot);
  String grouped;
  if (indian && whole.length > 3) {
    final tail = whole.substring(whole.length - 3);
    var head = whole.substring(0, whole.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    grouped = '${parts.join(',')},$tail';
  } else {
    grouped =
        whole.replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  }
  return '${v < 0 ? '-' : ''}$grouped$frac';
}

/// ₹ / $ prefix by currency code; anything else shows the code.
String fmtMoney(double v, String currency) => switch (currency) {
      'INR' => '₹${fmtNum(v)}',
      'USD' => '\$${fmtNum(v, indian: false)}',
      _ => '${fmtNum(v, indian: false)} $currency',
    };

/// One-line "smart money" facts about [symbol] from the pipeline's NSE blobs
/// (`market_blobs`: results_calendar, bulk_deals, insider_trades). Pure, so
/// the stock page and its test share it. Empty when nothing is on file.
List<String> companyEventLines(Map<String, dynamic> blobs, String symbol) {
  final out = <String>[];
  for (final r in (blobs['results_calendar'] as List? ?? const [])) {
    if (r['symbol'] == symbol) {
      out.add('Board meeting ${dmy(r['date'])} — ${r['purpose'] ?? 'results'}');
    }
  }
  final deals = (blobs['bulk_deals'] as Map?)?['deals'] as List? ?? const [];
  for (final d in deals) {
    if (d['symbol'] == symbol) {
      out.add('${d['type'] == 'block' ? 'Block' : 'Bulk'} ${d['side']} '
          '${fmtNum((d['qty'] as num).toDouble(), decimals: 0)} @ ₹${fmtNum((d['price'] as num).toDouble())}'
          ' · ${d['client'] ?? ''} (${d['date'] ?? ''})');
    }
  }
  for (final i in (blobs['insider_trades'] as List? ?? const [])) {
    if (i['symbol'] == symbol) {
      out.add('Insider ${(i['side'] ?? '').toString().toLowerCase()}: '
          '${i['person'] ?? ''} ${i['qty'] ?? ''} (${i['date'] ?? ''})');
    }
  }
  return out;
}

/// "2026-09-11" / "11-Sep-2026" (NSE deals, IPOs, flows) / "10-09-2026"
/// (NSE insider filings) -> "11 Sep"; the year is appended only when it is
/// not this year, so a table of this month's dates stays short.
String dmy(Object? iso) {
  final d = parseDate(iso);
  if (d == null) return '$iso';
  const m = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  final y = d.year == DateTime.now().year ? '' : ' ${d.year}';
  return '${d.day} ${m[d.month - 1]}$y';
}

const _mon = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// ISO, dd-MMM-yyyy or dd-MM-yyyy (with an optional time) -> DateTime, else null.
DateTime? parseDate(Object? v) {
  final s = '$v'.trim();
  final d = DateTime.tryParse(s);
  if (d != null) return d;
  final m = RegExp(r'^(\d{1,2})-(\w{3}|\d{2})-(\d{4})').firstMatch(s);
  if (m == null) return null;
  final mon = int.tryParse(m[2]!) ?? _mon[m[2]!.toLowerCase()];
  if (mon == null) return null;
  return DateTime(int.parse(m[3]!), mon, int.parse(m[1]!));
}

/// One row of a labelled four-column table (KvTable): metric · value ·
/// third · read, with a tone (-1 red, 0 ink, +1 green) for the read cell.
typedef KvRow = ({
  String metric,
  String value,
  String third,
  String read,
  int tone
});
