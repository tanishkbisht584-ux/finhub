import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../feed_cache.dart';
import '../models.dart';
import '../publishers.dart';
import '../share_palette.dart';
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

/// Put the feed on [id]'s card. False when the story isn't in the loaded list,
/// so the caller can fall back to the standalone detail screen.
bool jumpToStory(PageController pc, List<Story> list, int id) {
  final i = list.indexWhere((s) => s.id == id);
  if (i < 0) return false;
  if (pc.hasClients) pc.jumpToPage(i);
  return true;
}

/// The pipeline's fixed 8 (ai.py CATEGORIES). Strip order is fixed, not
/// data-driven — a stable strip beats one that jumps as stories churn.
const feedCategories = [
  'Markets', 'Economy', 'IPO', 'Corporate', 'Policy', 'Global',
  'Commodities', 'Geopolitics',
];

/// The one feed's composition (owner's call 2026-08-12: "only one feed to
/// scroll, with a filter to add categories, subtract them, or all"). Chips
/// toggle a category in or out of the single feed; this is a lasting
/// customization, persisted on-device. Default: everything.
final enabledCategories =
    ValueNotifier<Set<String>>({...feedCategories});
const _categoriesPrefsKey = 'feed_categories_v1';

Future<void> loadEnabledCategories() async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getStringList(_categoriesPrefsKey);
  if (saved != null) enabledCategories.value = saved.toSet();
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

/// An alerted story must never be invisible because the chips exclude its
/// category: open the feed back up.
void resetFilterForAlert() => enabledCategories.value = {...feedCategories};

/// The one feed the reader scrolls. A story with a null category (shouldn't
/// happen for approved rows, but guard) shows only when nothing is excluded.
List<Story> visibleStories(List<Story> list, Set<String> enabled) => [
      for (final s in list)
        if (s.category == null
            ? enabled.length == feedCategories.length
            : enabled.contains(s.category))
          s
    ];

final storiesProvider = FutureProvider<List<Story>>((ref) async {
  // Feed ranking: the single current featured story pinned, then newest
  // first. Severity-first ordering froze the feed — 41 stale L1/L2 cards
  // outranked every fresh L3/L4 story; impact is on the card instead.
  final since = DateTime.now()
      .toUtc()
      .subtract(const Duration(hours: 48))
      .toIso8601String();
  try {
    final rows = await Supabase.instance.client
        .from('stories')
        .select()
        .eq('status', 'approved')
        .gte('published_at', since)
        .order('is_featured', ascending: false)
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
    final members = await Supabase.instance.client
        .from('stories')
        .select('cluster_id,source_name,source_url,published_at')
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
      final outlets = [
        for (final m in ([...group]..sort((a, b) =>
            ((a['published_at'] ?? '') as String)
                .compareTo((b['published_at'] ?? '') as String))))
          if (seen.add(publisher((m['source_name'] ?? '') as String))) m
      ];
      row['outlets'] = outlets;
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

class _FeedScreenState extends ConsumerState<FeedScreen> {
  final _pc = PageController();

  @override
  void initState() {
    super.initState();
    pendingStory.addListener(_rebuild);
    enabledCategories.addListener(_onFilterChanged);
    loadEnabledCategories();
  }

  @override
  void dispose() {
    pendingStory.removeListener(_rebuild);
    enabledCategories.removeListener(_onFilterChanged);
    _pc.dispose();
    super.dispose();
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
  void _land(List<Story> list) {
    final id = pendingStory.value;
    if (id == null || !mounted) return;
    pendingStory.value = null;
    // The alerted story must never be invisible because of a chip — reset the
    // filter, then jump AFTER the frame that rebuilds the unfiltered PageView
    // (jumping now would index into the still-filtered list).
    resetFilterForAlert();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (jumpToStory(_pc, list, id)) return;
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
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Offline(onRetry: () => ref.refresh(storiesProvider)),
      data: (list) {
        if (pendingStory.value != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _land(list));
        }
        final shown = visibleStories(list, enabledCategories.value);
        return list.isEmpty
            ? const Center(child: Text('No stories yet — check back soon'))
            : Column(children: [
                if (cachedAt != null) _CacheBanner(savedAt: cachedAt),
                Expanded(
                  // The strip floats in the quiet zone above the card's
                  // IMPACT line (card margin 12 + padding 24) instead of
                  // costing the feed a row of its own.
                  child: Stack(children: [
                    shown.isEmpty
                        ? const Center(
                            child:
                                Text('Nothing enabled — tap All up top'))
                        : RefreshIndicator(
                            onRefresh: () =>
                                ref.refresh(storiesProvider.future),
                            child: PageView.builder(
                              controller: _pc,
                              scrollDirection: Axis.vertical,
                              itemCount: shown.length,
                              onPageChanged: (i) => _logView(shown[i].id),
                              itemBuilder: (context, i) =>
                                  StoryCard(story: shown[i]),
                            ),
                          ),
                    const Positioned(
                        top: 0, left: 0, right: 0, child: CategoryStrip()),
                  ]),
                ),
              ]);
      },
    );
  }

  void _logView(int storyId) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    Supabase.instance.client
        .from('events')
        .insert({'user_id': uid, 'story_id': storyId, 'type': 'view'})
        .then((_) {}, onError: (_) {});
  }
}

/// Chip strip floating above the card's IMPACT line (owner's call
/// 2026-08-12): ONE feed, and each chip toggles its category in or out of it.
/// All lights every chip. Clay-black minimal: flat, square, mono; green
/// marks an enabled chip.
class CategoryStrip extends StatelessWidget {
  const CategoryStrip({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: enabledCategories,
      builder: (context, enabled, _) => Container(
        height: 30,
        color: bg, // cards scroll beneath the floating strip
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            _chip('All', enabled.length == feedCategories.length,
                enableAllCategories),
            for (final c in feedCategories)
              _chip(c, enabled.contains(c), () => toggleCategory(c)),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 8, top: 3, bottom: 3),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: surface,
              border: Border.all(color: on ? green : border),
            ),
            child: Text(label,
                style: mono.copyWith(
                    fontSize: 10.5,
                    color: on ? green : inkDim,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
          ),
        ),
      );
}

class StoryCard extends ConsumerStatefulWidget {
  const StoryCard({super.key, required this.story});
  final Story story;

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

  @override
  void dispose() {
    _burst.dispose();
    _palette.dispose();
    super.dispose();
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
      }
      // The Saved tab reads its own provider; without this it kept serving the
      // list it fetched on first open and the change never appeared there.
      ref.invalidate(savedProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _pendingSave = was); // never leave a lie on screen
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not ${was ? 'remove' : 'save'}: $e')));
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
        .insert({'user_id': uid, 'story_id': story.id, 'type': 'share'})
        .then((_) {}, onError: (_) {});
  }

  Future<void> _fire(String targetId) async {
    try {
      final toast = await runShareTarget(targetId, story, _renderCard);
      _logShare();
      if (toast != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(milliseconds: 1100), content: Text(toast)));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not share')));
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
              body: id == 'saved' ? const SavedScreen() : const WatchlistScreen(),
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

  String get _horizon => switch (story.impactHorizon) {
        'short_term' => 'SHORT',
        'long_term' => 'LONG',
        'both' => 'SHORT + LONG',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final dir = directionColor(story.impactDirection);
    // The optimistic flag only knows about taps in this session; the saved list
    // is the source of truth, so a story saved earlier still shows filled.
    final known = ref.watch(savedProvider).valueOrNull;
    final isSaved = _pendingSave ?? (known?.any((s) => s.id == story.id) ?? false);
    return SafeArea(
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

          // Dim the card while the palette is up, so the targets read as a
          // layer above rather than more card furniture.
          IgnorePointer(
            child: FadeTransition(
              opacity: Tween<double>(begin: 0, end: 0.55).animate(_palette),
              child: Container(color: bg),
            ),
          ),

          // Centred above the rail: the hold starts anywhere, so the row
          // cannot be anchored to the thumb.
          Positioned(
            left: 0,
            right: 0,
            bottom: 128,
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

  Widget _card(Color dir, bool isSaved) {
    return Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: surface,
          border: Border(left: BorderSide(color: dir, width: 3)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // IMPACT 9/10 · SHORT + LONG — monospace ledger line
            Text.rich(TextSpan(children: [
              TextSpan(
                  text: 'IMPACT ${story.impactScore ?? '–'}/10',
                  style: mono.copyWith(
                      color: impactColor(story.impactScore),
                      fontWeight: FontWeight.w700)),
              if (_horizon.isNotEmpty)
                TextSpan(text: '  ·  $_horizon', style: mono),
            ])),
            const SizedBox(height: 14),
            if (story.hook != null)
              Text(story.hook!,
                  style: serif.copyWith(
                      fontSize: 30, fontWeight: FontWeight.w700, height: 1.2)),
            const SizedBox(height: 12),
            Text(story.headline,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, height: 1.35)),
            const SizedBox(height: 12),
            _MediaStrip(story: story),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(story.summary ?? '',
                        style: TextStyle(
                            fontSize: 15, height: 1.55, color: ink.withValues(alpha: 0.8))),
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
            const Divider(height: 20),
            // Attribution left, actions right — the arrangement every social
            // feed has trained thumbs to expect.
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(child: _attribution(dir)),
              _rail(isSaved),
            ]),
          ],
        ));
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
        onTap: () =>
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dir.withValues(alpha: 0.14),
              border: Border.all(color: dir.withValues(alpha: 0.5)),
            ),
            child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: serif.copyWith(
                    fontSize: 15, fontWeight: FontWeight.w700, color: dir)),
          ),
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
                        fontSize: 13, fontWeight: FontWeight.w600, height: 1.2)),
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
            padding: const EdgeInsets.fromLTRB(8, 6, 2, 6),
            child: Text('+$others more',
                style: mono.copyWith(
                    fontSize: 10.5,
                    color: dir,
                    fontWeight: FontWeight.w600)),
          ),
        ),
    ]);
  }

  /// Every outlet that ran this story, earliest first. Reading the same event
  /// in several papers is the point — so each row opens that outlet directly.
  void _showOutlets() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
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
              child: Text('Earliest first', style: mono.copyWith(fontSize: 10.5)),
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
                  title: Text(o.name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: o.publishedAt == null
                      ? null
                      : Text(_when(o.publishedAt!),
                          style: mono.copyWith(fontSize: 10.5)),
                  trailing:
                      Icon(Icons.north_east_rounded, size: 14, color: inkDim),
                  onTap: () => launchUrl(Uri.parse(o.url),
                      mode: LaunchMode.externalApplication),
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
      const SizedBox(height: 4),
      _railButton(
        icon: Icons.ios_share_rounded,
        tint: inkDim,
        onTap: () => _fire('card'),
      ),
    ]);
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
          transitionBuilder: (child, a) =>
              ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: child)),
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

/// 16:9 picture or video thumbnail between headline and summary (spec: M8).
/// Hotlinked from the origin CDN — we never re-host. A dead URL collapses the
/// whole strip: a blank card is fine, a broken-image icon is not.
class _MediaStrip extends StatefulWidget {
  const _MediaStrip({required this.story});
  final Story story;

  @override
  State<_MediaStrip> createState() => _MediaStripState();
}

class _MediaStripState extends State<_MediaStrip> {
  bool _dead = false;

  @override
  void didUpdateWidget(_MediaStrip old) {
    super.didUpdateWidget(old);
    // PageView.builder reuses this State across stories (no keys); without
    // this, one dead image permanently hides every later story's image too.
    if (old.story.imageUrl != widget.story.imageUrl) _dead = false;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: shareCapture,
      builder: (context, capturing, _) =>
          capturing ? const SizedBox.shrink() : _buildStrip(context),
    );
  }

  Widget _buildStrip(BuildContext context) {
    final s = widget.story;
    final url = s.imageUrl;
    if (url == null || _dead) return const SizedBox.shrink();
    // 2x logical width: crisp on device without decoding a 4000px press photo
    // into memory on a budget phone.
    final cacheW = (MediaQuery.of(context).size.width * 2).round();
    final img = AspectRatio(
      aspectRatio: 16 / 9,
      child: Image.network(
        url,
        fit: BoxFit.cover,
        cacheWidth: cacheW,
        // errorBuilder alone leaves a 16:9 hole; flag + rebuild collapses it.
        errorBuilder: (_, __, ___) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_dead) setState(() => _dead = true);
          });
          return const SizedBox.shrink();
        },
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : Container(color: surface),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: border)),
        child: s.videoUrl == null
            ? img
            : InkWell(
                onTap: () => launchUrl(Uri.parse(s.videoUrl!),
                    mode: LaunchMode.externalApplication),
                child: Stack(alignment: Alignment.center, children: [
                  img,
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration:
                        BoxDecoration(color: bg.withValues(alpha: 0.65)),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: ink, size: 34),
                  ),
                ]),
              ),
      ),
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
                style: serif.copyWith(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Check your connection — your saved stories still work.',
                textAlign: TextAlign.center, style: mono.copyWith(fontSize: 12)),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                  foregroundColor: ink, side: const BorderSide(color: border)),
              child: const Text('Try again'),
            ),
          ]),
        ),
      );
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text('Offline — showing stories saved $_age. Pull to retry.',
            style: mono.copyWith(fontSize: 11, color: amber)),
      );
}
