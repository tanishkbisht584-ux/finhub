"""Unit tests per spec §10: dedupe hashing, clustering, schema validation. No network."""
import pytest

from ai import validate
from run import assign_cluster, canonical_url, title_tokens, url_hash


def test_url_hash_strips_tracking_and_normalizes():
    a = url_hash("https://ET.com/story/1?utm_source=rss&utm_medium=x&gclid=abc")
    b = url_hash("https://et.com/story/1/")
    assert a == b
    assert url_hash("https://et.com/story/2") != a


def test_canonical_keeps_real_query():
    assert "id=100" in canonical_url("https://cnbc.com/rss?id=100&utm_source=x")


def test_cluster_same_story_joins_different_story_does_not():
    recent = [("cluster-1", title_tokens("RBI cuts repo rate by 25 bps"))]
    assert assign_cluster("RBI cuts repo rate 25 bps, first cut this year", recent) == "cluster-1"
    assert assign_cluster("Infosys Q1 profit rises 11 percent", recent) != "cluster-1"


CARD = {
    "hook": "Oil just got scary",
    "headline_rewrite": "Crude spikes 8% after supply shock",
    "summary": "s",
    "impact": {"direction": "negative", "strength": 3, "horizon": "short_term", "score": 9},
    "companies": [{"name": "ONGC", "nse_symbol": "ONGC"}],
    "sectors": ["Energy"],
    "category": "Commodities",
    "is_india_relevant": True,
    "confidence": "high",
}


def test_validate_accepts_good_card():
    assert validate(CARD) is CARD


@pytest.mark.parametrize("patch", [
    {"impact": {**CARD["impact"], "score": 11}},
    {"impact": {**CARD["impact"], "direction": "bullish"}},
    {"category": "Sports"},
    {"confidence": "certain"},
    {"is_india_relevant": "yes"},
])
def test_validate_rejects_bad_cards(patch):
    with pytest.raises(ValueError):
        validate({**CARD, **patch})


def test_prioritized_interleaves_sources_by_authority():
    from run import prioritized
    et = {"name": "ET", "authority": 8}
    rbi = {"name": "RBI", "authority": 10}
    items = [{"source": et, "published_at": f"2026-08-0{i}"} for i in range(1, 4)]
    items += [{"source": rbi, "published_at": "2026-08-01"}]
    out = prioritized(items)
    # highest authority leads, then every source gets a turn before ET's seconds
    assert out[0]["source"]["name"] == "RBI"
    assert out[1]["source"]["name"] == "ET"
    # newest first within a source
    assert [i["published_at"] for i in out if i["source"]["name"] == "ET"] == [
        "2026-08-03", "2026-08-02", "2026-08-01"]
    assert len(out) == len(items)  # nothing dropped


def test_alert_gate():
    from run import gate_passes
    assert gate_passes(8, 2, 5)        # multi-source confirmed
    assert gate_passes(9, 1, 10)       # primary source (RBI/exchange)
    assert not gate_passes(8, 1, 8)    # single-source non-primary waits for admin
    assert not gate_passes(7, 3, 10)   # below impact threshold
    assert not gate_passes(None, 3, 10)


def test_independent_sources_ignores_same_newsroom():
    from run import independent_sources
    # one newsroom's two feeds must not look like corroboration
    assert independent_sources(["ET Markets", "ET Top Stories"]) == 1
    assert independent_sources(["ET Markets", "LiveMint Markets"]) == 2
    assert independent_sources(["ET Markets", "ET IPO", "RBI Press"]) == 2
    assert independent_sources(["SEBI"]) == 1


def test_filing_noise_filter():
    from run import FILING_NOISE
    assert FILING_NOISE.search("Closure of Trading Window")
    assert FILING_NOISE.search("Certificate under Regulation 74(5)")
    assert not FILING_NOISE.search("Board approves acquisition of ABC Ltd")


def test_validate_rejects_missing_field():
    bad = dict(CARD)
    del bad["hook"]
    with pytest.raises(ValueError):
        validate(bad)
