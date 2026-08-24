"""Keyed news-API fetchers + quota-paced polling (run.py, phase 2). No network.
Run: cd pipeline && py -3 -m pytest test_sources.py"""
import pathlib
import re
from datetime import datetime, timedelta, timezone

import pytest

import run

NOW = datetime(2026, 8, 22, 12, 0, tzinfo=timezone.utc)
# The fetchers judge staleness against the real clock, so these must be
# relative — hardcoded dates rotted after two days.
FRESH = (datetime.now(timezone.utc) - timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
OLD = (datetime.now(timezone.utc) - timedelta(days=21)).strftime("%Y-%m-%dT%H:%M:%SZ")
SRC = {"id": 1, "name": "GNews.io Markets IN", "type": "gnews_api", "feed_url": "nifty", "authority": 6}

ITEM_KEYS = {"source", "url", "url_hash", "headline", "body", "image_url", "published_at"}


class _R:
    def __init__(self, payload):
        self._p = payload

    def raise_for_status(self):
        pass

    def json(self):
        return self._p


@pytest.fixture
def api(monkeypatch):
    """Stub requests.get with a payload and capture the params sent."""
    monkeypatch.setenv("GNEWS_API_KEY", "g1,g2")
    monkeypatch.setenv("NEWSDATA_API_KEY", "n1")
    monkeypatch.setenv("MARKETAUX_API_KEY", "m1")
    monkeypatch.setattr(run, "_key_turn", {})
    calls = []

    def install(payload):
        monkeypatch.setattr(run.requests, "get",
                            lambda url, params, headers, timeout: calls.append((url, params)) or _R(payload))
        return calls
    return install


def test_gnews_shapes_items_and_drops_stale(api):
    calls = api({"articles": [
        {"title": "Nifty ends flat", "url": "https://a/1", "description": "d", "image": "https://i/1.jpg",
         "publishedAt": FRESH, "source": {"name": "Moneycontrol"}},
        {"title": "Old", "url": "https://a/2", "publishedAt": OLD},
        {"title": "", "url": "https://a/3", "publishedAt": FRESH},
    ]})
    items = run.fetch_gnews_api(SRC)
    assert len(items) == 1 and set(items[0]) == ITEM_KEYS
    assert items[0]["image_url"] == "https://i/1.jpg" and items[0]["url_hash"] == run.url_hash("https://a/1")
    assert items[0]["published_at"] == FRESH.replace("Z", "+00:00")
    assert calls[0][1]["q"] == "nifty" and calls[0][1]["country"] == "in"


def test_newsdata_and_marketaux_field_maps(api):
    api({"results": [{"title": "RBI holds", "link": "https://n/1", "description": "d",
                      "image_url": None, "pubDate": FRESH.replace("T", " ").replace("Z", "")}]})
    nd = run.fetch_newsdata({**SRC, "type": "newsdata", "feed_url": "business"})
    assert nd[0]["url"] == "https://n/1" and nd[0]["image_url"] is None
    assert nd[0]["published_at"] == FRESH.replace("Z", "+00:00")
    calls = api({"data": [{"title": "TCS Q1", "url": "https://m/1", "description": "d",
                           "image_url": "https://m/i.jpg", "published_at": FRESH.replace("Z", ".000000Z"),
                           "entities": [{"symbol": "TCS.NSE"}]}]})
    ma = run.fetch_marketaux({**SRC, "type": "marketaux", "feed_url": ""})
    assert ma[0]["headline"] == "TCS Q1" and "search" not in calls[-1][1]


def test_api_key_rotates_and_fails_loud(api, monkeypatch):
    assert [run.api_key("GNEWS_API_KEY") for _ in range(3)] == ["g1", "g2", "g1"]
    monkeypatch.delenv("GNEWS_API_KEY")
    with pytest.raises(RuntimeError):
        run.api_key("GNEWS_API_KEY")


def test_parse_api_ts_variants():
    assert run.parse_api_ts(None) is None
    assert run.parse_api_ts("garbage") is None
    assert run.parse_api_ts("2026-08-22T10:00:00Z").tzinfo is not None
    assert run.parse_api_ts("2026-08-22 10:00:00").hour == 10


def test_due_for_poll_paces_keyed_apis_only():
    rss = {"type": "rss", "last_fetched_at": NOW.isoformat()}
    assert run.due_for_poll(rss, NOW)                                   # RSS: every loop
    g = {"type": "gnews_api", "last_fetched_at": (NOW - timedelta(minutes=10)).isoformat()}
    assert not run.due_for_poll(g, NOW)
    g["last_fetched_at"] = (NOW - timedelta(minutes=31)).isoformat()
    assert run.due_for_poll(g, NOW)
    assert run.due_for_poll({"type": "gnews_api", "last_fetched_at": None}, NOW)  # never fetched


def test_source_types_agree_across_migration_admin_and_fetchers():
    here = pathlib.Path(__file__).parent
    sql = (here / "migrations" / "011_market_upgrade.sql").read_text(encoding="utf-8")
    allowed = set(re.findall(r"'(\w+)'", re.search(r"\btype in\s*\(([^)]*)\)", sql, re.S).group(1)))
    admin = here.parent / "admin" / "pages" / "3_Sources.py"
    if admin.exists():
        types = set(re.findall(r'"(\w+)"', re.search(r"TYPES = \[([^\]]*)\]", admin.read_text(encoding="utf-8"), re.S).group(1)))
        assert types == allowed
    assert set(run.FETCHERS) <= allowed
    assert set(run.POLL_MIN) <= allowed
    seed = (here / "seed" / "sources_seed.sql").read_text(encoding="utf-8")
    assert set(re.findall(r"',\s*'(\w+)',\s*'", seed)) <= allowed
