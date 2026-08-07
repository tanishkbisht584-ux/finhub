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


def test_validate_rejects_missing_field():
    bad = dict(CARD)
    del bad["hook"]
    with pytest.raises(ValueError):
        validate(bad)
