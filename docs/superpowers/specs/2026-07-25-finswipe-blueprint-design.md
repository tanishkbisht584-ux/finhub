# FinSwipe — Product & Technical Blueprint (v2)

**Date:** 2026-07-25 (v2 — supersedes the 2026-07-12 FinHub blueprint)
**Status:** Approved design (pre-implementation)
**Owner:** Solo founder, building solo
**Budget constraint:** ~₹2,000/month running cost at launch; scale spend only after traction
**Repo:** `finhub` (name kept; product name is FinSwipe)

---

## 1. Vision

FinSwipe is not another finance news app, stock screener, or charting platform. It is **the fastest way for retail investors and traders to understand what is happening in the market and why it matters.**

Customer interviews showed people don't want more news — they want **better explanations**. The questions they actually ask: "Why is the market falling?", "Which stocks are affected?", "Is this short-term or long-term?", "How does this affect me?" Every feature must serve that single goal: context, not headlines.

**Market focus:** India-first (NSE/BSE, SEBI, RBI, Indian IPOs, corporate news) plus global/geopolitical news that can impact Indian markets. English. Android-first (Flutter).

### Success metric: Time to Understanding

> A user opens the app and understands the biggest market-moving event of the day in **under 15 seconds**.

Not downloads. Not time-in-app. Supporting signals (PostHog free tier): time from app-open to first full card read, cards understood per session, Q&A usage, alert open rate, D1/D7 return rate.

### Product principles

1. **Context over headlines** — every card answers: what happened, why, who is affected, positive or negative, short-term or long-term, why you should care.
2. **Trust is the foundation** — AI explains, never invents. Every summary and impact call is backed by named sources with links. Confidence is shown where relevant. No buy/sell recommendations, ever.
3. **Speed** — markets move in minutes; ingestion, summarization, and alerts are built for fast delivery.
4. **Ruthless focus** — interviewees asked for charts, broker integration, portfolio tools, AI ratings, trade journals. All refused for MVP. Solve one problem exceptionally well first.

---

## 2. Scope

### MVP (this blueprint — what gets built)

| Feature | Description |
|---|---|
| **Swipe feed** | Vertical, Reels-style. One swipe = one story, fully understood in seconds. |
| **Smart news card** | Single card, no tabs, read as a billboard in three levels: **hook** (AI-written, ≤8 words, arresting but strictly factual — never clickbait) · **story image** (article's own og:image preview with attribution; category-tinted aurora as the fallback visual — no empty image boxes) · headline · concise AI summary (what/why/who/why-care) · expected impact (positive/negative + strength) · **short-term vs long-term flag** · affected sectors & stocks (tappable) · source name + link to original. Written plainly enough for beginners, precise enough for traders. |
| **Q&A search** | Ask "Why is NIFTY falling today?" → sourced AI explanation. Two-tier: our stories first, whitelisted-web fallback. Suggested follow-up questions. |
| **Smart alerts** | Push notifications only for significant market-moving events; instant, machine-gated, personalized to follows. |
| **Basic stock page** | Current price (delayed) · lightweight chart · recent related news · a few key metrics. Deliberately NOT competing with Screener/TradingView. |
| **Follow** | Stocks, sectors, topics → boosts feed ranking and drives personalized alerts. |
| **Save / Share** | Bookmarks; share card rendered as branded image (WhatsApp/LinkedIn/X). |
| **Admin panel** | Streamlit: review queue, edit AI output, feature stories, merge duplicates, source health, alert override, kill switches. |

Login: Google sign-in required at first launch. Onboarding: sign in → pick ≥3 interests (sectors/topics/popular stocks) → feed. Under 60 seconds.

### Explicit non-goals for MVP (requested in interviews, deliberately refused)

Advanced charts, broker integration, portfolio management, AI stock recommendations/ratings, trade journals, advanced analytics. These delay validation and dilute focus.

### Phase 2+ (after Time-to-Understanding is validated)

Portfolio integration (news mapped to holdings) → richer fundamentals & AI company context → historical event comparisons → richer watchlists & risk views → eventually broker integration. Also: FastAPI backend (slots between Supabase and app when needed), ML recommendation engine (trained on `events` data collected from day one), iOS release, Supabase Pro (~₹2,100/mo — first scaling cost, triggered by success).

---

## 3. Architecture

Serverless-max: no owned servers. Two significant codebases (pipeline, app) + one small admin tool.

```
┌────────────────────────────────────────────────────────┐
│ 1. PIPELINE — Python, GitHub Actions cron              │
│    every 15 min (Mon–Fri 09:00–16:00 IST)              │
│    every 2 h otherwise                                 │
│                                                        │
│    fetch RSS (15–20 feeds) ──┐                         │
│    fetch NSE/BSE filings ────┼→ normalize → dedupe     │
│    fetch SEBI/RBI releases ──┘  + cluster   ↓          │
│                     Gemini (free tier): 1 call/story   │
│                                     ↓                  │
│               insert 'pending' → auto-approve rules    │
│                                     ↓                  │
│               alert engine: machine-gated FCM push     │
└──────────────────────────────┬─────────────────────────┘
                               ↓
┌────────────────────────────────────────────────────────┐
│ 2. SUPABASE (free tier)                                │
│    Postgres · Auth (Google, required) · RLS            │
│    Edge Function: Q&A search (two-tier, sourced)       │
└───────┬──────────────────────────────────┬─────────────┘
        ↓                                  ↓
┌───────────────────┐   ┌────────────────────────────────┐
│ 3. FLUTTER APP    │   │ 4. ADMIN PANEL — Streamlit     │
│    Android, v1    │   │    (Community Cloud, free)     │
│    + FCM push     │   └────────────────────────────────┘
│    + Yahoo prices │
└───────────────────┘   5. PostHog (free) — analytics
```

### Agent view of the pipeline

The pipeline is organized as a three-level agent hierarchy — implemented as parallel workers and one AI classification stage, not as separate LLM agents per level (which would multiply free-tier AI usage ~8× for identical output):

```
Level 1 — SOURCE AGENTS (one per outlet, all run in parallel)
  ET Markets agent · LiveMint agent · SEBI agent · RBI agent ·
  Yahoo agent · OilPrice agent · … (24 total)
  Each independently crawls its outlet's feed; a slow or dead
  outlet never blocks the others.
        ↓ all raw items
Level 2 — CATEGORY ROUTING (AI classification lane)
  Every story is read once by Gemini, which assigns its category:
  Markets | Economy | IPO | Global | Commodities | Corporate |
  Policy | Geopolitics — one structured call returns the full
  card INCLUDING the category (8 separate category agents would
  cost 8× and produce the same result).
        ↓ classified cards
Level 3 — MASTER ORCHESTRATOR
  Merges all source agents' output, dedupes/clusters the same
  story across outlets, and stores everything category-indexed
  in Postgres — so the feed can instantly serve "all Markets
  news" or "all IPO news".
```

Key decisions:

- **Feed cards contain zero runtime AI** — fully pre-generated by the pipeline; cards render instantly. The only runtime AI is Q&A search, behind an Edge Function (API key never ships in the app).
- **Feed ranking is SQL:** approved stories by recency + impact score, boosted for followed entities, featured pinned. Honest ₹0 personalization; the ML rec engine waits for Phase 2 and trains on `events` data collected from day one.
- **Importance/trust uses five signals, not one:** (1) AI impact score — content-based, primary rank driver; (2) cluster corroboration — trust gate for alerts; (3) **source authority weight** — `sources.authority` 1-10 (regulators/exchanges 10, national financial dailies 8, others 5) feeds both rank and the alert gate (a single authority-10 source like RBI auto-passes the gate; it IS the primary source); (4) **velocity** — cluster growth rate from member timestamps (3 outlets in 20 min = breaking; same in 8 h = routine); (5) **entity weight** — stories touching index heavyweights (`companies.is_nifty50`) get a rank boost. Phase 2 adds market-reaction verification (price move vs. claimed impact) and reader-behavior trending from `events`.
- **GitHub Actions as scheduler:** free, logged, emails on failure, stateless idempotent runs. Known limitation: cron can lag a few minutes under load — acceptable at MVP, documented as the first thing Phase 2's always-on worker fixes.
- **Speed path for breaking news:** primary-source and multi-source-confirmed high-impact stories flow ingest → AI → auto-approve → alert with no human in the loop (see §7).

---

## 4. Content Sourcing

1. **RSS (~15–20 feeds)** — breadth & speed: ET Markets, Moneycontrol, LiveMint, Business Standard, Hindu BusinessLine, Reuters India/World, global & geopolitics feeds.
2. **Primary sources** — depth & zero copyright risk: NSE/BSE corporate announcements, SEBI press releases, RBI notifications.
3. **AI rewriting** — headlines and summaries in original words; facts aren't copyrightable, expression is. Article bodies stored transiently for processing only. Every card shows source name + link.
4. **Market data** — Yahoo Finance (unofficial, free): ~15-min delayed prices + daily history for `.NS` symbols. Acceptable because FinSwipe explains news — it is not a trading terminal. Swappable for a paid API (Upstox/Kite ~₹2,000/mo) post-traction; the stock page reads prices through one internal interface so the swap touches one module.

**Legal guardrails:** attribution everywhere; no body-text republishing; SEBI-safe framing (describe impact and what to watch — never buy/sell advice); persistent "Not investment advice" disclaimer; drop any source on request.

### Verified source endpoints (checked 2026-07-25)

- **Moneycontrol:** official RSS is dead — all feeds at `moneycontrol.com/rss/*.xml` return HTTP 200 but froze on 23 Apr 2024 (some 2016). **Working route: Google News RSS** filtered to the site, verified fresh: `https://news.google.com/rss/search?q=site:moneycontrol.com&hl=en-IN&gl=IN&ceid=IN:en` (add keywords for topics, e.g. `+ipo`, `+nifty`). Applies to any outlet whose native RSS dies — Google News RSS is the universal fallback.
- **Nuvama:** no public feed. Corporate WordPress API is open but empty; retail site (nuvamawealth.com) is a closed JS app; research reports are proprietary/client-only. **Route: ingest public news coverage** of their research via Google News RSS query `"Nuvama"` — outlets report their calls ("Nuvama says…"), which is also the legally clean path (never summarize proprietary broker PDFs directly). Same pattern works for other brokerages (Motilal Oswal, Jefferies India, etc.).
- Pipeline implication: the `sources` table supports type `google_news_query` alongside `rss` — a source can be a query, not just a feed URL.

**Verified-fresh free feeds (tested 2026-07-25):**

| Source | URL | Status |
|---|---|---|
| ET Markets | `economictimes.indiatimes.com/markets/rssfeeds/1977021501.cms` | ✅ fresh same-day |
| ET Top Stories | `economictimes.indiatimes.com/rssfeedstopstories.cms` | ✅ fresh |
| LiveMint Markets | `livemint.com/rss/markets` | ✅ live |
| SEBI | `sebi.gov.in/sebirss.xml` | ✅ fresh same-day |
| RBI press releases | `rbi.org.in/pressreleases_rss.xml` | ✅ fresh |
| Yahoo Finance (global) | `finance.yahoo.com/news/rssindex` | ✅ fresh |
| MarketWatch (global) | `feeds.content.dowjones.io/public/rss/mw_topstories` | ✅ fresh |
| CNBC World | `search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100003114` | ✅ fresh |
| BBC Business (global/geo) | `feeds.bbci.co.uk/news/business/rss.xml` | ✅ fresh |
| Investing.com | `investing.com/rss/news.rss` | ✅ fresh |
| ET Economy | `economictimes.indiatimes.com/news/economy/rssfeeds/1373380680.cms` | ✅ fresh same-day |
| ET IPO/FPO | `economictimes.indiatimes.com/markets/ipos/fpos/rssfeeds/14655708.cms` | ✅ fresh |
| Times of India Business | `timesofindia.indiatimes.com/rssfeeds/1898055.cms` | ✅ fresh same-day |
| Business Today | `businesstoday.in/rssfeeds/?id=home` | ✅ fresh same-day |
| Inc42 (startups/IPO ecosystem) | `inc42.com/feed/` | ✅ fresh |
| Zerodha Z-Connect (market commentary) | `zerodha.com/z-connect/feed` | ✅ live, low frequency |
| WSJ Markets (global) | `feeds.content.dowjones.io/public/rss/RSSMarketsMain` | ✅ fresh |
| Guardian Business (global) | `theguardian.com/uk/business/rss` | ✅ fresh |
| OilPrice (commodities) | `oilprice.com/rss/main` | ✅ fresh same-day |
| Al Jazeera all-news (geopolitics) | `aljazeera.com/xml/rss/all.xml` | ⚠️ fresh but high non-market noise — burns AI quota on irrelevant stories; keep `is_active=false`, prefer the Google News geopolitics query |
| Google News `when:1h` queries | `news.google.com/rss/search?q=<query>+when:1h&hl=en-IN&gl=IN&ceid=IN:en` | ✅ fresh — breaking-news workhorse |
| NDTV Profit, HT Business, The Hindu Business, Zee Business, CNN Money, Mint non-markets sections | various | ❌ dead/blocked — reach via Google News `site:` queries if needed |

**Primary coverage by card category** (the AI assigns each story's actual category; this maps each source's main contribution):

| Category | Primary sources |
|---|---|
| Markets | ET Markets, LiveMint Markets, Moneycontrol (GNews), breaking-IN query, Zerodha Z-Connect, brokerage-calls query |
| Economy | ET Economy, RBI, TOI Business, Business Today |
| Policy | SEBI, RBI, breaking-IN query |
| IPO | ET IPO, GNews IPO query, Inc42 |
| Global | Yahoo Finance, MarketWatch, CNBC World, WSJ Markets, Investing.com |
| Commodities | OilPrice, Investing.com, ET Markets |
| Corporate | ET Top Stories, Business Today, TOI Business, Moneycontrol (GNews); NSE/BSE filings from M3 |
| Geopolitics | GNews geopolitics query, BBC Business, Guardian Business |
| Moneycontrol native RSS | `moneycontrol.com/rss/*.xml` | ❌ frozen Apr 2024 — use Google News `site:` query |
| Business Standard, Financial Express, PIB RSS | various | ❌ dead/blocked — use Google News `site:` queries |
| CNBC-TV18, BusinessLine | feed URLs exist | ⚠️ verify item dates in parser during M1 |
| NSE/BSE announcements | JSON APIs (cookie/header handshake needed) | Milestone 3; fastest primary source |

---

## 5. AI Engine

**Provider:** Google Gemini **free tier** (AI Studio API). **Model:** Gemini 2.5 Flash-Lite (Flash for Q&A if limits allow). Structured JSON output everywhere.

**Free-tier design rules:**
- All AI calls go through one small internal interface (`ai.py` / the Edge Function's single client) — switching to paid Gemini or OpenAI (~₹300–500/mo) is a config change, not a rewrite.
- Pipeline throttles to stay under free-tier requests-per-minute; a burst of breaking stories processes over minutes, not seconds — acceptable at MVP.
- Known trade-off: Google may use free-tier inputs to improve models. Our inputs are public news articles and anonymous market questions — nothing sensitive.
- Quota risk (Google shrinking free limits) is mitigated by the swappable interface + the ₹2,000/mo budget held in reserve.

### Story processing — one structured call per story

```json
{
  "hook": "billboard line, <=8 words, arresting but strictly factual",
  "headline_rewrite": "original wording, plain language",
  "summary": "what happened / why / who is affected / why you should care",
  "impact": {
    "direction": "positive|negative|mixed|neutral",
    "strength": 1-3,
    "horizon": "short_term|long_term|both",
    "score": 1-10
  },
  "companies": [{"name": "...", "nse_symbol": "..."}],
  "sectors": ["..."],
  "category": "Markets|Economy|IPO|Global|Commodities|Corporate|Policy|Geopolitics",
  "is_india_relevant": true,
  "confidence": "high|medium|low"
}
```

One call, not eight chained steps: cheaper, and impact/summary stay coherent. `confidence` is shown on the card when not high — trust principle made visible.

**Severity levels (L1 highest):** the DB derives `severity_level` from `impact_score` automatically (generated column): L1 = score 9–10 (breaking/historic — alert + pierces quiet hours), L2 = 7–8 (major — machine-gated alert), L3 = 4–6 (notable — normal feed), L4 = 1–3 (minor — sinks). Severity is rated by the same free-tier AI call that categorizes the story — zero extra cost or latency — then adjusted by the other four signals (authority, corroboration, velocity, entity weight).

**Chief Editor pass (two-level severity, built in Milestone 3):** per-story scoring judges each story in isolation; a second-level "editor" Gemini call runs once per pipeline run on a *compact digest* of the last ~3 hours of stories across all categories — headline + level + the code-computed signals (cluster size, authority, velocity, entity weight) per story. It re-levels stories that are inconsistent relative to peers, names the single most important story right now (feeds the alert engine and the Time-to-Understanding top card), and flags same-event pairs the clustering missed. One AI call per run (~30–40/day, compact text only) — comparative editorial judgment at free-tier cost. Signals stay code-computed; the editor consumes them as facts, never re-derives them.

**Quality safeguards:** schema validation before insert (1 retry with error appended → else `flagged`, never published) · company symbols validated against a seeded NSE/BSE table (no hallucinated tickers) · `is_india_relevant=false` dropped unless Geopolitics with score ≥ 6 · prompts versioned in `prompts/` with a ~20-article golden-set eval run on every change · admin edits stored as future few-shot data.

### Q&A search — the only runtime AI

1. User asks a question → Supabase Edge Function.
2. **Tier 1:** full-text search over our processed stories (last 7 days) + companies table → top ~5 stories → Gemini answers **only from those sources**, citing each claim. If sources don't cover it → Tier 2.
3. **Tier 2 (fallback):** live web search restricted to a **whitelisted domain list** (Reuters, ET, Mint, Moneycontrol, Business Standard, NSE/BSE/RBI/SEBI official). Answers labeled "from web sources" with links. The model never answers from its own knowledge — if the whitelist can't support an answer: "our sources don't clearly explain this yet."
4. **Answer format:** what's happening → why → who's affected → what to watch, confidence level, tappable source cards, and 2–3 suggested follow-up questions (each follow-up is a fresh sourced answer — mini-chat feel without freewheeling chat).
5. **Cost control:** no visible cap; silent abuse guard at 50 questions/user/day; popular questions cached 15 min (market panic ≠ thousand identical AI calls — and protects the free-tier daily quota). ₹0 within Gemini free tier; Tier 2 adds a search-API call (Tavily/Brave free tier at MVP volume).
6. **Provider fallback (Q&A only):** Gemini free tier caps at 1,000 requests/day. When the day's Gemini quota is near exhausted, Q&A calls fail over to **Groq** (free tier, Llama 3.3 70B, ~1,000 RPD, 30 RPM) — roughly doubling daily Q&A capacity to ~2,000/day at ₹0. Groq's inference is also near-instant, so failover costs no perceptible latency. Story processing and the Chief Editor stay on Gemini only (their volume is small and predictable — no fallback needed there). Routed through the same swappable AI interface (§5 intro) — trying Gemini first, Groq on quota/rate-limit error.

---

## 6. Data Model (Supabase Postgres)

- **stories** — id, url, url_hash (unique, dedupe), cluster_id, headline, summary, impact_direction, impact_strength, impact_horizon, impact_score, confidence, source_name, source_url, image_url, published_at, category, sectors[], status (`pending|approved|rejected|flagged`), is_featured, alerted_at, created_at
- **companies** — id, name, nse_symbol, bse_code, sector, logo_url, aliases[] (seeded from NSE/BSE listings)
- **story_companies** — story_id, company_id
- **users** — Supabase Auth + profile: display_name, fcm_token, alert_settings
- **follows** — user_id, target_type (`company|sector|category`), target_id
- **saves** — user_id, story_id, saved_at
- **sources** — id, name, type (`rss|nse|bse|sebi|rbi`), feed_url, is_active, last_fetched_at
- **events** — user_id, story_id, type (`view|swipe_past|save|share|qa_ask|alert_open`), created_at (pruned after 90 days; future rec-engine training data)
- **qa_cache** — question_hash, answer_json, created_at (15-min TTL)

**Dedupe, two layers:** `url_hash` drops exact duplicates before any AI cost; `cluster_id` groups near-duplicates (same story, many outlets) → one card showing "also covered by ET, Mint, BS" — and multi-source confirmation doubles as the alert trust gate.

**Search:** Postgres full-text over headline + summary + company names (also powers Q&A Tier 1). ₹0.

**RLS:** stories readable by authenticated users, writable only by pipeline service key; users write only their own rows. **Retention:** events > 90 d pruned; stories > 6 mo archived to JSON then deleted.

---

## 7. Smart Alerts

Push via FCM (free), sent by the pipeline the moment a qualifying story lands.

**Machine gate (speed without false alarms):** impact score ≥ 8 auto-alerts instantly **if** the story is (a) confirmed by 2+ independent sources (cluster size ≥ 2) **or** (b) from a primary source (exchange filing, RBI/SEBI release). Otherwise a **5-minute grace window**: a still-uncorroborated story from a trusted outlet (authority ≥ 8 — ET, Mint, Moneycontrol, WSJ, BBC) alerts anyway once it is 5 minutes old. Corroboration usually arrives first and fires sooner; the window caps the wait. Sources below authority 8 never alert solo, at any age.

**Rules:**
- Global market-movers: max 5/day. The cap limits **pushes, not publication** — a qualifying story past the cap is still approved into the feed, it just doesn't buzz a phone.
- Personalized: impact ≥ 6 touching a followed stock/sector → alert, max 5/day per user.
- Quiet hours 22:00–07:00 IST; pierced only by impact ≥ 9 ("wake me if the market is crashing").
- Every alert deep-links to its story card: open → understand → done. That flow *is* the 15-second metric.
- Admin panel: manual "send alert" override + per-user mute stats.

**Voice alerts for L1 only.** The rarest, historic-tier stories (impact 9–10) also get spoken aloud, not just pushed silently — reserved for L1 so the interruption stays meaningful and never trains users to ignore it. Uses the phone's **on-device text-to-speech** (Android's built-in TTS via `flutter_tts`) — ₹0 cost, no audio generation or hosting, since the phone synthesizes speech from text the pipeline already wrote. Speaks the AI-written **hook only** (e.g. "Oil just got scary for India") — roughly 3 seconds, matching the 15-second-understanding ethos; tapping the notification opens the full card. Toggle in Profile → Alerts ("Read the biggest stories aloud"), on by default since it's L1-gated and therefore rare.

---

## 8. Flutter App (Android v1)

**Stack:** Flutter, Riverpod, Supabase Flutter SDK, FCM, PostHog SDK, `flutter_tts` (on-device voice for L1 alerts, §7).

**Design language: liquid glass.** Frosted translucent cards (blur + saturation, 1px light borders) floating over deep, category-tinted static aurora gradients — the background hue itself signals the news category before reading a word. Performance rules for budget Android (most of the Indian market): at most two live blur surfaces per screen (story card + action dock); aurora backgrounds are pre-rendered static gradients, never live blur; devices that can't hold 60fps in the feed fall back to semi-transparent solid cards with identical layout. Severity/impact color accents ride on top of the glass (L1 ember red, positive mint, negative coral).

**Screens:**
1. **Onboarding** — Google sign-in (required) → pick ≥3 interests → feed. < 60 s.
2. **Home feed** — full-screen vertical PageView, snap-per-story, preload 3. The smart card (§2) with impact badge (direction/strength color), short-vs-long-term chip, company/sector chips (tap = follow or open stock page), source link, save/share.
3. **Search / Ask** — one box, two behaviors: entity queries ("Tata Motors") → stock page & related stories; question queries ("why is nifty falling") → Q&A answer card. Suggested trending questions shown.
4. **Stock page** — delayed price + light line chart (Yahoo), recent related story cards, a few key metrics (market cap, P/E, 52-wk range). Nothing more, by design.
5. **Watchlist** — followed entities + filtered feed.
6. **Saved** — bookmarks.
7. **Profile** — interests, alert settings (incl. voice-alert toggle, §7), disclaimer, sign-out.
8. **Story detail** — deep-link target (alerts & shares). Recipients without the app get a web preview page with install button.

**Share:** card rendered as branded image — every share is an ad.

---

## 9. Admin Panel (Streamlit, free hosting)

Review queue (AI output beside source article; approve/reject/edit) · auto-approve: score < 8 auto-approves after 10 min unreviewed; single-source score ≥ 8 held for approval (multi-source/primary auto-flows, §7) — the two thresholds must stay equal (auto-approve `< N`, alert gate `>= N`) or scores in the gap sit pending forever · feature/pin · cluster merge/split · flagged stories · source health · manual alert send · kill switches (pipeline, auto-approve, alerts).

---

## 10. Operations, Error Handling & Testing

Idempotent runs: hashes re-checked each run; no state in the runner; re-processing is a no-op.

| Failure | Handling |
|---|---|
| One feed down | Log, skip, continue; visible in source health |
| AI call error / invalid JSON | 1 retry with error appended → else `flagged`, never published |
| Free-tier quota exhausted mid-day | Stories queue as unprocessed; next runs catch up; admin sees backlog; config switch to paid model if chronic |
| Yahoo Finance breaks | Stock page degrades gracefully (news + metrics still render); price module isolated for API swap |
| Actions run crashes | Email to owner; next run self-heals |
| Free-tier limits near | Automated pruning; documented Supabase Pro threshold |
| False-alarm risk on alerts | Machine gate (§7); alerts kill switch in admin |

**Testing:** pipeline unit tests (dedupe hashing, feed parsing, schema validation) · golden set ~20 real articles, run on every pipeline/prompt change · Q&A eval: ~15 canned questions incl. unanswerables (must refuse, not invent) · widget tests for card + Q&A answer · manual device pass before each release.

---

## 11. Build Order

| # | Milestone | Est. | Runnable outcome |
|---|---|---|---|
| 1 | Pipeline core: RSS → dedupe/cluster → Gemini card → Supabase | 1–2 wk | AI cards in DB |
| 2 | Admin panel (Streamlit) | 3–5 d | You curate & read your own feed daily — first product test |
| 3 | Primary sources: NSE/BSE, SEBI, RBI + alert engine (machine gate, FCM send) | 1–1.5 wk | Exclusive content + alerts firing |
| 4 | Flutter app core: auth/onboarding → feed → save/share → stock page | 3–4 wk | Installable app |
| 5 | Q&A search (Edge Function + UI) + alert receive/deep-links + share images + PostHog → Play internal testing → closed beta | 1.5–2 wk | Beta users onboard |

Gate between 2→4: if *you* don't want to read your own feed every morning, fix content quality before writing any Flutter.

---

## 12. Cost Summary (launch)

| Item | Cost |
|---|---|
| Gemini free tier — story processing (~100 stories/day) | ₹0 |
| Gemini free tier — Q&A (cached, abuse-guarded) | ₹0 |
| Web search API for Q&A Tier 2 (Tavily/Brave free tier) | ₹0 |
| Supabase, GitHub Actions, Streamlit, PostHog, FCM, Yahoo | ₹0 |
| Google Play developer account | ₹2,600 one-time |
| **Total running** | **₹0/mo** — the ₹2,000/mo budget is held in reserve for the paid-model switch if free limits ever pinch (~₹300–500/mo) or Supabase Pro at scale |

---

## 13. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| AI fabrication in Q&A | Source-locked prompting (whitelist only), mandatory citations, refusal path, unanswerable-question evals |
| False alert on bad story | Machine gate: multi-source or primary-source only; kill switch |
| Yahoo Finance unofficial API breaks | Isolated price module; graceful degradation; paid-API swap path documented |
| Gemini free-tier limits shrink or vanish | Swappable AI interface; budget reserve covers paid Gemini/OpenAI (~₹300–500/mo) same-day |
| GitHub Actions cron lag vs "speed" promise | Accepted at MVP (minutes, not hours); Phase 2 always-on worker is the fix; primary-source path is already fastest |
| Copyright complaints | Original wording only, attribution + link-back, drop source on request |
| SEBI/regulatory | No advice language (prompt-enforced + evals), visible disclaimers |
| Scope creep (charts, brokers, portfolios…) | §2 non-goals list; roadmap gates features behind validated Time-to-Understanding |
| Solo-founder burnout | Auto-approve + machine-gated alerts keep the app alive unattended; every milestone ships something usable |

---

## 14. Locked Stack (₹0 running cost)

Every entry below is free-tier forever at MVP volume. Anything not listed here is **not** in the stack — adding one requires a written trigger (§14.3).

### 14.1 The list

| Layer | Choice | Free-tier reality | Why this one |
|---|---|---|---|
| Language (pipeline) | Python 3.11 | — | Feed parsing + AI SDKs are Python-native |
| Scheduler / CI / secrets | GitHub Actions cron | 2,000 min/mo private | Runner + scheduler + secret store + failure email in one file; no server to pay for |
| Feed fetch | `feedparser` + `httpx` | — | Tolerates malformed RSS; httpx gives per-request timeouts so one dead feed can't stall a run |
| Dedupe / cluster | `rapidfuzz` | — | C-speed title clustering on ~100 rows; no model, no index, no GPU |
| Article extraction | `trafilatura` | — | One call, best-in-class boilerplate removal; runs only on thin RSS items |
| Validation | `pydantic` v2 | — | The JSON contract *is* the anti-hallucination gate (§5) |
| Story AI | Gemini 2.5 Flash-Lite, structured output | ~1,000 req/day | One call → summary + impact + entities + category, coherent; chained models cost GPU and agree less |
| Q&A AI | Gemini Flash → **Groq Llama 3.3 70B** on quota error | ~1,000/day each | ~2,000 Q&A/day at ₹0; Groq is also faster, so failover is invisible |
| Q&A web tier 2 | **Tavily** | 1,000 credits/mo | Returns extracted content — skips a scrape+clean pass Brave would force |
| Database / Auth / Storage / Realtime / API | **Supabase** | 500 MB DB, 1 GB storage, 50k MAU | One free service replaces six; this collapse is the reason running cost is ₹0 |
| Search | Postgres FTS (`tsvector` + GIN) | included | Indexes 7 days of your own stories — fits in page cache; a search cluster would index less data for money |
| Queue | `stories.status` column | included | 100 stories/day needs neither replay nor partitioning |
| Q&A runtime | Supabase Edge Function (Deno) | 500k invocations/mo | Only runtime AI path; no container, no cold-start bill |
| Share preview page | Supabase Edge Function returning HTML + OG tags | same quota | Per-story OG tags rule out a static site; reuses the existing DB client |
| Admin panel | Streamlit on Community Cloud | free public app | Review queue for one user; a real frontend is days of work for an audience of 1 |
| Push | FCM | unlimited | Only path to Android push; payload carries story id for the deep link |
| Deep links | **Android App Links** (`assetlinks.json` + intent filter) | free | Firebase Dynamic Links shut down Aug 2025 — App Links are a manifest entry with nothing to deprecate |
| App | Flutter + Riverpod + `supabase_flutter` | — | One codebase; `AsyncValue` maps 1:1 to card loading/error states |
| Feed UI | `PageView.builder` | — | Full-screen snap scrolling is its default behavior |
| Images | `cached_network_image` | — | Disk cache + placeholder; critical on Indian mobile data |
| Voice (L1) | `flutter_tts` | free | On-device synthesis — no audio generation, hosting, or latency |
| Routing | `go_router` | — | Alert/share deep links are routes |
| Share image | `screenshot` + `share_plus` | — | Renders the existing card widget to PNG (~15 lines) |
| Prices | Yahoo Finance (delayed) | free | Isolated module; degrades gracefully (§10) |
| Product analytics | PostHog | 1M events/mo | Time-to-Understanding is a custom event, not a GA4 metric |
| Crash / error | Sentry | 5k errors/mo | Flutter + Edge Function + pipeline errors in one project |
| Tests | `pytest` + `flutter_test` | — | Golden-set eval is the only guard against silent quality drift |

Only non-zero line item in the whole product: **₹2,600 one-time** Play Store developer account.

### 14.2 Optimization levers — all free, all high-leverage

**Pipeline (protects AI quota = protects the ₹0)**
- Supabase project region **ap-south-1 (Mumbai)** — lowest RTT for every Indian user; a dropdown at project creation, unfixable later without a migration.
- `url_hash` unique index checked **before** any AI call — an exact duplicate must never cost a request.
- `cluster_id` near-dupes stored as `status='duplicate'`, never AI-processed (§6).
- `severity_level` as a generated column — derived by Postgres, never recomputed in app or pipeline.
- `qa_cache` 15-min TTL — a cache hit costs 0 ms and 0 quota during exactly the traffic spike that would exhaust the day.

**Database**
- Indexes that matter: `stories(status, published_at desc)` for the feed, GIN on the stored `tsvector` for search/Q&A tier 1, `story_companies(company_id)` for the stock page.
- Stored generated `tsvector` column, not `to_tsvector()` at query time — the index does the work once at write.
- Prune `events` > 90 d and archive `stories` > 6 mo (§6) — keeps the free 500 MB from becoming a paid tier.

**App (budget Android is the target device)**
- Select only the columns a screen renders — bytes over 3G are the real latency, not query time.
- `memCacheWidth` on `cached_network_image` sized to the card — decoding a 2000px image into a 400px slot is the #1 OOM cause on low-RAM devices.
- `RepaintBoundary` around the glass card; **max two live blur surfaces per screen**; aurora backgrounds as pre-rendered static gradients (§8) — blur is the single most expensive thing in this design.
- `const` constructors throughout the card tree so PageView swipes don't rebuild static chrome.
- Build with `--split-per-abi` and R8 shrinking — smaller APK converts better on budget devices and cheap data.
- Bundle only the font weights actually used.

### 14.3 Trigger to add anything else

Write the trigger before adding the tool. Current standing triggers: Redis when Supabase p95 is measurably the bottleneck · a queue when one cron run can't finish inside its interval · a search service past ~1M stories · a paid model when free quota is chronically exhausted (budget reserve, §12) · Supabase Pro when the 500 MB or 50k MAU line is actually crossed.
