# Implementation prompt — FinSwipe media strip

Hand this to Fable as-is.

---

You are working in the FinSwipe repo (`c:\Users\Tanis\Desktop\finhub`). It is a
zero-cost Indian financial news app: a Python pipeline (`pipeline/run.py`) fetches
RSS, scores stories with Gemini, and writes to Supabase; a Flutter app (`app/`)
shows them as full-screen swipeable cards.

Add a horizontal media strip to the story card: a 16:9 picture (or video
thumbnail) sitting between the headline and the summary.

## Absolute constraints — violating any of these fails the task

1. **Hotlink only.** Never download, copy, proxy, or re-host an image or video.
   Store the URL, let the device fetch it from the origin CDN. Copying media into
   Supabase Storage would blow the free tier within weeks. This is non-negotiable.
2. **No AI-generated or stock imagery, ever.** This is a news app. An illustrative
   image that isn't the actual event is misinformation. If there is no real,
   relevant image, show nothing.
3. **No new Flutter dependencies.** `Image.network` and `url_launcher` (already
   imported in `app/lib/screens/feed.dart`) cover this entirely.
4. **Respect the GitHub Actions budget.** `.github/workflows/pipeline.yml:5`
   budgets ~1300 of 2000 free minutes/month. Your changes get a hard cap of
   ~25 extra HTTP requests per run at 3s timeout each.
5. **Prefer nothing over wrong.** Every ambiguous case collapses the strip. A
   blank card is fine; a mismatched one is not.

## Task 1 — Flutter strip

`app/lib/models.dart`: add `imageUrl` (from `image_url`) and `videoUrl` (from
`video_url`) to `Story`. The `image_url` column already exists in the DB.

`app/lib/screens/feed.dart`: insert the strip between the headline
(line ~114) and the `Expanded` summary block (line ~118).

- `AspectRatio(aspectRatio: 16/9)` + `Image.network(..., fit: BoxFit.cover)`.
- Pass `cacheWidth` (~2x the logical card width) so a 4000px press photo doesn't
  decode into memory at full size on a budget phone.
- `errorBuilder` returns `SizedBox.shrink()` — a dead URL must collapse silently,
  never show a broken-image icon.
- `loadingBuilder` shows a flat `surface`-colored block, no spinner.
- If `videoUrl != null`, overlay a centered play badge and wrap in `InkWell` that
  opens `videoUrl` via `launchUrl(..., LaunchMode.externalApplication)`.
- If both URLs are null, render `SizedBox.shrink()` — no placeholder, no gap.

Match the existing clay-black style in `app/lib/theme.dart`: square corners,
`border` color, no shadows, no rounded rects.

## Task 2 — image relevance filter (pipeline)

Add `usable_image(url, seen_counts)` to `pipeline/run.py`. It returns the URL or
`None`. Reject when:

- The URL path matches any of: `logo`, `icon`, `avatar`, `author`, `byline`,
  `placeholder`, `default`, `sprite`, `blank`, `spacer`, `1x1`, `pixel`, `ads`.
- Declared dimensions are present and width < 400.
- **The same URL already appears on 3 or more stories from the last 7 days.**
  This is the important one — it catches house images (the generic "BSE building"
  photo, the paywall banner) that are technically valid but carry no information.
  Fetch these counts in a single query at the start of the run, not per story.

Apply it to the existing `entry_image()` result too, not only to new og:image
scrapes — the reused-house-image problem already exists in the current data.

## Task 3 — og:image fallback (pipeline)

Only for stories that pass the AI gate and are actually being inserted — never for
raw feed items. This bound is what keeps the Actions budget intact.

- Skip entirely if the item already has a usable image.
- `GET` the article URL, 3s timeout, parse `<meta property="og:image">`
  (fall back to `twitter:image`). Regex is fine; do not add a parser dependency.
- Run the result through `usable_image()`.
- Cap at 25 fetches per run. Any failure, timeout, or non-HTML response → `None`
  and move on. This must never raise.

## Task 4 — video

Migration `pipeline/migrations/004_media.sql`: `alter table stories add column
video_url text;`

Ingest: YouTube channel feeds (`https://www.youtube.com/feeds/videos.xml?channel_id=…`)
are plain RSS and drop straight into the existing `sources` table with a new
`type`. Add channels for CNBC-TV18, ET Now, Mint, Moneycontrol, Zee Business.
These items are media candidates, **not** stories — they must never be inserted
into `stories` on their own.

Matching, in this order:

1. **Cluster gate (free, deterministic).** Run the video title through the
   existing `assign_cluster()` / `title_tokens()` Jaccard logic. If it doesn't
   land in an existing story's cluster, discard it. No AI call.
2. **Recency gate.** Discard if published more than 12h from the story.
3. **Gemini adjudication**, one batched call per run covering all surviving
   candidates — never one call per video. Prompt it with video titles and
   candidate headlines and require it to return `null` for anything that isn't
   plainly the same event. Instruct it explicitly that returning `null` is the
   correct and preferred answer under uncertainty. A generic "Market Wrap" or
   "Closing Bell" clip must never match a specific story.

Thumbnail: `https://img.youtube.com/vi/<video_id>/hqdefault.jpg`, extracted from
the feed entry's `yt:videoId`. Set it as `image_url` when the story has none.

## Task 5 — retention (this is what makes it run for years)

There is no retention code in the repo. The `events` table
(`pipeline/migrations/003_users.sql:29`) gets a row on every card swipe and grows
without bound against a 500 MB free-tier database.

Add to the pipeline run, guarded to once per day:

```sql
delete from events where created_at < now() - interval '90 days';
```

## Verification

- Add `pipeline/tests` cases for `usable_image()`: a logo URL rejects, a small
  image rejects, an image already on 3 stories rejects, a normal article image
  passes.
- Add a case asserting a YouTube item never produces a row in `stories`.
- Run the existing pipeline test suite; it must stay green.
- Build the debug APK and confirm three cards render: one with an image, one with
  a video, one with neither (which must look exactly like today's card).

## Style

Match the surrounding code. `pipeline/run.py` uses short functions and comments
that explain *why* a rule exists (see the stale-item comment at line 137) rather
than what the code does. Keep that. Do not add abstractions, config classes, or
interfaces with one implementation — the smallest change that works is correct.
