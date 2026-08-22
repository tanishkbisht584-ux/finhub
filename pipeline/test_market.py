"""market.py: pure-function checks, no network. Run: cd pipeline && py -3 -m pytest test_market.py"""
import pathlib
import re
from datetime import datetime, timedelta, timezone

import market
from market import IST

UTC = timezone.utc


def ist(y, m, d, hh, mm):
    return datetime(y, m, d, hh, mm, tzinfo=IST).astimezone(UTC)


# ---------- Yahoo spark ----------

SPARK = {
    "TCS.NS": {"timestamp": [1786938300, 1787024700, 1787197500, 1787283900],
               "chartPreviousClose": 2313.2, "close": [2313.2, 2280.0, 2298.0, 2302.0]},
    "M&M.NS": {"timestamp": [1787283900], "chartPreviousClose": 3400.0, "close": [3434.0]},
    "GAPPY.NS": {"timestamp": [1, 2, 3], "chartPreviousClose": 10.0, "close": [None, 11.0, None]},
    "EMPTY.NS": {"timestamp": [], "chartPreviousClose": None, "close": []},
}


def test_parse_spark_uses_last_two_closes():
    p = market.parse_spark(SPARK["TCS.NS"])
    assert p.price == 2302.0 and p.prev == 2298.0
    assert p.change_pct == round((2302.0 - 2298.0) / 2298.0 * 100, 2)
    assert p.as_of == datetime.fromtimestamp(1787283900, tz=UTC).isoformat()
    assert p.closes == [2313.2, 2280.0, 2298.0, 2302.0]


def test_parse_spark_single_close_falls_back_to_chart_previous_close():
    p = market.parse_spark(SPARK["M&M.NS"])
    assert p.prev == 3400.0 and p.change_pct == 1.0


def test_parse_spark_skips_nulls_and_empty():
    assert market.parse_spark(SPARK["GAPPY.NS"]).price == 11.0
    assert market.parse_spark(SPARK["EMPTY.NS"]) is None


def test_fetch_spark_batches_by_20_and_passes_ampersand_via_params(monkeypatch):
    calls = []

    class R:
        ok = True

        def raise_for_status(self):
            pass

        def json(self):
            return {s: SPARK["M&M.NS"] for s in calls[-1]["symbols"].split(",")}

    monkeypatch.setattr(market.requests, "get",
                        lambda url, params, headers, timeout: calls.append(params) or R())
    monkeypatch.setattr(market.time, "sleep", lambda s: None)
    syms = [f"S{i}.NS" for i in range(25)] + ["M&M.NS"]
    out = market.fetch_spark(syms)
    assert len(calls) == 2 and calls[0]["symbols"].count(",") == 19
    assert "M&M.NS" in calls[1]["symbols"]  # requests encodes it; the key comes back raw
    assert set(out) == set(syms)


def test_fetch_spark_one_bad_batch_does_not_sink_the_rest(monkeypatch):
    n = {"i": 0}

    def get(url, params, headers, timeout):
        n["i"] += 1
        if n["i"] == 1:
            raise market.requests.ConnectionError("boom")

        class R:
            def raise_for_status(self):
                pass

            def json(self):
                return {"X.NS": SPARK["M&M.NS"]}
        return R()

    monkeypatch.setattr(market.requests, "get", get)
    monkeypatch.setattr(market.time, "sleep", lambda s: None)
    assert market.fetch_spark([f"S{i}.NS" for i in range(21)]) == {"X.NS": SPARK["M&M.NS"]}


# ---------- cadence ----------

def test_equity_cadence_is_15_min_in_market_hours_else_60():
    assert market.interval_minutes("equity", ist(2026, 8, 21, 10, 0)) == 15   # Friday 10:00
    assert market.interval_minutes("equity", ist(2026, 8, 21, 15, 44)) == 15  # post-close pass
    assert market.interval_minutes("equity", ist(2026, 8, 21, 15, 46)) == 60
    assert market.interval_minutes("equity", ist(2026, 8, 22, 10, 0)) == 60   # Saturday
    assert market.interval_minutes("fxcom", ist(2026, 8, 22, 10, 0)) == 15


def test_due_runs_once_per_interval(monkeypatch):
    monkeypatch.setattr(market, "_last_run", {})
    t0 = ist(2026, 8, 21, 10, 0)
    assert market.due("equity", t0)
    market._last_run["equity"] = t0
    assert not market.due("equity", t0 + timedelta(minutes=14))
    assert market.due("equity", t0 + timedelta(minutes=15))


def test_mf_due_once_per_nav_day_after_2230_ist(monkeypatch):
    monkeypatch.setattr(market, "_last_run", {})
    assert market.due("mf", ist(2026, 8, 21, 10, 0))          # never run -> seed now
    market._last_run["mf"] = ist(2026, 8, 21, 10, 0)
    assert not market.due("mf", ist(2026, 8, 21, 22, 0))      # same NAV day, before post
    assert market.due("mf", ist(2026, 8, 21, 22, 31))         # today's NAV is out
    market._last_run["mf"] = ist(2026, 8, 21, 22, 31)
    assert not market.due("mf", ist(2026, 8, 22, 9, 0))       # still yesterday's slot


# ---------- universe ----------

def test_equity_universe_followed_first_then_tagged_capped(monkeypatch):
    def sb(method, path, **kw):
        if path.startswith("follows"):
            return [{"target_id": "1"}, {"target_id": "2"}, {"target_id": "x"}]
        if path.startswith("story_companies"):
            return [{"company_id": 2}, {"company_id": 3}, {"company_id": 4}]
        if path.startswith("companies"):
            ids = re.search(r"id=in\.\(([^)]*)\)", path).group(1).split(",")
            return [{"id": int(i), "nse_symbol": f"C{i}", "name": f"Co {i}"} for i in ids]
        raise AssertionError(path)

    monkeypatch.setattr(market, "EQUITY_CAP", 3)
    syms = market.equity_universe(sb, datetime(2026, 8, 22, tzinfo=UTC))
    assert [s for s, _ in syms] == ["C1", "C2", "C3"]  # followed first, cap honoured


# ---------- rows / upsert ----------

def test_gold_in_inr_per_10g_is_derived_and_labelled():
    gc = market.Parsed(4624.1, 4516.3, 2.39, "2026-08-21T00:00:00+00:00", [4516.3, 4624.1])
    usdinr = market.Parsed(95.7, 95.8, -0.1, "2026-08-21T00:00:00+00:00", [95.8, 95.7])
    r = market.gold_inr_row(gc, usdinr, datetime(2026, 8, 22, tzinfo=UTC))
    assert r["symbol"] == "GOLD_INR_10G" and r["kind"] == "commodity"
    assert r["price"] == round(4624.1 * 95.7 / market.TROY_OZ_G * 10)
    assert r["meta"]["derived"] and "ex-duty" in r["meta"]["label"]
    assert r["change_pct"] == 2.39  # gold's own move; the FX leg is noise here


def test_upsert_chunks_and_sets_updated_at(monkeypatch):
    seen = []
    rows = [market.row(f"S{i}", "equity", f"Co {i}", market.parse_spark(SPARK["TCS.NS"]),
                       now=datetime(2026, 8, 22, tzinfo=UTC)) for i in range(150)]
    n = market.upsert(lambda m, p, **kw: seen.append((m, p, kw)), rows)
    assert n == 150 and len(seen) == 2
    assert seen[0][1] == "quotes?on_conflict=symbol"
    assert seen[0][2]["headers"]["Prefer"].startswith("resolution=merge-duplicates")
    assert all(r["updated_at"].startswith("2026-08-22") for r in seen[0][2]["json"])
    assert rows[0]["closes"] is None  # equities carry no sparkline


def test_kinds_match_the_migration_check():
    sql = pathlib.Path(__file__).with_name("migrations").joinpath("011_market_upgrade.sql").read_text()
    allowed = set(re.findall(r"'(\w+)'", re.search(r"kind in\s*\(([^)]*)\)", sql).group(1)))
    assert market.KINDS <= allowed


def test_refresh_isolates_a_failing_group(monkeypatch):
    monkeypatch.setattr(market, "_last_run", {})
    ran = []

    def ok(name):
        def fn(sb, now):
            ran.append(name)
            return 1
        return fn

    def bad(sb, now):
        raise RuntimeError("yahoo down")

    monkeypatch.setattr(market, "GROUPS", (("index", bad), ("fxcom", ok("fxcom")), ("crypto", ok("crypto"))))
    now = datetime(2026, 8, 22, 10, 0, tzinfo=UTC)
    counts = market.refresh(lambda *a, **k: [], now)
    assert counts == {"fxcom": 1, "crypto": 1} and ran == ["fxcom", "crypto"]
    assert set(market._last_run) == {"index", "fxcom", "crypto"}  # a failure waits its interval too


def test_market_is_an_admin_switch():
    from run import SWITCHES
    assert "market" in SWITCHES
