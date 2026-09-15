"""stockanalysis group: mapping (SA-owned columns only, two upsert buckets),
probe/watermark short-circuit, full pull + blobs. Session is faked; no network."""
from datetime import date, datetime, timezone

import pytest

import market
import stockanalysis as sa

NOW = datetime(2026, 9, 12, 12, 0, tzinfo=timezone.utc)


def site_row(sym, **kw):
    base = {"s": f"NSE-{sym}", "n": f"{sym} Ltd", "sector": "Energy", "industry": "Oil & Gas Refining",
            "priceDate": "2026-09-11",
            "dollarVolume": 11038003020, "ch1y": -8.678294, "ch1w": -4.87897, "allTimeHighChange": -21.98,
            "allTimeHigh": 1611.8, "allTimeHighDate": "2026-01-05", "fScore": 3, "nextEarningsDate": "2026-09-20",
            "analystRatings": None, "isin": ""}
    base.update(kw)
    return base


class R:
    def __init__(self, rows):
        self.rows = rows

    def raise_for_status(self):
        pass

    def json(self):
        return {"status": 200, "data": {"data": self.rows, "resultsCount": len(self.rows)}}


class S:
    """Fake session: records every call; cn=1 is the probe."""
    def __init__(self, price_date, rows):
        self.price_date, self.rows, self.calls = price_date, rows, []

    def get(self, url, params=None, headers=None, timeout=None):
        self.calls.append(params)
        if params["cn"] == 1:
            return R([{"s": "NSE-RELIANCE", "priceDate": self.price_date}])
        return R(self.rows)


def test_sa_rows_maps_rounds_filters_and_buckets():
    raw = {"RELIANCE": site_row("RELIANCE"), "M_M": site_row("M_M", ch1y=12.345),
           "BAD SYM": site_row("BAD SYM"), "X_Y": site_row("X_Y")}
    rows = {r["symbol"]: r for r in sa.sa_rows(raw, {"RELIANCE"}, NOW, known={"RELIANCE", "M&M"})}
    assert set(rows) == {"RELIANCE", "M&M"}                       # M_M resolved; BAD SYM + unknown X_Y dropped
    ril, mm = rows["RELIANCE"], rows["M&M"]
    assert ril["turnover_cr"] == round(11038003020 / 1e7, 2) and ril["ret_1y"] == -8.68
    assert ril["ret_3y"] is None and ril["f_score"] == 3
    assert ril["sa"] == {"allTimeHigh": 1611.8, "allTimeHighDate": "2026-01-05",
                         "nextEarningsDate": "2026-09-20"}       # None/"" dropped
    assert ril["sa_price_date"] == "2026-09-11" and ril["sa_at"] == NOW.isoformat()
    assert set(mm) - set(ril) == {"name"} and mm["name"] == "M_M Ltd"
    assert ril["sector"] == "Energy" and ril["industry"] == "Oil & Gas Refining"  # peer keys on every row
    for owned in ("pe", "pb", "de", "opm", "roe", "price", "mcap_cr"):
        assert owned not in ril                                     # never ours


def test_refresh_short_circuits_when_probe_equals_watermark():
    s = S("2026-09-11", [site_row("RELIANCE")])
    posts = []

    def sb(method, path, **kw):
        if method == "GET":
            return [{"sa_price_date": "2026-09-11"}]
        posts.append(path)

    assert sa.refresh_stockanalysis(sb, NOW, session=s) == 0
    assert len(s.calls) == 1 and s.calls[0]["cn"] == 1 and s.calls[0]["c"] == "s,priceDate"
    assert posts == []


def test_refresh_full_pull_writes_two_buckets_and_blobs(monkeypatch):
    monkeypatch.setattr(market, "_blob_sent", {})
    s = S("2026-09-11", [site_row("RELIANCE"), site_row("TCS"), site_row("NEWCO", ch1y=None)])
    posts = []

    def sb(method, path, **kw):
        if method == "GET" and "sa_price_date" in path:
            return [{"sa_price_date": "2026-09-10"}]
        if method == "GET" and path.startswith("companies"):
            return [{"nse_symbol": "TCS"}, {"nse_symbol": None}]
        if method == "GET":
            return [{"symbol": "RELIANCE"}, {"symbol": "TCS"}]
        posts.append((path, kw["json"]))

    assert sa.refresh_stockanalysis(sb, NOW, session=s) == 3
    metrics = [rows for p, rows in posts if p == "screener_metrics?on_conflict=symbol"]
    assert sorted(len(b) for b in metrics) == [1, 2]              # existing bucket + new-row bucket
    new = next(b for b in metrics if len(b) == 1)[0]
    assert new["symbol"] == "NEWCO" and new["name"] == "NEWCO Ltd" and new["ret_1y"] is None
    (blobs,) = [rows for p, rows in posts if p == "market_blobs?on_conflict=key"]
    assert {b["key"] for b in blobs} == {"earnings_calendar", "records"}


def test_sa_blobs_window_and_records():
    raw = {"A": site_row("A", nextEarningsDate="2026-09-26", allTimeHighChange=-0.2, ch1y=5),
           "B": site_row("B", nextEarningsDate="2026-09-27", allTimeHighChange=-3, ch1y=-5),
           "C": site_row("C", nextEarningsDate="2026-09-12", allTimeHighChange=0, ch1y=1),
           "D": site_row("D", nextEarningsDate=None, allTimeHighChange=-40, ch1y=None)}
    cal, rec = sa.sa_blobs(raw, NOW, date(2026, 9, 12))
    assert [e["symbol"] for e in cal["payload"]] == ["C", "A"]    # 14-day window inclusive, sorted; B outside
    assert rec["payload"] == {"ath": ["A", "C"], "near_ath_pct": 75.0, "up_1y_pct": 50.0,
                              "asof": "2026-09-11"}


@pytest.mark.parametrize("site,known,out", [
    ("M_M", {"M&M"}, "M&M"), ("BAJAJ_AUTO", {"BAJAJ-AUTO"}, "BAJAJ-AUTO"),
    ("NAM.INDIA", {"NAM-INDIA"}, "NAM-INDIA"), ("IL_FSENGG", {"IL&FSENGG"}, "IL&FSENGG"),
    ("RELIANCE", set(), "RELIANCE"), ("X_Y", {"X&Z"}, None), ("BAD SYM", {"BAD SYM"}, None)])
def test_resolve_symbol(site, known, out):
    assert sa.resolve_symbol(site, known) == out


def test_columns_cover_every_mapped_id():
    cols = set(sa.COLUMNS.split(","))
    assert set(sa.NUM) <= cols and set(sa.SA_KEYS) <= cols
    assert {"n", "sector", "industry", "priceDate", "dollarVolume"} <= cols


@pytest.mark.parametrize("v,scale,out", [(None, 1, None), (True, 1, None), ("x", 1, None),
                                         (12.3456, 1, 12.35), (11038003020, 1e7, 1103.8)])
def test_num(v, scale, out):
    assert sa._num(v, scale) == out
