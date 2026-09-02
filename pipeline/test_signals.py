"""signals.py: pure-function checks, no network. Run: cd pipeline && py -3 -m pytest test_signals.py"""
from datetime import datetime, timedelta, timezone

import signals

UTC = timezone.utc
NOW = datetime(2026, 9, 2, 12, 0, tzinfo=UTC)
AUTH = {"Reuters": 9, "ET Markets": 8, "Blog": 5, "SEBI": 10}

def pub(n):
    return {"ET Markets": "Economic Times", "ET Top Stories": "Economic Times"}.get(n, n)

def toks(title):
    return {w for w in title.lower().split() if len(w) > 2}

def row(i, headline, hours_ago, source="Reuters", status="approved", cluster="c1"):
    return {"id": i, "headline": headline, "source_name": source, "status": status,
            "cluster_id": cluster,
            "created_at": (NOW - timedelta(hours=hours_ago)).isoformat()}


# ---------- confidence ----------

def test_confidence_needs_independent_newsrooms_and_diversity():
    # two ET feeds are ONE newsroom -> low
    assert signals.confidence({"ET Markets", "ET Top Stories"}, AUTH, pub) == "low"
    assert signals.confidence({"Reuters", "Blog"}, AUTH, pub) == "med"
    # 3 newsrooms, gov+wire+media diversity -> high
    assert signals.confidence({"Reuters", "SEBI", "Blog"}, AUTH, pub) == "high"
    # 3 newsrooms all media, but a top-authority outlet carries it -> high
    assert signals.confidence({"Reuters", "Blog", "Mint"}, AUTH, pub) == "high"
    assert signals.confidence(set(), AUTH, pub) == "low"


# ---------- spikes ----------

def test_detect_spikes_gates_on_floor_ratio_and_outlets():
    window = []
    # "adani" carried 4x in the last 6h by 3 newsrooms, silent before -> spike
    for i, src in enumerate(["Reuters", "Mint", "Blog", "Reuters"]):
        window.append(row(100 + i, "adani ports probe", 1 + i * 0.5, source=src))
    # "results" mentioned steadily across the whole window -> no spike
    for i in range(12):
        window.append(row(200 + i, "quarterly results season", 2 + i * 3.5, cluster=f"r{i}"))
    # "solo" repeated by one outlet only -> no spike (fails outlet gate)
    for i in range(5):
        window.append(row(300 + i, "solo scoop repeated", 1 + i * 0.5, source="Blog", cluster=f"s{i}"))
    out = signals.detect_spikes(window, NOW, pub, toks, AUTH)
    assert [s["term"] for s in out] and all(s["term"] in ("adani", "ports", "probe") for s in out)
    assert out[0]["outlets"] == 3 and out[0]["count"] == 4
    assert out[0]["story_id"] in (100, 101, 102, 103)
    # one term per story: adani/ports/probe collapse to a single row
    assert len(out) == 1
    assert out[0]["confidence"] in ("med", "high")


def test_detect_spikes_excludes_rejected_and_needs_a_publishable_story():
    window = [row(1, "junk term flood", 1, status="rejected", cluster=f"j{i}") for i in range(6)]
    assert signals.detect_spikes(window, NOW, pub, toks, AUTH) == []
    # duplicates corroborate but cannot be the tap-through story on their own
    dupes = [row(10 + i, "ghost event story", 1, source=f"S{i}", status="duplicate")
             for i in range(4)]
    assert signals.detect_spikes(dupes, NOW, pub, toks, AUTH) == []
    # add one approved member -> the spike lands on it
    out = signals.detect_spikes(dupes + [row(9, "ghost event story", 1)], NOW, pub, toks, AUTH)
    assert out and out[0]["story_id"] == 9


# ---------- unusual coverage ----------

def test_unusual_story_ids_counts_independent_newsrooms_per_cluster():
    window = [row(1, "big event", 2, source="Reuters"),
              row(2, "big event", 1.5, source="Mint", status="duplicate"),
              row(3, "big event", 1.2, source="Blog", status="duplicate"),
              row(4, "big event", 1.0, source="SEBI", status="duplicate"),
              # 4 rows but two are the same newsroom -> only 3 independent, out
              row(5, "small event", 1, source="ET Markets", cluster="c2"),
              row(6, "small event", 1, source="ET Top Stories", status="duplicate", cluster="c2"),
              row(7, "small event", 1, source="Mint", status="duplicate", cluster="c2"),
              row(8, "small event", 1, source="Blog", status="duplicate", cluster="c2")]
    assert signals.unusual_story_ids(window, pub) == [1]


# ---------- move context ----------

def test_move_context_splits_explained_and_unexplained():
    window = [row(50, "TCS wins mega deal", 3), row(51, "TCS follow-up", 30)]
    movers = [("TCS", 4.2), ("INFY", -3.5)]
    links = [("TCS", 50), ("TCS", 51)]
    out = signals.move_context(movers, links, window)
    assert out["explained"] == [{"symbol": "TCS", "chg": 4.2, "story_id": 50,
                                 "title": "TCS wins mega deal"}]
    assert out["unexplained"] == [{"symbol": "INFY", "chg": -3.5}]


def test_move_context_ignores_links_to_unapproved_stories():
    window = [row(60, "rumour piece", 2, status="pending")]
    out = signals.move_context([("TCS", 5.0)], [("TCS", 60)], window)
    assert out["explained"] == [] and out["unexplained"] == [{"symbol": "TCS", "chg": 5.0}]


# ---------- refresh orchestration ----------

def test_refresh_throttles_and_isolates_failures(monkeypatch):
    monkeypatch.setattr(signals, "_last", {})
    writes = []
    monkeypatch.setattr(signals.market, "write_blobs", lambda sb, rows: writes.append(rows) or 1)

    def sb(method, path, **kw):
        if path.startswith("quotes"):
            return [{"symbol": "TCS", "change_pct": 4.0}, {"symbol": "INFY", "change_pct": 0.2}]
        if path.startswith("story_companies"):
            return [{"story_id": 50, "company_id": 7}]
        raise AssertionError(path)

    window = [row(50, "TCS wins mega deal", 3)]
    counts = signals.refresh(sb, window, AUTH, {"TCS": 7}, pub, toks, now=NOW)
    assert counts == {"spikes": 0, "moves": 1}
    keys = [r["key"] for rows in writes for r in rows]
    assert keys == ["trending", "move_context"]
    move = writes[1][0]["payload"]
    assert move["explained"][0]["symbol"] == "TCS" and move["computed_at"] == NOW.isoformat()
    # 4 minutes later: both throttled, nothing written, no reads made
    counts2 = signals.refresh(lambda *a, **k: (_ for _ in ()).throw(AssertionError("no reads")),
                              window, AUTH, {}, pub, toks, now=NOW + timedelta(minutes=4))
    assert counts2 == {} and len(writes) == 2
    # trending due at 5 min even when the move quotes read would fail
    counts3 = signals.refresh(lambda *a, **k: (_ for _ in ()).throw(RuntimeError("db down")),
                              window, AUTH, {}, pub, toks, now=NOW + timedelta(minutes=6))
    assert "spikes" in counts3 and "moves" not in counts3
