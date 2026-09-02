"""Signals layer (2026-09-02, from the worldmonitor study): keyword spikes,
source-convergence confidence, unusual-coverage flags, and news<->market move
context — computed each lap from the in-memory 48h story window run.py already
holds, published as market_blobs `trending` and `move_context`. Costs zero
extra story reads and zero AI calls.

Strictly DOWNSTREAM of clustering: nothing here feeds back into cluster_of()
or token weighting — corpus-frequency weighting was tried inside clustering
and removed for hurting merge quality (run.py, note near assign_cluster).
Display and alerts only.

No import of run.py (it imports us): helpers the window logic owns
(title_tokens, PUBLISHER) are passed in as arguments.
"""
from datetime import datetime, timedelta, timezone

import market  # write_blobs; market.py imports neither run nor signals

SPIKE_FLOOR = 4        # distinct mentions in 6h before a term can spike
SPIKE_RATIO = 2.5      # 6h rate must exceed this x the prior-42h rate
SPIKE_MIN_OUTLETS = 3  # independent newsrooms — one prolific feed can't fake it
SPIKE_CAP = 8          # blob keeps the strongest few, not a tag cloud
UNUSUAL_MIN_OUTLETS = 4
MOVER_MIN_PCT = 3.0    # an equity move worth explaining
COUNT_STATUSES = ("approved", "pending", "duplicate")  # dupes ARE corroboration

# Provenance class per NEWSROOM (post-PUBLISHER collapse). Everything absent is
# "media" — the default must be the common case, not a guess. ponytail: a dict
# until it outgrows one screen, same deal as run.PUBLISHER.
SOURCE_TYPE = {
    "SEBI": "gov", "RBI Press": "gov", "RBI Notifications": "gov",
    "RBI Speeches": "gov", "PIB Finance Ministry": "gov",
    "NSE": "exchange", "BSE": "exchange",
    "Reuters": "wire", "PTI": "wire",
}


def source_type(newsroom):
    return SOURCE_TYPE.get(newsroom, "media")


def confidence(source_names, authority, publisher):
    """low | med | high for the set of sources carrying one signal:
    independent-newsroom count x type diversity x best authority."""
    pubs = {publisher(n) for n in source_names}
    types = {source_type(p) for p in pubs}
    top = max((authority.get(n, 5) for n in source_names), default=5)
    if len(pubs) >= 3 and (len(types) >= 2 or top >= 9):
        return "high"
    if len(pubs) >= 2:
        return "med"
    return "low"


def detect_spikes(window, now, publisher, tokens_of, authority):
    """Terms mentioned materially more in the last 6h than their own prior-42h
    rate predicts, carried by several independent newsrooms.
    ponytail: the baseline is the window's own prior 42h, not a persisted 7d
    census — upgrade to stored daily counts only if this proves too twitchy."""
    cut = now - timedelta(hours=6)
    six, prior, sources6, best_story = {}, {}, {}, {}
    for r in window:
        if r.get("status") not in COUNT_STATUSES:
            continue
        ts = datetime.fromisoformat(r["created_at"].replace("Z", "+00:00"))
        toks = tokens_of(r.get("headline") or "")
        for t in toks:
            if ts >= cut:
                six[t] = six.get(t, 0) + 1
                sources6.setdefault(t, set()).add(r.get("source_name") or "")
                # the spike's tap-through story: newest approved beats pending
                cur = best_story.get(t)
                rank = (r["status"] == "approved", r["created_at"])
                if r["status"] in ("approved", "pending") and (cur is None or rank > cur[0]):
                    best_story[t] = (rank, r["id"])
            else:
                prior[t] = prior.get(t, 0) + 1
    out = []
    for t, n in six.items():
        if n < SPIKE_FLOOR or t not in best_story:
            continue
        # prior floor of one mention/42h: a cold term is judged by SPIKE_FLOOR alone
        ratio = (n / 6.0) / (max(prior.get(t, 0), 1) / 42.0)
        names = sources6[t]
        if ratio < SPIKE_RATIO or len({publisher(s) for s in names}) < SPIKE_MIN_OUTLETS:
            continue
        out.append({"term": t, "count": n, "ratio": round(ratio, 1),
                    "outlets": len({publisher(s) for s in names}),
                    "confidence": confidence(names, authority, publisher),
                    "story_id": best_story[t][1]})
    # one term per story: "adani" and "ports" spiking off the same event is one row
    out.sort(key=lambda s: -s["ratio"])
    seen, deduped = set(), []
    for s in out:
        if s["story_id"] in seen:
            continue
        seen.add(s["story_id"])
        deduped.append(s)
    return deduped[:SPIKE_CAP]


def unusual_story_ids(window, publisher):
    """Approved stories whose cluster is carried by unusually many independent
    newsrooms — the client badges these. Newest first, bounded."""
    clusters = {}
    for r in window:
        if r.get("status") in COUNT_STATUSES and r.get("cluster_id"):
            clusters.setdefault(r["cluster_id"], []).append(r)
    ids = []
    for rows in clusters.values():
        if len({publisher(r.get("source_name") or "") for r in rows}) < UNUSUAL_MIN_OUTLETS:
            continue
        approved = [r for r in rows if r["status"] == "approved"]
        if approved:
            ids.append(max(approved, key=lambda r: r["created_at"])["id"])
    return sorted(ids, reverse=True)[:20]


def move_context(movers, links, window):
    """movers: [(symbol, chg_pct)]; links: [(company_symbol, story_id)] for the
    last 24h. Each big mover is 'explained' (a tagged story exists) or
    'unexplained' (silent divergence — price moved, no news we carry)."""
    by_id = {r["id"]: r for r in window}
    story_for = {}
    for sym, sid in links:
        r = by_id.get(sid)
        if r and r.get("status") == "approved":
            cur = story_for.get(sym)
            if cur is None or r["created_at"] > cur["created_at"]:
                story_for[sym] = r
    explained, unexplained = [], []
    for sym, chg in movers:
        r = story_for.get(sym)
        if r:
            explained.append({"symbol": sym, "chg": chg, "story_id": r["id"],
                              "title": r.get("headline") or ""})
        else:
            unexplained.append({"symbol": sym, "chg": chg})
    return {"explained": explained, "unexplained": unexplained}


# ---------- lap orchestration (throttled; failures never block news) ----------

_last = {}  # blob -> utc datetime of last successful build

def _due(name, now, minutes):
    at = _last.get(name)
    return at is None or (now - at) >= timedelta(minutes=minutes)


def refresh(sb, window, authority, companies_by_key, publisher, tokens_of, now=None):
    """Build due signal blobs. window = run.recent_stories() output. Returns
    {"spikes": n, "moves": n} for the lap counts."""
    now = now or datetime.now(timezone.utc)
    counts = {}
    if _due("trending", now, 5):
        try:
            pub = lambda n: publisher(n)  # noqa: E731
            payload = {"spikes": detect_spikes(window, now, pub, tokens_of, authority),
                       "unusual_story_ids": unusual_story_ids(window, pub),
                       "computed_at": now.isoformat()}
            market.write_blobs(sb, [{"key": "trending", "payload": payload,
                                     "updated_at": now.isoformat()}])
            _last["trending"] = now
            counts["spikes"] = len(payload["spikes"])
        except Exception as e:  # noqa: BLE001
            print(f"SIGNALS FAIL trending: {e}")
    if _due("move_context", now, 10):
        try:
            rows = sb("GET", "quotes?select=symbol,change_pct&kind=eq.equity")
            movers = [(r["symbol"], r["change_pct"]) for r in rows
                      if r.get("change_pct") is not None and abs(r["change_pct"]) >= MOVER_MIN_PCT]
            links = []
            if movers:
                sym_by_cid = {}
                for sym, _ in movers:
                    cid = companies_by_key.get(sym.upper())
                    if cid:
                        sym_by_cid[cid] = sym
                if sym_by_cid:
                    since = (now - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
                    cids = ",".join(str(c) for c in sym_by_cid)
                    for l in sb("GET", "story_companies?select=story_id,company_id,"
                                       "stories!inner(created_at)"
                                       f"&stories.created_at=gte.{since}&company_id=in.({cids})"):
                        links.append((sym_by_cid[l["company_id"]], l["story_id"]))
            payload = {**move_context(movers, links, window), "computed_at": now.isoformat()}
            market.write_blobs(sb, [{"key": "move_context", "payload": payload,
                                     "updated_at": now.isoformat()}])
            _last["move_context"] = now
            counts["moves"] = len(payload["explained"]) + len(payload["unexplained"])
        except Exception as e:  # noqa: BLE001
            print(f"SIGNALS FAIL move_context: {e}")
    return counts
