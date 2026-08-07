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
MAX_AI_CALLS_PER_RUN = int(os.environ.get("MAX_AI_CALLS_PER_RUN", "60"))
AI_CONCURRENCY = int(os.environ.get("AI_CONCURRENCY", "6"))
AUTO_APPROVE_MINUTES = 5    # unreviewed score < 8 goes live after this (owner's call)
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


def title_tokens(title):
    return {w for w in re.findall(r"[a-z0-9]+", title.lower()) if w not in STOPWORDS}


# AI budget is ~500 calls/day/model; spending it on grey-market-premium updates
# is what starved the real news. These are stored 'rejected' (visible in admin),
# never silently dropped, and never sent to the AI.
LOW_VALUE = re.compile(
    r"grey market premium|\bGMP\b|subscription status|allotment status"
    r"|IPO day \d|day \d+ of (?:bidding|subscription)"
    r"|top (?:gainers|losers)|multibagger|penny stock"
    r"|stocks? to (?:watch|buy)|trade spotlight|f&o ban", re.I)


def prioritized(items):
    """Interleave sources so the per-run cap can never starve one (the old
    flat slice spent every run on the first 5 feeds and 21 sources never
    published). Highest-authority source first in each round, newest first
    within a source, so regulators and breaking news reach the AI soonest."""
    by_source = {}
    for i in items:
        by_source.setdefault(i["source"]["name"], []).append(i)
    for queue in by_source.values():
        queue.sort(key=lambda i: i["published_at"] or "", reverse=True)
    rounds = sorted(by_source.values(),
                    key=lambda q: -(q[0]["source"].get("authority") or 5))
    return [i for tier in zip_longest(*rounds) for i in tier if i is not None]


def assign_cluster(title, recent):
    """recent: list of (cluster_id, token_set). Jaccard >= 0.5 joins the cluster.
    ponytail: O(n) scan vs ~48h of stories (~200 rows) — fine; revisit with
    embeddings/minhash only if volume grows 100x."""
    tokens = title_tokens(title)
    if tokens:
        for cid, other in recent:
            if other and len(tokens & other) / len(tokens | other) >= 0.5:
                return cid
    return str(uuid.uuid4())


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


def send_fcm(hook, headline, story_id):
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
                          "data": {"story_id": str(story_id)}}},
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
        cluster_size = len(sb("GET", f"stories?select=id&cluster_id=eq.{s['cluster_id']}"))
        age_minutes = (now - parse_ts(s["created_at"])).total_seconds() / 60
        if not gate_passes(s["impact_score"], cluster_size,
                           authority_by_source.get(s["source_name"], 5), age_minutes):
            continue
        patch = {"status": "approved"}
        if may_push(s["impact_score"], now, sent_today + alerted):
            send_fcm(s["hook"] or s["headline"], s["headline"], s["id"])
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
        sb("PATCH", f"stories?id=eq.{out['top_story_id']}", json={"is_featured": True})
    return len(out["relevel"])


# ---------- self-healing (retry flagged, disable dead feeds, auto-approve) ----------

def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(s):
    """Postgres timestamptz -> aware datetime. Naive input is treated as UTC."""
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def retry_flagged(process_story, AIError, companies_by_key):
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
    """A feed that hasn't succeeded in 3 days is dead — deactivate it so it stops
    wasting run time; visible (and re-enablable) in the admin health tab."""
    cutoff = iso(datetime.now(timezone.utc) - timedelta(days=3))
    dead = sb("PATCH", f"sources?is_active=eq.true&last_fetched_at=lt.{cutoff}",
              json={"is_active": False}, headers={"Prefer": "return=representation"})
    for s in dead or []:
        print(f"SELF-HEAL: disabled dead source {s['name']}")
    return len(dead or [])


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
    from ai import AIError, QuotaExhausted, editor_pass, process_story  # after env load

    sources = sb("GET", "sources?select=*&is_active=eq.true")
    companies_by_key = {}
    for c in sb("GET", "companies?select=id,name,nse_symbol,aliases"):
        if c.get("nse_symbol"):
            companies_by_key[c["nse_symbol"].upper()] = c["id"]
        companies_by_key[c["name"].casefold()] = c["id"]
        for a in c.get("aliases") or []:
            companies_by_key[a.casefold()] = c["id"]

    since = (datetime.now(timezone.utc) - timedelta(hours=48)).strftime("%Y-%m-%dT%H:%M:%SZ")
    recent = [(r["cluster_id"], title_tokens(r["headline"]))
              for r in sb("GET", f"stories?select=cluster_id,headline&created_at=gte.{since}")]

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
        cid = assign_cluster(item["headline"], recent)
        known = any(cid == c for c, _ in recent)
        recent.append((cid, title_tokens(item["headline"])))
        if known:
            dupes.append((item, cid))
        elif LOW_VALUE.search(item["headline"]):
            noise.append((item, cid))
        else:
            to_process.append((item, cid))

    skipped = max(0, len(to_process) - MAX_AI_CALLS_PER_RUN)
    to_process = to_process[:MAX_AI_CALLS_PER_RUN]
    print(f"{len(items)} fetched, {len(fresh)} new -> {len(to_process)} to AI, "
          f"{len(dupes)} duplicates, {len(noise)} low-value (both free)"
          + (f", {skipped} deferred to next run (cap {MAX_AI_CALLS_PER_RUN})" if skipped else ""))

    def base_row(item, cid):
        return {"url": item["url"], "url_hash": item["url_hash"], "cluster_id": cid,
                "headline": item["headline"], "source_name": item["source"]["name"],
                "source_url": item["url"], "image_url": item["image_url"],
                "published_at": item["published_at"]}

    for status, batch in (("duplicate", dupes), ("rejected", noise)):
        for item, cid in batch:
            try:
                insert_story({**base_row(item, cid), "status": status}, companies_by_key)
            except requests.RequestException as e:
                print(f"{status.upper()} INSERT FAIL {item['url_hash'][:8]}: {e}")

    # Concurrent AI; ai.py's shared throttle keeps the free tier happy.
    processed = flagged = dropped = quota_blocked = 0
    with ThreadPoolExecutor(max_workers=AI_CONCURRENCY) as pool:
        futures = {pool.submit(process_story, item["source"]["name"],
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
            try:
                insert_story({
                    **base,
                    "hook": card["hook"], "headline": card["headline_rewrite"],
                    "summary": card["summary"],
                    "impact_direction": imp["direction"], "impact_strength": imp["strength"],
                    "impact_horizon": imp["horizon"], "impact_score": imp["score"],
                    "confidence": card["confidence"], "category": card["category"],
                    "sectors": card["sectors"],
                    "status": "pending" if keep else "rejected",
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
    healed = retry_flagged(process_story, AIError, companies_by_key)
    disabled = disable_dead_sources()
    approved = auto_approve()
    print(f"done: {processed} pending, {dropped} dropped (not India-relevant), {flagged} flagged"
          + (f", {quota_blocked} awaiting quota (retry next run)" if quota_blocked else "")
          + f" | editor: {releveled} releveled | alerts: {alerted} sent | "
          f"self-heal: {healed} recovered, {disabled} sources disabled, {approved} auto-approved")


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
