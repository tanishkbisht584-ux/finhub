# M8 Media Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every story card gets a real, relevant 16:9 image or video thumbnail between the headline and summary — or nothing at all, never a wrong one.

**Architecture:** The pipeline (`pipeline/run.py`) filters feed images through `usable_image()`, scrapes og:image for gate-passing stories that lack one, and matches YouTube videos from broadcaster channel feeds to existing story clusters (cluster gate → recency gate → one batched Gemini adjudication). The Flutter app (`app/`) renders whatever `image_url`/`video_url` hold; dead URLs collapse silently. A daily-bounded `events` retention delete keeps the free-tier DB alive.

**Tech Stack:** Python (requests, feedparser — already installed), Flutter (`Image.network`, `url_launcher` — already imported), Supabase PostgREST via the existing `sb()` wrapper, Gemini via existing `pipeline/ai.py` lanes.

## Global Constraints (from docs/media-strip-prompt.md — verbatim where quoted)

- **Hotlink only.** Never download, copy, proxy, or re-host media. Store the URL only.
- **No AI-generated or stock imagery, ever.** No real relevant image → show nothing.
- **No new Flutter dependencies.** No new Python dependencies either (regex over parser libs).
- **Actions budget:** hard cap **25 extra HTTP requests per run at 3s timeout each** for og:image; YouTube channel feeds count as normal source fetches.
- **Prefer nothing over wrong.** Every ambiguous case collapses the strip / returns None.
- YouTube items are media candidates, **never** rows in `stories`.
- Gemini video adjudication: **one batched call per run**, instructed that `null` is the preferred answer under uncertainty.
- Style: short functions, comments explain *why*, no abstractions/config classes/single-implementation interfaces.
- Migration file is `pipeline/migrations/007_media.sql` — the spec says 004 but 004–006 already exist; 007 is next.

---

### Task 1: Flutter media strip

**Files:**
- Modify: `app/lib/models.dart` (Story class, ~line 16–65)
- Modify: `app/lib/screens/feed.dart` (`_card`, between headline Text ~line 552 and the `Expanded` summary ~line 556)
- Test: `app/test/media_strip_test.dart`

**Interfaces:**
- Consumes: `stories.image_url` (exists in DB today), `stories.video_url` (added in Task 4 — null until then, which renders as "no strip", so this task ships safely first).
- Produces: `Story.imageUrl`, `Story.videoUrl` (both `String?`); private widget `_MediaStrip(story)` in feed.dart.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/media_strip_test.dart
//
// The strip must never degrade a card: no media -> no gap, dead URL -> silent
// collapse (widget-test HTTP always 400s, which conveniently IS the dead-URL
// case), video -> tappable with a play badge while the thumbnail lives.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryCard;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Story _s(Map<String, dynamic> overrides) => Story.fromJson({
      'id': 1,
      'headline': 'RBI holds repo rate',
      'hook': 'RBI stands still',
      'summary': 'Rates unchanged.',
      'impact_score': 7,
      'source_name': 'RBI Press',
      'source_url': 'https://rbi.org.in/x',
      'sectors': const [],
      ...overrides,
    });

Widget _app(Story s) => ProviderScope(
    child: MaterialApp(home: Scaffold(body: StoryCard(story: s))));

void main() {
  test('Story parses image_url and video_url', () {
    final s = _s({'image_url': 'https://cdn.et.com/a.jpg',
                  'video_url': 'https://www.youtube.com/watch?v=abc'});
    expect(s.imageUrl, 'https://cdn.et.com/a.jpg');
    expect(s.videoUrl, 'https://www.youtube.com/watch?v=abc');
    expect(_s(const {}).imageUrl, isNull);
  });

  testWidgets('no media, no strip — card is exactly today\'s card',
      (tester) async {
    await tester.pumpWidget(_app(_s(const {})));
    expect(find.byType(AspectRatio), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
  });

  testWidgets('dead image URL collapses the strip silently', (tester) async {
    await tester.pumpWidget(_app(_s({'image_url': 'https://x.invalid/a.jpg'})));
    await tester.pumpAndSettle();
    // Test HTTP returns 400 for every request: the errorBuilder path.
    expect(find.byType(AspectRatio), findsNothing);
    expect(find.byIcon(Icons.broken_image), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/media_strip_test.dart`
Expected: FAIL — `imageUrl` isn't defined on Story.

- [ ] **Step 3: Implement**

`app/lib/models.dart` — add two fields to `Story`, matching the existing field style exactly:

```dart
  final String? category;
  final List<String> sectors;
  final String? imageUrl;
  final String? videoUrl;
```

and in `Story.fromJson`'s initializer list (after `sectors = ...`):

```dart
        imageUrl = j['image_url'],
        videoUrl = j['video_url'],
```

`app/lib/screens/feed.dart` — in `_card`, insert between the headline `Text` and the summary `Expanded`:

```dart
            _MediaStrip(story: story),
```

and add the widget at file scope (near the other private card widgets):

```dart
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
  Widget build(BuildContext context) {
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
```

Notes for the implementer:
- `surface`, `border`, `bg`, `ink` come from `../theme.dart`, already imported.
- `launchUrl`/`LaunchMode` come from `url_launcher`, already imported in feed.dart.
- Square corners, flat colors, no shadows — the clay-black minimal style. Do NOT add borderRadius.
- A video with no thumbnail (`imageUrl == null`) renders nothing — prefer nothing over a naked play button.

- [ ] **Step 4: Run tests**

Run: `cd app && flutter test`
Expected: all pass (47 existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add app/lib/models.dart app/lib/screens/feed.dart app/test/media_strip_test.dart
git commit -m "M8: media strip — 16:9 image/video thumbnail on the story card"
```

---

### Task 2: `usable_image()` relevance filter (pipeline)

**Files:**
- Modify: `pipeline/run.py` (new function near `entry_image` ~line 258; wire-up in `main()` at `base_row` ~line 911 and the recent-stories preload ~line 858)
- Test: `pipeline/test_pipeline.py`

**Interfaces:**
- Consumes: `entry_image()` output (item["image_url"]), `sb()` for the seen-counts preload.
- Produces: `usable_image(url, seen_counts) -> str | None` and `image_seen_counts() -> dict[str, int]`. Task 3 and Task 4 both route URLs through `usable_image`.

- [ ] **Step 1: Write the failing tests**

Append to `pipeline/test_pipeline.py` (import `usable_image` at the top with the other `run` imports):

```python
def test_usable_image_rejects_junk_paths():
    from run import usable_image
    assert usable_image("https://et.com/img/logo.png", {}) is None
    assert usable_image("https://et.com/assets/icon-32.png", {}) is None
    assert usable_image("https://cdn.x.com/authors/rk-avatar.jpg", {}) is None
    assert usable_image("https://cdn.x.com/1x1.gif", {}) is None
    assert usable_image("https://cdn.x.com/ads/banner.jpg", {}) is None


def test_usable_image_rejects_declared_small():
    from run import usable_image
    # width declared in the URL the way CDNs do it
    assert usable_image("https://cdn.x.com/photo.jpg?width=200", {}) is None
    assert usable_image("https://cdn.x.com/photo-120x90.jpg", {}) is None
    # no declared dimensions -> benefit of the doubt
    assert usable_image("https://cdn.x.com/photo.jpg", {}) == "https://cdn.x.com/photo.jpg"


def test_usable_image_rejects_house_images():
    """The generic 'BSE building' photo on every filing story carries no
    information — 3+ appearances in a week means it's furniture, not news."""
    from run import usable_image
    url = "https://cdn.x.com/bse-building.jpg"
    assert usable_image(url, {url: 3}) is None
    assert usable_image(url, {url: 2}) == url


def test_usable_image_passes_normal_article_image():
    from run import usable_image
    u = "https://images.et.com/2026/08/rbi-governor-presser.jpg"
    assert usable_image(u, {}) == u
    assert usable_image(None, {}) is None
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd pipeline && python -m pytest test_pipeline.py -k usable_image -v`
Expected: FAIL — `cannot import name 'usable_image'`.

- [ ] **Step 3: Implement in `pipeline/run.py`**

Place directly under `entry_image()`:

```python
# Junk by path: logos, icons, bylines, spacers, ad slots. Case-insensitive,
# matched against the whole URL — CDNs hide these words in either path or file.
JUNK_IMAGE = re.compile(
    r"logo|icon|avatar|author|byline|placeholder|default|sprite|blank"
    r"|spacer|1x1|pixel|/ads?/", re.I)
# Declared width, the two ways CDNs write it: ?width=200 / ?w=200, or -120x90.
IMG_W_QUERY = re.compile(r"[?&](?:w|width)=(\d+)", re.I)
IMG_W_NAME = re.compile(r"[-_](\d{2,4})x\d{2,4}\.(?:jpe?g|png|webp|gif)", re.I)
HOUSE_IMAGE_USES = 3   # same URL on this many stories in 7d = furniture, not news
MIN_IMAGE_WIDTH = 400


def usable_image(url, seen_counts):
    """The url, or None if it would make the card worse than no image at all.
    Spec M8: prefer nothing over wrong — every ambiguous case returns None."""
    if not url:
        return None
    if JUNK_IMAGE.search(url):
        return None
    m = IMG_W_QUERY.search(url) or IMG_W_NAME.search(url)
    if m and int(m.group(1)) < MIN_IMAGE_WIDTH:
        return None
    if seen_counts.get(url, 0) >= HOUSE_IMAGE_USES:
        return None
    return url


def image_seen_counts():
    """URL -> how many stories carried it in the last 7 days. One query per run
    (sb() paginates); catches house images that are valid but say nothing."""
    since = iso(datetime.now(timezone.utc) - timedelta(days=7))
    counts = {}
    for r in sb("GET", f"stories?select=image_url&image_url=not.is.null"
                       f"&created_at=gte.{since}"):
        counts[r["image_url"]] = counts.get(r["image_url"], 0) + 1
    return counts
```

Wire-up in `main()`:

1. After the `companies_by_key` build, add:

```python
    seen_images = image_seen_counts()
```

2. In `base_row` change the image line to filter the feed-provided image (the reused-house-image problem already exists in current data):

```python
                "image_url": usable_image(item["image_url"], seen_images),
```

- [ ] **Step 4: Run the pipeline suite**

Run: `cd pipeline && python -m pytest test_pipeline.py -v`
Expected: all pass (existing + 4 new). `iso` is defined at module level in run.py — no import issues.

- [ ] **Step 5: Commit**

```bash
git add pipeline/run.py pipeline/test_pipeline.py
git commit -m "M8: usable_image() — junk paths, small images, house images never reach a card"
```

---

### Task 3: og:image fallback (pipeline)

**Files:**
- Modify: `pipeline/run.py` (new function under `usable_image()`; wire-up inside `main()`'s AI-result loop ~line 975)
- Test: `pipeline/test_pipeline.py`

**Interfaces:**
- Consumes: `usable_image(url, seen_counts)` from Task 2.
- Produces: `og_image(article_url, seen_counts) -> str | None` and module constant `OG_FETCH_CAP = 25`. `main()` tracks `og_fetches` count per run.

- [ ] **Step 1: Write the failing tests**

```python
def test_og_image_parses_meta_and_filters(monkeypatch):
    import run

    class FakeResp:
        headers = {"Content-Type": "text/html; charset=utf-8"}
        text = ('<html><head><meta property="og:image" '
                'content="https://cdn.et.com/2026/rbi-presser.jpg"/></head></html>')
        def raise_for_status(self): pass

    monkeypatch.setattr(run.requests, "get", lambda *a, **k: FakeResp())
    assert run.og_image("https://et.com/story", {}) == "https://cdn.et.com/2026/rbi-presser.jpg"
    # the scraped image still goes through the relevance filter
    FakeResp.text = ('<meta property="og:image" content="https://cdn.et.com/logo.png"/>')
    assert run.og_image("https://et.com/story", {}) is None


def test_og_image_falls_back_to_twitter_image(monkeypatch):
    import run

    class FakeResp:
        headers = {"Content-Type": "text/html"}
        text = '<meta name="twitter:image" content="https://cdn.x.com/photo.jpg">'
        def raise_for_status(self): pass

    monkeypatch.setattr(run.requests, "get", lambda *a, **k: FakeResp())
    assert run.og_image("https://x.com/s", {}) == "https://cdn.x.com/photo.jpg"


def test_og_image_never_raises(monkeypatch):
    import run
    def boom(*a, **k): raise run.requests.ConnectionError("dead host")
    monkeypatch.setattr(run.requests, "get", boom)
    assert run.og_image("https://dead.example/s", {}) is None

    class NotHtml:
        headers = {"Content-Type": "application/pdf"}
        text = ""
        def raise_for_status(self): pass
    monkeypatch.setattr(run.requests, "get", lambda *a, **k: NotHtml())
    assert run.og_image("https://x.com/file.pdf", {}) is None
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd pipeline && python -m pytest test_pipeline.py -k og_image -v`
Expected: FAIL — no `og_image`.

- [ ] **Step 3: Implement in `pipeline/run.py`**

```python
OG_FETCH_CAP = 25          # spec M8: hard cap per run, 3s timeout each —
OG_FETCH_TIMEOUT = 3       # this is what keeps the Actions budget intact
OG_IMAGE = re.compile(
    r'<meta[^>]+(?:property=["\']og:image["\']|name=["\']twitter:image["\'])'
    r'[^>]+content=["\']([^"\']+)["\']', re.I)
OG_IMAGE_REV = re.compile(  # content= before property=, the other attribute order
    r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+'
    r'(?:property=["\']og:image["\']|name=["\']twitter:image["\'])', re.I)


def og_image(article_url, seen_counts):
    """One bounded GET for the article's own og:image. Regex, not a parser
    dependency; any failure whatsoever is None — this must never cost a story."""
    try:
        r = requests.get(article_url, headers=UA, timeout=OG_FETCH_TIMEOUT)
        r.raise_for_status()
        if "html" not in r.headers.get("Content-Type", ""):
            return None
        m = OG_IMAGE.search(r.text) or OG_IMAGE_REV.search(r.text)
        return usable_image(m.group(1), seen_counts) if m else None
    except Exception:
        return None
```

Wire-up in `main()`'s AI-result loop — only for stories that pass the gate and are being inserted as cards, never raw feed items. Add `og_fetches = 0` next to the other counters (`processed = flagged = ...`), then insert right before the `insert_story` call for AI-processed stories (after the `twin` merge logic — a merged duplicate doesn't need its own image):

```python
            # og:image fallback (spec M8): only for a card actually being
            # inserted without a usable image — bounded so a bad news day
            # can't melt the Actions budget.
            if (keep and not twin and not base["image_url"]
                    and og_fetches < OG_FETCH_CAP):
                og_fetches += 1
                base["image_url"] = og_image(item["url"], seen_images)
```

- [ ] **Step 4: Run the pipeline suite**

Run: `cd pipeline && python -m pytest test_pipeline.py -v`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add pipeline/run.py pipeline/test_pipeline.py
git commit -m "M8: og:image fallback — 25 fetches/run, 3s timeout, filtered, never raises"
```

---

### Task 4: video — migration, YouTube ingest, matching

**Files:**
- Create: `pipeline/migrations/007_media.sql`
- Create: `pipeline/prompts/video_v1.txt`
- Modify: `pipeline/seed/sources_seed.sql` (append YouTube channels)
- Modify: `pipeline/ai.py` (add `video_match()` near `editor_pass`)
- Modify: `pipeline/run.py` (new `match_videos()`; `main()` splits youtube sources out of the story path)
- Test: `pipeline/test_pipeline.py`

**Interfaces:**
- Consumes: `cluster_of(headline, recent)` (returns `(cluster_id, known: bool)`), `title_tokens`, `sb()`, `usable_image` from Task 2.
- Produces: `run.match_videos(yt_sources, recent) -> int` (videos attached), `ai.video_match(pairs) -> list[int]` (indices of confirmed pairs; empty list on any failure). DB column `stories.video_url text`.

- [ ] **Step 1: Migration**

`pipeline/migrations/007_media.sql`:

```sql
-- M8: a story can carry one matched broadcaster video (hotlinked YouTube URL).
alter table stories add column if not exists video_url text;
```

Apply it: the repo has no migration runner or Postgres client — previous migrations were applied through the Supabase SQL editor. Print the SQL and ask Tanis to paste it at https://supabase.com/dashboard/project/hdgfdswzymfqgjqzqqve/sql — OR, if a Supabase access token is available in the session, apply via the Management API. **Do not proceed to Step 5 wiring until `select video_url from stories limit 1` succeeds** (verify with a quick `sb("GET", "stories?select=video_url&limit=1")` probe script).

- [ ] **Step 2: Resolve and seed the YouTube channels**

For each of CNBC-TV18, ET Now, Mint, Moneycontrol, Zee Business: fetch `https://www.youtube.com/@<handle>` (curl with the pipeline's UA), extract `"externalId":"UC..."` from the page source, then **verify** `https://www.youtube.com/feeds/videos.xml?channel_id=<id>` returns entries whose `<author><name>` matches the broadcaster. A wrong channel ID silently feeds wrong videos forever — verify all five before seeding. Handles to try first: `@CNBCTV18News`, `@ETNOW`, `@LiveMint`, `@moneycontrol`, `@ZeeBusiness`.

Append to `pipeline/seed/sources_seed.sql` and run the same insert against prod via `sb("POST", "sources", ...)`:

```sql
-- M8: broadcaster video channels. type='youtube' keeps them OUT of the story
-- path — their items are media candidates matched onto existing stories.
insert into sources (name, type, feed_url, authority) values
  ('CNBC-TV18 Video',    'youtube', 'https://www.youtube.com/feeds/videos.xml?channel_id=<verified-id>', 7),
  ('ET Now Video',       'youtube', 'https://www.youtube.com/feeds/videos.xml?channel_id=<verified-id>', 7),
  ('Mint Video',         'youtube', 'https://www.youtube.com/feeds/videos.xml?channel_id=<verified-id>', 7),
  ('Moneycontrol Video', 'youtube', 'https://www.youtube.com/feeds/videos.xml?channel_id=<verified-id>', 7),
  ('Zee Business Video', 'youtube', 'https://www.youtube.com/feeds/videos.xml?channel_id=<verified-id>', 6)
on conflict do nothing;
```

(`<verified-id>` placeholders are for THIS plan document only — the committed seed file must contain the five real, verified `UC...` ids. Committing a placeholder is a task failure.)

- [ ] **Step 3: Write the failing tests**

```python
def test_youtube_sources_never_enter_the_story_path():
    """A youtube source must be split out before the FETCHERS loop — its items
    are media candidates, and fetch_items would happily turn them into stories."""
    from run import split_sources
    sources = [{"type": "rss"}, {"type": "youtube"}, {"type": "nse"}]
    story_sources, yt_sources = split_sources(sources)
    assert {s["type"] for s in story_sources} == {"rss", "nse"}
    assert [s["type"] for s in yt_sources] == ["youtube"]


def test_video_candidates_gate_on_cluster_and_recency():
    from run import video_candidates, title_tokens
    now = datetime.now(timezone.utc)
    recent = [("c1", title_tokens("RBI cuts repo rate by 25 bps"))]
    stories = {"c1": {"id": 7, "headline": "RBI cuts repo rate by 25 bps",
                      "published_at": now.isoformat(), "video_url": None,
                      "image_url": None}}
    vids = [
        # same cluster, fresh -> candidate
        {"title": "RBI cuts repo rate 25 bps: what it means", "video_id": "a1",
         "published_at": now.isoformat()},
        # no cluster match -> discarded, no AI spent
        {"title": "Closing Bell: Sensex today", "video_id": "b2",
         "published_at": now.isoformat()},
        # matches but 13h stale -> discarded
        {"title": "RBI cuts repo rate by 25 bps analysis", "video_id": "c3",
         "published_at": (now - timedelta(hours=13)).isoformat()},
    ]
    cands = video_candidates(vids, recent, stories)
    assert [c["video_id"] for c in cands] == ["a1"]
    assert cands[0]["story_id"] == 7
```

Note for the implementer: `datetime`/`timedelta`/`timezone` are already imported at the top of `test_pipeline.py`'s `run` module; add `from datetime import datetime, timedelta, timezone` to the test file header if not present.

- [ ] **Step 4: Run to verify they fail**

Run: `cd pipeline && python -m pytest test_pipeline.py -k "youtube or video" -v`
Expected: FAIL — `split_sources` not defined.

- [ ] **Step 5: Implement**

`pipeline/prompts/video_v1.txt` (mirrors `editor_v1.txt`'s shape — note the doubled `{{ }}` braces everywhere except `{pairs}`, because the file goes through `.format()`):

```
You are matching broadcaster video clips to news stories for FinSwipe, an
Indian markets news app. Below are candidate pairs, one per line:
i | video title | story headline

Confirm a pair ONLY if the video is plainly about that exact event. A generic
market-wrap ("Closing Bell", "Market Wrap", "Top Stocks Today") must NEVER
match a specific story. When in doubt, leave it out — omitting a pair is the
correct and preferred answer under uncertainty. A story shown with a wrong
video is worse than a story with no video.

Return ONLY JSON: {{"match": [<i of each confirmed pair>]}}

Pairs:
{pairs}
```

`pipeline/ai.py` — add under `editor_pass`, same error posture (advisory, loud on failure, never blocks the run):

```python
VIDEO_PROMPT = (pathlib.Path(__file__).parent / "prompts" / "video_v1.txt").read_text(encoding="utf-8")


def video_match(pairs):
    """One batched call per run (spec M8) over 'i | video title | headline'
    lines. Returns the confirmed indices; [] on any failure — a lost video is
    nothing, a wrong one is misinformation."""
    if not pairs:
        return []
    try:
        lines = "\n".join(f"{i} | {v} | {h}" for i, (v, h) in enumerate(pairs))
        out = json.loads(_gemini(VIDEO_PROMPT.format(pairs=lines)))
        return [i for i in out.get("match", [])
                if isinstance(i, int) and 0 <= i < len(pairs)]
    except (AIError, QuotaExhausted, ValueError, KeyError, json.JSONDecodeError,
            requests.RequestException) as e:
        print(f"VIDEO MATCH FAILED ({type(e).__name__}): {str(e)[:200]}")
        return []
```

`pipeline/run.py` — three additions:

```python
VIDEO_MAX_AGE_HOURS = 12   # a clip 12h+ from the story is a different bulletin
VIDEO_BATCH_CAP = 20       # one AI call; keep the prompt readable


def split_sources(sources):
    """YouTube channels are media feeds, not news sources: their items must
    never become story rows, so they leave the story path here."""
    story = [s for s in sources if s["type"] != "youtube"]
    yt = [s for s in sources if s["type"] == "youtube"]
    return story, yt


def fetch_videos(source):
    """YouTube channel feed -> [{title, video_id, published_at}]. Plain RSS;
    feedparser exposes <yt:videoId> as entry.yt_videoid."""
    resp = requests.get(source["feed_url"], headers=UA, timeout=FETCH_TIMEOUT)
    resp.raise_for_status()
    vids = []
    for e in feedparser.parse(resp.content).entries:
        vid = e.get("yt_videoid")
        title = (e.get("title") or "").strip()
        if vid and title:
            vids.append({"title": title, "video_id": vid,
                         "published_at": entry_published(e)})
    return vids


def video_candidates(vids, recent, stories_by_cluster):
    """Free deterministic gates before any AI: the video's title must land in
    an existing story's cluster, and the clip must be within
    VIDEO_MAX_AGE_HOURS of the story. Survivors carry their story."""
    out = []
    for v in vids:
        cid, known = cluster_of(v["title"], recent)
        story = stories_by_cluster.get(cid) if known else None
        if not story or story["video_url"]:
            continue
        v_ts, s_ts = v.get("published_at"), story.get("published_at")
        if not v_ts or not s_ts:
            continue
        if abs((parse_ts(v_ts) - parse_ts(s_ts)).total_seconds()) > VIDEO_MAX_AGE_HOURS * 3600:
            continue
        out.append({**v, "story_id": story["id"],
                    "story_headline": story["headline"],
                    "story_image": story.get("image_url")})
    return out


def match_videos(yt_sources, recent, seen_images, video_match):
    """The whole video path: fetch channels, gate, one batched AI call, patch
    matched stories. Every failure path costs a video, never a story."""
    vids = []
    for s in yt_sources:
        try:
            vids += fetch_videos(s)
        except Exception as e:
            print(f"VIDEO FEED FAIL {s['name']}: {e}")
    if not vids:
        return 0
    since = iso(datetime.now(timezone.utc) - timedelta(hours=48))
    stories_by_cluster = {}
    for r in sb("GET", f"stories?select=id,cluster_id,headline,published_at,"
                       f"image_url,video_url&created_at=gte.{since}"
                       "&status=in.(approved,pending)"):
        stories_by_cluster.setdefault(r["cluster_id"], r)
    cands = video_candidates(vids, recent, stories_by_cluster)[:VIDEO_BATCH_CAP]
    confirmed = video_match([(c["title"], c["story_headline"]) for c in cands])
    attached = 0
    for i in confirmed:
        c = cands[i]
        patch = {"video_url": f"https://www.youtube.com/watch?v={c['video_id']}"}
        if not c["story_image"]:
            thumb = usable_image(
                f"https://img.youtube.com/vi/{c['video_id']}/hqdefault.jpg", seen_images)
            if thumb:
                patch["image_url"] = thumb
        sb("PATCH", f"stories?id=eq.{c['story_id']}", json=patch)
        attached += 1
    return attached
```

`main()` wiring:

1. `from ai import (...)` — add `video_match` to the import list.
2. After `sources = sb(...)`: `sources, yt_sources = split_sources(sources)` — this line alone guarantees the FETCHERS loop and everything downstream never sees a youtube source.
3. After the alert engines (next to `personal = personal_alert_engine()`):

```python
    videos = match_videos(yt_sources, recent, seen_images, video_match)
```

4. Add `, {videos} videos attached` into the `done:` print line.
5. `last_fetched_at` bookkeeping: append yt source ids to `fetched_source_ids` inside `match_videos`… no — keep it simple: PATCH `last_fetched_at` for yt sources inside `match_videos`'s fetch loop success path, mirroring what `main()` does for story sources. Otherwise `disable_dead_sources()` retires them in 3 days. Also note: `disable_dead_sources()` judges "silent" sources by stories produced — a youtube source never produces stories, so it would be retired as silent. Guard it: in `disable_dead_sources()`, skip `type == 'youtube'` sources in the silent-source loop (their select already includes... it selects `id,name,last_fetched_at` — add `type` to the select and `continue` on youtube).

- [ ] **Step 6: Run the pipeline suite**

Run: `cd pipeline && python -m pytest test_pipeline.py -v`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add pipeline/migrations/007_media.sql pipeline/prompts/video_v1.txt pipeline/seed/sources_seed.sql pipeline/ai.py pipeline/run.py pipeline/test_pipeline.py
git commit -m "M8: video — YouTube channel ingest, cluster+recency gates, one batched Gemini adjudication"
```

---

### Task 5: events retention

**Files:**
- Modify: `pipeline/run.py` (new function; one call in `main()` next to the other self-heal calls)
- Test: `pipeline/test_pipeline.py`

**Interfaces:**
- Consumes: `sb()`, `iso()`.
- Produces: `retention_sweep() -> None`.

- [ ] **Step 1: Write the failing test**

```python
def test_retention_cutoff_is_date_truncated(monkeypatch):
    """The cutoff must be a day boundary: the first sweep each day deletes
    everything older, every later sweep that day matches zero rows — that
    truncation IS the once-per-day guard, with no state to store."""
    import run
    calls = []
    monkeypatch.setattr(run, "sb", lambda m, p, **k: calls.append((m, p)) or [])
    run.retention_sweep()
    method, path = calls[0]
    assert method == "DELETE"
    assert "events?created_at=lt." in path
    assert "T00:00:00" in path
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd pipeline && python -m pytest test_pipeline.py -k retention -v`
Expected: FAIL — no `retention_sweep`.

- [ ] **Step 3: Implement**

```python
EVENTS_RETENTION_DAYS = 90   # spec M8: events grows on every swipe, forever,
                             # against a 500 MB free tier — this makes it run for years


def retention_sweep():
    """Delete events older than EVENTS_RETENTION_DAYS. The cutoff is truncated
    to the day, so the first run after midnight does the real delete and every
    other run that day matches nothing — a once-per-day guard with no state."""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=EVENTS_RETENTION_DAYS)) \
        .replace(hour=0, minute=0, second=0, microsecond=0)
    try:
        sb("DELETE", f"events?created_at=lt.{iso(cutoff)}")
    except requests.RequestException as e:
        print(f"RETENTION SWEEP FAILED: {e}")  # next run retries; nothing lost
```

In `main()`, next to the self-heal calls (after `approved = auto_approve()`):

```python
    retention_sweep()
```

- [ ] **Step 4: Run the suite**

Run: `cd pipeline && python -m pytest test_pipeline.py -v`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add pipeline/run.py pipeline/test_pipeline.py
git commit -m "M8: events retention — 90-day sweep, day-truncated cutoff as the daily guard"
```

---

### Task 6: end-to-end verification + release build

**Files:**
- Modify: `app/pubspec.yaml` (version bump)

- [ ] **Step 1: Full test suites**

```bash
cd pipeline && python -m pytest test_pipeline.py -v
cd app && flutter test
cd app && flutter analyze lib test
```
Expected: everything green; analyze adds no new warnings beyond the two pre-existing infos.

- [ ] **Step 2: Live pipeline smoke run**

Run one pipeline pass locally (`cd pipeline && python run.py`) with the prod `.env`. In the log confirm:
- no exceptions from the new paths,
- the `done:` line includes the videos-attached count,
- og:image fetches ≤ 25.

Then query: `stories?select=id,image_url,video_url&order=id.desc&limit=20` — confirm fresh stories carry filtered image URLs (no `logo`/`icon`/etc pattern) and any attached `video_url` points at a plausibly-matching YouTube video (open one and compare against its story headline by hand — this is the "prefer nothing over wrong" spot-check).

- [ ] **Step 3: Version bump + APK**

`app/pubspec.yaml`: `version: 0.11.0+21`.

```bash
cd app && flutter build apk --release --dart-define=SUPABASE_URL=https://hdgfdswzymfqgjqzqqve.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_RJZjS6Wf3H_VhDYoQm0_6w_id7eWb_G --dart-define=APP_VERSION=0.11.0
cp build/app/outputs/flutter-apk/app-release.apk /c/Users/Tanis/Desktop/finswipe-v0.11.0.apk
```

- [ ] **Step 4: On-device check (Tanis)**

Install, confirm Profile says 0.11.0, then swipe until three card kinds have been seen: one with an image, one with a video (play badge, opens YouTube externally), one with neither — the last must look exactly like today's card.

- [ ] **Step 5: Commit + tag**

```bash
git add app/pubspec.yaml
git commit -m "M8: v0.11.0 — media strip release"
git tag v0.11.0 && git push && git push --tags
```

---

## Self-review notes

- Spec coverage: Task 1 ↔ spec Task 1; Task 2 ↔ spec Task 2 (including applying the filter to `entry_image()` output via `base_row`); Task 3 ↔ spec Task 3; Task 4 ↔ spec Task 4 (migration renumbered 004→007 — 004–006 already exist); Task 5 ↔ spec Task 5; Task 6 ↔ spec Verification.
- Deviation from spec, deliberate: the once-per-day retention guard is implemented as a day-truncated cutoff (stateless no-op repeats) instead of stored state — same bounded work, zero new tables. Flagged in Task 5's comment.
- Deviation from spec, deliberate: `usable_image` width check reads dimensions declared **in the URL** (`?w=`, `-WxH.`) — feed entries' `media_content` width attributes are dropped by `entry_image()` today, and plumbing them through is not worth it; URL-declared widths catch the real CDN cases.
- The video with a dead/missing thumbnail renders nothing (Task 1 note) — "prefer nothing over wrong" extends to a naked play button.
- `video_match` receives `(video_title, story_headline)` tuples; `match_videos` passes exactly that. `cluster_of` returns `(cid, known)` — matches run.py:232.
