import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../analytics.dart';
import '../feed_cache.dart';
import '../follows.dart';
import '../models.dart';
import '../publishers.dart';
import '../remote_config.dart';
import '../share_palette.dart';
import '../ticks.dart';
import 'saved.dart';
import 'stock.dart';
import 'story_detail.dart';
import 'watchlist.dart';
import '../theme.dart';

/// Whether the feed currently on screen came from the device cache.
final servingCacheProvider = StateProvider<DateTime?>((ref) => null);

/// Story id from a tapped alert, waiting for the feed to land on it.
///
/// A ValueNotifier rather than a provider because the setter is `_openStory`
/// in main.dart — a top-level FCM callback with no WidgetRef and no context to
/// find a container with.
final pendingStory = ValueNotifier<int?>(null);

/// Story ids the pipeline flagged as unusually widely covered (signals.py,
/// `trending.unusual_story_ids`); the card shows a "Wide coverage" chip.
/// Fed by [_TrendingStrip]'s poll — one row, every 5 min.
final unusualStoryIds = ValueNotifier<Set<int>>({});

/// Which HomeShell tab is showing. A notification tap has to reach the feed
/// from wherever the app happens to be — Ask, Profile, or a pushed sub-screen.
/// Lives here (not main.dart) so the feed's poll can gate on it without a
/// feed→main import cycle.
final homeTab = ValueNotifier<int>(0);

/// HomeShell's tabs, in order. Markets sits at [marketsTab]; the feed's poll
/// and the Markets screen's refresh each gate on their own index.
const homeTabLabels = ['News', 'Markets', 'Ask', 'Profile'];
const marketsTab = 1;

/// Put the feed on [id]'s card. False when the story isn't in the loaded list,
/// so the caller can fall back to the standalone detail screen.
bool jumpToStory(PageController pc, List<FeedEntry> entries, int id) {
  final i = entries.indexWhere((e) => e.story?.id == id);
  if (i < 0) return false;
  if (pc.hasClients) pc.jumpToPage(i);
  return true;
}

/// The pipeline's fixed 8 (ai.py CATEGORIES). Strip order is fixed, not
/// data-driven — a stable strip beats one that jumps as stories churn.
const feedCategories = [
  'Markets',
  'Economy',
  'IPO',
  'Corporate',
  'Policy',
  'Global',
  'Commodities',
  'Geopolitics',
];

/// The one feed's composition (owner's call 2026-08-12: "only one feed to
/// scroll, with a filter to add categories, subtract them, or all"). Chips
/// toggle a category in or out of the single feed; this is a lasting
/// customization, persisted on-device. Default: everything.
final enabledCategories = ValueNotifier<Set<String>>({...feedCategories});
const _categoriesPrefsKey = 'feed_categories_v1';

Future<void> loadEnabledCategories() async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getStringList(_categoriesPrefsKey);
  // A persisted [] would open every launch on "Nothing matches your filters".
  // All-off is legal within a session (it has its own guidance text) but must
  // not be the state the app wakes up in.
  if (saved != null && saved.isNotEmpty) {
    enabledCategories.value = saved.toSet();
  }
}

Future<void> toggleCategory(String cat) async {
  final next = {...enabledCategories.value};
  next.contains(cat) ? next.remove(cat) : next.add(cat);
  enabledCategories.value = next;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(_categoriesPrefsKey, next.toList()..sort());
}

Future<void> enableAllCategories() async {
  enabledCategories.value = {...feedCategories};
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_categoriesPrefsKey);
}

/// LIVE mode (owner 2026-08-14): red tile top-left. On = the feed hugs the
/// bleeding edge — instant refresh on toggle, then a 15s fresh-poll instead
/// of the ambient 90s. Every launch starts LIVE (owner 2026-08-21); the pill
/// still toggles it off for the session.
final liveMode = ValueNotifier<bool>(true);
// Poll cadence comes from the admin's remote config (defaults 15 s / 90 s).
int get livePollSeconds => remoteConfig.livePollSeconds;
int get ambientPollSeconds => remoteConfig.ambientPollSeconds;

/// Minimum impact score a card needs to stay in the feed (0 = show all).
/// Same lifecycle as the category set: persisted, reset by alerts.
final minImpact = ValueNotifier<int>(0);
const _minImpactPrefsKey = 'feed_min_impact_v1';

Future<void> loadMinImpact() async {
  final prefs = await SharedPreferences.getInstance();
  minImpact.value = prefs.getInt(_minImpactPrefsKey) ?? 0;
}

Future<void> setMinImpact(int v) async {
  track('filter_impact', {'min': v});
  minImpact.value = v;
  final prefs = await SharedPreferences.getInstance();
  v == 0
      ? await prefs.remove(_minImpactPrefsKey)
      : await prefs.setInt(_minImpactPrefsKey, v);
}

/// Horizon lens: ALL, or only the short/long-term stories. Opened by tapping
/// the SHORT/LONG half of the card's ledger line. Same lifecycle as minImpact.
final horizonFilter = ValueNotifier<String>('all'); // 'all' | 'short' | 'long'
const _horizonPrefsKey = 'feed_horizon_v1';

Future<void> loadHorizonFilter() async {
  final prefs = await SharedPreferences.getInstance();
  horizonFilter.value = prefs.getString(_horizonPrefsKey) ?? 'all';
}

Future<void> setHorizonFilter(String v) async {
  track('filter_horizon', {'h': v});
  horizonFilter.value = v;
  final prefs = await SharedPreferences.getInstance();
  v == 'all'
      ? await prefs.remove(_horizonPrefsKey)
      : await prefs.setString(_horizonPrefsKey, v);
}

/// Muted publishers and tickers — curation, not a lens: no dial glow, and
/// neither the dial's Reset nor an alert's resetFilterForAlert touches them.
/// Unmute lives in the dial sheet's MUTED row.
final mutedSources = ValueNotifier<Set<String>>({}); // publisher() keys
final mutedSymbols = ValueNotifier<Set<String>>({}); // NSE symbols
const _mutedSourcesPrefsKey = 'feed_muted_sources_v1';
const _mutedSymbolsPrefsKey = 'feed_muted_symbols_v1';

Future<void> loadMutes() async {
  final prefs = await SharedPreferences.getInstance();
  mutedSources.value =
      (prefs.getStringList(_mutedSourcesPrefsKey) ?? const []).toSet();
  mutedSymbols.value =
      (prefs.getStringList(_mutedSymbolsPrefsKey) ?? const []).toSet();
}

Future<void> _toggleMute(ValueNotifier<Set<String>> muted, String prefsKey,
    String kind, String key) async {
  final next = {...muted.value};
  final on = !next.remove(key);
  if (on) next.add(key);
  muted.value = next;
  track('filter_mute', {'kind': kind, 'key': key, 'on': on});
  final prefs = await SharedPreferences.getInstance();
  next.isEmpty
      ? await prefs.remove(prefsKey)
      : await prefs.setStringList(prefsKey, next.toList()..sort());
}

Future<void> toggleMuteSource(String pub) =>
    _toggleMute(mutedSources, _mutedSourcesPrefsKey, 'source', pub);
Future<void> toggleMuteSymbol(String sym) =>
    _toggleMute(mutedSymbols, _mutedSymbolsPrefsKey, 'symbol', sym);

/// Newest published_at that was on screen at the last visit. The feed opens
/// on the newest card, so loaded-at-top counts as seen. Frozen for the
/// session (the setter only persists) so the caught-up divider doesn't chase
/// the live feed mid-session.
final lastSeenAtLaunch = ValueNotifier<DateTime?>(null);
const _lastSeenPrefsKey = 'feed_last_seen_v1';

Future<void> loadLastSeenStamp() async {
  final prefs = await SharedPreferences.getInstance();
  lastSeenAtLaunch.value =
      DateTime.tryParse(prefs.getString(_lastSeenPrefsKey) ?? '');
}

/// Persist only — never touches [lastSeenAtLaunch] mid-session.
Future<void> setLastSeenStamp(DateTime t) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_lastSeenPrefsKey, t.toIso8601String());
}

/// An alerted story must never be invisible because a filter excludes it:
/// open the feed back up.
void resetFilterForAlert() {
  enabledCategories.value = {...feedCategories};
  minImpact.value = 0;
  horizonFilter.value = 'all';
  // Persist too, or the narrow filter resurrects on next launch. Not routed
  // through setMinImpact: that would log a filter_impact event per alert.
  SharedPreferences.getInstance().then((p) {
    p.remove(_categoriesPrefsKey);
    p.remove(_minImpactPrefsKey);
    p.remove(_horizonPrefsKey);
  });
}

/// True when any filter is narrowing the feed — the tune button glows so a
/// thin feed is never a mystery.
bool filtersActive() =>
    enabledCategories.value.length != feedCategories.length ||
    minImpact.value > 0 ||
    horizonFilter.value != 'all';

/// Dedup-by-id merge for the infinite feed: [incoming] joins [current] at the
/// bottom (an older page) or the top, never duplicating a card the reader
/// already has.
List<Story> mergeStories(List<Story> current, List<Story> incoming,
    {bool atTop = false}) {
  final have = {for (final s in current) s.id};
  final fresh = [
    for (final s in incoming)
      if (!have.contains(s.id)) s
  ];
  return atTop ? [...fresh, ...current] : [...current, ...fresh];
}

/// Fresh arrivals land as the reader's NEXT swipe (owner 2026-08-14: "swipe a
/// story, recent news comes, next swipe shows the latest card"): deduped,
/// inserted right after [anchorId] — the card currently on screen. No anchor
/// (feed not started, card gone) falls back to the top.
List<Story> insertFresh(List<Story> feed, List<Story> fresh, int? anchorId) {
  final have = {for (final s in feed) s.id};
  final add = [
    for (final s in fresh)
      if (!have.contains(s.id)) s
  ];
  if (add.isEmpty) return feed;
  final at = anchorId == null ? -1 : feed.indexWhere((s) => s.id == anchorId);
  return [...feed.sublist(0, at + 1), ...add, ...feed.sublist(at + 1)];
}

/// One card per event: same-cluster approved siblings do ship (the pipeline's
/// collapse is best-effort — "Chandrasekaran resigns" once ran as 6 cards),
/// and every card already credits the whole cluster's outlets, so dropping
/// siblings loses nothing. Input pages are newest-first: first occurrence
/// wins. [have] = clusters already in the feed, so a late sibling of a card
/// the reader may be looking at is dropped, never swapped in under them.
List<Story> collapseClusters(List<Story> list, {Set<String> have = const {}}) {
  final seen = {...have};
  return [
    for (final s in list)
      if (s.clusterId == null || seen.add(s.clusterId!)) s
  ];
}

/// The one feed the reader scrolls. A story with a null category (shouldn't
/// happen for approved rows, but guard) shows only when nothing is excluded;
/// a null impact score counts as 0.
List<Story> visibleStories(
        List<Story> list, Set<String> enabled, int minImp, String horizon,
        {Set<String> mutedSrc = const {}, Set<String> mutedSym = const {}}) =>
    [
      for (final s in list)
        if ((s.category == null
                ? enabled.length == feedCategories.length
                : enabled.contains(s.category)) &&
            (s.impactScore ?? 0) >= minImp &&
            !mutedSrc.contains(publisher(s.sourceName)) &&
            !s.companies.any((c) => mutedSym.contains(c.nseSymbol)) &&
            // Same convention as null category: a story with no horizon shows
            // only when the lens is wide open. 'both' belongs to either lens.
            (horizon == 'all' ||
                (horizon == 'short'
                    ? s.impactHorizon == 'short_term' ||
                        s.impactHorizon == 'both'
                    : s.impactHorizon == 'long_term' ||
                        s.impactHorizon == 'both')))
          s
    ];

/// This session's reading, fed by onPageChanged. Module state, never reset:
/// the process lifetime IS the session.
final sessionViewedIds = <int>{};
final sessionCategoryCounts = <String, int>{};
final sessionSymbols = <String>{};

void recordSessionView(Story s) {
  if (!sessionViewedIds.add(s.id)) return;
  final c = s.category;
  if (c != null) {
    sessionCategoryCounts[c] = (sessionCategoryCounts[c] ?? 0) + 1;
  }
  for (final co in s.companies) {
    if (co.nseSymbol.isNotEmpty) sessionSymbols.add(co.nseSymbol);
  }
}

String? topCategory(Map<String, int> counts) {
  String? best;
  var n = 0;
  for (final e in counts.entries) {
    if (e.value > n) {
      n = e.value;
      best = e.key;
    }
  }
  return best;
}

/// Largest absolute day move among [symbols] with a live tick; null when
/// none have one.
({String symbol, double pct})? biggestMover(
    Set<String> symbols, Map<String, Tick> ticks) {
  ({String symbol, double pct})? best;
  for (final s in symbols) {
    final p = ticks[s]?.changePct;
    if (p != null && (best == null || p.abs() > best.pct.abs())) {
      best = (symbol: s, pct: p);
    }
  }
  return best;
}

/// Watchlist boost, bucketed: within 6-hour bands of published_at (absolute
/// epoch bands — deterministic), stories tagging a followed company float to
/// the band top; order is stable otherwise (explicit index tiebreak — Dart's
/// sort isn't stable). Chronology stays sacred at macro scale: a watchlist
/// story can jump at most ~6h, so "this morning" never outranks "right now"
/// (the owner removed severity-first ordering for exactly that failure).
/// Empty watchlist = identity. Null publishedAt sinks with the oldest.
List<Story> rankStories(List<Story> list, Set<int> watchlist) {
  if (watchlist.isEmpty || list.length < 2) return list;
  int band(Story s) => s.publishedAt == null
      ? -1
      : s.publishedAt!.toUtc().millisecondsSinceEpoch ~/
          Duration.millisecondsPerHour ~/
          6;
  bool hit(Story s) => s.companies.any((c) => watchlist.contains(c.id));
  final idx = {for (var i = 0; i < list.length; i++) list[i].id: i};
  return [...list]..sort((a, b) {
      final ba = band(a), bb = band(b);
      if (ba != bb) return bb.compareTo(ba); // newer band first
      final ha = hit(a), hb = hit(b);
      if (ha != hb) return ha ? -1 : 1;
      return idx[a.id]!.compareTo(idx[b.id]!);
    });
}

/// Ordering for a page-1 seed: today's latest first. The page arrives newest
/// first from SQL; it splits at the last-visit boundary and each side ranks
/// independently — a float can never drag an old story above a new one, which
/// would corrupt feedEntries' divider detection.
List<Story> orderSeed(List<Story> page,
    {DateTime? lastSeen, Set<int> watchlist = const {}}) {
  if (page.length < 2) return [...page];
  bool fresh(Story s) =>
      lastSeen != null && (s.publishedAt?.isAfter(lastSeen) ?? false);
  final newer = [
    for (final s in page)
      if (fresh(s)) s
  ];
  final older = [
    for (final s in page)
      if (!fresh(s)) s
  ];
  return [...rankStories(newer, watchlist), ...rankStories(older, watchlist)];
}

/// One page of the feed's vertical PageView: a story, the caught-up divider
/// (carrying the count of stories newer than the last-visit stamp), or the
/// end-of-feed page.
class FeedEntry {
  const FeedEntry.story(Story this.story)
      : newCount = null,
        isEnd = false,
        isRecap = false;
  const FeedEntry.caughtUp(int this.newCount)
      : story = null,
        isEnd = false,
        isRecap = false;
  const FeedEntry.end()
      : story = null,
        newCount = null,
        isEnd = true,
        isRecap = false;
  const FeedEntry.recap()
      : story = null,
        newCount = null,
        isEnd = false,
        isRecap = true;
  final Story? story;
  final int? newCount; // non-null = the divider page
  final bool isEnd;
  final bool isRecap; // session recap interstitial
}

/// The exact page list the PageView consumes — index math lives here, nowhere
/// else. The divider sits before the first OLD story that follows a NEW one,
/// so LIVE splices below the boundary can't move it. No new→old transition (first
/// install, nothing new, everything new) means no divider — the feed looks
/// exactly as it always did. A session-recap page follows every 25th story,
/// suppressed at the list end and next to the divider. Invariants callers
/// rely on: index 0 is always a story when [shown] is non-empty;
/// divider/recap/end are always preceded by a story.
const recapEvery = 25;

List<FeedEntry> feedEntries(
    List<Story> shown, DateTime? lastSeen, bool exhausted) {
  bool fresh(Story s) =>
      lastSeen != null && (s.publishedAt?.isAfter(lastSeen) ?? false);
  var at = -1;
  for (var i = 1; i < shown.length; i++) {
    if (!fresh(shown[i]) && fresh(shown[i - 1])) {
      at = i;
      break;
    }
  }
  final newCount = at < 0 ? 0 : shown.where(fresh).length;
  return [
    for (var i = 0; i < shown.length; i++) ...[
      if (i == at) FeedEntry.caughtUp(newCount),
      FeedEntry.story(shown[i]),
      if ((i + 1) % recapEvery == 0 && i + 1 != at && i + 1 < shown.length)
        const FeedEntry.recap(),
    ],
    if (exhausted) const FeedEntry.end(),
  ];
}

final storiesProvider = FutureProvider<List<Story>>((ref) async {
  // Feed ranking: newest first, full stop. Severity-first ordering froze the
  // feed — 41 stale L1/L2 cards outranked every fresh L3/L4 story; impact is
  // on the card instead. The featured pin went the same way: a day-old
  // "featured" card must never sit above today's news.
  final since = DateTime.now()
      .toUtc()
      .subtract(const Duration(hours: 48))
      .toIso8601String();
  try {
    final rows = await Supabase.instance.client
        .from('stories')
        .select(storyCols)
        .eq('status', 'approved')
        .gte('published_at', since)
        .order('published_at', ascending: false)
        .limit(50);
    final withOutlets = await _attachOutlets(rows.cast<Map<String, dynamic>>());
    final withCompanies = await _attachCompanies(withOutlets);
    await FeedCache.save(withCompanies);
    ref.read(servingCacheProvider.notifier).state = null;
    return withCompanies.map(Story.fromJson).toList();
  } catch (_) {
    // Offline, or Supabase having a moment. Yesterday's news beats an error
    // screen; only surface the failure if we have nothing saved either.
    final cached = await FeedCache.load();
    if (cached == null || cached.isEmpty) rethrow;
    ref.read(servingCacheProvider.notifier).state = await FeedCache.savedAt();
    return cached.map(Story.fromJson).toList();
  }
});

/// One hydrated page of the feed for the infinite scroll. [before] pages
/// downward (older than the reader's last card); [after] picks up fresh
/// arrivals. Same 48h window, ordering and hydration as the first page.
Future<List<Story>> fetchFeedPage({DateTime? before, DateTime? after}) async {
  final since = DateTime.now()
      .toUtc()
      .subtract(const Duration(hours: 48))
      .toIso8601String();
  var q = Supabase.instance.client
      .from('stories')
      .select(storyCols)
      .eq('status', 'approved')
      .gte('published_at', since);
  // lte, not lt: same-second neighbours must not fall through the crack —
  // mergeStories dedupes the one-card overlap by id.
  if (before != null) q = q.lte('published_at', before.toIso8601String());
  if (after != null) q = q.gt('published_at', after.toIso8601String());
  final rows = await q
      .order('published_at', ascending: false)
      .limit(after != null ? 20 : 50);
  final hydrated = await _attachCompanies(
      await _attachOutlets(rows.cast<Map<String, dynamic>>()));
  return hydrated.map(Story.fromJson).toList();
}

/// Attach every outlet that carried each story, earliest first.
///
/// The pipeline files same-event stories under one cluster_id and publishes
/// only the first as a card; the rest are kept as `duplicate` rows holding
/// their outlet and link. One extra query turns that discarded corroboration
/// into the card's "also reported by" list — six outlets agreeing is a trust
/// signal, and the reader gets a choice of where to read it.
///
/// One query for the whole page, never per card: 50 cards each fetching their
/// own outlets is 50 round trips on a phone network.
Future<List<Map<String, dynamic>>> _attachOutlets(
    List<Map<String, dynamic>> rows) async {
  final clusterIds =
      rows.map((r) => r['cluster_id']).whereType<String>().toSet().toList();
  if (clusterIds.isEmpty) return rows;
  try {
    // headline rides along since 2026-08-28: the story-so-far timeline needs
    // each episode's own wording. Same single query, wider projection.
    final members = await Supabase.instance.client
        .from('stories')
        .select('cluster_id,source_name,source_url,published_at,headline')
        .inFilter('cluster_id', clusterIds);
    final byCluster = <String, List<Map<String, dynamic>>>{};
    for (final m in members.cast<Map<String, dynamic>>()) {
      (byCluster[m['cluster_id'] as String] ??= []).add(m);
    }
    for (final row in rows) {
      final group = byCluster[row['cluster_id']] ?? const [];
      // One entry per NEWSROOM, not per feed. LiveMint arrives as both its own
      // section feed and a Google News proxy ("Mint Companies"); showing both
      // claims two outlets agree when it is one paper twice — the opposite of
      // what this list is for. Sorted first so the survivor of each newsroom is
      // its earliest telling, which is also the one the byline credits.
      final seen = <String>{};
      final sorted = [...group]..sort((a, b) =>
          ((a['published_at'] ?? '') as String)
              .compareTo((b['published_at'] ?? '') as String));
      final outlets = [
        for (final m in sorted)
          if (seen.add(publisher((m['source_name'] ?? '') as String))) m
      ];
      row['outlets'] = outlets;
      // The raw sorted group (headlines kept, newsrooms NOT deduped) feeds
      // the story-so-far page; storyTimeline() dedupes by headline instead.
      row['timeline'] = sorted;
    }
  } catch (_) {
    // Attribution is a bonus, never a reason to lose the feed.
  }
  return rows;
}

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
    // Prices ride the shared `ticks` map, not the row: the row is cached
    // offline and a cached % would replay as live. Not awaited — chips fill
    // in when it lands.
    unawaited(loadTicks([
      for (final l in links.cast<Map<String, dynamic>>())
        l['companies']['nse_symbol'] as String? ?? ''
    ]));
  } catch (_) {
    // Chips are a bonus, never a reason to lose the feed.
  }
  return rows;
}

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen>
    with WidgetsBindingObserver {
  final _pc = PageController();

  /// The one owned feed list: seeded from the provider's first page, grows
  /// at the bottom as the reader nears it, and takes fresh arrivals right
  /// after the card on screen. Not strictly chronological once fresh cards
  /// land mid-stream — that's the point.
  List<Story> _feed = const [];
  List<Story>? _page1Ref; // identity of the provider page we seeded from
  bool _exhausted = false;
  bool _loadingMore = false;
  Timer? _freshTimer;

  @override
  void initState() {
    super.initState();
    pendingStory.addListener(_rebuild);
    enabledCategories.addListener(_onFilterChanged);
    minImpact.addListener(_onFilterChanged);
    horizonFilter.addListener(_onFilterChanged);
    liveMode.addListener(_onLiveToggle);
    // The stamp read is async and may land after the first data build.
    lastSeenAtLaunch.addListener(_rebuild);
    // _rebuild, not _onFilterChanged: muting mid-feed must not teleport to
    // page 0 — the card vanishes and the next one slides into its index.
    mutedSources.addListener(_rebuild);
    mutedSymbols.addListener(_rebuild);
    loadEnabledCategories();
    loadMinImpact();
    loadHorizonFilter();
    loadLastSeenStamp();
    loadFollowedCompanies();
    loadMutes();
    WidgetsBinding.instance.addObserver(this);
    _startFreshTimer();
  }

  /// The feed lives in an IndexedStack and never disposes, so the poll would
  /// otherwise keep hitting Supabase from the background all day. Pause kills
  /// the timer; resume refreshes immediately (a returning reader shouldn't
  /// stare at hours-old cards for up to 90s) and restarts it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _freshTimer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _pullFresh();
      _startFreshTimer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _freshTimer?.cancel();
    pendingStory.removeListener(_rebuild);
    enabledCategories.removeListener(_onFilterChanged);
    minImpact.removeListener(_onFilterChanged);
    horizonFilter.removeListener(_onFilterChanged);
    liveMode.removeListener(_onLiveToggle);
    lastSeenAtLaunch.removeListener(_rebuild);
    mutedSources.removeListener(_rebuild);
    mutedSymbols.removeListener(_rebuild);
    _pc.dispose();
    super.dispose();
  }

  void _startFreshTimer() {
    _freshTimer?.cancel();
    // LIVE hugs the edge at 15s; ambient 90s matches the pipeline's cadence.
    _freshTimer = Timer.periodic(
        Duration(
            seconds: liveMode.value ? livePollSeconds : ambientPollSeconds),
        (_) => _pullFresh());
  }

  void _onLiveToggle() {
    track(liveMode.value ? 'live_on' : 'live_off');
    _startFreshTimer();
    // Going live re-baselines to the true latest and starts from the newest
    // card — same deterministic path as pull-to-refresh.
    if (liveMode.value) _manualRefresh();
    _rebuild();
  }

  bool _refreshing = false;

  /// The one refresh everything shares: refetch the newest page, re-seed,
  /// land on the newest card. Deterministic — no gesture arbitration.
  Future<void> _manualRefresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final fresh = ref.refresh(storiesProvider.future);
      await fresh;
      if (mounted && _pc.hasClients) _pc.jumpToPage(0);
    } catch (_) {
      // Offline: the current cards stand; nothing to report beyond the
      // cache banner the provider already raises.
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// The newest loaded story is on screen (the feed opens at the top) — that's
  /// next launch's divider stamp. Write only when it advances; a cache-served
  /// feed no-ops (its newest can't beat the stamp it was saved under).
  DateTime? _seenStamped;
  void _recordSeen() {
    DateTime? newest;
    for (final s in _feed) {
      if (s.publishedAt != null &&
          (newest == null || s.publishedAt!.isAfter(newest))) {
        newest = s.publishedAt;
      }
    }
    if (newest != null &&
        (_seenStamped == null || newest.isAfter(_seenStamped!))) {
      _seenStamped = newest;
      setLastSeenStamp(newest);
    }
  }

  /// Seed (or re-seed after a pull-to-refresh) from the provider's page.
  List<Story> _seeded(List<Story> page1) {
    if (!identical(page1, _page1Ref)) {
      _page1Ref = page1;
      // ponytail: the prefs stamp read could in theory land after this
      // network fetch — accepted; segmenting just no-ops once.
      _feed = orderSeed(page1,
          lastSeen: lastSeenAtLaunch.value,
          watchlist: followedCompanyIds.value);
      _exhausted = false;
    }
    return _feed;
  }

  /// Clusters already represented in the feed — a fresh sibling of one of
  /// these is a duplicate card, not news.
  Set<String> _feedClusters() =>
      {for (final s in _feed) if (s.clusterId != null) s.clusterId!};

  /// What the PageView actually shows: one card per cluster, then the
  /// reader's filters. _feed itself stays RAW (siblings kept) so the
  /// pagination cursor and exhaustion logic never miss ground that display
  /// collapsed away.
  List<Story> _shownStories() => visibleStories(collapseClusters(_feed),
      enabledCategories.value, minImpact.value, horizonFilter.value,
      mutedSrc: mutedSources.value, mutedSym: mutedSymbols.value);

  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted) return;
    _loadingMore = true;
    try {
      DateTime? cursor;
      for (final s in _feed) {
        // oldest card anywhere in the stream — fresh mid-stream inserts mean
        // the list isn't strictly chronological, so scan rather than peek
        if (s.publishedAt != null &&
            (cursor == null || s.publishedAt!.isBefore(cursor))) {
          cursor = s.publishedAt;
        }
      }
      if (cursor == null) return;
      // Older pages sit below the caught-up divider: plain watchlist rank,
      // no segmenting. Same ids either way, so exhaustion math is untouched.
      final page = rankStories(
          await fetchFeedPage(before: cursor), followedCompanyIds.value);
      final merged = mergeStories(_feed, page);
      if (merged.length == _feed.length) {
        _exhausted = true; // the 48h window is drained — the feed may end
      } else {
        _feed = merged;
      }
      if (mounted) setState(() {});
    } catch (_) {
      // Offline mid-scroll: the reader keeps what's loaded; the next swipe
      // near the bottom simply tries again.
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _pullFresh() async {
    if (!mounted) return;
    // Alive-but-hidden on another tab: don't poll into the void.
    if (homeTab.value != 0) return;
    // An empty feed has no newest-stamp to poll from; the full refresh is the
    // only way it can ever recover (pipeline stall, quiet-hour install).
    if (_feed.isEmpty) {
      _manualRefresh();
      return;
    }
    DateTime? newest;
    for (final s in _feed) {
      if (s.publishedAt != null &&
          (newest == null || s.publishedAt!.isAfter(newest))) {
        newest = s.publishedAt;
      }
    }
    if (newest == null) return;
    try {
      // ponytail: a fresh sibling of a card already in the feed is DROPPED,
      // not swapped in — replacing could yank the card being read, and the
      // existing card's outlet credits already tell the multi-source story.
      final fresh = collapseClusters(await fetchFeedPage(after: newest),
          have: _feedClusters());
      if (fresh.isEmpty || !mounted) return;
      // Anchor on the card being read RIGHT NOW: the fresh cards become the
      // very next swipe, seamlessly — never a jump, never behind the reader.
      int? anchorId;
      final shown = _shownStories();
      final entries =
          feedEntries(shown, lastSeenAtLaunch.value, _exhausted);
      final page = _pc.hasClients ? _pc.page?.round() : null;
      if (page != null && shown.isNotEmpty) {
        final i = page.clamp(0, entries.length - 1);
        // Sitting on the divider or end page: anchor to the story just above
        // (safe — sentinels are never at index 0 and always follow a story).
        anchorId = (entries[i].story ?? entries[i - 1].story)?.id;
      }
      final grown = insertFresh(_feed, fresh, anchorId);
      if (grown.length != _feed.length) {
        _feed = grown;
        // LIVE promises freshness; a silent off-screen splice delivers
        // nothing. One light tap is the honest minimum.
        if (liveMode.value) HapticFeedback.lightImpact();
        setState(() {});
      }
    } catch (_) {
      // A missed poll is nothing; the next one runs in 90s.
    }
  }

  /// A different filter is a different feed: start it from its top card.
  void _onFilterChanged() {
    if (_pc.hasClients) _pc.jumpToPage(0);
    _rebuild();
  }

  /// An alert tapped while the feed is already on screen changes nothing the
  /// providers watch, so ask for the frame that runs [_land].
  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// Called after the frame that built the PageView, so the controller has
  /// clients to jump with.
  void _land() {
    final id = pendingStory.value;
    if (id == null || !mounted) return;
    pendingStory.value = null;
    // The alerted story must never be invisible because of a chip — reset the
    // filter, then jump AFTER the frame that rebuilds the unfiltered PageView
    // (jumping now would index into the still-filtered list).
    resetFilterForAlert();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The same entries the PageView shows — _feed, not the provider page,
      // so LIVE splices and the divider can't skew the landing index.
      final entries =
          feedEntries(_shownStories(), lastSeenAtLaunch.value, _exhausted);
      if (jumpToStory(_pc, entries, id)) return;
      // Aged past the feed's 48h window, unapproved since the alert went out,
      // or we are serving the offline cache. One card beats the wrong card.
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => StoryDetailScreen(storyId: id)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final stories = ref.watch(storiesProvider);
    final cachedAt = ref.watch(servingCacheProvider);
    return stories.when(
      loading: () => Center(child: appSpinner()),
      error: (e, _) => _Offline(onRetry: () => ref.refresh(storiesProvider)),
      data: (list) {
        if (pendingStory.value != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _land());
        }
        _seeded(list);
        _recordSeen();
        final shown = _shownStories();
        final entries =
            feedEntries(shown, lastSeenAtLaunch.value, _exhausted);
        // A short visible list can't reach onPageChanged's load trigger (one
        // card can't swipe at all), so pull older pages until the filter has
        // enough to show or the 48h window is drained. Each round either grows
        // _feed or sets _exhausted, so this converges; _loadingMore serializes.
        if (!_exhausted && !_loadingMore && shown.length < 5) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _loadMore();
          });
        }
        // Cards keep the full screen; the filter is one round tile at top
        // right, below the system inset so it clears every phone's status
        // bar and notch.
        final inset = MediaQuery.of(context).padding.top;
        return list.isEmpty
            // A dead-end with no way out kept new installs at quiet hours on
            // a permanently blank screen (the pull-to-refresh only exists
            // inside the PageView that isn't built here).
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('No stories yet — check back soon'),
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: _manualRefresh,
                  child: const Text('Try again'),
                ),
              ]))
            : Column(children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  child: cachedAt != null
                      ? _CacheBanner(savedAt: cachedAt)
                      : const SizedBox(width: double.infinity),
                ),
                const AnimatedSize(
                    duration: Duration(milliseconds: 200),
                    child: _TrendingStrip()),
                Expanded(
                  child: Stack(children: [
                    shown.isEmpty
                        ? Center(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                const Icon(Icons.tune, size: 30, color: inkDim),
                                const SizedBox(height: 12),
                                Text('Nothing matches your filters',
                                    style: serif.copyWith(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 6),
                                Text('Tap the dial to widen them.',
                                    style: mono.copyWith(fontSize: 11.5)),
                              ]))
                        : NotificationListener<OverscrollNotification>(
                            // RefreshIndicator on a vertical PageView loses
                            // the gesture to the page snap (seen on device:
                            // pull did nothing). Overscroll past the first
                            // card IS the pull — trigger the refresh
                            // directly, no arbitration to lose.
                            onNotification: (n) {
                              // depth 0 = the PageView itself; a card's inner
                              // summary scroll must not refresh the feed.
                              if (n.depth == 0 &&
                                  n.overscroll < -6 &&
                                  _pc.hasClients &&
                                  (_pc.page ?? 1) < 0.5) {
                                _manualRefresh();
                              }
                              return false;
                            },
                            child: PageView.builder(
                              controller: _pc,
                              scrollDirection: Axis.vertical,
                              itemCount: entries.length,
                              onPageChanged: (i) {
                                final s = entries[i].story;
                                if (s != null) {
                                  _logView(s.id);
                                  recordSessionView(s);
                                }
                                // A few cards from the bottom: fetch the
                                // next page before the reader gets there.
                                if (i >= entries.length - 4) {
                                  _loadMore();
                                }
                              },
                              itemBuilder: (context, i) {
                                final e = entries[i];
                                return e.story != null
                                    ? StoryPager(story: e.story!)
                                    : e.isEnd
                                        ? const _EndOfFeed()
                                        : e.isRecap
                                            ? const _RecapPage()
                                            : _CaughtUpPage(
                                                newCount: e.newCount!);
                              },
                            ),
                          ),
                    if (_refreshing)
                      Positioned(
                          // banner up = the Stack starts below the notch
                          // already; don't push the bar down a second time
                          top: cachedAt != null ? 0 : inset,
                          left: 0,
                          right: 0,
                          child: const LinearProgressIndicator(
                              minHeight: 2,
                              color: green,
                              backgroundColor: Colors.transparent)),
                    Positioned(
                        top: cachedAt != null ? 8 : inset + 8,
                        left: 16,
                        child: const LiveButton()),
                    Positioned(
                        top: cachedAt != null ? 8 : inset + 8,
                        right: 16,
                        child: const FeedFilterButton()),
                  ]),
                ),
              ]);
      },
    );
  }

  void _logView(int storyId) {
    // A view log is bookkeeping, never worth an error surface (also lets
    // widget tests swipe the real feed with Supabase uninitialized).
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      Supabase.instance.client
          .from('events')
          .insert({'user_id': uid, 'story_id': storyId, 'type': 'view'}).then(
              (_) {},
              onError: (_) {});
      track('view', {'story_id': storyId});
    } catch (_) {}
  }
}

/// The honest end (owner 2026-08-14): when the 48h window is drained the
/// feed stops — no loop, no spinner theatre.
class _EndOfFeed extends StatelessWidget {
  const _EndOfFeed();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.done_all_rounded, size: 30, color: inkDim),
        const SizedBox(height: 12),
        Text("You're all caught up",
            style: serif.copyWith(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text("That's the last 48 hours of market news.",
            style: mono.copyWith(fontSize: 11.5)),
      ]),
    );
  }
}

/// The caught-up divider: one full page at the boundary between stories newer
/// than the last visit and older ones. Copy deliberately distinct from
/// _EndOfFeed's "You're all caught up".
class _CaughtUpPage extends StatelessWidget {
  const _CaughtUpPage({required this.newCount});
  final int newCount;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.vertical_align_top_rounded, size: 30, color: inkDim),
        const SizedBox(height: 12),
        Text("That's everything new",
            style: serif.copyWith(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
            newCount == 1
                ? '1 new story since your last visit — older news below.'
                : '$newCount new stories since your last visit — '
                    'older news below.',
            style: mono.copyWith(fontSize: 11.5)),
      ]),
    );
  }
}

/// Session recap interstitial: every 25th card, a one-page breather with the
/// session's reading stats. Dumb rendering of tested pure functions; the
/// mover line self-omits when no viewed ticker has a live tick.
class _RecapPage extends StatelessWidget {
  const _RecapPage();

  @override
  Widget build(BuildContext context) {
    final n = sessionViewedIds.length;
    final cat = topCategory(sessionCategoryCounts);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.receipt_long_rounded, size: 30, color: inkDim),
        const SizedBox(height: 12),
        Text('Your session so far',
            style: serif.copyWith(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
            '${n == 1 ? '1 story' : '$n stories'} read'
            '${cat == null ? '' : ' — mostly $cat'}.',
            style: mono.copyWith(fontSize: 11.5)),
        ValueListenableBuilder<Map<String, Tick>>(
          valueListenable: ticks,
          builder: (_, m, __) {
            final mover = biggestMover(sessionSymbols, m);
            if (mover == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${mover.symbol} ',
                    style: mono.copyWith(fontSize: 11.5)),
                Text(fmtPct(mover.pct, decimals: 1),
                    style: mono.copyWith(
                        fontSize: 11.5,
                        color: mover.pct >= 0 ? green : red)),
                Text(' — the biggest mover you read.',
                    style: mono.copyWith(fontSize: 11.5)),
              ]),
            );
          },
        ),
      ]),
    );
  }
}

/// LIVE toggle, top left — the filter dial's mirror twin. Red when on (red =
/// market-direction urgency in this app's language), calm surface when off.
class LiveButton extends StatelessWidget {
  const LiveButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: liveMode,
      builder: (context, on, _) => GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          liveMode.value = !on;
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: on
                ? red.withValues(alpha: 0.18)
                : surface.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: on ? red : border, width: on ? 1.5 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.sensors, size: 16, color: on ? red : inkDim),
            const SizedBox(width: 5),
            Text('LIVE',
                style: mono.copyWith(
                    fontSize: 10.5,
                    color: on ? red : inkDim,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
          ]),
        ),
      ),
    );
  }
}

/// One round tile at top right (owner's call 2026-08-12: a symbol, not an
/// edge-to-edge strip, so it fits every phone). Same visual language as the
/// share palette's tiles: circular, tint glow when live, mono microlabel.
/// Glows green whenever a filter is narrowing the feed — a thin feed must
/// never be a mystery.
class FeedFilterButton extends StatelessWidget {
  const FeedFilterButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: enabledCategories,
      builder: (context, _, __) => ValueListenableBuilder<int>(
        valueListenable: minImpact,
        builder: (context, _, __) {
          final live = filtersActive();
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              showFeedFilterSheet(context);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: live
                    ? green.withValues(alpha: 0.18)
                    : surface.withValues(alpha: 0.96),
                shape: BoxShape.circle,
                border: Border.all(
                    color: live ? green : border, width: live ? 1.5 : 1),
              ),
              child: Icon(Icons.tune, size: 18, color: live ? green : inkDim),
            ),
          );
        },
      ),
    );
  }
}

/// The one pill treatment every filter surface wears (tint glow, mono label,
/// 140ms ease) — the dial sheet and both ledger-line mini sheets share it.
Widget filterPill(String label, bool on, Color tint, VoidCallback onTap,
        {double fontSize = 11}) =>
    GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: on ? tint.withValues(alpha: 0.18) : surface,
          border: Border.all(color: on ? tint : border, width: on ? 1.5 : 1),
        ),
        child: Text(label,
            style: mono.copyWith(
                fontSize: fontSize,
                color: on ? tint : inkDim,
                fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
      ),
    );

/// Shared dressing for the clay-black filter sheets: square corners, mono
/// header, one Wrap of pills.
void showPillSheet(BuildContext context, String header,
    Widget Function(BuildContext) pills) {
  showModalBottomSheet(
    context: context,
    backgroundColor: bg,
    shape: const RoundedRectangleBorder(), // square corners, clay-black
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(header,
                  style:
                      mono.copyWith(fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Builder(builder: pills),
            ]),
      ),
    ),
  );
}

/// The dial's panel: categories only (owner 2026-08-21 — impact and horizon
/// moved onto the card's ledger line, where they're visible).
void showFeedFilterSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: bg,
    shape: const RoundedRectangleBorder(), // square corners, clay-black
    builder: (_) => ValueListenableBuilder<Set<String>>(
      valueListenable: enabledCategories,
      builder: (context, enabled, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text('YOUR FEED',
                      style: mono.copyWith(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  filterPill(
                      'Reset', filtersActive(), green, resetFilterForAlert,
                      fontSize: 10),
                ]),
                const SizedBox(height: 14),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  filterPill('All', enabled.length == feedCategories.length,
                      green, enableAllCategories),
                  for (final c in feedCategories)
                    filterPill(
                        c, enabled.contains(c), green, () => toggleCategory(c)),
                ]),
                // ponytail: the sheet isn't scrollable — dozens of mutes
                // would overflow; wrap in SingleChildScrollView when a real
                // user gets there.
                ValueListenableBuilder<Set<String>>(
                  valueListenable: mutedSources,
                  builder: (context, srcs, _) =>
                      ValueListenableBuilder<Set<String>>(
                    valueListenable: mutedSymbols,
                    builder: (context, syms, _) =>
                        srcs.isEmpty && syms.isEmpty
                            ? const SizedBox.shrink()
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                    const SizedBox(height: 18),
                                    Text('MUTED — TAP TO UNMUTE',
                                        style: mono.copyWith(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 10),
                                    Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          for (final p in srcs.toList()
                                            ..sort())
                                            filterPill(p.toUpperCase(), true,
                                                red, () => toggleMuteSource(p)),
                                          for (final s in syms.toList()
                                            ..sort())
                                            filterPill(s, true, red,
                                                () => toggleMuteSymbol(s)),
                                        ]),
                                  ]),
                  ),
                ),
              ]),
        ),
      ),
    ),
  );
}

/// Mini sheet behind the card's IMPACT text.
void showImpactSheet(BuildContext context) {
  showPillSheet(
    context,
    'MIN IMPACT',
    (context) => ValueListenableBuilder<int>(
      valueListenable: minImpact,
      builder: (context, minImp, _) =>
          Wrap(spacing: 8, runSpacing: 8, children: [
        filterPill('ANY', minImp == 0, green, () => setMinImpact(0)),
        filterPill('4+', minImp == 4, amber, () => setMinImpact(4)),
        filterPill('6+', minImp == 6, amber, () => setMinImpact(6)),
        // 8+ burns ember, same as the card's IMPACT line
        filterPill('8+', minImp == 8, red, () => setMinImpact(8)),
      ]),
    ),
  );
}

/// Mini sheet behind the card's SHORT/LONG text.
void showHorizonSheet(BuildContext context) {
  showPillSheet(
    context,
    'HORIZON',
    (context) => ValueListenableBuilder<String>(
      valueListenable: horizonFilter,
      builder: (context, h, _) => Wrap(spacing: 8, runSpacing: 8, children: [
        filterPill('ALL', h == 'all', green, () => setHorizonFilter('all')),
        filterPill(
            'SHORT', h == 'short', green, () => setHorizonFilter('short')),
        filterPill('LONG', h == 'long', green, () => setHorizonFilter('long')),
      ]),
    ),
  );
}

class StoryCard extends ConsumerStatefulWidget {
  const StoryCard({super.key, required this.story, this.onReadMore});
  final Story story;

  /// Feed-only: the bottom "Read more" strip's tap, wired by StoryPager to the
  /// same page-turn as a left swipe. Null (detail/saved/stock) hides the strip.
  final VoidCallback? onReadMore;

  @override
  ConsumerState<StoryCard> createState() => _StoryCardState();
}

class _StoryCardState extends ConsumerState<StoryCard>
    with TickerProviderStateMixin {
  Story get story => widget.story;

  /// This session's optimistic intent; null means "trust the saved list".
  /// A plain bool could only ever express saving — there was no way to say
  /// "I just unsaved this" without the server list overriding it back.
  bool? _pendingSave;
  final _shareKey = GlobalKey();

  /// Same PageView-reuse trap _MediaStrip and StoryPager document: without
  /// this, a save toggled on the last story paints this one's bookmark.
  @override
  void didUpdateWidget(StoryCard old) {
    super.didUpdateWidget(old);
    if (old.story.id != widget.story.id) _pendingSave = null;
  }

  static const _tileSize = 46.0;
  static const _tileGap = 10.0;

  /// Travel per tile for the vertical ribbon: wide, because a stray flick
  /// there navigates away.
  static const _stepPx = 84.0;

  /// Travel per cell in the share grid, deliberately shorter. The grid is a
  /// glide across nine targets rather than a walk along a row, so it wants to
  /// be light under the thumb; the grid's own geometry stops a wobble
  /// crossing a boundary, which is what the wider step was guarding against.
  static const _gridStepPx = 52.0;
  int? _activeTarget;
  Offset? _pressOrigin;
  final _bookmarkKey = GlobalKey();
  bool _holdIsRibbon = false;

  late final AnimationController _burst = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 550));
  late final AnimationController _palette = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 200));

  /// Recognizers behind the summary's tappable glossary terms — rebuilt per
  /// build, disposed here (the State owns them; DeepReadPages stays static).
  final _termTaps = <TapGestureRecognizer>[];

  /// term -> definition, once per session across all cards. The qa function's
  /// qa_cache makes the fetch itself a once-ever cost globally.
  static final _termDefs = <String, String>{};

  @override
  void dispose() {
    _burst.dispose();
    _palette.dispose();
    for (final r in _termTaps) {
      r.dispose();
    }
    super.dispose();
  }

  Future<String?> _define(String term) async {
    final key = term.toLowerCase();
    if (_termDefs.containsKey(key)) return _termDefs[key];
    try {
      final res = await Supabase.instance.client.functions
          .invoke('qa', body: {'question': term, 'mode': 'define'});
      final a = QaAnswer.fromJson(Map<String, dynamic>.from(res.data));
      final def =
          a.sections.isNotEmpty ? a.sections.first.body : a.whatsHappening;
      if (def.trim().isEmpty) return null;
      return _termDefs[key] = def;
    } catch (_) {
      return null; // a failed lookup shows the honest fallback, never an error
    }
  }

  void _showDefinition(String term) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: bg,
      shape: const RoundedRectangleBorder(),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(term.toUpperCase(),
                  style: mono.copyWith(fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              FutureBuilder<String?>(
                future: _define(term),
                builder: (_, snap) => Text(
                    snap.connectionState != ConnectionState.done
                        ? 'Looking it up…'
                        : snap.data ??
                            'No definition right now — try asking in Ask.',
                    style: const TextStyle(fontSize: 15, height: 1.5)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Summary as spans with tappable glossary terms (dotted underline). Old
  /// recognizers are disposed on every rebuild; share capture renders the
  /// plain text instead so underlines never bake into the PNG.
  List<InlineSpan> _summarySpans(TextStyle base) {
    for (final r in _termTaps) {
      r.dispose();
    }
    _termTaps.clear();
    return [
      for (final seg in glossarySegments(story.summary ?? ''))
        if (seg.isTerm)
          TextSpan(
            text: seg.text,
            style: base.copyWith(
                decoration: TextDecoration.underline,
                decorationStyle: TextDecorationStyle.dotted,
                decorationColor: inkDim),
            recognizer: () {
              final r = TapGestureRecognizer()
                ..onTap = () => _showDefinition(seg.text);
              _termTaps.add(r);
              return r;
            }(),
          )
        else
          TextSpan(text: seg.text, style: base),
    ];
  }

  bool _isSavedNow() {
    final known = ref.read(savedProvider).valueOrNull;
    return _pendingSave ?? (known?.any((s) => s.id == story.id) ?? false);
  }

  /// Toggles. Optimistic in both directions: the icon flips the instant you
  /// tap and only reverts if the write actually fails. Waiting on a network
  /// round-trip before showing anything is what made saving feel broken.
  Future<void> _toggleSave({bool viaDoubleTap = false}) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    final was = _isSavedNow();
    // Double-tap only ever saves — the gesture people already know should
    // never take something away by accident.
    if (viaDoubleTap && was) return;

    setState(() => _pendingSave = !was);
    HapticFeedback.selectionClick();
    if (!was && viaDoubleTap) _burst.forward(from: 0);
    try {
      final saves = Supabase.instance.client.from('saves');
      if (was) {
        await saves.delete().eq('user_id', user.id).eq('story_id', story.id);
      } else {
        await saves.upsert({'user_id': user.id, 'story_id': story.id});
        track('save', {'story_id': story.id});
      }
      // The Saved tab reads its own provider; without this it kept serving the
      // list it fetched on first open and the change never appeared there.
      ref.invalidate(savedProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _pendingSave = was); // never leave a lie on screen
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not ${was ? 'remove' : 'save'}: $e')));
    }
  }

  /// The card as a PNG — every share is an ad (spec §8). The media strip
  /// hides itself for this one frame (see shareCapture) so a hotlinked press
  /// photo is never baked into the file we hand off to another app.
  Future<Uint8List?> _renderCard() async {
    shareCapture.value = true;
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          _shareKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      return bytes.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      shareCapture.value = false;
    }
  }

  void _logShare() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    Supabase.instance.client
        .from('events')
        .insert({'user_id': uid, 'story_id': story.id, 'type': 'share'}).then(
            (_) {},
            onError: (_) {});
    track('share', {'story_id': story.id});
  }

  bool _sharing = false;

  Future<void> _fire(String targetId) async {
    // Two quick hold-releases would overlap captures: the first one's finally
    // drops shareCapture mid-flight and the press photo gets baked into the
    // second PNG. Serialize instead.
    if (_sharing) return;
    _sharing = true;
    try {
      final toast = await runShareTarget(targetId, story, _renderCard);
      _logShare();
      if (toast != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(milliseconds: 1100),
            content: Text(toast)));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not share')));
    } finally {
      _sharing = false;
    }
  }

  /// Fires the ribbon's choice. Kept separate from _fire so the share
  /// analytics event never counts a navigation.
  void _fireRibbon(int index) {
    final id = ribbonTargets[index].id;
    if (id != 'saved' && id != 'watchlist') return; // cancel is a no-op
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
              appBar: AppBar(
                  backgroundColor: bg,
                  surfaceTintColor: bg,
                  elevation: 0,
                  leading: const BackButton(color: ink)),
              body:
                  id == 'saved' ? const SavedScreen() : const WatchlistScreen(),
            )));
  }

  // ---- hold-and-slide share ----

  bool _pressedBookmark(Offset global) {
    final box = _bookmarkKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return false;
    // A little forgiveness around a 44px target that sits under a thumb.
    return ((box.localToGlobal(Offset.zero) & box.size).inflate(10))
        .contains(global);
  }

  void _openPalette(Offset origin) {
    // One long-press recognizer decides both gestures by where it began.
    // Two overlapping recognizers — card-wide for share, bookmark for the
    // ribbon — were genuinely ambiguous, and the card's won every time, so
    // holding the bookmark opened the share palette instead.
    HapticFeedback.mediumImpact();
    _holdIsRibbon = _pressedBookmark(origin);
    _pressOrigin = origin;
    setState(() => _activeTarget =
        _holdIsRibbon ? defaultRibbonTarget : defaultShareTarget);
    _palette.forward();
  }

  /// Selection is measured from where the thumb pressed, not from the palette's
  /// box. Hit-testing against the row itself failed in the obvious way: the
  /// thumb sits on the rail ~96px *below* the tiles, so it never fell inside
  /// them and nothing ever highlighted. Distance travelled is what the gesture
  /// is actually about, and it does not care where anything is laid out.
  void _trackThumb(Offset globalPos) {
    if (_pressOrigin == null) return;
    final dx = globalPos.dx - _pressOrigin!.dx;
    final dy = globalPos.dy - _pressOrigin!.dy;

    // The ribbon is the same gesture on the other axis: slide up to walk it.
    if (_holdIsRibbon) {
      final next = (defaultRibbonTarget + (dy / _stepPx).round())
          .clamp(0, ribbonTargets.length - 1);
      if (next != _activeTarget) {
        HapticFeedback.selectionClick();
        setState(() => _activeTarget = next);
      }
      return;
    }

    // Escape hatch, well past the grid's own reach so it cannot fire by
    // accident now that a Cancel tile exists too.
    if (dy > 240) {
      if (_activeTarget != null) setState(() => _activeTarget = null);
      return;
    }

    // Two axes, one cell each: the grid opens on its centre, so a target is
    // never more than one short glide away in either direction.
    const cols = shareGridColumns;
    final rows = (shareTargets.length / cols).ceil();
    final col = (1 + (dx / _gridStepPx).round()).clamp(0, cols - 1);
    final row = (1 + (dy / _gridStepPx).round()).clamp(0, rows - 1);
    final next = (row * cols + col).clamp(0, shareTargets.length - 1);
    if (next != _activeTarget) {
      HapticFeedback.selectionClick();
      setState(() => _activeTarget = next);
    }
  }

  Future<void> _closePalette({bool commit = false}) async {
    final chosen = _activeTarget;
    final wasRibbon = _holdIsRibbon;
    await _palette.reverse();
    if (mounted) setState(() => _activeTarget = null);
    _holdIsRibbon = false;
    if (!commit || chosen == null || !mounted) return;
    if (wasRibbon) {
      _fireRibbon(chosen);
    } else {
      await _fire(shareTargets[chosen].id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dir = directionColor(story.impactDirection);
    // The optimistic flag only knows about taps in this session; the saved list
    // is the source of truth, so a story saved earlier still shows filled.
    final known = ref.watch(savedProvider).valueOrNull;
    final isSaved =
        _pendingSave ?? (known?.any((s) => s.id == story.id) ?? false);
    // top: false — the hero bleeds behind the status bar; _CardHero pads the
    // IMPACT line by the inset itself.
    return SafeArea(
      top: false,
      child: GestureDetector(
        // Plain detector on purpose: LongPressGestureRecognizer already allows
        // unlimited drift before it accepts, so a hand-rolled one bought
        // nothing. Widget tests cover this gesture inside the real feed tree.
        onDoubleTap: () => _toggleSave(viaDoubleTap: true),
        onLongPressStart: (d) => _openPalette(d.globalPosition),
        onLongPressMoveUpdate: (d) => _trackThumb(d.globalPosition),
        onLongPressEnd: (_) => _closePalette(commit: true),
        onLongPressCancel: () => _closePalette(),
        child: Stack(alignment: Alignment.center, children: [
          RepaintBoundary(key: _shareKey, child: _card(dir, isSaved)),

          // Reels-style action rail on the right edge, over the card and
          // outside the RepaintBoundary — share PNGs stay free of UI icons.
          // 90 ends the stack just above the read-more strip; the attribution
          // row is left-anchored, so the icons overlap only empty space.
          Positioned(right: 10, bottom: 90, child: _rail(isSaved)),

          // Dim the card while the palette is up, so the targets read as a
          // layer above rather than more card furniture.
          IgnorePointer(
            child: FadeTransition(
              opacity: Tween<double>(begin: 0, end: 0.55).animate(_palette),
              child: Container(color: bg),
            ),
          ),

          // Centred above the rail: the hold starts anywhere, so the row
          // cannot be anchored to the thumb. 46 keeps the ribbon 44 below
          // the rail anchor, same delta as before the rail dropped.
          Positioned(
            left: 0,
            right: 0,
            bottom: 46,
            child: IgnorePointer(
              child: _holdIsRibbon
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 26),
                        child: RibbonColumn(
                          animation: _palette,
                          activeIndex: _activeTarget,
                          tileSize: _tileSize,
                          gap: _tileGap,
                        ),
                      ),
                    )
                  : Center(
                      child: SharePaletteRow(
                        animation: _palette,
                        activeIndex: _activeTarget,
                        tileSize: _tileSize,
                        gap: _tileGap,
                      ),
                    ),
            ),
          ),

          // brief bookmark flash confirming the double tap registered
          FadeTransition(
            opacity: Tween<double>(begin: 1, end: 0).animate(
                CurvedAnimation(parent: _burst, curve: const Interval(0.5, 1))),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.6, end: 1.25).animate(
                  CurvedAnimation(parent: _burst, curve: Curves.easeOutBack)),
              child: IgnorePointer(
                child: _burst.isAnimating || _burst.isCompleted
                    ? const Icon(Icons.bookmark_rounded, size: 96, color: green)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  bool get _hasGlanceLines =>
      (story.whyItMatters ?? '').isNotEmpty ||
      (story.winnersLosers ?? '').isNotEmpty ||
      story.claimStatus != null;

  static const _claimColor = {
    'confirmed': green,
    'reported': amber,
    'rumour': red,
  };

  /// One merged row: winners/losers · claim status · watchlist flag.
  /// Merged deliberately — three separate lines would tip small phones into
  /// _FitScroll's inner-scroll mode and kill the vertical feed swipe.
  List<Widget> _glanceRow() => [
        ValueListenableBuilder<Set<int>>(
            valueListenable: followedCompanyIds,
            builder: (_, followed, __) {
              final watched = story.companies
                  .where((c) => followed.contains(c.id))
                  .map((c) => c.nseSymbol)
                  .where((s) => s.isNotEmpty)
                  .toList();
              final chips = <Widget>[
                if ((story.winnersLosers ?? '').isNotEmpty)
                  _glanceChip(story.winnersLosers!),
                if (story.claimStatus != null)
                  _glanceChip(story.claimStatus!,
                      dot: _claimColor[story.claimStatus]),
                if (watched.isNotEmpty)
                  _glanceChip('★ ${watched.join(', ')} on your watchlist',
                      dot: null),
                // Read, not listened: the strip's 5-min poll lands well before
                // the next card build. Stays inside this ONE Wrap (see above).
                if (unusualStoryIds.value.contains(story.id))
                  _glanceChip('Wide coverage', dot: green),
              ];
              if (chips.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(spacing: 8, runSpacing: 8, children: chips),
              );
            }),
      ];

  Widget _card(Color dir, bool isSaved) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Hero zone (image-top template, owner 2026-08-18, mockup in
        // docs/mockups/finswipe-card-mockup.html): photo full-bleed with the
        // IMPACT line on a scrim, or the hook in the photo's slot when there
        // is no image.
        _CardHero(story: story, interactive: widget.onReadMore != null),
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: surface,
              border: Border(left: BorderSide(color: dir, width: 3)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Image cards carry the hook below the photo; text cards
                // already showed it inside the hero. maxLines guards the
                // small-phone RenderFlex overflow, as before.
                if (story.imageUrl != null) ...[
                  Text(story.hook ?? story.headline,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: serif.copyWith(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          height: 1.2)),
                  const SizedBox(height: 12),
                ],
                Expanded(
                  child: _FitScroll(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Glance lines (014): why-it-matters above the summary,
                        // then one merged chip row. NULL fields (old stories,
                        // weak lanes) render nothing. When present, the summary
                        // is clamped so the card can't tip into _FitScroll's
                        // inner-scroll mode and eat the vertical feed swipe.
                        if ((story.whyItMatters ?? '').isNotEmpty) ...[
                          Text(story.whyItMatters!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 15,
                                  height: 1.4,
                                  fontWeight: FontWeight.w700,
                                  color: ink)),
                          const SizedBox(height: 8),
                        ],
                        ValueListenableBuilder<bool>(
                            valueListenable: shareCapture,
                            builder: (_, capturing, __) {
                              final base = TextStyle(
                                  fontSize: 15,
                                  height: 1.55,
                                  color: ink.withValues(alpha: 0.8));
                              return capturing
                                  ? Text(story.summary ?? '',
                                      maxLines: _hasGlanceLines ? 5 : null,
                                      overflow: _hasGlanceLines
                                          ? TextOverflow.ellipsis
                                          : null,
                                      style: base)
                                  : Text.rich(
                                      TextSpan(children: _summarySpans(base)),
                                      maxLines: _hasGlanceLines ? 5 : null,
                                      overflow: _hasGlanceLines
                                          ? TextOverflow.ellipsis
                                          : null);
                            }),
                        ..._glanceRow(),
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
                                        // Taller than the inert sector chips and
                                        // carrying the ↗ — this one navigates,
                                        // and nothing else distinguished them.
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 8),
                                        decoration: BoxDecoration(
                                            color: surface,
                                            border: Border.all(color: border)),
                                        child: ValueListenableBuilder<
                                                Map<String, Tick>>(
                                            valueListenable: ticks,
                                            builder: (_, m, __) {
                                              final t = m[c.nseSymbol];
                                              return Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text('\$${c.nseSymbol}',
                                                        style: mono.copyWith(
                                                            fontSize: 12,
                                                            color: ink)),
                                                    if (t?.changePct !=
                                                        null) ...[
                                                      const SizedBox(width: 5),
                                                      Text(
                                                          fmtPct(t!.changePct,
                                                              decimals: 1),
                                                          style: mono.copyWith(
                                                              fontSize: 11,
                                                              color: t.up
                                                                  ? green
                                                                  : red)),
                                                    ],
                                                    const SizedBox(width: 3),
                                                    const Icon(
                                                        Icons.north_east_rounded,
                                                        size: 10,
                                                        color: inkDim),
                                                  ]);
                                            }),
                                      ),
                                    ))
                                .toList(),
                          ),
                        ],
                        if (story.sectors.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: story.sectors
                                .map((s) => Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                          border: Border.all(color: border)),
                                      child: Text(s,
                                          style: mono.copyWith(fontSize: 12)),
                                    ))
                                .toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // Attribution owns the full width now — the action rail
                // floats on the card's right edge (see build).
                _attribution(dir),
              ],
            ),
          ),
        ),
        if (widget.onReadMore != null) _readMoreStrip(dir),
      ],
    );
  }

  /// Deep Read's visible front door: the strip mirrors the inspiration's
  /// bottom teaser and fires the same page-turn as a left swipe. The teaser
  /// text is the headline (freed up by the hook-only card); a hookless card
  /// already shows the headline big, so fall back to the summary there.
  Widget _readMoreStrip(Color dir) {
    final teaser = story.hook != null ? story.headline : (story.summary ?? '');
    return GestureDetector(
      onTap: widget.onReadMore,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              dir.withValues(alpha: 0.05),
              dir.withValues(alpha: 0.12),
            ],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (teaser.isNotEmpty) ...[
              Text(teaser,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: ink.withValues(alpha: 0.85))),
              const SizedBox(height: 6),
            ],
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Read more',
                  style: mono.copyWith(
                      fontSize: 12, fontWeight: FontWeight.w700, color: dir)),
              const SizedBox(width: 5),
              Icon(Icons.arrow_forward_rounded, size: 14, color: dir),
            ]),
          ],
        ),
      ),
    );
  }

  /// Outlet identity, styled like a handle: monogram, name, and the link out.
  ///
  /// Credit goes to whoever published FIRST, not to whichever copy the
  /// pipeline happened to process — being first is the thing worth crediting.
  /// Everyone else who ran it sits behind "+N more".
  Widget _attribution(Color dir) {
    final scoop = story.outlets.isNotEmpty ? story.outlets.first : null;
    final name = scoop?.name ?? story.sourceName;
    final url = scoop?.url ?? story.sourceUrl;
    final others = story.outlets.length - 1;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      InkWell(
        onTap: () => openExternal(context, url),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          // The outlet's favicon when the link has a real host; the letter
          // monogram otherwise (Google-News proxies, dead icons, offline).
          OutletMark(name: name, url: url, color: dir),
          const SizedBox(width: 9),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.2)),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('Read original', style: mono.copyWith(fontSize: 10.5)),
                  const SizedBox(width: 3),
                  Icon(Icons.north_east_rounded, size: 10, color: inkDim),
                  if (story.confidence != null &&
                      story.confidence != 'high') ...[
                    const SizedBox(width: 8),
                    Text('· ${story.confidence}',
                        style: mono.copyWith(fontSize: 10.5, color: amber)),
                  ],
                ]),
              ],
            ),
          ),
        ]),
      ),
      if (others > 0)
        InkWell(
          onTap: _showOutlets,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Text('+$others more',
                style: mono.copyWith(
                    fontSize: 10.5, color: dir, fontWeight: FontWeight.w600)),
          ),
        ),
    ]);
  }

  /// Every outlet that ran this story, earliest first. Reading the same event
  /// in several papers is the point — so each row opens that outlet directly.
  void _showOutlets() {
    showModalBottomSheet<void>(
      context: context,
      // Same language as the filter sheet: clay-black, deliberately square.
      backgroundColor: bg,
      shape: const RoundedRectangleBorder(),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Row(children: [
              Text('Reported by ${story.outlets.length} outlets',
                  style: serif.copyWith(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child:
                  Text('Earliest first', style: mono.copyWith(fontSize: 10.5)),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: story.outlets.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final o = story.outlets[i];
                return ListTile(
                  dense: true,
                  leading: Text(i == 0 ? 'FIRST' : '${i + 1}',
                      style: mono.copyWith(
                          fontSize: 10, color: i == 0 ? green : inkDim)),
                  title: Row(children: [
                    OutletMark(name: o.name, url: o.url, color: inkDim, size: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(o.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                  ]),
                  subtitle: o.publishedAt == null
                      ? null
                      : Text(_when(o.publishedAt!),
                          style: mono.copyWith(fontSize: 10.5)),
                  trailing:
                      Icon(Icons.north_east_rounded, size: 14, color: inkDim),
                  onTap: () => openExternal(context, o.url),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  String _when(DateTime t) {
    final d = DateTime.now().toUtc().difference(t.toUtc());
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  /// Vertical action rail. Share is a single control with two gestures: tap
  /// for the system sheet, hold to slide straight to a destination.
  Widget _rail(bool isSaved) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _railButton(
        key: _bookmarkKey,
        icon: isSaved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
        tint: isSaved ? green : inkDim,
        onTap: _toggleSave,
      ),
      const SizedBox(height: 12),
      _railButton(
        icon: Icons.ios_share_rounded,
        tint: inkDim,
        onTap: () => _fire('card'),
      ),
      const SizedBox(height: 12),
      _railButton(
        icon: Icons.volume_off_outlined,
        tint: inkDim,
        onTap: _showMuteSheet,
      ),
      // Follow this STORY (015): bell pings only when the cluster develops.
      // 4 tiles is the rail's hard cap — a 5th would climb into the hero.
      if (story.clusterId != null) ...[
        const SizedBox(height: 12),
        ValueListenableBuilder<Set<String>>(
            valueListenable: followedClusterIds,
            builder: (_, followed, __) {
              final on = followed.contains(story.clusterId);
              return _railButton(
                icon: on
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_none_rounded,
                tint: on ? green : inkDim,
                onTap: () => toggleFollowCluster(story.clusterId!),
              );
            }),
      ],
    ]);
  }

  /// Mute this card's publisher or any of its tickers. Undo lives in the
  /// filter dial's MUTED row — no SnackBar (filterPill already haptics).
  void _showMuteSheet() {
    final pub = publisher(widget.story.sourceName);
    showPillSheet(
      context,
      'MUTE',
      (sheet) => Wrap(spacing: 8, runSpacing: 8, children: [
        if (pub.isNotEmpty)
          filterPill('MUTE ${pub.toUpperCase()}', false, red, () {
            toggleMuteSource(pub);
            Navigator.pop(sheet);
          }),
        for (final c in widget.story.companies
            .where((c) => c.nseSymbol.isNotEmpty))
          filterPill('MUTE ${c.nseSymbol}', false, red, () {
            toggleMuteSymbol(c.nseSymbol);
            Navigator.pop(sheet);
          }),
      ]),
    );
  }

  Widget _railButton({
    Key? key,
    required IconData icon,
    required Color tint,
    VoidCallback? onTap,
  }) {
    return SizedBox(
      key: key,
      width: 44,
      height: 44,
      child: InkResponse(
        onTap: onTap,
        radius: 26,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          transitionBuilder: (child, a) => ScaleTransition(
              scale: a, child: FadeTransition(opacity: a, child: child)),
          child: Icon(icon, key: ValueKey(icon), size: 24, color: tint),
        ),
      ),
    );
  }
}

/// True while a share PNG capture is in flight (see StoryCard._renderCard).
/// The strip hides itself during capture so the hotlinked press photo it
/// shows on screen is never baked into the redistributed share image — that
/// would be exactly the re-hosting the strip's own hotlink comment forbids.
final shareCapture = ValueNotifier<bool>(false);

/// The card's top zone (image-top template, spec M8 + owner 2026-08-18).
/// Three faces, one widget, because the dead-image state lives here:
///  - photo: full-bleed press image behind the status bar, IMPACT on a scrim.
///    Hotlinked from the origin CDN — we never re-host; a dead URL falls back.
///  - text: no image — the hook takes the photo's slot on plain feed bg.
///  - compact: image exists but is dead or a share capture is in flight —
///    just the IMPACT row, so the PNG keeps the ledger line but never the
///    hotlinked photo, and the hook below the hero still shows exactly once.
/// An outlet's mark: its favicon (Google s2, keyed on the article host) in a
/// tinted ring, or the first-letter monogram when there is no real host or
/// the icon fails to load. One widget for the card credit and the outlet sheet.
class OutletMark extends StatelessWidget {
  const OutletMark(
      {super.key,
      required this.name,
      required this.url,
      required this.color,
      this.size = 32});
  final String name;
  final String url;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = faviconUrl(url);
    Widget monogram() => Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: serif.copyWith(
            fontSize: size * 0.47, fontWeight: FontWeight.w700, color: color));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: icon == null
          ? monogram()
          : Image.network(icon,
              key: const ValueKey('outlet-favicon'), // tests count hero images by type
              width: size * 0.6,
              height: size * 0.6,
              cacheWidth: 64,
              errorBuilder: (_, __, ___) => monogram()),
    );
  }
}

class _CardHero extends StatefulWidget {
  const _CardHero({required this.story, this.interactive = false});
  final Story story;

  /// Feed cards only: the ledger line's halves open the impact and horizon
  /// filter sheets. Detail/saved/stock keep a passive line.
  final bool interactive;

  @override
  State<_CardHero> createState() => _CardHeroState();
}

class _CardHeroState extends State<_CardHero> {
  bool _dead = false;

  @override
  void didUpdateWidget(_CardHero old) {
    super.didUpdateWidget(old);
    // PageView.builder reuses this State across stories (no keys); without
    // this, one dead image permanently hides every later story's image too.
    if (old.story.imageUrl != widget.story.imageUrl) _dead = false;
  }

  String get _horizon => switch (widget.story.impactHorizon) {
        'short_term' => 'SHORT',
        'long_term' => 'LONG',
        'both' => 'SHORT + LONG',
        _ => '',
      };

  /// IMPACT 9/10 · SHORT + LONG — monospace ledger line, centered between the
  /// floating LIVE/filter tiles' 44px row (owner 2026-08-14). The card paints
  /// edge-to-edge now, so the status inset is handled here on every face.
  /// On feed cards each half is a filter door: IMPACT opens the min-impact
  /// sheet, the horizon opens the ALL/SHORT/LONG sheet (owner 2026-08-21).
  /// Single taps ride behind the card's double-tap arena, like the strip.
  Widget _impactRow(BuildContext context) {
    final s = widget.story;
    final impact = Text('IMPACT ${s.impactScore ?? '–'}/10',
        style: mono.copyWith(
            color: impactColor(s.impactScore), fontWeight: FontWeight.w700));
    final horizon =
        _horizon.isEmpty ? null : Text('  ·  $_horizon', style: mono);
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 8),
      child: SizedBox(
        height: 44,
        child: Center(
          // Two texts can't soft-wrap like the old single Text.rich did, so
          // scale the whole line down on a width it doesn't fit.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _ledgerTap(impact, () => showImpactSheet(context)),
              if (horizon != null)
                _ledgerTap(horizon, () => showHorizonSheet(context)),
            ]),
          ),
        ),
      ),
    );
  }

  /// Tap target around one half of the ledger line, padded toward the 44px
  /// row height — the text alone is not thumb-sized.
  Widget _ledgerTap(Widget label, VoidCallback open) {
    final padded =
        Padding(padding: const EdgeInsets.symmetric(vertical: 13), child: label);
    if (!widget.interactive) return padded;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        open();
      },
      child: padded,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: shareCapture,
      builder: (context, capturing, _) {
        final s = widget.story;
        final url = s.imageUrl;
        final heroH = MediaQuery.sizeOf(context).height * 0.35;

        if (url == null) {
          // Text face: the hook lives where the photo would be. minHeight,
          // not a fixed height — a 4-line hook on a small phone grows the
          // zone instead of overflowing it; _FitScroll below absorbs it.
          return Container(
            width: double.infinity,
            color: bg,
            constraints: BoxConstraints(minHeight: heroH * 0.9),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _impactRow(context),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
                  child: Text(s.hook ?? s.headline,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: serif.copyWith(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          height: 1.2)),
                ),
              ],
            ),
          );
        }

        if (capturing || _dead) {
          // Compact face: ledger line only. The hook renders below the hero
          // for every image-bearing story, so nothing is lost.
          return Container(
            width: double.infinity,
            color: bg,
            padding: const EdgeInsets.only(bottom: 8),
            child: _impactRow(context),
          );
        }

        // Photo face.
        // 2x logical width: crisp on device without decoding a 4000px press
        // photo into memory on a budget phone.
        final cacheW = (MediaQuery.of(context).size.width * 2).round();
        final img = Image.network(
          url,
          fit: BoxFit.cover,
          cacheWidth: cacheW,
          // errorBuilder alone leaves a hole; flag + rebuild swaps the face.
          errorBuilder: (_, __, ___) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_dead) setState(() => _dead = true);
            });
            return const SizedBox.shrink();
          },
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : Container(color: surface),
          // Decoded frames fade in instead of hard-cutting over the surface
          // placeholder.
          frameBuilder: (context, child, frame, syncLoaded) => syncLoaded
              ? child
              : AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 220),
                  child: child),
        );

        return SizedBox(
          width: double.infinity,
          height: heroH,
          child: Stack(fit: StackFit.expand, children: [
            img,
            if (s.videoUrl != null)
              InkWell(
                onTap: () => openExternal(context, s.videoUrl!),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration:
                        BoxDecoration(color: bg.withValues(alpha: 0.65)),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: ink, size: 34),
                  ),
                ),
              ),
            // Top scrim so the ledger line reads on any photo.
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                height: MediaQuery.of(context).padding.top + 108,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      bg.withValues(alpha: 0.88),
                      bg.withValues(alpha: 0.55),
                      bg.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            Align(alignment: Alignment.topCenter, child: _impactRow(context)),
            // Hairline where the photo meets the text block.
            const Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                  height: 1,
                  width: double.infinity,
                  child: ColoredBox(color: border)),
            ),
          ]),
        );
      },
    );
  }
}

/// Shown when the network failed and there is nothing cached to fall back on.
class _Offline extends StatelessWidget {
  const _Offline({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 40, color: inkDim),
            const SizedBox(height: 14),
            Text("Can't reach FinSwipe",
                style:
                    serif.copyWith(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Check your connection — your saved stories still work.',
                textAlign: TextAlign.center,
                style: mono.copyWith(fontSize: 12)),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ]),
        ),
      );
}

/// Session memo of generated deep reads: re-encountering a card after the
/// vertical PageView rebuilt its State is instant, no second round trip.
final _deepReadMemo = <int, DeepRead>{};

/// After the deepread daily cap (429), prefetch pauses so every card viewed
/// doesn't burn a doomed invoke. Manual opens still try — a tap is intent,
/// and the admin may have raised the cap via app_config.edge.
/// ponytail: flat 10-min pause, not a server retry-after.
DateTime? _deepReadCapUntil;

/// Page 0 is the story card; swiping LEFT reveals the AI-written whole story
/// as newspaper pages (spec 2026-08-16). Generated on first open by the
/// `deepread` edge function, which caches in stories.deep_read forever after —
/// this widget always asks the function and lets it decide cache vs generate.
/// Feed-only dress: detail/saved/stock screens keep the plain StoryCard.
class StoryPager extends StatefulWidget {
  const StoryPager({super.key, required this.story});
  final Story story;

  @override
  State<StoryPager> createState() => _StoryPagerState();
}

class _StoryPagerState extends State<StoryPager> {
  final _hpc = PageController();
  DeepRead? _read;
  bool _requested = false; // invoke fired for this story (open or prefetch)
  bool _failed = false; // network failure — distinct from an AI refusal
  int? _failedStatus; // HTTP status behind _failed (429 = daily cap)
  bool _onDeep = false; // past the card — back should return, not exit
  bool _opened = false; // the reader actually went deep (analytics gate)
  bool _tracked = false; // deep_read logged once per story per session
  bool _retriedOnOpen = false; // one silent retry when a prefetch had failed
  Timer? _prefetch;

  @override
  void initState() {
    super.initState();
    _read = _deepReadMemo[widget.story.id];
    _hpc.addListener(_onScroll);
    _armPrefetch();
  }

  @override
  void didUpdateWidget(StoryPager old) {
    super.didUpdateWidget(old);
    // The vertical PageView reuses this State across stories (same trap the
    // media strip documents): land the new story on its card, not mid-read.
    if (old.story.id != widget.story.id) {
      _read = _deepReadMemo[widget.story.id];
      _requested = false;
      _failed = false;
      _failedStatus = null;
      _onDeep = false;
      _opened = false;
      _tracked = false;
      _retriedOnOpen = false;
      if (_hpc.hasClients) _hpc.jumpToPage(0);
      _armPrefetch();
    }
  }

  @override
  void dispose() {
    _prefetch?.cancel();
    _hpc.dispose();
    super.dispose();
  }

  /// Speed-read the room: after ~2s on a card the reader might go deep, so
  /// start the write now — a left swipe (or the Read-more strip) then lands on
  /// a finished read. Only viewed cards generate, and the edge function's
  /// server-side cache makes each story a one-time cost across all users
  /// (owner 2026-08-21 — chosen over pipeline pre-generation, which would
  /// spend tokens on stories nobody opens).
  void _armPrefetch() {
    _prefetch?.cancel();
    if (_read != null) return; // memo hit — nothing to warm
    final cap = _deepReadCapUntil;
    if (cap != null && DateTime.now().isBefore(cap)) return; // capped
    final id = widget.story.id;
    _prefetch = Timer(const Duration(seconds: 2), () {
      if (mounted && widget.story.id == id) _ensureRead();
    });
  }

  /// First pull past the card's edge is the "open": analytics fire here (not
  /// on prefetch), and a prefetch that failed quietly gets one silent retry
  /// on the transition edge — never per scroll pixel.
  void _onScroll() {
    final deep = (_hpc.page ?? 0) > 0.5;
    if (deep != _onDeep) {
      setState(() => _onDeep = deep);
      if (deep) {
        _opened = true;
        _maybeTrack();
        // Not for a capped user: the silent retry would just burn another
        // doomed invoke — the button and its honest copy take over.
        if (_failed && !_retriedOnOpen && _failedStatus != 429) {
          _retriedOnOpen = true;
          _retryRead();
        }
      }
    }
    if (deep) _ensureRead();
  }

  /// deep_read means "a person read it" — once per story per session, only
  /// after a real open, whether content arrived before (prefetch) or after.
  void _maybeTrack() {
    if (_tracked || !_opened || !(_read?.hasContent ?? false)) return;
    _tracked = true;
    track('deep_read', {'story_id': widget.story.id});
  }

  Future<void> _ensureRead() async {
    if (_requested || _read != null) return;
    _requested = true;
    final id = widget.story.id;
    if (!remoteConfig.deepReadEnabled) {
      // Admin paused deep reads: the honest "not available" page, no invoke.
      if (mounted) setState(() => _read = DeepRead.fromJson(null));
      return;
    }
    try {
      final res = await Supabase.instance.client.functions.invoke('deepread',
          body: {'story_id': id}).timeout(const Duration(seconds: 20));
      final read = DeepRead.fromJson(
          res.data is Map ? Map<String, dynamic>.from(res.data as Map) : null);
      // A refusal isn't cached server-side either — leave it out of the memo
      // so a later encounter retries against a possibly-richer story.
      // Analytics moved to _maybeTrack (open-gated): a prefetch that is never
      // read must not count as a deep_read.
      if (read.hasContent) _deepReadMemo[id] = read;
      if (mounted && widget.story.id == id) {
        setState(() => _read = read);
        _maybeTrack();
      }
    } on FunctionException catch (e) {
      // The daily cap is an expected state, not an outage (ask.dart
      // precedent): keep the status so the failure page can say so.
      if (e.status == 429) {
        _deepReadCapUntil = DateTime.now().add(const Duration(minutes: 10));
      }
      if (mounted && widget.story.id == id) {
        setState(() {
          _failed = true;
          _failedStatus = e.status;
        });
      }
    } catch (_) {
      if (mounted && widget.story.id == id) {
        // _requested stays true: _onScroll fires per scroll pixel while the
        // deep read is showing, and resetting here turned one offline moment
        // into a burst of invokes. Retry is the button's job now.
        setState(() {
          _failed = true;
          _failedStatus = null;
        });
      }
    }
  }

  void _retryRead() {
    setState(() {
      _failed = false;
      _failedStatus = null;
      _requested = false;
    });
    _ensureRead();
  }

  @override
  Widget build(BuildContext context) {
    final read = _read;
    // "The story so far" is a client-composed page from cluster data — zero
    // AI — slotted between the card and the AI pages when the cluster has a
    // real history. The glossary rides the cached deep_read as a closing page.
    final episodes = storyTimeline(widget.story.timeline);
    final tOff = episodes.length >= 2 ? 1 : 0;
    final deepCount = (read?.hasContent ?? false)
        ? read!.pages.length + (read.glossary.isNotEmpty ? 1 : 0)
        : 1;
    // Android back inside a deep read returns to the card; it was popping
    // the root route, i.e. exiting the app two pages into a story.
    return PopScope(
      canPop: !_onDeep,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _onDeep) {
          _hpc.animateToPage(0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut);
        }
      },
      child: PageView.builder(
        controller: _hpc,
        itemCount: 1 + tOff + deepCount,
        itemBuilder: (context, i) {
          if (tOff == 1 && i == 1) {
            return _StorySoFarPage(
                episodes: episodes,
                outlets: widget.story.outlets,
                story: widget.story);
          }
          if (i == 0) {
            // The strip is the left swipe with a visible front door: same
            // controller, same page, so _ensureRead/analytics/back-handling
            // all come along for free.
            return StoryCard(
                story: widget.story,
                onReadMore: () => _hpc.animateToPage(1,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut));
          }
          // Network failure and AI refusal are different stories: one deserves
          // a retry button, the other the honest fallback in DeepReadPages.
          if (_failed) {
            return _FailedPage(
                onRetry: _retryRead, capped: _failedStatus == 429);
          }
          if (read == null) return const _WritingPage();
          return DeepReadPages(
            read: read.hasContent ? read : DeepRead(const []),
            pageIndex: i - 1 - tOff,
            impactScore: widget.story.impactScore,
            category: widget.story.category,
            direction: widget.story.impactDirection,
            sourceUrl: widget.story.sourceUrl,
            sourceName: widget.story.sourceName,
          );
        },
      ),
    );
  }
}

/// First-open state while the edge function writes the story (~2-3s once,
/// instant from cache ever after).
class _WritingPage extends StatelessWidget {
  const _WritingPage();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      color: surface,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: green)),
          const SizedBox(height: 14),
          Text('writing your story…', style: mono.copyWith(fontSize: 11.5)),
        ]),
      ),
    );
  }
}

/// The deep read couldn't be fetched (offline, hung function). Distinct from
/// the AI-refusal fallback inside DeepReadPages — that one means "this story
/// can't be written", this one means "try again".
class _FailedPage extends StatelessWidget {
  const _FailedPage({required this.onRetry, this.capped = false});
  final VoidCallback onRetry;
  final bool capped; // daily deep-read cap (429), not a network problem

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      color: surface,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              capped
                  ? "That's a lot of deep reads for one day — full stories "
                      'return tomorrow.'
                  : "Couldn't load the full story — check your connection.",
              textAlign: TextAlign.center,
              style: mono.copyWith(fontSize: 11.5)),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: onRetry,
            child: const Text('Try again'),
          ),
        ]),
      ),
    );
  }
}

/// One newspaper page of a deep read: serif heading, serif body, mono
/// metadata and page dots — the card's clay-black language in print dress.
/// An empty [read] renders the honest fallback instead of a blank page.
/// "The story so far": the cluster's episodes as a dated timeline, composed
/// entirely from rows the feed already fetched — zero AI, works offline from
/// the cache, present only when the cluster has a real history (>=2 distinct
/// headlines). Sits between the card and the AI pages in print dress.
class _StorySoFarPage extends StatelessWidget {
  const _StorySoFarPage(
      {required this.episodes, required this.outlets, required this.story});
  final List<Outlet> episodes;
  final List<Outlet> outlets;
  final Story story;

  String _when(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().toUtc().difference(t.toUtc());
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final first = outlets.isNotEmpty ? outlets.first : null;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: surface,
          border: Border(
              left: BorderSide(
                  color: directionColor(story.impactDirection), width: 3)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 28),
          Center(
              child: Text('THE STORY SO FAR',
                  style: mono.copyWith(fontWeight: FontWeight.w700))),
          const SizedBox(height: 6),
          // Coverage lens: who carried it, who was first — from data already
          // in memory.
          if (outlets.length > 1)
            Center(
              child: Text(
                  '${outlets.length} newsrooms · first: ${first?.name ?? ''}',
                  style: mono.copyWith(fontSize: 11, color: inkDim)),
            ),
          const SizedBox(height: 16),
          Expanded(
            child: _FitScroll(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final e in episodes) ...[
                    Text(
                        '${_when(e.publishedAt)}'
                        '${e.name.isNotEmpty ? ' · ${e.name}' : ''}',
                        style: mono.copyWith(fontSize: 11, color: inkDim)),
                    const SizedBox(height: 3),
                    Text(e.headline ?? '',
                        style: serif.copyWith(fontSize: 16.5, height: 1.35)),
                    const SizedBox(height: 14),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
              child: Text('swipe for the full story →',
                  style: mono.copyWith(fontSize: 10.5, color: inkDim))),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

class DeepReadPages extends StatelessWidget {
  const DeepReadPages(
      {super.key,
      required this.read,
      required this.pageIndex,
      this.impactScore,
      this.category,
      this.direction,
      this.sourceUrl,
      this.sourceName});
  final DeepRead read;
  final int pageIndex;
  final int? impactScore;
  final String? category;
  final String? direction;
  final String? sourceUrl;
  final String? sourceName;

  @override
  Widget build(BuildContext context) {
    if (!read.hasContent) {
      final url = sourceUrl;
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        color: surface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Full story unavailable — read the original.',
                  textAlign: TextAlign.center,
                  style: mono.copyWith(fontSize: 12)),
              if (url != null && url.isNotEmpty) ...[
                const SizedBox(height: 14),
                // Same "Read original ↗" idiom as the card's attribution.
                InkWell(
                  onTap: () => openExternal(context, url),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if ((sourceName ?? '').isNotEmpty) ...[
                      Text(sourceName!,
                          style: mono.copyWith(
                              fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 6),
                    ],
                    Text('Read original', style: mono.copyWith(fontSize: 12)),
                    const SizedBox(width: 3),
                    const Icon(Icons.north_east_rounded,
                        size: 11, color: inkDim),
                  ]),
                ),
              ],
            ]),
          ),
        ),
      );
    }
    // Past the last AI page sits the glossary, when the read carries one —
    // print-dress "In plain words" box, static text from the cached payload.
    final onGlossary = read.glossary.isNotEmpty && pageIndex >= read.pages.length;
    final page = onGlossary
        ? null
        : read.pages[pageIndex.clamp(0, read.pages.length - 1)];
    final dotCount = read.pages.length + (read.glossary.isNotEmpty ? 1 : 0);

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: surface,
          // Keep the card's direction accent through the whole read — it's
          // the one persistent color signal, and it vanished on swipe.
          border: Border(
              left: BorderSide(color: directionColor(direction), width: 3)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Same clearance as the card, so the floating LIVE/filter tiles
          // never sit on the text.
          // SafeArea above already consumed the status inset — adding it again
          // opened a ~47px dead band over every card.
          const SizedBox(height: 28),
          Center(
            child: Text.rich(TextSpan(children: [
              TextSpan(
                  text: 'IMPACT ${impactScore ?? '–'}/10',
                  style: mono.copyWith(
                      color: impactColor(impactScore),
                      fontWeight: FontWeight.w700)),
              if (category != null)
                TextSpan(text: '  ·  $category', style: mono),
            ])),
          ),
          const SizedBox(height: 18),
          if ((onGlossary ? 'In plain words' : page?.heading) != null) ...[
            Text(onGlossary ? 'In plain words' : page!.heading!,
                style:
                    serif.copyWith(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
          ],
          Expanded(
            child: _FitScroll(
              child: onGlossary
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final e in read.glossary) ...[
                          Text(e.term,
                              style: serif.copyWith(
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(e.definition,
                              style: serif.copyWith(
                                  fontSize: 15.5, height: 1.5)),
                          const SizedBox(height: 14),
                        ],
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The story's one telling number, pulled big — classic
                        // print callout, only on the opening page.
                        if (pageIndex == 0 && read.keyStat != null) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 14),
                            decoration: BoxDecoration(
                                border: Border.all(color: border)),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(read.keyStat!.value,
                                      style: mono.copyWith(
                                          fontSize: 22,
                                          fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 3),
                                  Text(read.keyStat!.label,
                                      style: mono.copyWith(
                                          fontSize: 11.5, color: inkDim)),
                                ]),
                          ),
                        ],
                        Text(page!.body,
                            style:
                                serif.copyWith(fontSize: 16.5, height: 1.65)),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              // The one place the reader's position is shown — give the page
              // turn actual motion instead of a reflowed character string.
              for (var i = 0; i < dotCount; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == pageIndex ? 6 : 4,
                  height: i == pageIndex ? 6 : 4,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == pageIndex ? ink : inkDim),
                ),
            ]),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// Quiet line marking the feed as a saved copy, so nothing on screen is
/// silently passed off as live.
class _CacheBanner extends StatelessWidget {
  const _CacheBanner({required this.savedAt});
  final DateTime savedAt;

  String get _age {
    final m = DateTime.now().difference(savedAt).inMinutes;
    if (m < 1) return 'just now';
    if (m < 60) return '$m min ago';
    final h = m ~/ 60;
    return h < 24 ? '$h h ago' : '${h ~/ 24} d ago';
  }

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: amber.withValues(alpha: 0.12),
        // The banner is the topmost thing on screen: it clears the notch
        // itself so the Stack below starts at an honest y=0.
        padding: EdgeInsets.fromLTRB(
            16, MediaQuery.of(context).padding.top + 6, 16, 6),
        child: Text('Offline — showing stories saved $_age. Pull to retry.',
            style: mono.copyWith(fontSize: 11, color: amber)),
      );
}

/// Scrolls only when its child actually overflows; otherwise the drag falls
/// through to the feed's vertical PageView. A live inner vertical scrollable
/// wins the gesture arena even with nothing to scroll, which made the summary
/// — most of the card — dead ground for the app's one core gesture.
class _FitScroll extends StatefulWidget {
  const _FitScroll({required this.child});
  final Widget child;

  @override
  State<_FitScroll> createState() => _FitScrollState();
}

class _FitScrollState extends State<_FitScroll> {
  final _sc = ScrollController();
  bool _overflows = false;

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-measure every build: the PageView reuses this State across stories,
    // and maxScrollExtent is computed even under NeverScrollableScrollPhysics.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sc.hasClients) return;
      final o = _sc.position.maxScrollExtent > 0;
      if (o != _overflows) setState(() => _overflows = o);
    });
    return SingleChildScrollView(
      controller: _sc,
      physics: _overflows ? null : const NeverScrollableScrollPhysics(),
      child: widget.child,
    );
  }
}

/// Bordered mono chip shared by the card's glance row and the trending strip.
Widget _glanceChip(String text, {Color? dot}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(border: Border.all(color: border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot != null) ...[
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 5),
        ],
        Text(text, style: mono.copyWith(fontSize: 12)),
      ]),
    );

/// "Trending now" — keyword spikes from the `trending` market blob
/// (pipeline/signals.py). Polls one tiny row every 5 min, the server's own
/// rebuild throttle. Tap jumps the feed to the spike's story. Hidden while
/// empty or unreachable — a miss must never cost the feed anything.
class _TrendingStrip extends StatefulWidget {
  const _TrendingStrip();

  @override
  State<_TrendingStrip> createState() => _TrendingStripState();
}

class _TrendingStripState extends State<_TrendingStrip> {
  List<Map<String, dynamic>> _spikes = const [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final row = await Supabase.instance.client
          .from('market_blobs')
          .select('payload')
          .eq('key', 'trending')
          .maybeSingle()
          .timeout(const Duration(seconds: 4));
      final p = (row?['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (!mounted) return;
      unusualStoryIds.value = {
        for (final id in (p['unusual_story_ids'] as List? ?? const []))
          (id as num).toInt()
      };
      setState(() => _spikes = [
            for (final x in (p['spikes'] as List? ?? const []))
              Map<String, dynamic>.from(x as Map)
          ]);
    } catch (_) {
      // Unreachable (or Supabase not initialised in a widget test): no strip.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_spikes.isEmpty) return const SizedBox(width: double.infinity);
    // The feed Column starts at y=0 (no SafeArea): pad past the notch so the
    // ribbon sits between the status bar and the LIVE row.
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Center(child: Text('TRENDING', style: monoLabel)),
          const SizedBox(width: 10),
          for (final s in _spikes)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: InkWell(
                  onTap: () {
                    homeTab.value = 0;
                    pendingStory.value = (s['story_id'] as num?)?.toInt();
                  },
                  child: _glanceChip('#${s['term']} · ${s['outlets']}',
                      dot: s['confidence'] == 'high' ? green : null),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }
}
