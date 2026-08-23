"""FinSwipe M1 pipeline: fetch feeds -> normalize -> dedupe -> cluster ->
Gemini card -> insert 'pending' into Supabase. Idempotent: url_hash re-checked
every run, so re-processing is a no-op."""
import contextlib
import hashlib
import html
import io
import os
import pathlib
import re
import socket
import sys
import time
import traceback
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from itertools import zip_longest
from urllib.parse import quote_plus, urlsplit, urlunsplit, parse_qsl, urlencode

import feedparser
import requests

# AI calls per run. Only genuinely new stories cost one — same-story items from
# other outlets are stored as cluster duplicates for free, so this goes much
# further than the old flat story cap it replaces.
MAX_AI_CALLS_PER_RUN = int(os.environ.get("MAX_AI_CALLS_PER_RUN", "120"))
AI_CONCURRENCY = int(os.environ.get("AI_CONCURRENCY", "6"))
AI_PHASE_SECONDS = int(os.environ.get("AI_PHASE_SECONDS", "300"))  # leave room for alerts/approve before the job timeout
# Sized against the measured pool: 4 Gemini keys x 4 models (~8000) + 4 Groq
# keys x 3 models (12000 exact, from x-ratelimit headers). 16000 leaves the
# Gemini estimate a wide error margin and ~4000/day spare for runtime Q&A (M5).
DAILY_AI_BUDGET = int(os.environ.get("DAILY_AI_BUDGET", "16000"))
PENDING_MAX_MINUTES = 10    # owner's rule 2026-08-14: NOTHING relevant waits longer
AUTO_APPROVE_MINUTES = 2    # unreviewed score < 8 goes live after this (owner's
                            # call 2026-08-12: ordinary news visible within ~5
                            # min of announcement; rejecting later still pulls
                            # a card from the feed instantly)
FAST_LANE_SCORE = 8         # >= this publishes on arrival, no approval wait
BREAKING_MINUTES = 15       # younger than this jumps the AI queue entirely
SILENT_SOURCE_DAYS = 3      # fetches fine but publishes nothing -> retire it
REVIVE_AFTER_HOURS = 12     # ... and re-probe every retired source this often
TRUSTED_SOLO_MINUTES = 5    # uncorroborated major story alerts anyway after this
TRUSTED_AUTHORITY = 8       # ET/Mint/WSJ/BBC/Moneycontrol tier; below this never alerts solo
MAX_ALERTS_PER_DAY = 5      # pushes only; publication is never capped (spec §7)
QUIET_START_IST = 22        # no pushes 22:00-07:00 IST ...
QUIET_END_IST = 7
QUIET_PIERCE_SCORE = 9      # ... unless it's this big ("wake me if the market is crashing")
IST = timezone(timedelta(hours=5, minutes=30))
FETCH_TIMEOUT = 20
UA = {"User-Agent": "Mozilla/5.0 (FinSwipe pipeline; +private)"}

# ---------- remote config (admin cockpit) ----------
# Every constant above (and the few defined further down) can be overridden
# from the admin's app_config.pipeline row: `knobs` by name, `switches` to
# pause a stage. The functions read module globals at call time, so rebinding
# the global IS the mechanism — don't refactor these into default arguments.
KNOBS = ("MAX_AI_CALLS_PER_RUN", "AI_CONCURRENCY", "AI_PHASE_SECONDS", "DAILY_AI_BUDGET",
         "PENDING_MAX_MINUTES", "AUTO_APPROVE_MINUTES", "FAST_LANE_SCORE", "BREAKING_MINUTES",
         "SILENT_SOURCE_DAYS", "REVIVE_AFTER_HOURS", "TRUSTED_SOLO_MINUTES", "TRUSTED_AUTHORITY",
         "MAX_ALERTS_PER_DAY", "QUIET_START_IST", "QUIET_END_IST", "QUIET_PIERCE_SCORE",
         "PERSONAL_CAP_PER_DAY", "PERSONAL_MIN_SCORE", "OG_FETCH_CAP", "EVENTS_RETENTION_DAYS",
         "REJECTED_RETENTION_DAYS")
MODEL_ENVS = ("GEMINI_MODELS", "GROQ_MODEL", "OPENROUTER_MODEL")  # ai.py reads env at call time
SWITCHES = ("pipeline", "auto_approve", "alerts", "personal_alerts", "chief_editor", "market")


def load_config():
    """The admin's pipeline row; {} (= code defaults) when unreachable or absent."""
    try:
        rows = sb("GET", "app_config?select=value&key=eq.pipeline")
        return rows[0]["value"] if rows else {}
    except Exception as e:  # table missing pre-migration, network, anything
        print(f"CONFIG READ FAILED ({e}); using defaults")
        return {}


def apply_config(cfg):
    """Apply knob overrides to this module (and ai's env/throttle); return the
    switch map with every switch present, defaulting to on. Unknown keys ignored."""
    for k, v in (cfg.get("knobs") or {}).items():
        key = str(k).upper()
        if key in KNOBS:
            globals()[key] = int(v)
        elif key in MODEL_ENVS:
            os.environ[key] = str(v)
        elif key == "AI_RPM_PER_LANE":
            import ai
            ai.RPM_PER_LANE = int(v)
    switches = cfg.get("switches") or {}
    return {name: bool(switches.get(name, True)) for name in SWITCHES}


def load_env():
    env = pathlib.Path(__file__).parent / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())


# ---------- Supabase (PostgREST) ----------

PAGE = 1000  # PostgREST's silent per-response row cap


def sb(method, path, **kwargs):
    key = os.environ["SUPABASE_SERVICE_KEY"]
    headers = {"apikey": key, "Authorization": f"Bearer {key}",
               "Content-Type": "application/json", **kwargs.pop("headers", {})}

    def call(extra_headers=None):
        r = requests.request(
            method, f"{os.environ['SUPABASE_URL'].rstrip('/')}/rest/v1/{path}",
            headers={**headers, **(extra_headers or {})}, timeout=30, **kwargs)
        if not r.ok:  # PostgREST puts the actual reason in the body, not the status
            raise requests.HTTPError(f"{r.status_code} {path.split('?')[0]}: {r.text[:300]}",
                                     response=r)
        return r.json() if r.text else None

    if method != "GET":
        return call()
    # PostgREST silently truncates every response at 1000 rows. Once 57 sources
    # filled the 48h window past that (3177 rows on 2026-08-10), the dedupe
    # preload was reading only the OLDEST 1000 — so every new story was matched
    # against everything except the recent cards it could actually duplicate,
    # and the same event published as two cards again. Page until a short page;
    # queries with their own limit= return one short page and are unaffected.
    rows, start = [], 0
    while True:
        page = call({"Range": f"{start}-{start + PAGE - 1}"})
        rows += page or []
        if not page or len(page) < PAGE:
            return rows
        start += PAGE


# ---------- normalize / dedupe ----------

TRACKING_PARAMS = re.compile(r"^(utm_|fbclid|gclid|ref$|cmpid)", re.I)


def canonical_url(url):
    s = urlsplit(url.strip())
    query = urlencode([(k, v) for k, v in parse_qsl(s.query) if not TRACKING_PARAMS.match(k)])
    return urlunsplit((s.scheme.lower(), s.netloc.lower(), s.path.rstrip("/"), query, ""))


def url_hash(url):
    return hashlib.sha256(canonical_url(url).encode()).hexdigest()


STOPWORDS = {"the", "a", "an", "of", "to", "in", "on", "for", "and", "as", "at", "by", "is", "its", "with", "after", "amid"}

# Filing and results scaffolding, ignored when deciding "same story?". Every
# announcement carries it, so it drowns out the one token that actually
# identifies the story — the company. "ABFRL: Outcome of Board Meeting" and
# "JSWENERGY: Outcome of Board Meeting" shared 3 of their 4 words and merged;
# 43 unrelated companies ended up in one cluster and 42 were dropped as
# duplicates. Content words never go in here, only template words.
BOILERPLATE = {
    "outcome", "intimation", "disclosure", "disclosures", "submission",
    "compliance", "certificate", "regulation", "regulations", "lodr",
    "listing", "obligations", "requirements", "board", "meeting",
    "announcement", "announcements", "filing", "filings", "update",
    "results", "result", "highlights", "earnings", "call", "transcript",
    "presentation", "quarter", "quarterly", "unaudited", "audited",
    "financial", "financials", "consolidated", "standalone", "statement",
    "statements", "q1", "q2", "q3", "q4", "fy",
    "ltd", "limited", "inc", "corp", "corporation", "plc", "company",
    "press", "release",
    # IPO-process and currency scaffolding: "X raises Rs N crore from anchor
    # investors ahead of IPO" is 8 template words around a 3-word identity, and
    # merged 12 different issuers. Units and process words name no story.
    "rs", "crore", "anchor", "investors", "allotment", "details",
    "watch", "review",
}


def title_tokens(title):
    """Words that identify WHICH story this is. Template words are excluded —
    two filings that differ only by company name must not look alike."""
    return {w for w in re.findall(r"[a-z0-9]+", title.lower())
            if w not in STOPWORDS and w not in BOILERPLATE}


# AI budget is ~500 calls/day/model; spending it on grey-market-premium updates
# is what starved the real news. These are stored 'rejected' (visible in admin),
# never silently dropped, and never sent to the AI.
# Owner's junk definition (2026-08-12): junk = NOT financial. Market listicles
# ("stocks to watch", "top gainers") are real content — the AI reads and
# scores them now. Only repetitive status spam stays pattern-filtered: the
# same GMP/allotment counter reposted forty times a day is a ticker, not news.
# Non-financial junk (Bollywood, lifestyle) is the AI's call, never a keyword
# match — "Zee Entertainment" is a listed company.
LOW_VALUE = re.compile(
    r"grey market premium|\bGMP\b|subscription status|allotment status"
    r"|IPO day \d|day \d+ of (?:bidding|subscription)", re.I)


def age_minutes(item, now=None):
    """Minutes since the outlet published it; unknown dates sort as ancient."""
    ts = item.get("published_at")
    if not ts:
        return float("inf")
    try:
        return ((now or datetime.now(timezone.utc)) - parse_ts(ts)).total_seconds() / 60
    except (ValueError, TypeError):
        return float("inf")


def prioritized(items):
    """Order the AI queue: minutes-old news first, then a fair round-robin.

    Round-robin alone fixed source starvation but still let a 300-item backlog
    sit between a just-published market-mover and the AI. Anything younger than
    BREAKING_MINUTES now jumps the whole queue, newest first, so breaking news
    is in the first batch of the very next poll regardless of backlog depth.
    The rest keeps the interleave: one per source per round, authority first."""
    now = datetime.now(timezone.utc)
    breaking = sorted((i for i in items if age_minutes(i, now) <= BREAKING_MINUTES),
                      key=lambda i: age_minutes(i, now))
    by_source = {}
    for i in items:
        if age_minutes(i, now) > BREAKING_MINUTES:
            by_source.setdefault(i["source"]["name"], []).append(i)
    for queue in by_source.values():
        queue.sort(key=lambda i: i["published_at"] or "", reverse=True)
    rounds = sorted(by_source.values(),
                    key=lambda q: -(q[0]["source"].get("authority") or 5))
    return breaking + [i for tier in zip_longest(*rounds) for i in tier if i is not None]


def assign_cluster(title, recent):
    """recent: list of (cluster_id, token_set), ONE entry per cluster — see
    cluster_of(). Jaccard >= 0.5 joins the cluster.

    ponytail: a corpus-frequency rule (ignore words common across the last 48h)
    was tried here and removed — measured on a week of real headlines it either
    changed nothing or, tuned low enough to bite, cost more true duplicates than
    the false merges it split (59 -> 46 correctly merged pairs). BOILERPLATE
    stays a list because the list demonstrably works and the clever version did
    not. Revisit with embeddings only if volume grows 100x."""
    tokens = title_tokens(title)
    if tokens:
        for cid, other in recent:
            if other and len(tokens & other) / len(tokens | other) >= 0.5:
                return cid
    return str(uuid.uuid4())


SAME_STORY = 0.70  # on AI-written headlines, which share one house style


def merge_target(rewritten, published):
    """The cluster this card belongs to if another outlet already told this
    story, else None. `published` is (cluster_id, tokens) per card already
    written this window.

    The pre-AI check compares the outlets' own wording, and two newsrooms
    rarely word anything the same way — ET's "Goyal says India not backing
    BRICS currency" and Mint's "No common BRICS currency: Piyush Goyal" share
    barely a third of their words and both get processed. The AI then rewrites
    both into one house style, at which point they are word-for-word identical.
    Comparing after the rewrite is comparing meaning, because the model has
    already done the interpreting. Measured on 48h of real cards: at 0.6 the
    matches are genuine (same court stay, same pension approval, same results),
    The bar sits above the 0.5 used on raw headlines, and is set from measured
    pairs rather than taste. Same event scores 0.71-1.00 (one court stay told
    twice, "rally" vs "climb"); different events of the same shape score up to
    0.64 ("Infosys Q1 profit rises 11%" vs "Wipro Q1 profit rises 9%", which
    share every word but the two company names). 0.70 is the gap between them.
    The margin is thin, so it errs high: a missed merge shows a duplicate card,
    a wrong merge deletes a real story."""
    tokens = title_tokens(rewritten)
    if not tokens:
        return None
    for cid, other in published:
        if other and len(tokens & other) / len(tokens | other) >= SAME_STORY:
            return cid
    return None


def cluster_of(headline, recent):
    """Assign `headline` to a cluster, recording a new one in `recent` in place.
    Returns (cluster_id, already_seen).

    `recent` holds one entry per cluster — its seed — and never every member.
    Matching against every member made clusters grow by chain: A joins B, C
    joins A, and the group drifts until its members share nothing. That is how
    43 unrelated board-meeting filings became a single cluster with zero tokens
    in common. Comparing against the seed alone keeps a cluster about the story
    that started it."""
    cid = assign_cluster(headline, recent)
    known = any(cid == c for c, _ in recent)
    if not known:
        recent.append((cid, title_tokens(headline)))
    return cid, known


# ---------- fetch ----------

def feed_url(source):
    if source["type"] == "google_news_query":
        return (f"https://news.google.com/rss/search?q={quote_plus(source['feed_url'])}"
                "&hl=en-IN&gl=IN&ceid=IN:en")
    return source["feed_url"]


def entry_image(entry):
    for m in entry.get("media_content", []) or []:
        if m.get("url"):
            return m["url"]
    for l in entry.get("links", []) or []:
        if l.get("rel") == "enclosure" and str(l.get("type", "")).startswith("image"):
            return l.get("href")
    return None


# Junk by path: logos, icons, bylines, spacers, ad slots. Case-insensitive,
# matched against the whole URL — CDNs hide these words in either path or file.
# Two different boundary rules, because one \b...\b for everything was wrong
# both ways: "author"/"default" need BOTH boundaries (else "regulatory-authority"
# and "wilful-defaulters" false-positive), but the rest only need a boundary
# before the token, else digit-suffixed junk (logo2x.png, avatar1.jpg) survives
# untouched — nothing legitimate ends a word right where "logo"/"icon"/etc. do.
JUNK_IMAGE = re.compile(
    r"\b(?:logo|icon|avatar|sprite|spacer|byline|placeholder|blank)"
    r"|\b(?:author|default)\b|1x1|pixel|/ads?/", re.I)
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


# ---------- per-process caches (egress) ----------
# Measured 2026-08-23: the resident poller re-downloaded ~2 MB of unchanged
# rows on every lap — 48 h of stories, every company, 3 days of source_name,
# ~1,600 already-known url hashes — about 55 GB/month against Supabase's 5 GB
# free egress, and the org was put on notice. Everything here keeps one copy
# per process and asks PostgREST only for what changed since the last lap.

REFRESH_SECONDS = 3600          # companies reload; window reload while 012 is missing
WINDOW_REFRESH_SECONDS = 6 * 3600   # window reload once 012 deltas carry edits too (~once per CI process)
IMAGE_REFRESH_SECONDS = 6 * 3600    # 7 d image counts: history only — this process counts its own inserts live
RECENT_HOURS = 48

_recent_cache = {"at": 0.0, "since": None, "start": None, "rows": {}, "col": "updated_at"}


def recent_stories():
    """The RECENT_HOURS story window every lap clusters against, oldest first.

    Full reload once per WINDOW_REFRESH_SECONDS (REFRESH_SECONDS while the
    delta can't see edits); rows that age out are dropped locally every call;
    between reloads only rows created OR edited since the last call are
    fetched, via `updated_at` (migration 012), so an admin reject or an editor
    merge is visible next lap exactly as it was when the whole window was
    re-read each time. Until 012 is applied PostgREST 400s on the column; then
    we fall back to a `created_at` delta — this process's own inserts still
    arrive next lap, edits wait for the hourly reload.

    `gte` plus an id-keyed dict: rows sharing the boundary second are fetched
    again and replace themselves, never skipped; dict order stays created_at
    ascending because refetched rows keep their slot and new ones append."""
    c = _recent_cache
    now = time.monotonic()
    start = datetime.now(timezone.utc) - timedelta(hours=RECENT_HOURS)
    if now - c["at"] > (WINDOW_REFRESH_SECONDS if c["col"] == "updated_at" else REFRESH_SECONDS):
        c.update(at=now, rows={}, since=None)
    c["start"] = start
    full = c["since"] is None
    while True:
        col = "created_at" if full else c["col"]
        since = iso(start) if full else c["since"]
        sel = "id,cluster_id,headline,status,source_name,created_at" + (",updated_at" if c["col"] == "updated_at" else "")
        try:
            rows = sb("GET", f"stories?select={sel}&{col}=gte.{since}&order=created_at.asc")
            break
        except requests.HTTPError as e:
            if c["col"] == "updated_at" and "updated_at" in str(e):
                print("RECENT WINDOW: migration 012 not applied — created_at delta, edits land hourly")
                c["col"] = "created_at"
                continue
            raise
    for r in rows:
        c["rows"][r["id"]] = r
    if rows:
        c["since"] = iso(max(parse_ts(r[c["col"]]) for r in rows))
    # Trim here, every call: rows age out of the window at the same moment
    # they used to fall off the old created_at>=48h query, and an edited row
    # older than the window never gets in.
    for sid in [i for i, r in c["rows"].items() if parse_ts(r["created_at"]) < start]:
        del c["rows"][sid]
    return list(c["rows"].values())


_known_hashes = set()


def existing_hashes(hashes):
    """Which of `hashes` already have a story row. A row is never deleted, so a
    hash once seen here (or inserted by insert_story) is remembered for the
    life of the process: the same ~1,600 feed items come back every lap and
    used to be echoed back from the database each time (~130 KB/lap)."""
    ask = [h for h in dict.fromkeys(hashes) if h not in _known_hashes]
    for i in range(0, len(ask), 100):
        chunk = ",".join(f'"{h}"' for h in ask[i:i + 100])
        for row in sb("GET", f"stories?select=url_hash&url_hash=in.({chunk})"):
            _known_hashes.add(row["url_hash"])
    return {h for h in hashes if h in _known_hashes}


_companies_cache = {"at": 0.0, "by_key": {}}


def companies_index():
    """nse_symbol / name / alias -> company id, reloaded hourly. Nothing in
    this pipeline inserts companies, so an hour-old copy tags exactly as well."""
    if time.monotonic() - _companies_cache["at"] > REFRESH_SECONDS:
        by_key = {}
        for c in sb("GET", "companies?select=id,name,nse_symbol,aliases"):
            if c.get("nse_symbol"):
                by_key[c["nse_symbol"].upper()] = c["id"]
            by_key[c["name"].casefold()] = c["id"]
            for a in c.get("aliases") or []:
                by_key[a.casefold()] = c["id"]
        _companies_cache.update(at=time.monotonic(), by_key=by_key)
    return _companies_cache["by_key"]


_seen_images_cache = {"at": 0.0, "counts": {}}


def image_seen_counts():
    """URL -> how many CARDS carried it in the last 7 days. Only rows that
    reached approved/pending count: rejected/duplicate rows never showed
    anyone an image, so they're not evidence of a house image. Ordered so
    sb()'s Range paging can't skip or duplicate a row mid-scan.

    Memoized per process and refreshed once per IMAGE_REFRESH_SECONDS: this runs on
    every main() iteration, and a resident poller (LOOP_SECONDS) calls main()
    every 45s in prod — an unmemoized full scan of ~11k rows/week on every
    iteration would be an egress bill for a number that only moves when a run
    actually inserts a new image. The returned dict is the cached object
    itself, not a copy: callers increment counts into it as they assign
    images (see the og-fallback site), and reusing the same
    object lets those increments carry forward into the next iteration too,
    tightening house-image detection within the cache window instead of
    resetting every 45s."""
    if time.monotonic() - _seen_images_cache["at"] <= IMAGE_REFRESH_SECONDS:
        return _seen_images_cache["counts"]
    since = iso(datetime.now(timezone.utc) - timedelta(days=7))
    counts = {}
    for r in sb("GET", f"stories?select=image_url&image_url=not.is.null"
                       f"&created_at=gte.{since}&status=in.(approved,pending)"
                       "&order=created_at.asc"):
        counts[r["image_url"]] = counts.get(r["image_url"], 0) + 1
    _seen_images_cache["at"] = time.monotonic()
    _seen_images_cache["counts"] = counts
    return counts


OG_FETCH_CAP = 25          # spec M8: hard cap per run, 3s timeout each —
OG_FETCH_TIMEOUT = 3       # this is what keeps the Actions budget intact
OG_IMAGE = re.compile(
    r'<meta[^>]+(?:property=["\']og:image["\']|name=["\']twitter:image["\'])'
    r'[^>]+content=["\']([^"\']+)["\']', re.I)
OG_IMAGE_REV = re.compile(  # content= before property=, the other attribute order
    r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+'
    r'(?:property=["\']og:image["\']|name=["\']twitter:image["\'])', re.I)


def promote_dupe_images(images_by_cluster):
    """PATCH each imageless card whose cluster gained an image via a duplicate.

    A GNews-proxied card can never fetch its own image (Google's links are
    JS-locked), but its direct-feed duplicate arrives carrying one — the first
    15 direct-feed stories (2026-08-12) all filed as image-bearing dupes under
    imageless cards. One query for all affected clusters, never per dupe."""
    if not images_by_cluster:
        return 0
    cids = ",".join(f'"{c}"' for c in images_by_cluster)
    cards = sb("GET", f"stories?select=id,cluster_id&cluster_id=in.({cids})"
                      "&status=in.(approved,pending)&image_url=is.null")
    for c in cards:
        sb("PATCH", f"stories?id=eq.{c['id']}",
           json={"image_url": images_by_cluster[c["cluster_id"]]})
    return len(cards)


def article_url_for_image(url, cid, alt_urls):
    """The URL worth fetching an og:image from, or None.

    GNews wrapper links hide the article behind JS Google deliberately locked
    (no redirect, opaque tokens — verified 2026-08-11), so fetching them yields
    Google's app shell, never the outlet page. The same story from a direct
    outlet feed sits in the same cluster carrying the real article URL —
    borrow it. No direct sibling means there is nothing worth fetching."""
    if "news.google.com" not in url:
        return url
    return alt_urls.get(cid)


def og_image(article_url, seen_counts):
    """One bounded GET for the article's own og:image. Regex, not a parser
    dependency; any failure whatsoever is None — this must never cost a story.

    Streamed and capped at 512 KiB read: og:image lives in <head>, so nothing
    past that is needed, and a huge or slow page can't hold the socket or
    memory hostage for it."""
    try:
        with requests.get(article_url, headers=UA, timeout=OG_FETCH_TIMEOUT,
                          stream=True) as r:
            r.raise_for_status()
            if "html" not in r.headers.get("Content-Type", ""):
                return None
            text = r.raw.read(524288, decode_content=True).decode("utf-8", "replace")
        m = OG_IMAGE.search(text) or OG_IMAGE_REV.search(text)
        # HTML-escapes content= routinely ("?w=800&amp;h=450"); unescape before
        # the URL is stored/used, or it 404s and the width filter reads junk.
        return usable_image(html.unescape(m.group(1)), seen_counts) if m else None
    except Exception:
        return None


def entry_published(entry):
    t = entry.get("published_parsed") or entry.get("updated_parsed")
    return datetime(*t[:6], tzinfo=timezone.utc).isoformat() if t else None


def fetch_items(source):
    resp = requests.get(feed_url(source), headers=UA, timeout=FETCH_TIMEOUT)
    resp.raise_for_status()
    items = []
    # RSS feeds sometimes resurface years-old links (seen: a 2019 ET story) —
    # stale items burn AI quota and pollute the feed. No date = benefit of doubt.
    stale = datetime.now(timezone.utc) - timedelta(hours=48)
    for e in feedparser.parse(resp.content).entries:
        link, title = e.get("link"), (e.get("title") or "").strip()
        if not link or not title:
            continue
        t = e.get("published_parsed") or e.get("updated_parsed")
        if t and datetime(*t[:6], tzinfo=timezone.utc) < stale:
            continue
        items.append({
            "source": source,
            "url": link,
            "url_hash": url_hash(link),
            "headline": title,
            "body": re.sub(r"<[^>]+>", " ", e.get("summary", "") or ""),
            "image_url": entry_image(e),
            "published_at": entry_published(e),
        })
    return items


# ---------- primary sources: NSE/BSE corporate announcements (spec M3) ----------

def parse_exchange_ts(value):
    """BSE/NSE return '07-Aug-2026 23:57:46' (sometimes T-separated), which
    Postgres rejects outright — pass None rather than poison the insert."""
    if not value:
        return None
    text = str(value).strip().replace("T", " ")
    for fmt in ("%d-%b-%Y %H:%M:%S", "%d-%b-%Y %H:%M", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(text, fmt).strftime("%Y-%m-%dT%H:%M:%S+05:30")
        except ValueError:
            continue
    return None


FILING_NOISE = re.compile(
    r"trading window|share certificate|duplicate share|loss of share|regulation 74"
    r"|reg\. 74|esop|investor meet|analyst meet|newspaper publication|book closure",
    re.I)


def fetch_bse(source):
    today = datetime.now(timezone.utc).astimezone().strftime("%Y%m%d")
    r = requests.get(
        "https://api.bseindia.com/BseIndiaAPI/api/AnnSubCategoryGetData/w",
        params={"pageno": 1, "strCat": "-1", "strPrevDate": today, "strScrip": "",
                "strSearch": "P", "strToDate": today, "strType": "C", "subcategory": "-1"},
        headers={**UA, "Referer": "https://www.bseindia.com/"}, timeout=FETCH_TIMEOUT)
    r.raise_for_status()
    items = []
    for a in r.json().get("Table", []):
        subject = (a.get("NEWSSUB") or a.get("HEADLINE") or "").strip()
        company = (a.get("SLONGNAME") or "").strip()
        if not subject or FILING_NOISE.search(subject):
            continue
        url = a.get("NSURL") or (
            f"https://www.bseindia.com/xml-data/corpfiling/AttachLive/{a['ATTACHMENTNAME']}"
            if a.get("ATTACHMENTNAME") else None)
        if not url:
            continue
        headline = f"{company}: {subject}" if company else subject
        items.append({"source": source, "url": url, "url_hash": url_hash(url),
                      "headline": headline[:500], "body": a.get("MORE", "") or subject,
                      "image_url": None,
                      "published_at": parse_exchange_ts(a.get("NEWS_DT"))})
    return items


def fetch_nse(source):
    # NSE needs a cookie warm-up; its Akamai layer may still 403 datacenter IPs —
    # if so this logs as a feed failure and self-heal/source-health make it visible.
    s = requests.Session()
    s.headers.update({**UA, "Accept": "*/*", "Accept-Language": "en-US,en;q=0.9",
                      "Referer": "https://www.nseindia.com/"})
    s.get("https://www.nseindia.com", timeout=FETCH_TIMEOUT)
    r = s.get("https://www.nseindia.com/api/corporate-announcements?index=equities",
              timeout=FETCH_TIMEOUT)
    r.raise_for_status()
    items = []
    for a in r.json():
        subject = (a.get("desc") or "").strip()
        symbol = (a.get("symbol") or "").strip()
        url = a.get("attchmntFile")
        if not subject or not url or FILING_NOISE.search(subject):
            continue
        items.append({"source": source, "url": url, "url_hash": url_hash(url),
                      "headline": f"{symbol}: {subject}"[:500],
                      "body": a.get("attchmntText", "") or subject, "image_url": None,
                      "published_at": parse_exchange_ts(a.get("an_dt"))})
    return items


FETCHERS = {"nse": fetch_nse, "bse": fetch_bse}


# ---------- keyed news APIs (2026-08-22): JSON in, the same item dict out ----------
# Real article URLs and images, unlike Google News proxies. Every free tier is
# metered per day, so the fetch loop polls these on an interval (POLL_MIN)
# instead of every 45 s like RSS: GNews.io 100 req/day, NewsData 200/day,
# MarketAux 100/day (3 articles each — last priority). Keys are comma lists
# (ai._split) rotated per call. ponytail: MarketAux tags tickers+sentiment in
# `entities[]` — use them when the AI's company tagging proves weak.

POLL_MIN = {"gnews_api": 30, "newsdata": 20, "marketaux": 20}  # minutes between polls, per row
_key_turn = {}


def api_key(env):
    import ai  # env is loaded in main(), after import time
    keys = ai._split(env)
    if not keys:
        raise RuntimeError(f"{env} unset — source skipped")
    i = _key_turn.get(env, 0)
    _key_turn[env] = i + 1
    return keys[i % len(keys)]


def due_for_poll(source, now):
    """RSS every loop; a keyed API only once its interval has passed since
    last_fetched_at (a skipped source is not stamped, so the clock is honest)."""
    mins = POLL_MIN.get(source["type"])
    last = source.get("last_fetched_at")
    if not mins or not last:
        return True
    return parse_ts(last) <= now - timedelta(minutes=mins)


def parse_api_ts(s):
    """'2026-08-22T10:00:00Z' / '2026-08-22 10:00:00' / '...T10:00:00.000000Z'
    -> aware UTC datetime; None when absent or unparseable."""
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(str(s).strip().replace("Z", "+00:00").replace(" ", "T"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def api_items(source, rows, url_key, title_key, body_key, image_key, ts_key):
    stale = datetime.now(timezone.utc) - timedelta(hours=48)
    items = []
    for a in rows:
        url, title = a.get(url_key), (a.get(title_key) or "").strip()
        if not url or not title:
            continue
        ts = parse_api_ts(a.get(ts_key))
        if ts and ts < stale:
            continue
        items.append({"source": source, "url": url, "url_hash": url_hash(url),
                      "headline": title, "body": a.get(body_key) or "",
                      "image_url": a.get(image_key) or None,
                      "published_at": ts.isoformat() if ts else None})
    return items


def fetch_gnews_api(source):
    r = requests.get("https://gnews.io/api/v4/search",
                     params={"q": source["feed_url"], "lang": "en", "country": "in",
                             "max": 10, "apikey": api_key("GNEWS_API_KEY")},
                     headers=UA, timeout=FETCH_TIMEOUT)
    r.raise_for_status()
    return api_items(source, r.json().get("articles") or [],
                     "url", "title", "description", "image", "publishedAt")


def fetch_newsdata(source):
    r = requests.get("https://newsdata.io/api/1/latest",
                     params={"apikey": api_key("NEWSDATA_API_KEY"), "q": source["feed_url"],
                             "country": "in", "language": "en"},
                     headers=UA, timeout=FETCH_TIMEOUT)
    r.raise_for_status()
    return api_items(source, r.json().get("results") or [],
                     "link", "title", "description", "image_url", "pubDate")


def fetch_marketaux(source):
    params = {"api_token": api_key("MARKETAUX_API_KEY"), "countries": "in",
              "language": "en", "filter_entities": "true"}
    if source.get("feed_url"):
        params["search"] = source["feed_url"]
    r = requests.get("https://api.marketaux.com/v1/news/all", params=params,
                     headers=UA, timeout=FETCH_TIMEOUT)
    r.raise_for_status()
    return api_items(source, r.json().get("data") or [],
                     "url", "title", "description", "image_url", "published_at")


FETCHERS.update({"gnews_api": fetch_gnews_api, "newsdata": fetch_newsdata,
                 "marketaux": fetch_marketaux})


# ---------- alert engine (spec §7 machine gate) ----------

def in_quiet_hours(now):
    """Spec §7: 22:00-07:00 IST. Window wraps midnight, hence the `or`."""
    h = now.astimezone(IST).hour
    return h >= QUIET_START_IST or h < QUIET_END_IST


def may_push(score, now, sent_today):
    """Whether this story may buzz a phone. Failing here never blocks publication —
    the story still reaches the feed, it just stays silent. Pure for tests."""
    if sent_today >= MAX_ALERTS_PER_DAY:
        return False
    if in_quiet_hours(now) and (score is None or score < QUIET_PIERCE_SCORE):
        return False
    return True


# Several feeds share one newsroom, so counting rows in a cluster overstates
# corroboration: ET Markets + ET Top Stories on the same story is ONE outlet
# agreeing with itself, not two independent confirmations. Anything unlisted is
# its own publisher. ponytail: a dict until it outgrows one screen, then a
# `publisher` column on sources.
PUBLISHER = {
    "ET Top Stories": "Economic Times", "ET Markets": "Economic Times",
    "ET Economy": "Economic Times", "ET IPO": "Economic Times",
    "ET Commodities": "Economic Times", "ET Stocks News": "Economic Times",
    "ET Banking": "Economic Times", "ET MF": "Economic Times",
    "GNews Moneycontrol": "Moneycontrol",
    # A section feed and its Google News proxy are the same newsroom twice over.
    "Hindu BusinessLine": "BusinessLine", "BusinessLine Markets": "BusinessLine",
    "BusinessLine Economy": "BusinessLine", "BusinessLine Companies": "BusinessLine",
    # Same parent as BusinessLine (Kasturi & Sons) — separate desks, but grouped
    # deliberately: a false alert costs more than one that waits out the 5-minute
    # trusted-solo window.
    "The Hindu Business": "BusinessLine",
    "LiveMint Markets": "LiveMint", "LiveMint Money": "LiveMint",
    "LiveMint Companies": "LiveMint", "LiveMint Industry": "LiveMint",
    "LiveMint Economy": "LiveMint", "Mint Companies": "LiveMint",
    "RBI Press": "RBI", "RBI Notifications": "RBI", "RBI Speeches": "RBI",
    "Investing.com": "Investing.com", "Investing Commodities": "Investing.com",
    "Investing Economy": "Investing.com",
    # Two queries against one aggregator API are one source twice over.
    "GNews.io Markets IN": "GNews.io", "GNews.io Stocks IN": "GNews.io",
    "NewsData Business IN": "NewsData", "NewsData Markets IN": "NewsData",
}


def independent_sources(source_names):
    """Distinct newsrooms behind a cluster — the number the alert gate means."""
    return len({PUBLISHER.get(n, n) for n in source_names})


def gate_passes(score, cluster_size, authority, age_minutes=0):
    """Impact >= 8 AND one of: 2+ independent sources, a primary source, or a
    trusted outlet (authority >= 8) whose story is still uncorroborated after
    TRUSTED_SOLO_MINUTES. The grace window is the speed/trust trade: corroboration
    usually lands first and fires sooner; if it doesn't, a major outlet alone is
    good enough after 5 min. Low-authority sources still never alert solo.
    Pure for tests."""
    if score is None or score < 8:
        return False
    return (cluster_size >= 2
            or authority >= 10
            or (authority >= TRUSTED_AUTHORITY and age_minutes >= TRUSTED_SOLO_MINUTES))


def send_fcm(hook, headline, story_id, score):
    """Push to the 'alerts' FCM topic (the app subscribes in M4). No-op until
    FIREBASE_SERVICE_ACCOUNT_JSON is configured."""
    import json as _json
    sa_json = os.environ.get("FIREBASE_SERVICE_ACCOUNT_JSON")
    if not sa_json:
        print(f"ALERT (FCM not configured): {hook}")
        return False
    from google.oauth2 import service_account
    import google.auth.transport.requests
    creds = service_account.Credentials.from_service_account_info(
        _json.loads(sa_json), scopes=["https://www.googleapis.com/auth/firebase.messaging"])
    creds.refresh(google.auth.transport.requests.Request())
    r = requests.post(
        f"https://fcm.googleapis.com/v1/projects/{creds.project_id}/messages:send",
        headers={"Authorization": f"Bearer {creds.token}"},
        json={"message": {"topic": "alerts",
                          "notification": {"title": hook, "body": headline},
                          # hook + score ride along so the client can deep-link
                          # and decide on L1 voice without a fetch (spec §7)
                          "data": {"story_id": str(story_id), "hook": hook,
                                   "impact_score": str(score)}}},
        timeout=30)
    r.raise_for_status()
    return True


def _fcm_token_is_dead(status_code, text):
    """404 = dead token (app uninstalled/unregistered). 400 alone can just be
    a malformed message, not a dead token -- only "UNREGISTERED" in the FCM
    response body means the token itself is what's gone."""
    return status_code == 404 or (status_code == 400 and "UNREGISTERED" in (text or ""))


def send_fcm_token(token, hook, headline, story_id, score):
    """Direct-to-device variant of send_fcm for personalized alerts. Returns
    "sent" | "dead" | "fail" — the caller clears "dead" tokens and only
    counts "sent" against the daily cap."""
    import json as _json
    sa_json = os.environ.get("FIREBASE_SERVICE_ACCOUNT_JSON")
    if not sa_json:
        print(f"PERSONAL ALERT (FCM not configured): {hook}")
        return "fail"
    from google.oauth2 import service_account
    import google.auth.transport.requests
    creds = service_account.Credentials.from_service_account_info(
        _json.loads(sa_json), scopes=["https://www.googleapis.com/auth/firebase.messaging"])
    creds.refresh(google.auth.transport.requests.Request())
    r = requests.post(
        f"https://fcm.googleapis.com/v1/projects/{creds.project_id}/messages:send",
        headers={"Authorization": f"Bearer {creds.token}"},
        json={"message": {"token": token,
                          "notification": {"title": hook, "body": headline},
                          "data": {"story_id": str(story_id), "hook": hook,
                                   "impact_score": str(score)}}},
        timeout=30)
    if r.ok:
        return "sent"
    return "dead" if _fcm_token_is_dead(r.status_code, r.text) else "fail"


def personal_matches(story, follows_by_user, companies_of):
    """Users whose follows this story touches. follows_by_user: {user_id:
    [(target_type, target_id)]}; companies_of(story_id) -> set of company-id
    strings. Pure so the matching rules are testable without a database."""
    cats = {story.get("category")} - {None}
    secs = set(story.get("sectors") or [])
    comps = None  # lazy: most stories touch no follower at all
    hit = set()
    for uid, follows in follows_by_user.items():
        for ttype, tid in follows:
            if ttype == "category" and tid in cats:
                hit.add(uid); break
            if ttype == "sector" and tid in secs:
                hit.add(uid); break
            if ttype == "company":
                if comps is None:
                    comps = companies_of(story["id"])
                if tid in comps:
                    hit.add(uid); break
    return hit


PERSONAL_CAP_PER_DAY = 5     # spec §7
PERSONAL_MIN_SCORE = 6


def personal_alert_engine(now=None):
    """Spec §7 personalized alerts: impact >= 6 touching a followed
    company/sector/category -> direct push, max 5/day/user, quiet hours
    pierced only by >= 9. Per-user state in profiles.alert_settings.pa
    (ponytail: jsonb counter+cursor; a real sends table when DDL access
    returns / beta grows). Globally-alerted stories are excluded — the topic
    push already reached everyone."""
    now = now or datetime.now(timezone.utc)
    profiles = sb("GET", "profiles?select=id,fcm_token,alert_settings"
                         "&fcm_token=not.is.null")
    profiles = [p for p in profiles
                if (p.get("alert_settings") or {}).get("personalized", True)]
    if not profiles:
        return 0
    all_follows = sb("GET", "follows?select=user_id,target_type,target_id")
    follows_by_user = {}
    for f in all_follows:
        follows_by_user.setdefault(f["user_id"], []).append(
            (f["target_type"], f["target_id"]))
    if not follows_by_user:
        return 0

    today = now.astimezone(IST).strftime("%Y-%m-%d")
    cutoff = iso(now - timedelta(hours=6))
    stories = sb("GET", "stories?select=id,hook,headline,impact_score,category,sectors"
                        f"&created_at=gte.{cutoff}&impact_score=gte.{PERSONAL_MIN_SCORE}"
                        "&alerted_at=is.null&status=eq.approved"
                        "&order=id.asc")
    if not stories:
        return 0

    link_cache = {}
    def companies_of(sid):
        if sid not in link_cache:
            link_cache[sid] = {str(r["company_id"]) for r in
                               sb("GET", f"story_companies?select=company_id&story_id=eq.{sid}")}
        return link_cache[sid]

    sent = 0
    quiet = in_quiet_hours(now)
    for p in profiles:
        uid = p["id"]
        if uid not in follows_by_user:
            continue
        try:
            settings = p.get("alert_settings") or {}
            pa = settings.get("pa") or {}
            n_today = pa.get("n", 0) if pa.get("d") == today else 0
            cursor = pa.get("cur", 0)
            new_cursor = cursor
            # A mid-loop exception (bad story shape, companies_of network blip)
            # must not lose this user's pa state — the finally still PATCHes
            # whatever cursor/count were reached, so a retry next pass resumes
            # instead of re-buzzing the same stories.
            try:
                for s in stories:
                    if s["id"] <= cursor:
                        continue
                    new_cursor = max(new_cursor, s["id"])
                    if n_today >= PERSONAL_CAP_PER_DAY:
                        continue  # cursor still advances: stale news never buzzes later
                    if quiet and (s["impact_score"] or 0) < QUIET_PIERCE_SCORE:
                        continue
                    if uid not in personal_matches(s, {uid: follows_by_user[uid]}, companies_of):
                        continue
                    result = send_fcm_token(p["fcm_token"], s["hook"] or s["headline"],
                                            s["headline"], s["id"], s["impact_score"])
                    if result == "sent":
                        n_today += 1
                        sent += 1
                    elif result == "dead":
                        sb("PATCH", f"profiles?id=eq.{uid}", json={"fcm_token": None})
                        break  # token's gone: no point trying it against later stories
            finally:
                if new_cursor != cursor or n_today != (pa.get("n", 0) if pa.get("d") == today else 0):
                    sb("PATCH", f"profiles?id=eq.{uid}",
                       json={"alert_settings": {**settings,
                             "pa": {"d": today, "n": n_today, "cur": new_cursor}}})
        except Exception as e:
            # one bad user (dead creds, malformed token, transient network blip)
            # never stops the rest of the run's pushes
            print(f"PERSONAL ALERT failed for user {uid}: {str(e)[:80]}")
            continue
    return sent


def alert_engine(authority_by_source, push=True):
    """Speed path: qualifying stories auto-approve + alert with no human in the loop.
    The 5/day cap limits PUSHES, not publication — a story past the cap is still
    approved so it reaches the feed, it just doesn't buzz anyone's phone.
    Single-source non-primary high-impact stays in the admin queue until it is
    either corroborated or old enough to clear gate_passes()."""
    now = datetime.now(timezone.utc)
    # IST is explicit, never the host clock: this pipeline may run on a UTC VM,
    # and "5 alerts per day" / "quiet hours" are promises about the user's day.
    midnight = iso(now.astimezone(IST).replace(
        hour=0, minute=0, second=0, microsecond=0).astimezone(timezone.utc))
    sent_today = len(sb("GET", f"stories?select=id&alerted_at=gte.{midnight}"))
    cutoff = iso(now - timedelta(hours=6))
    candidates = sb("GET", "stories?select=id,hook,headline,impact_score,cluster_id,"
                           "source_name,created_at"
                           f"&alerted_at=is.null&impact_score=gte.8&created_at=gte.{cutoff}"
                           "&status=in.(pending,approved)&order=impact_score.desc")
    alerted = published = 0
    for s in candidates:
        cluster_size = independent_sources(
            r["source_name"] for r in
            sb("GET", f"stories?select=source_name&cluster_id=eq.{s['cluster_id']}"))
        age_minutes = (now - parse_ts(s["created_at"])).total_seconds() / 60
        if not gate_passes(s["impact_score"], cluster_size,
                           authority_by_source.get(s["source_name"], 5), age_minutes):
            continue
        patch = {"status": "approved"}
        if push and may_push(s["impact_score"], now, sent_today + alerted):
            send_fcm(s["hook"] or s["headline"], s["headline"], s["id"],
                     s["impact_score"])
            patch["alerted_at"] = now.isoformat()
            alerted += 1
        else:
            published += 1  # capped, quiet hours or alerts switched off: live, silent
        sb("PATCH", f"stories?id=eq.{s['id']}", json=patch)
    if published:
        print(f"{published} story(ies) published without a push (cap, quiet hours or switch)")
    return alerted


# ---------- chief editor (spec §5, one comparative call per run) ----------

def chief_editor(editor_pass):
    cutoff = iso(datetime.now(timezone.utc) - timedelta(hours=3))
    rows = sb("GET", "stories?select=id,headline,impact_score,category,cluster_id,source_name"
                     f"&created_at=gte.{cutoff}&status=in.(pending,approved)&limit=100")
    if len(rows) < 2:
        return 0
    counts = {}
    for r in rows:
        counts[r["cluster_id"]] = counts.get(r["cluster_id"], 0) + 1
    auth = {s["name"]: s["authority"] for s in sb("GET", "sources?select=name,authority")}
    digest = "\n".join(
        f"{r['id']} | {r['impact_score']} | {r['category']} | {counts[r['cluster_id']]} | "
        f"{auth.get(r['source_name'], 5)} | {r['headline']}" for r in rows)
    out = editor_pass(digest)
    if not out:
        return 0
    ids = {r["id"] for r in rows}
    for rl in out["relevel"]:
        if rl["id"] in ids:
            sb("PATCH", f"stories?id=eq.{rl['id']}", json={"impact_score": rl["score"]})
    # Same-event merges the clustering missed (spec §5). Seen live 2026-08-12:
    # 'Chandrasekaran resigns' ran as 6 approved cards because every outlet
    # rephrased it and token overlap can't see synonyms. The duplicate joins
    # the keeper's CLUSTER (its outlet keeps its credit on the card) and its
    # status leaves the feed. Both ids must come from the digest we actually
    # showed the editor — a hallucinated id must never touch a row.
    cluster_of_id = {r["id"]: r["cluster_id"] for r in rows}
    merged = 0
    for keep, dup in out.get("merge", []):
        if keep in ids and dup in ids:
            sb("PATCH", f"stories?id=eq.{dup}",
               json={"status": "duplicate", "cluster_id": cluster_of_id[keep]})
            merged += 1
    if merged:
        print(f"EDITOR MERGE: {merged} same-event card(s) folded into their cluster")
    if out["top_story_id"] in ids:
        # one featured at a time — stale pins were freezing the feed's top
        sb("PATCH", "stories?is_featured=eq.true", json={"is_featured": False})
        sb("PATCH", f"stories?id=eq.{out['top_story_id']}", json={"is_featured": True})
    return len(out["relevel"])


# ---------- self-healing (retry flagged, disable dead feeds, auto-approve) ----------

def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(s):
    """Postgres timestamptz -> aware datetime. Naive input is treated as UTC."""
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def remaining_budget_today(window):
    """Free-tier calls left today, paced so the day doesn't get spent by dawn.
    Counts non-duplicate rows since IST midnight — every one cost roughly a call
    (duplicates and low-value filtering are free). Slight overcount is deliberate:
    running out early is worse than pacing conservatively. `window` is
    recent_stories(): 48 h always covers "since midnight", no extra read."""
    midnight = datetime.now(timezone.utc).astimezone(IST).replace(
        hour=0, minute=0, second=0, microsecond=0)
    spent = sum(1 for r in window
                if r["status"] != "duplicate" and parse_ts(r["created_at"]) >= midnight)
    left = max(0, DAILY_AI_BUDGET - spent)
    if left == 0:
        print(f"daily AI budget spent ({spent}/{DAILY_AI_BUDGET}); "
              "fetching continues, processing resumes after IST midnight")
    return left


def retry_flagged(process_story, AIError, QuotaExhausted, companies_by_key):
    """Re-run AI on recently flagged stories (headline-only — body isn't stored).
    Older than 24h we stop trying; admin sees them. Cap 20/run, newest first:
    enough to drain a mass outage pileup (2026-08-11: 3.4k flagged in a day,
    5/run could never catch up inside the 24h window) while a normal day's
    handful costs nothing extra. QuotaExhausted still breaks out early."""
    cutoff = iso(datetime.now(timezone.utc) - timedelta(hours=24))
    rows = sb("GET", f"stories?select=id,headline,source_name&status=eq.flagged"
                     f"&created_at=gte.{cutoff}&order=created_at.desc&limit=20")
    healed = 0
    for row in rows:
        try:
            card = process_story(row["source_name"], row["headline"],
                                 "(body unavailable — assess from the headline alone)")
        except QuotaExhausted:
            break  # out of budget, not a bad story: leave it untouched for later
        except AIError as e:
            sb("PATCH", f"stories?id=eq.{row['id']}", json={"raw_ai_error": str(e)})
            continue
        imp = card["impact"]
        keep = card["is_india_relevant"] or (card["category"] == "Geopolitics" and imp["score"] >= 6)
        sb("PATCH", f"stories?id=eq.{row['id']}", json={
            "hook": card["hook"], "headline": card["headline_rewrite"],
            "summary": card["summary"],
            "impact_direction": imp["direction"], "impact_strength": imp["strength"],
            "impact_horizon": imp["horizon"], "impact_score": imp["score"],
            "confidence": card["confidence"], "category": card["category"],
            "sectors": card["sectors"], "raw_ai_error": None,
            "status": "pending" if keep else "rejected",
        })
        healed += 1  # ai.py throttles; no extra sleep needed
    return healed


def disable_dead_sources(sources):
    """Two ways a source dies, and only one used to be caught. `sources` is
    main()'s active list for this lap (one read, shared).

    (a) It stops responding — last_fetched_at goes stale. Caught before.
    (b) It answers HTTP 200 forever with frozen content. last_fetched_at keeps
        updating, so it looked permanently healthy while contributing nothing.
        This is exactly how Moneycontrol's RSS died (200 OK, frozen since Apr
        2024) and we would never have noticed. Now a source that fetches fine
        but has produced no story in SILENT_SOURCE_DAYS is retired too.

    Nothing is deleted: a retired source is re-probed by revive_sources()."""
    now = datetime.now(timezone.utc)
    dead = sb("PATCH", f"sources?is_active=eq.true&last_fetched_at=lt.{iso(now - timedelta(days=3))}",
              json={"is_active": False}, headers={"Prefer": "return=representation"}) or []
    for s in dead:
        print(f"SELF-HEAL: disabled unreachable source {s['name']}")

    since = iso(now - timedelta(days=SILENT_SOURCE_DAYS))
    # "Produced something in SILENT_SOURCE_DAYS": the 48 h window answers it
    # for almost every source for free; only the few quiet ones are asked of
    # the database, and only for their own rows (a quiet source has few).
    producing = {r["source_name"] for r in recent_stories()}
    quiet = [s["name"] for s in sources if s["name"] not in producing]
    if quiet:
        names = ",".join('"' + n.replace('"', '') + '"' for n in quiet)
        producing |= {r["source_name"] for r in
                      sb("GET", f"stories?select=source_name&created_at=gte.{since}"
                                f"&source_name=in.({names})")}
    dead_ids = {s["id"] for s in dead}
    for s in sources:
        if s["id"] in dead_ids:
            continue
        # Only judge a source that has had a fair chance: seeded long enough ago
        # that SILENT_SOURCE_DAYS of silence is evidence rather than newness.
        if s["name"] in producing or not s["last_fetched_at"]:
            continue
        if parse_ts(s["last_fetched_at"]) < now - timedelta(days=SILENT_SOURCE_DAYS):
            continue  # stale-fetch case, already handled above
        first_seen = sb("GET", f"stories?select=created_at&source_name=eq."
                               f"{quote_plus(s['name'])}&order=created_at.asc&limit=1")
        if not first_seen or parse_ts(first_seen[0]["created_at"]) > now - timedelta(days=SILENT_SOURCE_DAYS):
            continue  # too new to judge
        sb("PATCH", f"sources?id=eq.{s['id']}", json={"is_active": False})
        dead.append(s)
        print(f"SELF-HEAL: retired silent source {s['name']} "
              f"(fetches fine, no story in {SILENT_SOURCE_DAYS}d)")
    return len(dead)


def revive_sources():
    """Re-probe retired sources so an outage is never permanent.

    Disabling was previously one-way: a feed that had a bad week stayed off
    forever and only a human could bring it back. Every REVIVE_AFTER_HOURS we
    give each retired source one fetch; if it returns anything fresh, it rejoins
    the rotation on its own. A failed probe leaves last_fetched_at untouched,
    so the next attempt is naturally spaced rather than hammering a dead host."""
    cutoff = iso(datetime.now(timezone.utc) - timedelta(hours=REVIVE_AFTER_HOURS))
    revived = 0
    for s in sb("GET", "sources?select=*&is_active=eq.false&type=neq.youtube"):
        if s["last_fetched_at"] and s["last_fetched_at"] > cutoff:
            continue  # probed recently enough
        try:
            items = FETCHERS.get(s["type"], fetch_items)(s)
        except Exception as e:
            print(f"REVIVE probe failed {s['name']}: {str(e)[:80]}")
            continue
        if not items:
            continue  # reachable but still empty; stays retired
        sb("PATCH", f"sources?id=eq.{s['id']}",
           json={"is_active": True,
                 "last_fetched_at": datetime.now(timezone.utc).isoformat()})
        revived += 1
        print(f"SELF-HEAL: revived {s['name']} — {len(items)} fresh items")
    return revived


def auto_approve():
    """Spec §9: score < 8 auto-approves after AUTO_APPROVE_MINUTES unreviewed;
    score >= 8 is alert_engine's job.

    Must stay < 8, not < 7: alert_engine only touches score >= 8, so a score-7
    story matched neither rule and sat pending forever — and 7 is L2 'major'."""
    cutoff = iso(datetime.now(timezone.utc) - timedelta(minutes=AUTO_APPROVE_MINUTES))
    rows = sb("PATCH", f"stories?status=eq.pending&impact_score=lt.8&created_at=lt.{cutoff}",
              json={"status": "approved"}, headers={"Prefer": "return=representation"})
    # Owner's rule (2026-08-14): no relevant story waits more than 10 minutes,
    # score be damned. The fast lane approves >= 8 at insert, but a healed
    # flag or an editor relevel re-enters pending ABOVE the < 8 ceiling and
    # sat there forever (seen live: 2 stuck cards). Age alone now publishes —
    # pending already means the AI judged it relevant.
    backstop = iso(datetime.now(timezone.utc) - timedelta(minutes=PENDING_MAX_MINUTES))
    rows2 = sb("PATCH", f"stories?status=eq.pending&created_at=lt.{backstop}",
               json={"status": "approved"}, headers={"Prefer": "return=representation"})
    return len(rows or []) + len(rows2 or [])


EVENTS_RETENTION_DAYS = 90   # spec M8: events grows on every swipe, forever,
                             # against a 500 MB free tier — this makes it run for years
REJECTED_RETENTION_DAYS = 30  # 2026-08-23: rejected rows were 26% of stories (9.6k) and
                              # nobody ever sees one; they only exist as "seen this url".
                              # ~2k stories/day since the throughput fix → 500 MB in ~4
                              # months; this roughly halves that. Approved cards: never.


def retention_sweep():
    """Delete events older than EVENTS_RETENTION_DAYS. The cutoff is truncated
    to the day, so the first run after midnight does the real delete and every
    other run that day matches nothing — a once-per-day guard with no state."""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=EVENTS_RETENTION_DAYS)) \
        .replace(hour=0, minute=0, second=0, microsecond=0)
    try:
        sb("DELETE", f"events?created_at=lt.{iso(cutoff)}")
        # A rejected story's only job after a month is holding a url_hash; a
        # feed that resurfaces a 30-day-old link just gets it rejected again.
        rej = (datetime.now(timezone.utc) - timedelta(days=REJECTED_RETENTION_DAYS)) \
            .replace(hour=0, minute=0, second=0, microsecond=0)
        sb("DELETE", f"stories?status=eq.rejected&created_at=lt.{iso(rej)}")
        # run/edge logs: 1 run row per loop iteration (~1900/day) would eat the
        # free tier in months — keep failures 14 d, healthy runs 48 h, edge 30 d
        now = datetime.now(timezone.utc)
        sb("DELETE", f"pipeline_runs?ok=eq.true&started_at=lt.{iso(now - timedelta(hours=48))}")
        sb("DELETE", f"pipeline_runs?started_at=lt.{iso(now - timedelta(days=14))}")
        sb("DELETE", f"edge_log?created_at=lt.{iso(now - timedelta(days=30))}")
    except requests.RequestException as e:
        print(f"RETENTION SWEEP FAILED: {e}")  # next run retries; nothing lost


# ---------- main ----------

def insert_story(row, companies_by_key, card=None):
    story = sb("POST", "stories", json=row, headers={"Prefer": "return=representation"})[0]
    _known_hashes.add(row["url_hash"])
    links = []
    for c in (card or {}).get("companies", []):
        cid = (companies_by_key.get(str(c.get("nse_symbol", "")).upper())
               or companies_by_key.get(str(c.get("name", "")).casefold()))
        if cid:
            links.append({"story_id": story["id"], "company_id": cid})
    if links:
        sb("POST", "story_companies", json=links, headers={"Prefer": "resolution=ignore-duplicates"})
    return story


def main(cfg=None):
    load_env()
    switches = apply_config(load_config() if cfg is None else cfg)
    on = switches.get
    from ai import (AIError, QuotaExhausted, editor_pass, process_story,
                    usage_report)  # after env load

    # type=neq.youtube: the video feature was retired 2026-08-23 (pictures only);
    # channel rows stay in the table but must never enter the story path.
    sources = sb("GET", "sources?select=*&is_active=eq.true&type=neq.youtube")
    companies_by_key = companies_index()
    seen_images = image_seen_counts()

    # Oldest first, one entry per cluster: the seed decides what the cluster is
    # about (see cluster_of). Loading every member is what let clusters chain.
    window = recent_stories()
    recent, seen_clusters, published = [], set(), []
    for r in window:
        if r["cluster_id"] not in seen_clusters:
            seen_clusters.add(r["cluster_id"])
            recent.append((r["cluster_id"], title_tokens(r["headline"])))
        # Cards that reached the feed: their `headline` is the AI's rewrite, so
        # this is the only list where comparing like with like is possible.
        if r["status"] in ("approved", "pending"):
            published.append((r["cluster_id"], title_tokens(r["headline"])))

    items, fetched_source_ids = [], []
    poll_now = datetime.now(timezone.utc)
    for s in sources:
        if not due_for_poll(s, poll_now):  # keyed APIs: quota-paced, not every loop
            continue
        try:
            items += FETCHERS.get(s["type"], fetch_items)(s)
            fetched_source_ids.append(s["id"])
        except Exception as e:  # one dead feed never blocks the rest (spec §10)
            print(f"FEED FAIL {s['name']}: {e}")

    seen = existing_hashes([i["url_hash"] for i in items])
    fresh, batch_hashes = [], set()
    for i in items:
        if i["url_hash"] not in seen and i["url_hash"] not in batch_hashes:
            fresh.append(i)
            batch_hashes.add(i["url_hash"])
    fresh = prioritized(fresh)

    # Cluster first, AI second. An item that joins an existing cluster is the
    # same story from another outlet: store it as a 'duplicate' member (free
    # corroboration for the alert gate) and spend no AI call on it.
    to_process, dupes, noise = [], [], []
    for item in fresh:
        cid, known = cluster_of(item["headline"], recent)
        if known:
            dupes.append((item, cid))
        elif LOW_VALUE.search(item["headline"]):
            noise.append((item, cid))
        else:
            to_process.append((item, cid))

    # Direct-feed article URL per cluster, for cards whose own URL is a GNews
    # wrapper (see article_url_for_image). A dupe IS the same story told by
    # another outlet, so its URL is a faithful stand-in for the card's.
    alt_urls = {}
    for item, cid in dupes:
        if "news.google.com" not in item["url"]:
            alt_urls.setdefault(cid, item["url"])

    # Two ceilings: this run's share, and what's left of today's free quota.
    # The daily one only started mattering once the poller ran continuously —
    # 3800 passes/day against a ~3000-call budget would spend the day by 02:00
    # and leave the feed frozen until midnight.
    cap = min(MAX_AI_CALLS_PER_RUN, remaining_budget_today(window))
    skipped = max(0, len(to_process) - cap)
    to_process = to_process[:cap]
    print(f"{len(items)} fetched, {len(fresh)} new -> {len(to_process)} to AI, "
          f"{len(dupes)} duplicates, {len(noise)} low-value (both free)"
          + (f", {skipped} deferred to next run (cap {cap})" if skipped else ""))

    def base_row(item, cid):
        return {"url": item["url"], "url_hash": item["url_hash"], "cluster_id": cid,
                "headline": item["headline"], "source_name": item["source"]["name"],
                "source_url": item["url"], "image_url": usable_image(item["image_url"], seen_images),
                # No usable date from the source => stamp ingestion time. The app
                # filters the feed on published_at, and NULL fails that filter, so
                # an undated story was silently invisible forever — which had
                # swallowed every BSE filing and most SEBI/RBI releases, i.e. the
                # highest-authority primary sources the product exists to surface.
                "published_at": item["published_at"] or datetime.now(timezone.utc).isoformat()}

    # Low-value items each open their own cluster, so nothing depends on them.
    for item, cid in noise:
        try:
            insert_story({**base_row(item, cid), "status": "rejected"}, companies_by_key)
        except requests.RequestException as e:
            print(f"REJECTED INSERT FAIL {item['url_hash'][:8]}: {e}")
    # Duplicates wait for the AI phase — see the guard below.

    # Concurrent AI; ai.py's per-lane throttle keeps the free tier happy.
    # Hard wall-clock budget: when only one model lane is live the throttle caps
    # throughput at ~15/min, so a full cap could outlast the job timeout and kill
    # the run before alerts and auto-approve ever execute. Past the deadline the
    # remaining stories defer exactly like a quota block — nothing is lost.
    processed = flagged = dropped = quota_blocked = merged = 0
    og_fetches = 0
    landed = set()   # clusters whose card actually reached the database this run
    deadline = time.monotonic() + AI_PHASE_SECONDS

    def process_within_budget(name, headline, body):
        if time.monotonic() > deadline:
            raise QuotaExhausted("AI phase budget spent; deferred to next run")
        return process_story(name, headline, body)

    with ThreadPoolExecutor(max_workers=AI_CONCURRENCY) as pool:
        futures = {pool.submit(process_within_budget, item["source"]["name"],
                               item["headline"], item["body"]): (item, cid)
                   for item, cid in to_process}
        for fut in as_completed(futures):
            item, cid = futures[fut]
            base = base_row(item, cid)
            try:
                card = fut.result()
            except QuotaExhausted:
                # Insert nothing: the url stays unseen, so a later run reprocesses
                # it with the full article body instead of a headline-only retry.
                quota_blocked += 1
                continue
            except AIError as e:
                insert_story({**base, "status": "flagged", "raw_ai_error": str(e)},
                             companies_by_key)
                flagged += 1
                continue
            imp = card["impact"]
            keep = card["is_india_relevant"] or (
                card["category"] == "Geopolitics" and imp["score"] >= 6)
            # Fast lane (owner's latency spec, 2026-08-08): a major story is
            # visible the moment it is understood — no approval wait — because
            # the cost of being 5 min late on a market-mover is worse than the
            # cost of a rare bad card, which the admin can still reject.
            # PUSHING is untouched: alert_engine still demands corroboration
            # before anything buzzes a phone. Publish fast, alert carefully.
            live_now = keep and imp["score"] >= FAST_LANE_SCORE
            # Second dedupe, now that the AI has put both outlets' wording into
            # one voice. The story is still stored — its outlet and link are
            # what a card's "also reported by" list is built from — but it
            # joins the existing cluster instead of becoming a second card for
            # the same news. The AI call is already spent by here; this
            # protects the feed, not the budget.
            twin = merge_target(card["headline_rewrite"], published) if keep else None
            if twin:
                base = {**base, "cluster_id": twin}
                merged += 1
            elif keep:
                published.append((base["cluster_id"],
                                  title_tokens(card["headline_rewrite"])))
            # og:image fallback (spec M8): only for a card actually being
            # inserted without a usable image — bounded so a bad news day
            # can't melt the Actions budget.
            fetch_url = article_url_for_image(item["url"], base["cluster_id"],
                                              alt_urls)
            if (keep and not twin and not base["image_url"] and fetch_url
                    and og_fetches < OG_FETCH_CAP):
                og_fetches += 1
                base["image_url"] = og_image(fetch_url, seen_images)
                if base["image_url"]:
                    # seen_images is read-only
                    # for the rest of this run otherwise, and one generic
                    # og:image could land on up to OG_FETCH_CAP cards before
                    # any run ever counts it 3 times.
                    seen_images[base["image_url"]] = seen_images.get(base["image_url"], 0) + 1
            try:
                insert_story({
                    **base,
                    "hook": card["hook"], "headline": card["headline_rewrite"],
                    "summary": card["summary"],
                    "impact_direction": imp["direction"], "impact_strength": imp["strength"],
                    "impact_horizon": imp["horizon"], "impact_score": imp["score"],
                    "confidence": card["confidence"], "category": card["category"],
                    "sectors": card["sectors"],
                    "status": "duplicate" if twin else (
                        ("approved" if live_now else "pending") if keep else "rejected"),
                }, companies_by_key, card)
            except requests.RequestException as e:  # never lose the whole run to one row
                print(f"INSERT FAIL {item['source']['name']}: {e}")
                continue
            landed.add(base["cluster_id"])
            if keep and not twin and base["image_url"]:
                # Count the card's image the moment it lands (this is the
                # only writer of stories), so the third use of an outlet's
                # house graphic is refused on the very next lap — the 7 d
                # reload in image_seen_counts is history, not the live count.
                seen_images[base["image_url"]] = seen_images.get(base["image_url"], 0) + 1
            processed += 1 if keep else 0
            dropped += 0 if keep else 1

    # A duplicate is only meaningful next to the card it duplicates. Its parent
    # may never have been stored — the per-run cap cuts the queue, quota runs
    # out, the AI phase hits its deadline — and duplicates cost nothing, so they
    # used to be written anyway. The parent then returned on the next run,
    # matched the cluster its own copies had created, and was filed as a
    # duplicate too: 969 stories sat in 226 clusters where every member was a
    # duplicate and no card was ever shown, TBO Tek's results and Britannia's
    # shareholder meeting among them.
    #
    # So hold them until the parent is known to have landed — either it was
    # already in the database when this run started, or it was inserted above.
    # Otherwise drop the duplicate unwritten: its url stays unseen, and the next
    # run picks up the whole group together.
    held = 0
    dupe_images = {}
    for item, cid in dupes:
        if cid not in seen_clusters and cid not in landed:
            held += 1
            continue
        try:
            row = base_row(item, cid)
            insert_story({**row, "status": "duplicate"}, companies_by_key)
            if row["image_url"]:
                dupe_images.setdefault(cid, row["image_url"])
        except requests.RequestException as e:
            print(f"DUPLICATE INSERT FAIL {item['url_hash'][:8]}: {e}")
    if held:
        print(f"{held} duplicates held back: their story was deferred, so the "
              f"whole group waits for the next run")
    promoted = promote_dupe_images(dupe_images)
    if promoted:
        print(f"{promoted} imageless card(s) took a duplicate's image")

    if fetched_source_ids:
        ids = ",".join(str(i) for i in fetched_source_ids)
        sb("PATCH", f"sources?id=in.({ids})",
           json={"last_fetched_at": datetime.now(timezone.utc).isoformat()})

    # The digest only moves when a pending/approved card lands, and 32% of
    # cycles (measured 2026-08-17) insert nothing but duplicates — the editor
    # was re-reading the same 100 rows every 3.2 min for ~20% of the daily call
    # budget. Skipping those costs no coverage: a relevel or a merge can only
    # become available once a new card enters the window.
    # Admin switches pause a stage, never the publication path above.
    releveled = chief_editor(editor_pass) if processed and on("chief_editor") else 0
    alerted = alert_engine({s["name"]: s["authority"] for s in sources}, push=on("alerts"))
    personal = personal_alert_engine() if on("personal_alerts") else 0
    healed = retry_flagged(process_story, AIError, QuotaExhausted, companies_by_key)
    disabled = disable_dead_sources(sources)
    revived = revive_sources()
    # off = strict manual review; the PENDING_MAX_MINUTES backstop is inside too
    approved = auto_approve() if on("auto_approve") else 0
    retention_sweep()
    quotes = 0
    if on("market"):  # prices/FX/crypto into `quotes` (market.py); never blocks news
        try:
            import market
            quotes = sum(market.refresh(sb).values())
        except Exception as e:
            print(f"MARKET FAIL: {e}")
    print(f"done: {processed} pending, {dropped} dropped (not India-relevant), {flagged} flagged"
          + (f", {merged} merged into an existing story" if merged else "")
          + (f", {quota_blocked} awaiting quota (retry next run)" if quota_blocked else "")
          + f" | editor: {releveled} releveled | alerts: {alerted} sent, {personal} personal alerts | "
          f"self-heal: {healed} recovered, {disabled} retired, {revived} revived, {approved} auto-approved"
          + (f" | market: {quotes} quotes" if quotes else ""))
    served = usage_report()
    if served:  # which lane actually carried the run — silent failover is visible
        print("AI served by: " + ", ".join(f"{m}={n}" for m, n in
                                           sorted(served.items(), key=lambda kv: -kv[1])))
    return {"fetched": len(items), "new": len(fresh), "to_ai": len(to_process),
            "dupes": len(dupes), "noise": len(noise), "deferred": skipped,
            "processed": processed, "dropped": dropped, "flagged": flagged, "merged": merged,
            "quota_blocked": quota_blocked, "held": held, "releveled": releveled,
            "alerted": alerted, "personal": personal, "healed": healed,
            "disabled": disabled, "revived": revived, "approved": approved, "quotes": quotes,
            "switched_off": [k for k, v in switches.items() if not v]}


# ---------- run log (admin cockpit) ----------

ERR_RE = re.compile(r"FAIL|Traceback|Exception", re.I)


class _Tee(io.TextIOBase):
    """stdout to both the real console (GitHub log) and a buffer (run row)."""
    def __init__(self, *streams):
        self.streams = streams

    def write(self, s):
        for stream in self.streams:
            stream.write(s)
        return len(s)

    def flush(self):
        for stream in self.streams:
            stream.flush()


def run_logged():
    """One main() wrapped in a pipeline_runs row: started/finished, ok, stage
    counts, which AI lanes served, the captured stdout. Honours the admin's
    `pipeline` switch. Logging may fail without failing the run, and vice versa."""
    load_env()
    cfg = load_config()
    if not (cfg.get("switches") or {}).get("pipeline", True):
        print("pipeline PAUSED by admin switch; nothing fetched")
        return True
    run_id = None
    try:
        host = os.environ.get("GITHUB_RUN_ID") or socket.gethostname()
        run_id = sb("POST", "pipeline_runs", json={"host": host},
                    headers={"Prefer": "return=representation"})[0]["id"]
    except Exception as e:  # pre-migration or Supabase hiccup: run anyway
        print(f"RUN LOG INSERT FAILED: {e}")
    from ai import usage_report
    before = usage_report()  # cumulative per process; this run = the diff
    buf = io.StringIO()
    ok, counts = True, None
    with contextlib.redirect_stdout(_Tee(sys.__stdout__, buf)):
        try:
            counts = main(cfg)
        except Exception:
            ok = False
            traceback.print_exc(file=sys.stdout)
    if run_id is None:
        return ok
    after = usage_report()
    log = buf.getvalue()[-20000:]
    try:
        sb("PATCH", f"pipeline_runs?id=eq.{run_id}", json={
            "finished_at": datetime.now(timezone.utc).isoformat(), "ok": ok, "counts": counts,
            "errors": [l for l in log.splitlines() if ERR_RE.search(l)][:50],
            "ai_usage": {k: n - before.get(k, 0) for k, n in after.items() if n - before.get(k, 0)},
            "log": log})
    except Exception as e:
        print(f"RUN LOG PATCH FAILED: {e}")
    return ok


if __name__ == "__main__":
    # LOOP_SECONDS unset -> one run and exit (GitHub Actions). Set it -> stay
    # resident and poll, for an always-on host. main() is idempotent, so a
    # crashed run costs nothing but the interval.
    loop_seconds = int(os.environ.get("LOOP_SECONDS", "0"))
    # LOOP_MAX_SECONDS bounds the process so a cron-launched poller exits before
    # the next one starts; unset means run forever (always-on host).
    deadline = int(os.environ.get("LOOP_MAX_SECONDS", "0"))
    if not loop_seconds:
        sys.exit(0 if run_logged() else 1)
    else:
        started = time.monotonic()
        while True:
            try:
                run_logged()
            except Exception:
                traceback.print_exc()  # never let one bad run kill the poller
            if deadline and time.monotonic() - started + loop_seconds > deadline:
                print("loop deadline reached; exiting for the next scheduled run")
                break
            time.sleep(loop_seconds)
