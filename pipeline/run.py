"""FinSwipe M1 pipeline: fetch feeds -> normalize -> dedupe -> cluster ->
Gemini card -> insert 'pending' into Supabase. Idempotent: url_hash re-checked
every run, so re-processing is a no-op."""
import hashlib
import os
import pathlib
import re
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
AUTO_APPROVE_MINUTES = 5    # unreviewed score < 8 goes live after this (owner's call)
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


def load_env():
    env = pathlib.Path(__file__).parent / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())


# ---------- Supabase (PostgREST) ----------

def sb(method, path, **kwargs):
    key = os.environ["SUPABASE_SERVICE_KEY"]
    r = requests.request(
        method, f"{os.environ['SUPABASE_URL'].rstrip('/')}/rest/v1/{path}",
        headers={"apikey": key, "Authorization": f"Bearer {key}",
                 "Content-Type": "application/json", **kwargs.pop("headers", {})},
        timeout=30, **kwargs)
    if not r.ok:  # PostgREST puts the actual reason in the body, not the status
        raise requests.HTTPError(f"{r.status_code} {path.split('?')[0]}: {r.text[:300]}",
                                 response=r)
    return r.json() if r.text else None


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
LOW_VALUE = re.compile(
    r"grey market premium|\bGMP\b|subscription status|allotment status"
    r"|IPO day \d|day \d+ of (?:bidding|subscription)"
    r"|top (?:gainers|losers)|multibagger|penny stock"
    r"|stocks? to (?:watch|buy)|trade spotlight|f&o ban", re.I)


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


def alert_engine(authority_by_source):
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
        if may_push(s["impact_score"], now, sent_today + alerted):
            send_fcm(s["hook"] or s["headline"], s["headline"], s["id"],
                     s["impact_score"])
            patch["alerted_at"] = now.isoformat()
            alerted += 1
        else:
            published += 1  # capped or quiet hours: goes live silently, no push
        sb("PATCH", f"stories?id=eq.{s['id']}", json=patch)
    if published:
        print(f"{published} story(ies) published without a push (cap or quiet hours)")
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


def remaining_budget_today():
    """Free-tier calls left today, paced so the day doesn't get spent by dawn.
    Counts non-duplicate rows since IST midnight — every one cost roughly a call
    (duplicates and low-value filtering are free). Slight overcount is deliberate:
    running out early is worse than pacing conservatively."""
    midnight = iso(datetime.now(timezone.utc).astimezone(IST).replace(
        hour=0, minute=0, second=0, microsecond=0).astimezone(timezone.utc))
    spent = len(sb("GET", f"stories?select=id&created_at=gte.{midnight}"
                          "&status=neq.duplicate"))
    left = max(0, DAILY_AI_BUDGET - spent)
    if left == 0:
        print(f"daily AI budget spent ({spent}/{DAILY_AI_BUDGET}); "
              "fetching continues, processing resumes after IST midnight")
    return left


def retry_flagged(process_story, AIError, QuotaExhausted, companies_by_key):
    """Re-run AI on recently flagged stories (headline-only — body isn't stored).
    Older than 24h we stop trying; admin sees them. Cap 5/run to protect quota."""
    cutoff = iso(datetime.now(timezone.utc) - timedelta(hours=24))
    rows = sb("GET", f"stories?select=id,headline,source_name&status=eq.flagged"
                     f"&created_at=gte.{cutoff}&limit=5")
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


def disable_dead_sources():
    """Two ways a source dies, and only one used to be caught.

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
    producing = {r["source_name"] for r in
                 sb("GET", f"stories?select=source_name&created_at=gte.{since}")}
    for s in sb("GET", "sources?select=id,name,last_fetched_at&is_active=eq.true"):
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
    for s in sb("GET", "sources?select=*&is_active=eq.false"):
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
    return len(rows or [])


# ---------- main ----------

def existing_hashes(hashes):
    found = set()
    for i in range(0, len(hashes), 100):
        chunk = ",".join(f'"{h}"' for h in hashes[i:i + 100])
        for row in sb("GET", f"stories?select=url_hash&url_hash=in.({chunk})"):
            found.add(row["url_hash"])
    return found


def insert_story(row, companies_by_key, card=None):
    story = sb("POST", "stories", json=row, headers={"Prefer": "return=representation"})[0]
    links = []
    for c in (card or {}).get("companies", []):
        cid = (companies_by_key.get(str(c.get("nse_symbol", "")).upper())
               or companies_by_key.get(str(c.get("name", "")).casefold()))
        if cid:
            links.append({"story_id": story["id"], "company_id": cid})
    if links:
        sb("POST", "story_companies", json=links, headers={"Prefer": "resolution=ignore-duplicates"})
    return story


def main():
    load_env()
    from ai import (AIError, QuotaExhausted, editor_pass, process_story,
                    usage_report)  # after env load

    sources = sb("GET", "sources?select=*&is_active=eq.true")
    companies_by_key = {}
    for c in sb("GET", "companies?select=id,name,nse_symbol,aliases"):
        if c.get("nse_symbol"):
            companies_by_key[c["nse_symbol"].upper()] = c["id"]
        companies_by_key[c["name"].casefold()] = c["id"]
        for a in c.get("aliases") or []:
            companies_by_key[a.casefold()] = c["id"]

    since = (datetime.now(timezone.utc) - timedelta(hours=48)).strftime("%Y-%m-%dT%H:%M:%SZ")
    # Oldest first, one entry per cluster: the seed decides what the cluster is
    # about (see cluster_of). Loading every member is what let clusters chain.
    recent, seen_clusters = [], set()
    for r in sb("GET", f"stories?select=cluster_id,headline&created_at=gte.{since}"
                       "&order=created_at.asc"):
        if r["cluster_id"] not in seen_clusters:
            seen_clusters.add(r["cluster_id"])
            recent.append((r["cluster_id"], title_tokens(r["headline"])))

    items, fetched_source_ids = [], []
    for s in sources:
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

    # Two ceilings: this run's share, and what's left of today's free quota.
    # The daily one only started mattering once the poller ran continuously —
    # 3800 passes/day against a ~3000-call budget would spend the day by 02:00
    # and leave the feed frozen until midnight.
    cap = min(MAX_AI_CALLS_PER_RUN, remaining_budget_today())
    skipped = max(0, len(to_process) - cap)
    to_process = to_process[:cap]
    print(f"{len(items)} fetched, {len(fresh)} new -> {len(to_process)} to AI, "
          f"{len(dupes)} duplicates, {len(noise)} low-value (both free)"
          + (f", {skipped} deferred to next run (cap {cap})" if skipped else ""))

    def base_row(item, cid):
        return {"url": item["url"], "url_hash": item["url_hash"], "cluster_id": cid,
                "headline": item["headline"], "source_name": item["source"]["name"],
                "source_url": item["url"], "image_url": item["image_url"],
                # No usable date from the source => stamp ingestion time. The app
                # filters the feed on published_at, and NULL fails that filter, so
                # an undated story was silently invisible forever — which had
                # swallowed every BSE filing and most SEBI/RBI releases, i.e. the
                # highest-authority primary sources the product exists to surface.
                "published_at": item["published_at"] or datetime.now(timezone.utc).isoformat()}

    for status, batch in (("duplicate", dupes), ("rejected", noise)):
        for item, cid in batch:
            try:
                insert_story({**base_row(item, cid), "status": status}, companies_by_key)
            except requests.RequestException as e:
                print(f"{status.upper()} INSERT FAIL {item['url_hash'][:8]}: {e}")

    # Concurrent AI; ai.py's per-lane throttle keeps the free tier happy.
    # Hard wall-clock budget: when only one model lane is live the throttle caps
    # throughput at ~15/min, so a full cap could outlast the job timeout and kill
    # the run before alerts and auto-approve ever execute. Past the deadline the
    # remaining stories defer exactly like a quota block — nothing is lost.
    processed = flagged = dropped = quota_blocked = 0
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
            try:
                insert_story({
                    **base,
                    "hook": card["hook"], "headline": card["headline_rewrite"],
                    "summary": card["summary"],
                    "impact_direction": imp["direction"], "impact_strength": imp["strength"],
                    "impact_horizon": imp["horizon"], "impact_score": imp["score"],
                    "confidence": card["confidence"], "category": card["category"],
                    "sectors": card["sectors"],
                    "status": ("approved" if live_now else "pending") if keep else "rejected",
                }, companies_by_key, card)
            except requests.RequestException as e:  # never lose the whole run to one row
                print(f"INSERT FAIL {item['source']['name']}: {e}")
                continue
            processed += 1 if keep else 0
            dropped += 0 if keep else 1

    if fetched_source_ids:
        ids = ",".join(str(i) for i in fetched_source_ids)
        sb("PATCH", f"sources?id=in.({ids})",
           json={"last_fetched_at": datetime.now(timezone.utc).isoformat()})

    releveled = chief_editor(editor_pass)
    alerted = alert_engine({s["name"]: s["authority"] for s in sources})
    healed = retry_flagged(process_story, AIError, QuotaExhausted, companies_by_key)
    disabled = disable_dead_sources()
    revived = revive_sources()
    approved = auto_approve()
    print(f"done: {processed} pending, {dropped} dropped (not India-relevant), {flagged} flagged"
          + (f", {quota_blocked} awaiting quota (retry next run)" if quota_blocked else "")
          + f" | editor: {releveled} releveled | alerts: {alerted} sent | "
          f"self-heal: {healed} recovered, {disabled} retired, {revived} revived, {approved} auto-approved")
    served = usage_report()
    if served:  # which lane actually carried the run — silent failover is visible
        print("AI served by: " + ", ".join(f"{m}={n}" for m, n in
                                           sorted(served.items(), key=lambda kv: -kv[1])))


if __name__ == "__main__":
    # LOOP_SECONDS unset -> one run and exit (GitHub Actions). Set it -> stay
    # resident and poll, for an always-on host. main() is idempotent, so a
    # crashed run costs nothing but the interval.
    loop_seconds = int(os.environ.get("LOOP_SECONDS", "0"))
    # LOOP_MAX_SECONDS bounds the process so a cron-launched poller exits before
    # the next one starts; unset means run forever (always-on host).
    deadline = int(os.environ.get("LOOP_MAX_SECONDS", "0"))
    if not loop_seconds:
        main()
    else:
        started = time.monotonic()
        while True:
            try:
                main()
            except Exception:
                traceback.print_exc()  # never let one bad run kill the poller
            if deadline and time.monotonic() - started + loop_seconds > deadline:
                print("loop deadline reached; exiting for the next scheduled run")
                break
            time.sleep(loop_seconds)
