"""FinSwipe M1 pipeline: fetch feeds -> normalize -> dedupe -> cluster ->
Gemini card -> insert 'pending' into Supabase. Idempotent: url_hash re-checked
every run, so re-processing is a no-op."""
import hashlib
import os
import pathlib
import re
import time
import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import quote_plus, urlsplit, urlunsplit, parse_qsl, urlencode

import feedparser
import requests

MAX_STORIES_PER_RUN = int(os.environ.get("MAX_STORIES_PER_RUN", "40"))
AI_CALL_GAP_SECONDS = 5  # free-tier RPM throttle (spec §5)
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
    r.raise_for_status()
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
    for e in feedparser.parse(resp.content).entries:
        link, title = e.get("link"), (e.get("title") or "").strip()
        if not link or not title:
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


# ---------- self-healing (retry flagged, disable dead feeds, auto-approve) ----------

def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


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
        healed += 1
        time.sleep(AI_CALL_GAP_SECONDS)
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
    """Spec §9: score < 7 auto-approves after 2h unreviewed; score >= 8 single-source
    stays pending for the admin queue."""
    cutoff = iso(datetime.now(timezone.utc) - timedelta(hours=2))
    rows = sb("PATCH", f"stories?status=eq.pending&impact_score=lt.7&created_at=lt.{cutoff}",
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
    from ai import AIError, process_story  # after env load

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
            items += fetch_items(s)
            fetched_source_ids.append(s["id"])
        except Exception as e:  # one dead feed never blocks the rest (spec §10)
            print(f"FEED FAIL {s['name']}: {e}")

    seen = existing_hashes([i["url_hash"] for i in items])
    fresh, batch_hashes = [], set()
    for i in items:
        if i["url_hash"] not in seen and i["url_hash"] not in batch_hashes:
            fresh.append(i)
            batch_hashes.add(i["url_hash"])
    fresh = fresh[:MAX_STORIES_PER_RUN]
    print(f"{len(items)} fetched, {len(fresh)} new (cap {MAX_STORIES_PER_RUN})")

    processed = flagged = dropped = 0
    for item in fresh:
        s = item["source"]
        base = {
            "url": item["url"], "url_hash": item["url_hash"],
            "cluster_id": assign_cluster(item["headline"], recent),
            "headline": item["headline"], "source_name": s["name"],
            "source_url": item["url"], "image_url": item["image_url"],
            "published_at": item["published_at"],
        }
        try:
            card = process_story(s["name"], item["headline"], item["body"])
        except AIError as e:
            insert_story({**base, "status": "flagged", "raw_ai_error": str(e)}, companies_by_key)
            flagged += 1
            continue
        imp = card["impact"]
        keep = card["is_india_relevant"] or (card["category"] == "Geopolitics" and imp["score"] >= 6)
        story = insert_story({
            **base,
            "hook": card["hook"], "headline": card["headline_rewrite"],
            "summary": card["summary"],
            "impact_direction": imp["direction"], "impact_strength": imp["strength"],
            "impact_horizon": imp["horizon"], "impact_score": imp["score"],
            "confidence": card["confidence"], "category": card["category"],
            "sectors": card["sectors"],
            "status": "pending" if keep else "rejected",
        }, companies_by_key, card)
        recent.append((story["cluster_id"], title_tokens(item["headline"])))
        processed += 1 if keep else 0
        dropped += 0 if keep else 1
        time.sleep(AI_CALL_GAP_SECONDS)

    if fetched_source_ids:
        ids = ",".join(str(i) for i in fetched_source_ids)
        sb("PATCH", f"sources?id=in.({ids})",
           json={"last_fetched_at": datetime.now(timezone.utc).isoformat()})

    healed = retry_flagged(process_story, AIError, companies_by_key)
    disabled = disable_dead_sources()
    approved = auto_approve()
    print(f"done: {processed} pending, {dropped} dropped (not India-relevant), {flagged} flagged | "
          f"self-heal: {healed} recovered, {disabled} sources disabled, {approved} auto-approved")


if __name__ == "__main__":
    main()
