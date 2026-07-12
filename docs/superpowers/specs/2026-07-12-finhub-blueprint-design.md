# FinHub — Product & Technical Blueprint

**Date:** 2026-07-12
**Status:** Approved design (pre-implementation)
**Owner:** Solo founder, building solo
**Budget constraint:** ~₹2,000/month running cost at launch; scale spend only after traction

---

## 1. Vision

**One sentence:** An AI-powered, swipe-first financial news app that helps Indian users understand market events in under a minute, with explanations tailored to beginners, traders, and investors.

**Not** a finance app — a new way to consume financial information. One swipe = one story. Every card answers: what happened, why, who is affected, what to watch next.

**Market focus:** India-first (NSE/BSE, SEBI, RBI, Indian IPOs, Indian corporate news) **plus** global/geopolitical news that can impact Indian markets. English language. Android-first.

### Success metric (the only one that matters for MVP)

> A user understands the day's 10 most important financial stories in under 5 minutes — and comes back tomorrow.

Measured via PostHog (free tier): session length, stories viewed per session, explain-tab opens, D1/D7 retention.

---

## 2. Scope

### Phase 1 (this blueprint — what gets built)

| Area | In scope |
|---|---|
| Pipeline | ~15–20 RSS feeds + NSE/BSE corporate announcements + SEBI/RBI releases; dedupe; AI card generation |
| AI | Full pre-generation per story: summary + beginner/trader/investor views + entity extraction + classification + sentiment + impact score (OpenAI) |
| App (Flutter, Android) | Required Google sign-in, onboarding, vertical swipe feed, smart news card, 3 explain tabs, follow (stocks/sectors/topics), search, save, share-as-image, watchlist, profile |
| Personalization | SQL-based: recency + impact score + boost for followed entities + admin-featured pinning. No ML. |
| Admin panel | Real panel in Phase 1 (Streamlit): review queue, approve/reject, edit AI output, feature stories, merge duplicates, source health, pipeline kill switches |
| Analytics | PostHog free tier; thin `events` table collecting swipe/tab/save signals (future rec-engine training data) |

### Phase 2 (documented upgrade path, NOT built now)

- FastAPI backend service (slots between Supabase and the app; pipeline moves from GitHub Actions to the same server — nothing rewritten, only re-hosted)
- Real recommendation engine (trained on the `events` data collected since day one)
- Push notifications (FCM), watchlist alerts
- iOS release (Flutter codebase is already cross-platform; just enable the target)
- Supabase Pro (~₹2,100/mo) when free-tier limits are hit — the first scaling cost, triggered by success

### Parking lot (future, from original brief)

Daily market recap, earnings/IPO/economic calendars, historical event comparisons, AI follow-up chat, portfolio-linked news, creator videos, audio summaries, Hindi/Hinglish explanations.

---

## 3. Architecture

Serverless-max: no owned servers. Two significant codebases (pipeline, app) + one small admin tool.

```
┌────────────────────────────────────────────────────────┐
│ 1. PIPELINE — Python, GitHub Actions cron              │
│    every 30 min (Mon–Fri 09:00–16:00 IST)              │
│    every 2 h otherwise                                 │
│                                                        │
│    fetch RSS (15–20 feeds) ──┐                         │
│    fetch NSE/BSE filings ────┼→ normalize → dedupe     │
│    fetch SEBI/RBI releases ──┘      ↓                  │
│                     OpenAI: one structured call/story  │
│                                     ↓                  │
│                     insert into Supabase as 'pending'  │
└──────────────────────────────┬─────────────────────────┘
                               ↓
┌────────────────────────────────────────────────────────┐
│ 2. SUPABASE (free tier)                                │
│    Postgres · Auth (Google, required) · Storage        │
│    Row Level Security                                  │
└───────┬──────────────────────────────────┬─────────────┘
        ↓                                  ↓
┌───────────────────┐   ┌────────────────────────────────┐
│ 3. FLUTTER APP    │   │ 4. ADMIN PANEL — Streamlit     │
│    Android, v1    │   │    (Community Cloud, free)     │
└───────────────────┘   └────────────────────────────────┘
     5. PostHog (free) — product analytics
```

Key decisions:

- **The app never calls the AI.** Cards are fully pre-built by the pipeline; explain tabs open instantly.
- **Feed ranking is a SQL query on purpose** — honest Phase-1 personalization a solo founder can run for ₹0.
- **GitHub Actions as scheduler:** free, built-in logs, email on failure, stateless runs.
- **Upgrade path preserved:** Supabase Postgres remains the database in every future phase.

---

## 4. Content Sourcing Strategy (hybrid)

1. **RSS feeds (~15–20)** — breadth and speed: ET Markets, Moneycontrol, LiveMint, Business Standard, The Hindu BusinessLine, Reuters India/World, and global/geopolitics feeds relevant to markets.
2. **Primary sources** — depth and zero copyright risk: NSE/BSE corporate announcement feeds, SEBI press releases, RBI notifications/press releases.
3. **AI rewriting** — every headline and summary is written in original words by the AI; facts are not copyrightable, expression is. Every card displays source name + link to the original article.

**Legal guardrails:**
- Never republish article body text; store it transiently for AI processing only.
- Attribution on every card (`source_name`, `source_url`, "read original" link).
- SEBI-safe framing: trader/investor views describe *what to watch*, never buy/sell recommendations. Persistent "Not investment advice" disclaimer on cards and in app onboarding.

---

## 5. AI Engine

**Provider:** OpenAI. **Model:** GPT-4o-mini at launch (GPT-5-mini as drop-in upgrade). Structured Outputs (JSON schema) for every call.

**One structured call per story** (not eight chained steps — cheaper, and views are more coherent when generated together):

```json
{
  "headline_rewrite": "...",
  "summary": "what happened / why / who is affected / what to watch",
  "beginner_explanation": "plain language, concepts defined",
  "trader_view": "short-term impact, sectors/levels to watch (no advice)",
  "investor_view": "long-term implications, what to monitor (no advice)",
  "companies": [{"name": "...", "nse_symbol": "..."}],
  "sectors": ["..."],
  "category": "Markets|Economy|IPO|Global|Commodities|Corporate|Policy|Geopolitics",
  "sentiment": {"label": "positive|negative|neutral", "strength": 1-3},
  "impact_score": 1-10,
  "is_india_relevant": true
}
```

**Quality safeguards:**
- Schema validation before insert; one retry with the validation error appended; still failing → stored `flagged`, never published.
- Company symbols validated against a seeded NSE/BSE symbol table — hallucinated tickers cannot enter the database.
- `is_india_relevant=false` stories are dropped unless category is Geopolitics with impact ≥ 6.
- Prompts live in a versioned `prompts/` directory; a golden-set eval script (~20 real articles with expected outputs) runs on every prompt change.
- Admin edits to AI output are stored — future few-shot/fine-tuning data.

**Cost at ~100 stories/day (~3,000/month):** ~1.5k input + ~1.2k output tokens per story → **~₹300–500/month.**

---

## 6. Data Model (Supabase Postgres)

Eight tables:

- **stories** — id, url, url_hash (unique, dedupe), cluster_id, headline, summary, beginner_view, trader_view, investor_view, source_name, source_url, image_url, published_at, category, sectors[], sentiment, impact_score, status (`pending|approved|rejected|flagged`), is_featured, created_at
- **companies** — id, name, nse_symbol, bse_code, sector, logo_url, aliases[] (seeded from NSE/BSE listings)
- **story_companies** — story_id, company_id (join)
- **users** — Supabase Auth + profile: display_name, experience_level (`beginner|trader|investor`) → sets default explain tab
- **follows** — user_id, target_type (`company|sector|category`), target_id
- **saves** — user_id, story_id, saved_at
- **sources** — id, name, type (`rss|nse|bse|sebi|rbi`), feed_url, is_active, last_fetched_at
- **events** — user_id, story_id, type (`view|swipe_past|tab_open|save|share`), created_at (pruned after 90 days; future rec-engine training data)

**Dedupe, two layers:**
1. `url_hash` — exact duplicates dropped before any AI cost.
2. `cluster_id` — near-duplicates (same story, many outlets) clustered by title similarity; feed shows one card with "also covered by ET, Mint, BS" (a feature, not just hygiene).

**Search:** Postgres full-text index over headline + summary + company names. ₹0.

**Row Level Security:** stories readable by authenticated users, writable only by the pipeline service key; users write only their own follows/saves/events.

**Retention:** events > 90 days pruned; stories > 6 months archived to JSON dump then deleted (keeps free tier healthy).

---

## 7. Flutter App (Android v1)

**Stack:** Flutter, Riverpod state management, Supabase Flutter SDK, PostHog SDK. No custom backend calls in Phase 1.

**Screens:**
1. **Onboarding** — Google sign-in (required) → one question: "I'm new to markets / I trade / I invest long-term" (sets `experience_level`) → pick ≥3 interests → feed. Target: under 60 seconds.
2. **Home Feed** — full-screen vertical PageView, snap-per-story, preload next 3 cards. Card contents: headline · AI summary · company/sector chips (tap = follow/related) · impact badge + sentiment color accent · source + timestamp + "read original" · 🟢🔵🟣 explain tabs (instant, default = user's experience level) · save & share.
3. **Search** — companies, topics, categories; results as swipe cards.
4. **Watchlist** — followed entities + feed filtered to them.
5. **Saved** — bookmarks.
6. **Profile** — experience level (switchable), interests, settings, disclaimer, sign-out.
7. **Story detail** — deep-link target. Shared links open a lightweight web preview page (story card + install button) for recipients without the app.

**Share:** card rendered as a branded image for WhatsApp/LinkedIn/X — every share is an ad.

**Feed ranking (Phase 1):** `status='approved'`, ordered by recency + impact_score, boosted for followed companies/sectors/categories, `is_featured` pinned top.

---

## 8. Admin Panel (Streamlit, Phase 1)

Hosted free on Streamlit Community Cloud, gated by admin login.

- **Review queue** — pending stories, AI output side-by-side with source article; approve / reject / edit.
- **Auto-approve rule** — stories with impact < 7 auto-approve after 2 h unreviewed (feed never starves overnight). Toggleable.
- **Feature** — pin important stories.
- **Duplicates** — view clusters, merge/split.
- **Flagged** — stories that failed AI validation, with raw article for manual handling.
- **Source health** — last_fetched_at per source, pause individual sources.
- **Kill switches** — pause pipeline, pause auto-approve.

---

## 9. Operations, Error Handling & Testing

**Idempotent pipeline runs:** every run re-checks hashes against the DB; re-processing is a no-op; no state in the runner.

| Failure | Handling |
|---|---|
| One feed down | Log, skip, continue; visible via source health |
| OpenAI error / invalid JSON | 1 retry with error appended → else store `flagged`; never published |
| Whole run crashes | GitHub Actions emails owner; next run self-heals |
| Free-tier limits approached | Automated pruning (events 90d, stories 6mo); documented threshold for Supabase Pro upgrade |

**Testing:**
- Pipeline unit tests: dedupe hashing, feed parsing, JSON-schema validation (the three silent-corruption risks).
- Golden set: ~20 real articles with expected extraction results; run on every pipeline/prompt change.
- Prompt eval script: diff outputs over the golden set when prompts change.
- App: widget tests for feed card + explain tabs; manual pass on a physical Android device before each release.

---

## 10. Build Order

| # | Milestone | Est. | Runnable outcome |
|---|---|---|---|
| 1 | Pipeline core: RSS → dedupe → OpenAI card → Supabase | 1–2 wk | AI-generated finance cards appearing in DB |
| 2 | Admin panel (Streamlit) | 3–5 d | You read/curate your own feed daily — first product test |
| 3 | Primary sources: NSE/BSE, SEBI, RBI | 1 wk | Exclusive, zero-copyright content flowing |
| 4 | Flutter app: auth/onboarding → feed → tabs → save/share/search/watchlist | 3–4 wk | Installable app on your phone |
| 5 | Polish: share images, deep links, PostHog, Play internal testing → closed beta | 1–2 wk | Beta users onboard |

Gate between 2→4: if *you* don't want to read your own feed every morning, fix content quality before writing any Flutter.

---

## 11. Cost Summary (launch)

| Item | Cost |
|---|---|
| OpenAI (GPT-4o-mini, ~3,000 stories/mo, all views) | ~₹300–500/mo |
| Supabase, GitHub Actions, Streamlit, PostHog | ₹0 |
| Google Play developer account | ₹2,600 one-time |
| **Total running** | **~₹500/mo** (headroom to 3–4× volume within ₹2,000) |

First scaling costs (triggered by success, not required at launch): Supabase Pro ~₹2,100/mo; stronger AI models; FCM at scale (free anyway).

---

## 12. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Copyright complaints from publishers | Original AI wording only; attribution + link-back on every card; drop a source on request |
| SEBI/regulatory (investment advice) | No buy/sell language (enforced in prompts + golden-set evals); visible disclaimer everywhere |
| AI hallucination (wrong ticker/fact) | Symbol-table validation; admin review queue; impact ≥ 7 requires human approval |
| RSS feeds change/break | Source health dashboard; pipeline tolerates individual failures |
| Free tiers change terms | Standard Postgres + Python everywhere — portable by design; FastAPI path documented |
| Solo-founder burnout | Auto-approve keeps feed alive without daily babysitting; milestones each ship something usable |
