# FinSwipe Milestone 1: News Pipeline Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Python pipeline that polls verified RSS feeds + Google News RSS queries, dedupes/clusters stories, generates structured news cards with Gemini (free tier), and stores them as `pending` rows in Supabase — running automatically on GitHub Actions cron.

**Architecture:** Stateless batch script (idempotent — safe to re-run anytime). Flow per run: load active sources from DB → fetch/parse feeds → drop already-seen URLs (hash check) → cluster near-duplicate titles → enrich thin items with article text → one Gemini structured-output call per new story → validate → insert `pending`. No servers; GitHub Actions is the scheduler.

**Tech Stack:** Python 3.11+, feedparser, httpx, pydantic v2, rapidfuzz, trafilatura, google-genai, supabase (Python client), pytest. Spec: `docs/superpowers/specs/2026-07-25-finswipe-blueprint-design.md`.

## Global Constraints

- Free tiers only: Gemini free tier (model `gemini-2.5-flash-lite`), Supabase free tier, GitHub Actions free minutes.
- All AI calls go through `ai.py` only — model name comes from config (`GEMINI_MODEL`), so a paid-model switch is a config change (spec §5).
- Throttle AI calls: minimum 5 seconds between calls (free-tier RPM safety).
- AI prompts must never produce buy/sell advice language (spec §4 legal guardrails); the prompt in Task 8 is exact — do not soften it.
- Stories are inserted with `status='pending'` — nothing is auto-approved in M1 (that's M2's admin panel).
- Near-duplicates are stored as rows with the same `cluster_id` and `status='duplicate'` (never AI-processed; saves quota).
- Company symbols must validate against the seeded `companies` table; unmatched symbols become `null` (name kept) — no hallucinated tickers (spec §5).
- `is_india_relevant=false` stories are dropped unless `category='Geopolitics'` and `impact.score >= 6` (spec §5).
- Windows dev machine: commands below use PowerShell-compatible forms; CI uses ubuntu-latest.
- Every commit message: conventional style (`feat:`, `test:`, `chore:`).

## Repository layout after M1

```
finhub/
├── docs/superpowers/...            (existing)
├── pipeline/
│   ├── requirements.txt
│   ├── pytest.ini
│   ├── .env.example
│   ├── migrations/001_initial.sql
│   ├── seed/sources_seed.sql
│   ├── src/finswipe/
│   │   ├── __init__.py
│   │   ├── config.py               env loading + constants
│   │   ├── models.py               pydantic models (FeedItem, StoryCard, …)
│   │   ├── fetchers.py             RSS + Google News fetching/parsing
│   │   ├── dedupe.py               url hashing + title clustering
│   │   ├── extract.py              article-text enrichment (trafilatura)
│   │   ├── db.py                   Supabase access (thin wrapper)
│   │   ├── ai.py                   Gemini card generation (the ONLY AI module)
│   │   └── run.py                  orchestration entry point
│   └── tests/
│       ├── fixtures/sample_rss.xml
│       ├── fixtures/sample_gnews.xml
│       ├── test_models.py
│       ├── test_fetchers.py
│       ├── test_dedupe.py
│       ├── test_extract.py
│       └── test_ai.py
└── .github/workflows/pipeline.yml
```

---

### Task 0: Human setup (accounts, database, secrets) — requires the founder, not a subagent

**Files:**
- Create: `pipeline/migrations/001_initial.sql`
- Create: `pipeline/seed/sources_seed.sql`
- Create: `pipeline/.env.example`

**Interfaces:**
- Produces: a live Supabase project with tables `sources`, `stories`, `companies`, `story_companies`; env vars `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `GEMINI_API_KEY` available locally in `pipeline/.env` and later as GitHub secrets.

- [ ] **Step 1: Create accounts (manual, in browser)**

1. https://supabase.com → New project (free tier), region `ap-south-1 (Mumbai)` if offered. Note the **Project URL** and the **service_role key** (Settings → API).
2. https://aistudio.google.com → Get API key (free tier). Note the key.

- [ ] **Step 2: Write the migration SQL file**

Create `pipeline/migrations/001_initial.sql`:

```sql
create table sources (
  id            bigint generated always as identity primary key,
  name          text not null,
  type          text not null check (type in ('rss','google_news_query','nse','bse','sebi','rbi')),
  feed_url      text not null,          -- for google_news_query this is the query string
  is_active     boolean not null default true,
  last_fetched_at timestamptz
);

create table companies (
  id          bigint generated always as identity primary key,
  name        text not null,
  nse_symbol  text unique,
  bse_code    text,
  sector      text,
  logo_url    text,
  aliases     text[] default '{}'
);

create table stories (
  id               bigint generated always as identity primary key,
  url              text not null,
  url_hash         text not null unique,
  cluster_id       uuid not null,
  headline         text not null,
  summary          text,
  impact_direction text check (impact_direction in ('positive','negative','mixed','neutral')),
  impact_strength  int  check (impact_strength between 1 and 3),
  impact_horizon   text check (impact_horizon in ('short_term','long_term','both')),
  impact_score     int  check (impact_score between 1 and 10),
  confidence       text check (confidence in ('high','medium','low')),
  source_name      text not null,
  source_url       text not null,
  image_url        text,
  published_at     timestamptz,
  category         text check (category in ('Markets','Economy','IPO','Global','Commodities','Corporate','Policy','Geopolitics')),
  sectors          text[] default '{}',
  status           text not null default 'pending'
                   check (status in ('pending','approved','rejected','flagged','duplicate')),
  is_featured      boolean not null default false,
  alerted_at       timestamptz,
  raw_ai_error     text,                -- populated when status='flagged'
  created_at       timestamptz not null default now()
);
create index stories_status_idx     on stories (status, published_at desc);
create index stories_cluster_idx    on stories (cluster_id);
create index stories_created_idx    on stories (created_at desc);
create index stories_category_idx   on stories (category, status, published_at desc);

create table story_companies (
  story_id   bigint references stories(id) on delete cascade,
  company_id bigint references companies(id) on delete cascade,
  primary key (story_id, company_id)
);
```

- [ ] **Step 3: Write the sources seed file (the verified roster from spec §4)**

Create `pipeline/seed/sources_seed.sql`:

```sql
insert into sources (name, type, feed_url) values
('ET Markets',        'rss', 'https://economictimes.indiatimes.com/markets/rssfeeds/1977021501.cms'),
('ET Top Stories',    'rss', 'https://economictimes.indiatimes.com/rssfeedstopstories.cms'),
('LiveMint Markets',  'rss', 'https://www.livemint.com/rss/markets'),
('SEBI',              'rss', 'https://www.sebi.gov.in/sebirss.xml'),
('RBI Press',         'rss', 'https://www.rbi.org.in/pressreleases_rss.xml'),
('Yahoo Finance',     'rss', 'https://finance.yahoo.com/news/rssindex'),
('MarketWatch',       'rss', 'https://feeds.content.dowjones.io/public/rss/mw_topstories'),
('CNBC World',        'rss', 'https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100003114'),
('BBC Business',      'rss', 'https://feeds.bbci.co.uk/news/business/rss.xml'),
('Investing.com',     'rss', 'https://www.investing.com/rss/news.rss'),
('ET Economy',        'rss', 'https://economictimes.indiatimes.com/news/economy/rssfeeds/1373380680.cms'),
('ET IPO',            'rss', 'https://economictimes.indiatimes.com/markets/ipos/fpos/rssfeeds/14655708.cms'),
('TOI Business',      'rss', 'https://timesofindia.indiatimes.com/rssfeeds/1898055.cms'),
('Business Today',    'rss', 'https://www.businesstoday.in/rssfeeds/?id=home'),
('Inc42',             'rss', 'https://inc42.com/feed/'),
('Zerodha Z-Connect', 'rss', 'https://zerodha.com/z-connect/feed'),
('WSJ Markets',       'rss', 'https://feeds.content.dowjones.io/public/rss/RSSMarketsMain'),
('Guardian Business', 'rss', 'https://www.theguardian.com/uk/business/rss'),
('OilPrice',          'rss', 'https://oilprice.com/rss/main'),
('GNews Moneycontrol','google_news_query', 'site:moneycontrol.com'),
('GNews Breaking-IN', 'google_news_query', 'nifty OR sensex OR RBI OR SEBI when:1h'),
('GNews IPO',         'google_news_query', 'ipo india when:6h'),
('GNews Brokerages',  'google_news_query', '"Nuvama" OR "Motilal Oswal" OR "Jefferies India" when:6h'),
('GNews Geopolitics', 'google_news_query', 'geopolitics oil sanctions tariff india market when:6h');
```

- [ ] **Step 4: Apply SQL in Supabase (manual)**

Supabase dashboard → SQL Editor → paste `001_initial.sql` → Run. Then paste `sources_seed.sql` → Run.
Verify: Table Editor shows 4 tables; `sources` has 24 rows.

- [ ] **Step 5: Create `pipeline/.env.example` and your local `.env`**

`pipeline/.env.example`:
```
SUPABASE_URL=https://YOURPROJECT.supabase.co
SUPABASE_SERVICE_KEY=eyJ...service_role_key...
GEMINI_API_KEY=AIza...
GEMINI_MODEL=gemini-2.5-flash-lite
```

Copy it to `pipeline/.env` and fill real values. **Never commit `.env`** — Step 6 guards this.

- [ ] **Step 6: Add .gitignore and commit**

Create/append repo-root `.gitignore`:
```
.env
__pycache__/
*.pyc
.venv/
.pytest_cache/
```

```powershell
git add .gitignore pipeline/migrations/001_initial.sql pipeline/seed/sources_seed.sql pipeline/.env.example
git commit -m "chore: M1 database schema, source seed, env template"
```

---

### Task 1: Project scaffold + config

**Files:**
- Create: `pipeline/requirements.txt`, `pipeline/pytest.ini`, `pipeline/src/finswipe/__init__.py`, `pipeline/src/finswipe/config.py`
- Test: `pipeline/tests/test_config.py` (trivial import test folded in here)

**Interfaces:**
- Produces: `config.settings` object with attributes `supabase_url: str`, `supabase_service_key: str`, `gemini_api_key: str`, `gemini_model: str`, `ai_min_interval_seconds: float = 5.0`, `fetch_timeout: int = 20`, `user_agent: str`. Later tasks import `from finswipe.config import settings`.

- [ ] **Step 1: Write requirements and pytest config**

`pipeline/requirements.txt`:
```
feedparser==6.0.11
httpx==0.27.0
pydantic==2.8.2
pydantic-settings==2.4.0
rapidfuzz==3.9.6
trafilatura==1.12.2
google-genai==1.16.1
supabase==2.7.4
python-dotenv==1.0.1
pytest==8.3.2
```

`pipeline/pytest.ini`:
```ini
[pytest]
pythonpath = src
testpaths = tests
```

- [ ] **Step 2: Create venv and install (PowerShell, from `pipeline/`)**

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```
Expected: all packages install without error.

- [ ] **Step 3: Write the failing test**

`pipeline/tests/test_config.py`:
```python
def test_settings_load(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_KEY", "k")
    monkeypatch.setenv("GEMINI_API_KEY", "g")
    from finswipe.config import Settings
    s = Settings()
    assert s.supabase_url == "https://x.supabase.co"
    assert s.gemini_model == "gemini-2.5-flash-lite"
    assert s.ai_min_interval_seconds == 5.0
```

- [ ] **Step 4: Run test to verify it fails**

Run: `pytest tests/test_config.py -v`
Expected: FAIL (ModuleNotFoundError: finswipe)

- [ ] **Step 5: Implement**

`pipeline/src/finswipe/__init__.py`: empty file.

`pipeline/src/finswipe/config.py`:
```python
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    supabase_url: str
    supabase_service_key: str
    gemini_api_key: str
    gemini_model: str = "gemini-2.5-flash-lite"
    ai_min_interval_seconds: float = 5.0
    fetch_timeout: int = 20
    user_agent: str = (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) FinSwipeBot/0.1 (+news aggregator; contact via repo)"
    )


settings = Settings()
```

- [ ] **Step 6: Run test to verify it passes**

Run: `pytest tests/test_config.py -v`
Expected: PASS

- [ ] **Step 7: Commit**

```powershell
git add pipeline/requirements.txt pipeline/pytest.ini pipeline/src pipeline/tests/test_config.py
git commit -m "feat: pipeline scaffold and settings"
```

---

### Task 2: Pydantic models

**Files:**
- Create: `pipeline/src/finswipe/models.py`
- Test: `pipeline/tests/test_models.py`

**Interfaces:**
- Produces (all later tasks depend on these exact names):
  - `FeedItem(source_id: int, source_name: str, title: str, url: str, summary: str = "", image_url: str | None = None, published_at: datetime | None = None)`
  - `CompanyRef(name: str, nse_symbol: str | None)`
  - `Impact(direction: Literal['positive','negative','mixed','neutral'], strength: int (1-3), horizon: Literal['short_term','long_term','both'], score: int (1-10))`
  - `StoryCard(headline_rewrite: str, summary: str, impact: Impact, companies: list[CompanyRef], sectors: list[str], category: Literal['Markets','Economy','IPO','Global','Commodities','Corporate','Policy','Geopolitics'], is_india_relevant: bool, confidence: Literal['high','medium','low'])`

- [ ] **Step 1: Write the failing tests**

`pipeline/tests/test_models.py`:
```python
import pytest
from pydantic import ValidationError
from finswipe.models import StoryCard, Impact, CompanyRef, FeedItem


def valid_card_dict():
    return {
        "headline_rewrite": "RBI holds repo rate at 6.5%",
        "summary": "What happened... why... who is affected... why you should care.",
        "impact": {"direction": "neutral", "strength": 2, "horizon": "short_term", "score": 6},
        "companies": [{"name": "HDFC Bank", "nse_symbol": "HDFCBANK"}],
        "sectors": ["Banking"],
        "category": "Economy",
        "is_india_relevant": True,
        "confidence": "high",
    }


def test_valid_card_parses():
    card = StoryCard.model_validate(valid_card_dict())
    assert card.impact.score == 6
    assert card.companies[0].nse_symbol == "HDFCBANK"


def test_bad_category_rejected():
    d = valid_card_dict()
    d["category"] = "Sports"
    with pytest.raises(ValidationError):
        StoryCard.model_validate(d)


def test_score_out_of_range_rejected():
    d = valid_card_dict()
    d["impact"]["score"] = 11
    with pytest.raises(ValidationError):
        StoryCard.model_validate(d)


def test_feed_item_defaults():
    item = FeedItem(source_id=1, source_name="ET", title="T", url="https://x.com/a")
    assert item.summary == "" and item.published_at is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/test_models.py -v` — Expected: FAIL (no module `finswipe.models`)

- [ ] **Step 3: Implement**

`pipeline/src/finswipe/models.py`:
```python
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class FeedItem(BaseModel):
    source_id: int
    source_name: str
    title: str
    url: str
    summary: str = ""
    image_url: str | None = None
    published_at: datetime | None = None


class CompanyRef(BaseModel):
    name: str
    nse_symbol: str | None = None


class Impact(BaseModel):
    direction: Literal["positive", "negative", "mixed", "neutral"]
    strength: int = Field(ge=1, le=3)
    horizon: Literal["short_term", "long_term", "both"]
    score: int = Field(ge=1, le=10)


class StoryCard(BaseModel):
    headline_rewrite: str
    summary: str
    impact: Impact
    companies: list[CompanyRef] = []
    sectors: list[str] = []
    category: Literal[
        "Markets", "Economy", "IPO", "Global", "Commodities", "Corporate", "Policy", "Geopolitics"
    ]
    is_india_relevant: bool
    confidence: Literal["high", "medium", "low"]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_models.py -v` — Expected: 4 PASS

- [ ] **Step 5: Commit**

```powershell
git add pipeline/src/finswipe/models.py pipeline/tests/test_models.py
git commit -m "feat: pydantic models for feed items and AI story cards"
```

---

### Task 3: Feed fetching & parsing

**Files:**
- Create: `pipeline/src/finswipe/fetchers.py`, `pipeline/tests/fixtures/sample_rss.xml`, `pipeline/tests/fixtures/sample_gnews.xml`
- Test: `pipeline/tests/test_fetchers.py`

**Interfaces:**
- Consumes: `FeedItem` from Task 2, `settings` from Task 1.
- Produces:
  - `build_google_news_url(query: str) -> str`
  - `parse_feed(xml_bytes: bytes, source_id: int, source_name: str, is_google_news: bool) -> list[FeedItem]`
  - `fetch_source(source: dict) -> list[FeedItem]` where `source` is a `sources` table row dict (`{'id','name','type','feed_url',...}`); returns `[]` on any fetch error (logged, never raises).

- [ ] **Step 1: Create fixtures**

`pipeline/tests/fixtures/sample_rss.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>ET Markets</title>
<item>
  <title>Sensex jumps 500 points on IT rally</title>
  <link>https://economictimes.indiatimes.com/markets/story-1.cms</link>
  <description>Indian equities rose sharply led by IT stocks after strong US cues.</description>
  <pubDate>Sat, 25 Jul 2026 10:00:00 +0530</pubDate>
</item>
<item>
  <title>RBI keeps rates unchanged</title>
  <link>https://economictimes.indiatimes.com/markets/story-2.cms</link>
  <description>The central bank held the repo rate at 6.5 percent.</description>
  <pubDate>Sat, 25 Jul 2026 11:00:00 +0530</pubDate>
</item>
</channel></rss>
```

`pipeline/tests/fixtures/sample_gnews.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>"nifty" - Google News</title>
<item>
  <title>Nifty ends above 26,000 for first time - Moneycontrol</title>
  <link>https://news.google.com/rss/articles/CBMiABC123?oc=5</link>
  <pubDate>Sat, 25 Jul 2026 12:00:00 GMT</pubDate>
  <source url="https://www.moneycontrol.com">Moneycontrol</source>
</item>
</channel></rss>
```

- [ ] **Step 2: Write the failing tests**

`pipeline/tests/test_fetchers.py`:
```python
from pathlib import Path

from finswipe.fetchers import build_google_news_url, parse_feed

FIX = Path(__file__).parent / "fixtures"


def test_build_google_news_url_encodes_query():
    url = build_google_news_url("nifty OR sensex when:1h")
    assert url.startswith("https://news.google.com/rss/search?q=")
    assert "nifty%20OR%20sensex%20when%3A1h" in url
    assert "gl=IN" in url


def test_parse_regular_rss():
    items = parse_feed((FIX / "sample_rss.xml").read_bytes(), source_id=1,
                       source_name="ET Markets", is_google_news=False)
    assert len(items) == 2
    assert items[0].title == "Sensex jumps 500 points on IT rally"
    assert items[0].url == "https://economictimes.indiatimes.com/markets/story-1.cms"
    assert items[0].published_at is not None
    assert "IT stocks" in items[0].summary


def test_parse_google_news_cleans_title_and_source():
    items = parse_feed((FIX / "sample_gnews.xml").read_bytes(), source_id=11,
                       source_name="GNews", is_google_news=True)
    assert len(items) == 1
    # Trailing " - Outlet" stripped from title; outlet promoted to source_name
    assert items[0].title == "Nifty ends above 26,000 for first time"
    assert items[0].source_name == "Moneycontrol"
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `pytest tests/test_fetchers.py -v` — Expected: FAIL (no module `finswipe.fetchers`)

- [ ] **Step 4: Implement**

`pipeline/src/finswipe/fetchers.py`:
```python
import logging
import time
import urllib.parse
from datetime import datetime, timezone

import feedparser
import httpx

from finswipe.config import settings
from finswipe.models import FeedItem

log = logging.getLogger(__name__)


def build_google_news_url(query: str) -> str:
    q = urllib.parse.quote(query)
    return f"https://news.google.com/rss/search?q={q}&hl=en-IN&gl=IN&ceid=IN:en"


def _entry_published(entry) -> datetime | None:
    parsed = entry.get("published_parsed") or entry.get("updated_parsed")
    if not parsed:
        return None
    return datetime.fromtimestamp(time.mktime(parsed), tz=timezone.utc)


def _entry_image(entry) -> str | None:
    for m in entry.get("media_content", []) or []:
        if m.get("url"):
            return m["url"]
    for l in entry.get("links", []) or []:
        if l.get("type", "").startswith("image/") and l.get("href"):
            return l["href"]
    return None


def parse_feed(xml_bytes: bytes, source_id: int, source_name: str,
               is_google_news: bool) -> list[FeedItem]:
    parsed = feedparser.parse(xml_bytes)
    items: list[FeedItem] = []
    for e in parsed.entries:
        title = (e.get("title") or "").strip()
        url = (e.get("link") or "").strip()
        if not title or not url:
            continue
        name = source_name
        if is_google_news:
            # Google News titles end with " - Outlet"; the <source> tag holds the outlet.
            outlet = (e.get("source", {}) or {}).get("title", "")
            if outlet and title.endswith(f" - {outlet}"):
                title = title[: -(len(outlet) + 3)].strip()
            elif " - " in title:
                title, _, tail = title.rpartition(" - ")
                outlet = outlet or tail
            name = outlet or source_name
        items.append(FeedItem(
            source_id=source_id,
            source_name=name,
            title=title,
            url=url,
            summary=(e.get("summary") or e.get("description") or "").strip(),
            image_url=_entry_image(e),
            published_at=_entry_published(e),
        ))
    return items


def fetch_source(source: dict) -> list[FeedItem]:
    is_gnews = source["type"] == "google_news_query"
    url = build_google_news_url(source["feed_url"]) if is_gnews else source["feed_url"]
    try:
        resp = httpx.get(url, headers={"User-Agent": settings.user_agent},
                         timeout=settings.fetch_timeout, follow_redirects=True)
        resp.raise_for_status()
    except Exception as exc:  # any network/HTTP failure: log, skip source
        log.warning("fetch failed for %s: %s", source["name"], exc)
        return []
    return parse_feed(resp.content, source["id"], source["name"], is_gnews)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pytest tests/test_fetchers.py -v` — Expected: 3 PASS

- [ ] **Step 6: Commit**

```powershell
git add pipeline/src/finswipe/fetchers.py pipeline/tests/test_fetchers.py pipeline/tests/fixtures
git commit -m "feat: RSS and Google News feed fetching and parsing"
```

---

### Task 4: Dedupe & clustering

**Files:**
- Create: `pipeline/src/finswipe/dedupe.py`
- Test: `pipeline/tests/test_dedupe.py`

**Interfaces:**
- Produces:
  - `url_hash(url: str) -> str` — sha256 hex of normalized URL
  - `normalize_title(title: str) -> str`
  - `find_cluster(title: str, recent: list[dict]) -> str | None` — `recent` rows are `{'headline': str, 'cluster_id': str}`; returns the matched `cluster_id` or None. Similarity: rapidfuzz `token_set_ratio >= 80` on normalized titles.

- [ ] **Step 1: Write the failing tests**

`pipeline/tests/test_dedupe.py`:
```python
from finswipe.dedupe import url_hash, normalize_title, find_cluster


def test_url_hash_ignores_tracking_params_and_scheme():
    a = url_hash("https://example.com/story-1?utm_source=x&utm_campaign=y")
    b = url_hash("http://example.com/story-1")
    c = url_hash("https://example.com/story-2")
    assert a == b
    assert a != c


def test_url_hash_keeps_meaningful_params():
    a = url_hash("https://example.com/page?id=100")
    b = url_hash("https://example.com/page?id=200")
    assert a != b


def test_normalize_title():
    assert normalize_title("  RBI Holds RATES!  ") == "rbi holds rates"


def test_find_cluster_matches_same_story_different_wording():
    recent = [{"headline": "RBI keeps repo rate unchanged at 6.5%", "cluster_id": "abc-123"}]
    got = find_cluster("RBI holds repo rate at 6.5%, stance neutral", recent)
    assert got == "abc-123"


def test_find_cluster_no_match_for_different_story():
    recent = [{"headline": "RBI keeps repo rate unchanged at 6.5%", "cluster_id": "abc-123"}]
    assert find_cluster("Tata Motors launches new EV in Pune", recent) is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/test_dedupe.py -v` — Expected: FAIL (no module)

- [ ] **Step 3: Implement**

`pipeline/src/finswipe/dedupe.py`:
```python
import hashlib
import re
import urllib.parse

from rapidfuzz import fuzz

_TRACKING_PARAMS = {"utm_source", "utm_medium", "utm_campaign", "utm_term",
                    "utm_content", "fbclid", "gclid", "ref", "cmp"}
SIMILARITY_THRESHOLD = 80


def url_hash(url: str) -> str:
    p = urllib.parse.urlsplit(url.strip())
    query = [(k, v) for k, v in urllib.parse.parse_qsl(p.query)
             if k.lower() not in _TRACKING_PARAMS]
    normalized = urllib.parse.urlunsplit(
        ("https", p.netloc.lower(), p.path.rstrip("/"),
         urllib.parse.urlencode(sorted(query)), ""))
    return hashlib.sha256(normalized.encode()).hexdigest()


def normalize_title(title: str) -> str:
    t = title.lower().strip()
    t = re.sub(r"[^a-z0-9\s]", "", t)
    return re.sub(r"\s+", " ", t).strip()


def find_cluster(title: str, recent: list[dict]) -> str | None:
    norm = normalize_title(title)
    for row in recent:
        score = fuzz.token_set_ratio(norm, normalize_title(row["headline"]))
        if score >= SIMILARITY_THRESHOLD:
            return row["cluster_id"]
    return None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_dedupe.py -v` — Expected: 5 PASS

- [ ] **Step 5: Commit**

```powershell
git add pipeline/src/finswipe/dedupe.py pipeline/tests/test_dedupe.py
git commit -m "feat: url hashing and title-similarity clustering"
```

---

### Task 5: Article-text enrichment

**Files:**
- Create: `pipeline/src/finswipe/extract.py`
- Test: `pipeline/tests/test_extract.py`

**Interfaces:**
- Consumes: `FeedItem` (Task 2), `settings` (Task 1).
- Produces:
  - `needs_enrichment(item: FeedItem) -> bool` — True when `len(item.summary) < 300` and URL is not a Google News redirect (`news.google.com` links block scraping — skip those).
  - `enrich(item: FeedItem) -> FeedItem` — returns a copy with `summary` replaced by extracted article text (capped at 4000 chars) when extraction succeeds; original item unchanged on any failure. Never raises.

- [ ] **Step 1: Write the failing tests**

`pipeline/tests/test_extract.py`:
```python
from unittest.mock import patch

from finswipe.extract import needs_enrichment, enrich
from finswipe.models import FeedItem


def make_item(summary: str, url: str = "https://example.com/story") -> FeedItem:
    return FeedItem(source_id=1, source_name="ET", title="T", url=url, summary=summary)


def test_needs_enrichment_when_summary_thin():
    assert needs_enrichment(make_item("short")) is True


def test_no_enrichment_when_summary_rich():
    assert needs_enrichment(make_item("x" * 400)) is False


def test_no_enrichment_for_google_news_links():
    item = make_item("short", url="https://news.google.com/rss/articles/abc")
    assert needs_enrichment(item) is False


def test_enrich_replaces_summary_on_success():
    item = make_item("short")
    with patch("finswipe.extract._download_and_extract", return_value="Full article text " * 30):
        out = enrich(item)
    assert len(out.summary) > 300
    assert out.title == item.title


def test_enrich_keeps_original_on_failure():
    item = make_item("short")
    with patch("finswipe.extract._download_and_extract", return_value=None):
        out = enrich(item)
    assert out.summary == "short"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/test_extract.py -v` — Expected: FAIL (no module)

- [ ] **Step 3: Implement**

`pipeline/src/finswipe/extract.py`:
```python
import logging

import httpx
import trafilatura

from finswipe.config import settings
from finswipe.models import FeedItem

log = logging.getLogger(__name__)
MIN_RICH_SUMMARY = 300
MAX_TEXT_CHARS = 4000


def needs_enrichment(item: FeedItem) -> bool:
    if "news.google.com" in item.url:
        return False
    return len(item.summary) < MIN_RICH_SUMMARY


def _download_and_extract(url: str) -> str | None:
    try:
        resp = httpx.get(url, headers={"User-Agent": settings.user_agent},
                         timeout=settings.fetch_timeout, follow_redirects=True)
        resp.raise_for_status()
        return trafilatura.extract(resp.text, include_comments=False)
    except Exception as exc:
        log.info("article extraction failed for %s: %s", url, exc)
        return None


def enrich(item: FeedItem) -> FeedItem:
    text = _download_and_extract(item.url)
    if text and len(text) > len(item.summary):
        return item.model_copy(update={"summary": text[:MAX_TEXT_CHARS]})
    return item
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_extract.py -v` — Expected: 5 PASS

- [ ] **Step 5: Commit**

```powershell
git add pipeline/src/finswipe/extract.py pipeline/tests/test_extract.py
git commit -m "feat: article text enrichment for thin feed summaries"
```

---

### Task 6: Supabase access layer

**Files:**
- Create: `pipeline/src/finswipe/db.py`
- Test: `pipeline/tests/test_db.py`

**Interfaces:**
- Consumes: `settings` (Task 1), `FeedItem`/`StoryCard` (Task 2).
- Produces class `Database` with methods (later tasks call these exact names):
  - `active_sources() -> list[dict]`
  - `recent_hashes(hours: int = 72) -> set[str]`
  - `recent_for_clustering(hours: int = 48) -> list[dict]` — rows `{'headline','cluster_id'}` of non-duplicate stories
  - `valid_symbols() -> set[str]` — all `nse_symbol` values from `companies`
  - `insert_story(row: dict) -> None`
  - `mark_fetched(source_id: int) -> None`
  - `build_story_row(item, card, cluster_id, status) -> dict` — **pure static function**, unit-tested
  - `build_duplicate_row(item, cluster_id) -> dict` — **pure static function**, unit-tested

- [ ] **Step 1: Write the failing tests (pure functions only — network methods are exercised in Task 9's live run)**

`pipeline/tests/test_db.py`:
```python
from finswipe.db import Database
from finswipe.models import FeedItem, StoryCard


def make_item() -> FeedItem:
    return FeedItem(source_id=1, source_name="ET Markets", title="RBI holds rates",
                    url="https://et.com/rbi-holds?utm_source=rss", summary="body text")


def make_card() -> StoryCard:
    return StoryCard.model_validate({
        "headline_rewrite": "RBI holds repo rate at 6.5%",
        "summary": "s", 
        "impact": {"direction": "neutral", "strength": 1, "horizon": "short_term", "score": 5},
        "companies": [], "sectors": ["Banking"], "category": "Economy",
        "is_india_relevant": True, "confidence": "high",
    })


def test_build_story_row_maps_fields():
    row = Database.build_story_row(make_item(), make_card(), cluster_id="c-1", status="pending")
    assert row["headline"] == "RBI holds repo rate at 6.5%"
    assert row["impact_score"] == 5
    assert row["impact_horizon"] == "short_term"
    assert row["status"] == "pending"
    assert row["cluster_id"] == "c-1"
    assert row["source_name"] == "ET Markets"
    assert row["url_hash"]  # present and non-empty
    assert row["sectors"] == ["Banking"]


def test_build_duplicate_row_minimal():
    row = Database.build_duplicate_row(make_item(), cluster_id="c-1")
    assert row["status"] == "duplicate"
    assert row["cluster_id"] == "c-1"
    assert row["headline"] == "RBI holds rates"   # original title, no AI
    assert "impact_score" not in row or row["impact_score"] is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/test_db.py -v` — Expected: FAIL (no module)

- [ ] **Step 3: Implement**

`pipeline/src/finswipe/db.py`:
```python
from datetime import datetime, timedelta, timezone

from supabase import create_client

from finswipe.config import settings
from finswipe.dedupe import url_hash
from finswipe.models import FeedItem, StoryCard


class Database:
    def __init__(self):
        self.client = create_client(settings.supabase_url, settings.supabase_service_key)

    def active_sources(self) -> list[dict]:
        return (self.client.table("sources").select("*")
                .eq("is_active", True).execute().data)

    def recent_hashes(self, hours: int = 72) -> set[str]:
        cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
        rows = (self.client.table("stories").select("url_hash")
                .gte("created_at", cutoff).execute().data)
        return {r["url_hash"] for r in rows}

    def recent_for_clustering(self, hours: int = 48) -> list[dict]:
        cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
        return (self.client.table("stories").select("headline,cluster_id")
                .gte("created_at", cutoff).neq("status", "duplicate")
                .execute().data)

    def valid_symbols(self) -> set[str]:
        rows = self.client.table("companies").select("nse_symbol").execute().data
        return {r["nse_symbol"] for r in rows if r["nse_symbol"]}

    def insert_story(self, row: dict) -> None:
        self.client.table("stories").insert(row).execute()

    def mark_fetched(self, source_id: int) -> None:
        (self.client.table("sources")
         .update({"last_fetched_at": datetime.now(timezone.utc).isoformat()})
         .eq("id", source_id).execute())

    @staticmethod
    def build_story_row(item: FeedItem, card: StoryCard, cluster_id: str, status: str) -> dict:
        return {
            "url": item.url,
            "url_hash": url_hash(item.url),
            "cluster_id": cluster_id,
            "headline": card.headline_rewrite,
            "summary": card.summary,
            "impact_direction": card.impact.direction,
            "impact_strength": card.impact.strength,
            "impact_horizon": card.impact.horizon,
            "impact_score": card.impact.score,
            "confidence": card.confidence,
            "source_name": item.source_name,
            "source_url": item.url,
            "image_url": item.image_url,
            "published_at": item.published_at.isoformat() if item.published_at else None,
            "category": card.category,
            "sectors": card.sectors,
            "status": status,
        }

    @staticmethod
    def build_duplicate_row(item: FeedItem, cluster_id: str) -> dict:
        return {
            "url": item.url,
            "url_hash": url_hash(item.url),
            "cluster_id": cluster_id,
            "headline": item.title,
            "source_name": item.source_name,
            "source_url": item.url,
            "published_at": item.published_at.isoformat() if item.published_at else None,
            "status": "duplicate",
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_db.py -v` — Expected: 2 PASS

- [ ] **Step 5: Commit**

```powershell
git add pipeline/src/finswipe/db.py pipeline/tests/test_db.py
git commit -m "feat: supabase access layer with row builders"
```

---

### Task 7: Seed the companies table (NSE symbol list)

**Files:**
- Create: `pipeline/seed/seed_companies.py`

**Interfaces:**
- Consumes: `Database` (Task 6).
- Produces: `companies` table populated (~2000 NSE equities) so `valid_symbols()` returns a real set. One-off script, run manually.

- [ ] **Step 1: Write the seed script**

`pipeline/seed/seed_companies.py`:
```python
"""One-off: seed companies from NSE's official equity list CSV.
Run from pipeline/:  python seed/seed_companies.py
If the download 403s, download the CSV manually in a browser from
https://archives.nseindia.com/content/equities/EQUITY_L.csv
save as pipeline/seed/EQUITY_L.csv and re-run.
"""
import csv
import io
import sys
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))
from finswipe.db import Database  # noqa: E402

CSV_URL = "https://archives.nseindia.com/content/equities/EQUITY_L.csv"
LOCAL = Path(__file__).parent / "EQUITY_L.csv"


def load_csv_text() -> str:
    if LOCAL.exists():
        return LOCAL.read_text(encoding="utf-8", errors="replace")
    resp = httpx.get(CSV_URL, timeout=30, follow_redirects=True,
                     headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
    resp.raise_for_status()
    return resp.text


def main():
    reader = csv.DictReader(io.StringIO(load_csv_text()))
    rows = []
    for r in reader:
        symbol = (r.get("SYMBOL") or "").strip()
        name = (r.get("NAME OF COMPANY") or "").strip()
        if symbol and name:
            rows.append({"name": name, "nse_symbol": symbol})
    db = Database()
    for i in range(0, len(rows), 500):
        db.client.table("companies").upsert(
            rows[i:i + 500], on_conflict="nse_symbol").execute()
    print(f"seeded {len(rows)} companies")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it**

Run (from `pipeline/`, venv active): `python seed/seed_companies.py`
Expected: `seeded ~2000+ companies` (exact count varies). Verify in Supabase Table Editor.

- [ ] **Step 3: Commit**

```powershell
git add pipeline/seed/seed_companies.py
git commit -m "feat: NSE company symbol seeding script"
```

---

### Task 8: Gemini card generation

**Files:**
- Create: `pipeline/src/finswipe/ai.py`
- Test: `pipeline/tests/test_ai.py`

**Interfaces:**
- Consumes: `settings` (Task 1), `FeedItem`/`StoryCard` (Task 2).
- Produces:
  - `generate_card(item: FeedItem, valid_symbols: set[str]) -> StoryCard` — raises `CardGenerationError(last_error: str)` after 1 retry fails. Applies symbol validation (unknown `nse_symbol` → `None`). Enforces ≥5s spacing between calls (module-level timestamp).
  - `should_publish(card: StoryCard) -> bool` — the India-relevance rule.
  - `class CardGenerationError(Exception)` with attribute `.last_error`.

- [ ] **Step 1: Write the failing tests**

`pipeline/tests/test_ai.py`:
```python
import json
from unittest.mock import MagicMock, patch

import pytest

import finswipe.ai as ai
from finswipe.ai import CardGenerationError, generate_card, should_publish
from finswipe.models import FeedItem, StoryCard


def make_item() -> FeedItem:
    return FeedItem(source_id=1, source_name="ET", title="RBI holds rates",
                    url="https://et.com/x", summary="The RBI held the repo rate...")


def card_json(symbol="HDFCBANK", relevant=True, category="Economy", score=6) -> str:
    return json.dumps({
        "headline_rewrite": "RBI holds repo rate at 6.5%",
        "summary": "s",
        "impact": {"direction": "neutral", "strength": 1, "horizon": "short_term", "score": score},
        "companies": [{"name": "HDFC Bank", "nse_symbol": symbol}],
        "sectors": ["Banking"], "category": category,
        "is_india_relevant": relevant, "confidence": "high",
    })


def fake_response(text: str):
    r = MagicMock()
    r.text = text
    return r


@patch("finswipe.ai._sleep_for_rate_limit", lambda: None)
def test_generate_card_success_and_symbol_validation():
    with patch.object(ai, "_client") as client:
        client.models.generate_content.return_value = fake_response(card_json(symbol="FAKESYM"))
        card = generate_card(make_item(), valid_symbols={"HDFCBANK"})
    assert isinstance(card, StoryCard)
    assert card.companies[0].nse_symbol is None      # invalid symbol nulled
    assert card.companies[0].name == "HDFC Bank"     # name preserved


@patch("finswipe.ai._sleep_for_rate_limit", lambda: None)
def test_generate_card_retries_then_raises():
    with patch.object(ai, "_client") as client:
        client.models.generate_content.return_value = fake_response("not json at all")
        with pytest.raises(CardGenerationError) as exc:
            generate_card(make_item(), valid_symbols=set())
    assert client.models.generate_content.call_count == 2   # first try + 1 retry
    assert exc.value.last_error


@patch("finswipe.ai._sleep_for_rate_limit", lambda: None)
def test_generate_card_retry_recovers():
    with patch.object(ai, "_client") as client:
        client.models.generate_content.side_effect = [
            fake_response("broken"), fake_response(card_json())]
        card = generate_card(make_item(), valid_symbols={"HDFCBANK"})
    assert card.impact.score == 6


def test_should_publish_rules():
    ok = StoryCard.model_validate(json.loads(card_json()))
    assert should_publish(ok) is True
    foreign = StoryCard.model_validate(json.loads(card_json(relevant=False)))
    assert should_publish(foreign) is False
    geo = StoryCard.model_validate(json.loads(
        card_json(relevant=False, category="Geopolitics", score=7)))
    assert should_publish(geo) is True
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/test_ai.py -v` — Expected: FAIL (no module)

- [ ] **Step 3: Implement**

`pipeline/src/finswipe/ai.py`:
```python
import json
import logging
import time

from google import genai

from finswipe.config import settings
from finswipe.models import FeedItem, StoryCard

log = logging.getLogger(__name__)

_client = genai.Client(api_key=settings.gemini_api_key)
_last_call_ts: float = 0.0

PROMPT = """You are the news engine for FinSwipe, an Indian financial news app.
Read the article below and produce ONE JSON object, nothing else.

Rules — follow every one:
- Write in your own original words. Never copy sentences from the article.
- Plain language a market beginner understands; keep precision a trader respects.
- "summary" must cover, in 3-5 short sentences: what happened, why it happened,
  who is affected, and why the reader should care.
- NEVER give buy/sell/hold advice or price targets. Describe impact and what to
  watch — never what to do. This is a legal requirement.
- Only mention companies actually central to the story. Use official NSE symbols
  when you are certain; otherwise set nse_symbol to null.
- If facts are thin or the article is vague, set confidence to "medium" or "low".
- impact.score: 1-3 minor, 4-6 notable, 7-8 major market-moving, 9-10 historic.
- is_india_relevant: true if it affects Indian markets, companies, or economy.

JSON schema (all fields required):
{
  "headline_rewrite": "string",
  "summary": "string",
  "impact": {"direction": "positive|negative|mixed|neutral", "strength": 1-3,
             "horizon": "short_term|long_term|both", "score": 1-10},
  "companies": [{"name": "string", "nse_symbol": "string or null"}],
  "sectors": ["string"],
  "category": "Markets|Economy|IPO|Global|Commodities|Corporate|Policy|Geopolitics",
  "is_india_relevant": true,
  "confidence": "high|medium|low"
}

ARTICLE
Source: {source}
Title: {title}
Text: {text}
"""


class CardGenerationError(Exception):
    def __init__(self, last_error: str):
        super().__init__(last_error)
        self.last_error = last_error


def _sleep_for_rate_limit() -> None:
    global _last_call_ts
    wait = settings.ai_min_interval_seconds - (time.monotonic() - _last_call_ts)
    if wait > 0:
        time.sleep(wait)
    _last_call_ts = time.monotonic()


def _call_model(prompt: str) -> str:
    _sleep_for_rate_limit()
    resp = _client.models.generate_content(
        model=settings.gemini_model,
        contents=prompt,
        config={"response_mime_type": "application/json"},
    )
    return resp.text or ""


def _validate_symbols(card: StoryCard, valid_symbols: set[str]) -> StoryCard:
    for c in card.companies:
        if c.nse_symbol and c.nse_symbol not in valid_symbols:
            c.nse_symbol = None
    return card


def generate_card(item: FeedItem, valid_symbols: set[str]) -> StoryCard:
    prompt = PROMPT.replace("{source}", item.source_name) \
                   .replace("{title}", item.title) \
                   .replace("{text}", item.summary[:4000])
    last_error = ""
    for attempt in range(2):  # first try + 1 retry (spec §5)
        raw = ""
        try:
            raw = _call_model(prompt if attempt == 0
                              else f"{prompt}\n\nYour previous output was invalid: {last_error}\nReturn ONLY valid JSON.")
            card = StoryCard.model_validate(json.loads(raw))
            return _validate_symbols(card, valid_symbols)
        except Exception as exc:
            last_error = f"{exc} | raw: {raw[:200]}"
            log.warning("card generation attempt %d failed: %s", attempt + 1, last_error)
    raise CardGenerationError(last_error)


def should_publish(card: StoryCard) -> bool:
    if card.is_india_relevant:
        return True
    return card.category == "Geopolitics" and card.impact.score >= 6
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_ai.py -v` — Expected: 4 PASS

- [ ] **Step 5: Commit**

```powershell
git add pipeline/src/finswipe/ai.py pipeline/tests/test_ai.py
git commit -m "feat: gemini structured card generation with retry and symbol validation"
```

---

### Task 9: Orchestration + first live run

**Files:**
- Create: `pipeline/src/finswipe/run.py`

**Interfaces:**
- Consumes: everything above, by the exact names defined in Tasks 1-8.
- Produces: `python -m finswipe.run` executes one full pipeline pass and prints a summary line. This is also the module CI invokes.

- [ ] **Step 1: Implement (no unit test — this is glue; its test is the live run below)**

`pipeline/src/finswipe/run.py`:
```python
import logging
import uuid
from concurrent.futures import ThreadPoolExecutor

from finswipe import ai, extract, fetchers
from finswipe.db import Database
from finswipe.dedupe import find_cluster, url_hash

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("finswipe.run")

MAX_AI_STORIES_PER_RUN = 40  # free-tier quota guard per run
FETCH_WORKERS = 8            # source agents fetched in parallel


def main() -> None:
    db = Database()
    seen = db.recent_hashes()
    recent = db.recent_for_clustering()
    symbols = db.valid_symbols()
    stats = {"fetched": 0, "new": 0, "dupes": 0, "published": 0,
             "dropped": 0, "flagged": 0}

    # Level 1: source agents — one worker per outlet, in parallel.
    sources = db.active_sources()
    items = []
    with ThreadPoolExecutor(max_workers=FETCH_WORKERS) as pool:
        for source, got in zip(sources, pool.map(fetchers.fetch_source, sources)):
            db.mark_fetched(source["id"])
            stats["fetched"] += len(got)
            items.extend(got)

    ai_budget = MAX_AI_STORIES_PER_RUN
    for item in items:
        h = url_hash(item.url)
        if h in seen:
            continue
        seen.add(h)
        stats["new"] += 1

        cluster = find_cluster(item.title, recent)
        if cluster:
            db.insert_story(Database.build_duplicate_row(item, cluster))
            stats["dupes"] += 1
            continue

        cluster = str(uuid.uuid4())
        recent.append({"headline": item.title, "cluster_id": cluster})

        if ai_budget <= 0:
            log.info("AI budget for this run exhausted; %s left for next run", item.title)
            continue
        ai_budget -= 1

        if extract.needs_enrichment(item):
            item = extract.enrich(item)

        try:
            card = ai.generate_card(item, symbols)
        except ai.CardGenerationError as exc:
            row = Database.build_duplicate_row(item, cluster)
            row.update({"status": "flagged", "raw_ai_error": exc.last_error})
            db.insert_story(row)
            stats["flagged"] += 1
            continue

        if not ai.should_publish(card):
            stats["dropped"] += 1
            continue

        db.insert_story(Database.build_story_row(item, card, cluster, status="pending"))
        stats["published"] += 1

    log.info("run complete: %s", stats)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run the full test suite**

Run (from `pipeline/`): `pytest -v`
Expected: all tests from Tasks 1-8 PASS.

- [ ] **Step 3: First live run (requires Task 0 + Task 7 done, `.env` filled)**

Run: `python -m finswipe.run`
Expected: log lines per source, then `run complete: {'fetched': 200+, 'new': ..., 'published': ...}`. Takes several minutes (5s AI spacing × new stories).

- [ ] **Step 4: Verify in Supabase (manual)**

Table Editor → `stories`: rows with `status='pending'`, readable `headline`/`summary`, sensible `impact_score`, `category`. Spot-check 5 stories against their `source_url`. If summaries are garbage, fix the prompt in `ai.py` — do not proceed to Task 10 until you'd read this feed yourself.

- [ ] **Step 5: Verify idempotency**

Run: `python -m finswipe.run` again immediately.
Expected: `new: 0` (or near-zero) — nothing re-processed, no duplicate rows (unique `url_hash` guarantees it).

- [ ] **Step 6: Commit**

```powershell
git add pipeline/src/finswipe/run.py
git commit -m "feat: pipeline orchestration entry point"
```

---

### Task 10: GitHub Actions schedule

**Files:**
- Create: `.github/workflows/pipeline.yml`

**Interfaces:**
- Consumes: `python -m finswipe.run` (Task 9); repo secrets `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `GEMINI_API_KEY`.

- [ ] **Step 1: Write the workflow**

`.github/workflows/pipeline.yml`:
```yaml
name: news-pipeline
on:
  schedule:
    # UTC. Market hours IST 09:00-16:00 = 03:30-10:30 UTC, Mon-Fri: every 15 min.
    - cron: "*/15 3-10 * * 1-5"
    # Off hours: every 2 hours.
    - cron: "0 0-2/2,12-22/2 * * *"
  workflow_dispatch: {}   # manual run button

concurrency:
  group: news-pipeline
  cancel-in-progress: false

jobs:
  run:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    defaults:
      run: { working-directory: pipeline }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: pip install -r requirements.txt
      - run: python -m finswipe.run
        env:
          SUPABASE_URL: ${{ secrets.SUPABASE_URL }}
          SUPABASE_SERVICE_KEY: ${{ secrets.SUPABASE_SERVICE_KEY }}
          GEMINI_API_KEY: ${{ secrets.GEMINI_API_KEY }}
```

- [ ] **Step 2: Add repo secrets (manual, founder)**

GitHub → repo → Settings → Secrets and variables → Actions → New repository secret, for each of: `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `GEMINI_API_KEY`.

- [ ] **Step 3: Commit, push, and trigger manually**

```powershell
git add .github/workflows/pipeline.yml
git commit -m "chore: scheduled pipeline runs on GitHub Actions"
git push
```
Then: GitHub → Actions tab → news-pipeline → "Run workflow". Watch the log; expected same summary line as the local run.

- [ ] **Step 4: Confirm the schedule fires**

Wait for the next quarter-hour inside market hours (or 2-hour slot otherwise); confirm a run appears in the Actions tab without manual trigger. Milestone 1 complete — fresh AI news cards now accumulate in Supabase automatically.

---

## Self-Review Notes

- **Spec coverage:** ingestion (T3), Google News query sources (T0 seed + T3), two-layer dedupe (T4, wired in T9), article enrichment for thin snippets (T5), single-call Gemini card w/ retry + flagging (T8), symbol validation vs seeded table (T7+T8), India-relevance rule (T8 `should_publish`), pending-only inserts (T9), idempotency (T9 step 5), 15-min market-hours cron (T10), free-tier throttling (T8 spacing + T9 per-run cap). Primary sources NSE/BSE/SEBI/RBI: SEBI+RBI RSS included now; NSE/BSE JSON APIs are Milestone 3 per spec §11 — intentionally out.
- **Status enum note:** M1 extends spec §6's status enum with `'duplicate'` (cluster members) — reflected in the migration; spec's feed queries (`status='approved'`) are unaffected.
- **Type consistency check:** `FeedItem`/`StoryCard` field names match between models (T2), row builders (T6), AI (T8), and orchestration (T9); `find_cluster` consumes `{'headline','cluster_id'}` which `recent_for_clustering()` selects.
