# Deep Read — Design

Owner's spec (2026-08-14, approved): *"I was swiping, saw an interesting story,
I want to know more — I swipe left for the next page and, just like a
newspaper, I can read the whole news there. The AI will understand and explain
the whole story in an easy way; a long story can spread to the next page."*
Generation on FIRST open, cached forever after (owner accepted 2-3s first-open
wait; cost follows curiosity, not volume).

## Reading flow

- Each feed card becomes page 0 of a **horizontal** PageView; the outer feed
  stays the vertical one. Swipe LEFT → deep-read pages 1..N; swipe RIGHT →
  back to the card; vertical swipes anywhere continue the feed.
- First open shows a "writing your story…" page for the ~2-3s generation, then
  the pages. Openings after that are instant (cached).
- Newspaper dress within clay-black: serif headings, 16.5px serif body with
  generous leading, mono metadata line (outlet count · category · IMPACT),
  page dots at the bottom. No new dependencies.

## Data

- Migration `008_deep_read.sql`: `alter table stories add column if not
  exists deep_read jsonb;` (null until someone opens it).
- Contract (also the app model's test fixture):
  `{"pages": [{"heading": "What happened", "body": "…"}, …]}` — 3-6 pages,
  each 60-120 words: What happened / Background / Who's affected / Why it
  matters (+ What's next when the article supports it). Body plain text.

## Generation (edge function `deepread`, mirrors `qa`)

- POST `{story_id}` with the user's JWT (same auth stance as `qa`).
- If `stories.deep_read` is set → return it (no AI call).
- Else build context: the story row (headline, hook, summary, category,
  companies, impact), every cluster member's headline + outlet (corroboration
  = extra facts), and the article body fetched from `source_url` when the URL
  is not a GNews wrapper (5s timeout, tags stripped, first ~6000 chars; any
  failure → proceed without it).
- One chat call, Groq-first lanes exactly like `qa` (chat never competes with
  the pipeline's Gemini pool); JSON mode; validated server-side: 1-8 pages,
  every page has non-empty body, else refuse.
- Refusal path (thin context, model down): `{"pages": []}` → app shows "Full
  story unavailable — read the original" with the outlet link. Never cached,
  so a later open retries.
- Save validated JSON to `stories.deep_read`, return it. Facts only, easy
  language, never advice — same prompt lineage as story_v1.
- `track('deep_read', {story_id})` on open (PostHog + nothing else; Supabase
  `events` gains type `deep_read` only if trivially allowed by schema).

## Non-goals

Pre-generation for unopened stories; images inside deep-read pages; TTS;
translations. RLS stays read-for-anon on approved stories — the WRITE of
deep_read happens only in the edge function (service role).

## Test contract

- App: `DeepRead.fromJson` tolerates refusal + truncation (QaAnswer pattern);
  page widgets render heading/body; card→pages navigation exists per card.
- Function: context builder handles GNews-wrapper skip; validator rejects
  empty/oversized page lists (deno tests colocated like qa's, if present).
