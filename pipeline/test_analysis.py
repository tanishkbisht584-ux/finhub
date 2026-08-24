"""market.py v0.20.0: fundamentals (Yahoo quoteSummary), technicals (computed),
NSE flows. Pure checks, no network. Run: cd pipeline && py -3 -m pytest test_analysis.py"""
import math
from datetime import datetime, timedelta, timezone

import market
from market import IST

UTC = timezone.utc
NOW = datetime(2026, 8, 23, 12, 0, tzinfo=UTC)


def ist(y, m, d, hh, mm):
    return datetime(y, m, d, hh, mm, tzinfo=IST).astimezone(UTC)


# ---------- fundamentals ----------

QS = {"quoteSummary": {"result": [{
    "summaryDetail": {"trailingPE": {"raw": 16.722359}, "forwardPE": {"raw": 14.172454},
                      "marketCap": {"raw": 8328837070848}, "dividendYield": {"raw": 0.0282}},
    "defaultKeyStatistics": {"priceToBook": {"raw": 7.5970087}, "trailingEps": {"raw": 137.66}, "beta": {"raw": 0.164}},
    "financialData": {"returnOnEquity": {"raw": 0.47743}, "debtToEquity": {"raw": 10.211}, "profitMargins": {"raw": 0.18052},
                      "revenueGrowth": {"raw": 0.139}, "earningsGrowth": {"raw": 0.046}, "targetMeanPrice": {"raw": 2460.0488},
                      "recommendationKey": "buy"},
    "incomeStatementHistoryQuarterly": {"incomeStatementHistory": [
        {"endDate": {"fmt": "2026-06-30"}, "totalRevenue": {"raw": 722750000000}, "netIncome": {"raw": 133490000000}},
        {"endDate": {"fmt": "2026-03-31"}, "totalRevenue": {"raw": 706980000000}, "netIncome": {"raw": 137180000000}}]},
    "majorHoldersBreakdown": {"insidersPercentHeld": {"raw": 0.71794}, "institutionsPercentHeld": {"raw": 0.17663}},
    "assetProfile": {"sector": "Technology", "industry": "Information Technology Services"},
}], "error": None}}


def test_parse_fundamentals_maps_and_rounds():
    f = market.parse_fundamentals(QS)
    assert f["pe"] == 16.72 and f["fwd_pe"] == 14.17 and f["pb"] == 7.6 and f["eps"] == 137.66
    assert f["div_yield"] == 2.8 and f["roe"] == 47.7 and f["margin"] == 18.1
    assert f["de"] == 0.1                      # Yahoo reports debt/equity in percent
    assert f["rev_growth"] == 13.9 and f["earn_growth"] == 4.6
    assert f["target"] == 2460.05 and f["rec"] == "buy"
    assert f["promoter_pct"] == 71.8 and f["inst_pct"] == 17.7
    assert f["sector"] == "Technology" and f["quarters"][0] == {"end": "2026-06-30", "revenue": 722750000000, "net_income": 133490000000}
    assert len(f["quarters"]) == 2 and f["mcap"] == 8328837070848


def test_parse_fundamentals_tolerates_missing_modules():
    assert market.parse_fundamentals({"quoteSummary": {"result": [{"summaryDetail": {"trailingPE": {}}}]}}) == {}
    assert market.parse_fundamentals({"quoteSummary": {"result": None, "error": {"code": "Not Found"}}}) == {}
    assert market.parse_fundamentals({}) == {}


def test_yahoo_session_caches_crumb_and_rejects_html(monkeypatch):
    calls = []

    class R:
        def __init__(self, text):
            self.text = text

        def raise_for_status(self):
            pass

    class S:
        def __init__(self):
            self.headers = {}

        def get(self, url, timeout=None, **kw):
            calls.append(url)
            return R("<html>consent</html>" if "bad" in url else "AbCd1234")

    monkeypatch.setattr(market.requests, "Session", S)
    monkeypatch.setattr(market, "_yahoo", {"session": None, "crumb": None})
    s, crumb = market.yahoo_session()
    assert crumb == "AbCd1234" and len(calls) == 2          # fc.yahoo + getcrumb
    s2, crumb2 = market.yahoo_session()
    assert s2 is s and len(calls) == 2                       # cached
    monkeypatch.setattr(market, "_yahoo", {"session": None, "crumb": None})
    monkeypatch.setattr(market, "CRUMB_URL", "https://bad/getcrumb")
    try:
        market.yahoo_session()
        assert False, "html crumb accepted"
    except RuntimeError:
        pass


# ---------- technicals ----------

def _series(n, start=100.0, step=0.5):
    return [round(start + i * step, 2) for i in range(n)]


def test_compute_technicals_on_a_rising_series():
    closes = _series(260)            # 260 bars, steady climb 100 -> 229.5
    vols = [1000] * 259 + [2600]
    t = market.compute_technicals(closes, vols)
    assert t["sma20"] == round(sum(closes[-20:]) / 20, 2)
    assert t["sma50"] and t["sma200"] and t["sma50"] > t["sma200"]
    assert 60 <= t["rsi14"] <= 100                      # only gains -> RSI 100
    assert t["hi52"] == 229.5 and t["lo52"] == 100.0 and t["pos52"] == 1.0
    assert t["vol_ratio"] == round(2600 / (sum(vols[-20:]) / 20), 2)
    assert t["above200"] is True and t["trend"] == "up"
    # a perfectly linear ramp converges MACD to its signal: hist -> 0
    assert t["macd_hist"] == 0.0 and t["vs50"] > 0 and t["vs200"] > 0
    assert t["close"] == 229.5


def test_compute_technicals_falling_and_short_series():
    closes = _series(260, start=300, step=-0.5)
    t = market.compute_technicals(closes, None)
    assert t["trend"] == "down" and t["above200"] is False and t["pos52"] == 0.0
    assert 0 <= t["rsi14"] <= 40 and "vol_ratio" not in t
    short = market.compute_technicals(_series(30), [1] * 30)
    assert "sma200" not in short and "sma50" not in short and short["sma20"] is not None
    assert short["trend"] == "mixed" and "above200" not in short
    assert market.compute_technicals([], []) == {}
    assert market.compute_technicals([100.0, None, 101.0], None)["close"] == 101.0


def test_rsi_is_50_for_alternating_equal_moves():
    closes = [100 + (i % 2) for i in range(60)]          # +1, -1, +1 ...
    t = market.compute_technicals(closes, None)
    assert abs(t["rsi14"] - 50) < 3  # Wilder smoothing tilts toward the latest move


# ---------- meta merge / cadence / row ----------

def test_equity_price_row_omits_meta_so_analysis_survives_refresh():
    p = market.Parsed(100.0, 99.0, 1.01, "2026-08-21T00:00:00+00:00", [99.0, 100.0])
    r = market.row("TCS", "equity", "TCS", p, NOW)
    assert "meta" not in r
    r2 = market.row("bitcoin", "crypto", "Bitcoin", p, NOW, meta={"usd": 1})
    assert r2["meta"] == {"usd": 1}


def test_merge_meta_updates_only_known_rows_and_keeps_other_keys(monkeypatch):
    written = []

    def sb(method, path, **kw):
        if method == "GET":
            return [{"symbol": "TCS", "kind": "equity", "name": "TCS", "price": 1, "meta": {"t": {"rsi14": 60}}},
                    {"symbol": "INFY", "kind": "equity", "name": "Infosys", "price": 2, "meta": None}]
        written.extend(kw["json"])

    n = market.merge_meta(sb, {"TCS": {"pe": 16}, "INFY": {"pe": 20}, "NOPE": {"pe": 1}}, "f", NOW)
    assert n == 2 and {w["symbol"] for w in written} == {"TCS", "INFY"}
    tcs = next(w for w in written if w["symbol"] == "TCS")
    assert tcs["meta"]["t"] == {"rsi14": 60} and tcs["meta"]["f"] == {"pe": 16}
    assert tcs["meta"]["f_at"] == NOW.isoformat() and tcs["price"] == 1 and tcs["kind"] == "equity"


def test_stale_filter_skips_symbols_refreshed_recently():
    fresh = (NOW - timedelta(hours=3)).isoformat()
    old = (NOW - timedelta(hours=30)).isoformat()
    existing = {"A": {"f_at": fresh}, "B": {"f_at": old}, "C": {}}
    assert market.needs_refresh(["A", "B", "C", "D"], existing, "f_at", NOW) == ["B", "C", "D"]


def test_analysis_groups_are_slotted_daily(monkeypatch):
    monkeypatch.setattr(market, "_last_run", {})
    assert market.due("fundamentals", ist(2026, 8, 21, 10, 0))          # never run
    market._last_run["fundamentals"] = ist(2026, 8, 21, 10, 0)
    assert not market.due("fundamentals", ist(2026, 8, 21, 16, 0))      # before the close slot
    assert market.due("fundamentals", ist(2026, 8, 21, 16, 31))         # close slot opened
    market._last_run["technicals"] = ist(2026, 8, 21, 16, 16)
    assert not market.due("technicals", ist(2026, 8, 22, 9, 0))         # same slot (yesterday's close)
    assert market.due("technicals", ist(2026, 8, 22, 16, 16))
    assert [g for g, _ in market.GROUPS][-4:] == ["fundamentals", "technicals", "macro", "nse"]


# ---------- flows ----------

def test_parse_fiidii_and_option_chain():
    fii = [{"buyValue": "15258.71", "category": "DII", "date": "21-Aug-2026", "netValue": "2124.14", "sellValue": "13134.57"},
           {"buyValue": "12560.91", "category": "FII/FPI", "date": "21-Aug-2026", "netValue": "-542.71", "sellValue": "13103.62"}]
    f = market.parse_fiidii(fii)
    assert f["fii"] == {"buy": 12560.91, "sell": 13103.62, "net": -542.71} and f["dii"]["net"] == 2124.14 and f["date"] == "21-Aug-2026"
    oc = {"records": {"underlyingValue": 24252, "data": [
        {"strikePrice": 24200, "CE": {"openInterest": 100}, "PE": {"openInterest": 300}},
        {"strikePrice": 24300, "CE": {"openInterest": 500}, "PE": {"openInterest": 400}},
        {"strikePrice": 24400, "CE": {"openInterest": 200}}]},
          "filtered": {"CE": {"totOI": 2708660}, "PE": {"totOI": 2918695}}}
    o = market.parse_option_chain(oc, "25-Aug-2026")
    assert o["pcr"] == round(2918695 / 2708660, 2) and o["underlying"] == 24252 and o["expiry"] == "25-Aug-2026"
    assert o["max_oi_strike"] == 24300 and o["ce_oi"] == 2708660
    assert market.nearest_expiry({"expiryDates": ["25-Aug-2026", "01-Sep-2026"]}) == "25-Aug-2026"
    assert market.breadth([{"index": "NIFTY 50", "advances": "25", "declines": "24"}, {"index": "NIFTY 500", "advances": "240", "declines": "255"}, {"index": "NIFTY IT"}]) == \
        {"NIFTY 50": {"adv": 25, "dec": 24}, "NIFTY 500": {"adv": 240, "dec": 255}}


def test_refresh_nse_blobs_writes_flows_and_survives_partial_failure():
    class R:
        def __init__(self, payload, ok=True):
            self.p, self.ok_ = payload, ok
            self.headers = {"content-type": "application/json" if ok else "text/html"}
            self.status_code = 200 if ok else 404

        def raise_for_status(self):
            if not self.ok_:
                raise market.requests.HTTPError("404")

        def json(self):
            return self.p

    class S:
        def get(self, url, params=None, timeout=None):
            tail = url.rsplit("/", 1)[1]
            return {
                "allIndices": R({"data": [{"key": "BROAD MARKET INDICES", "index": "NIFTY 50", "last": 1, "percentChange": 0.1, "advances": "25", "declines": "24"}]}),
                "event-calendar": R([]), "corporate-board-meetings": R([]),
                "snapshot-capital-market-largedeal": R({"as_on_date": "x", "BULK_DEALS_DATA": [], "BLOCK_DEALS_DATA": []}),
                "corporates-pit-gg": R({"data": []}),
                "fiidiiTradeReact": R([{"buyValue": "1", "category": "FII/FPI", "date": "d", "netValue": "-1", "sellValue": "2"}]),
                "option-chain-contract-info": R(None, ok=False),   # PCR unavailable today
            }[tail]

    written = []

    def sb(method, path, **kw):
        if method == "GET":
            if path.startswith("market_blobs"):
                return []
            return [{"nse_symbol": "TCS"}]
        written.extend(kw["json"])

    market.refresh_nse_blobs(sb, NOW, session=S())
    flows = next(r for r in written if r["key"] == "flows")["payload"]
    assert flows["fii"]["net"] == -1.0 and flows["breadth"]["NIFTY 50"] == {"adv": 25, "dec": 24}
    assert "pcr" not in flows                                  # missing piece, not a missing blob
    assert {r["key"] for r in written} == {"results_calendar", "bulk_deals", "insider_trades", "nse_indices", "flows"}


# ---------- on-demand backfill (analysis_requests) ----------

def _req_sb(requests_rows, companies, quotes, log):
    """sb stub that records every call and reflects the given tables."""
    def sb(method, path, **kw):
        log.append((method, path))
        if method == "GET":
            if path.startswith("analysis_requests"):
                return requests_rows
            if path.startswith("companies"):
                return companies
            if path.startswith("quotes"):
                return quotes
            return []
        return None
    return sb


def test_refresh_analysis_new_creates_row_and_merges_both_metas(monkeypatch):
    log, upserts = [], []
    sb = _req_sb([{"symbol": "ABC"}], [{"nse_symbol": "ABC", "name": "ABC Ltd"}], [], log)
    monkeypatch.setattr(market, "fetch_spark",
                        lambda syms: {"ABC.NS": {"timestamp": [1], "close": [10.0],
                                                 "chartPreviousClose": 9.0}})
    monkeypatch.setattr(market, "upsert",
                        lambda sb_, rows, **kw: upserts.append(rows) or len(rows))
    monkeypatch.setattr(market, "fetch_fundamentals_for",
                        lambda syms: {"ABC": {"pe": 10.0}} if syms == ["ABC"] else {})
    monkeypatch.setattr(market, "fetch_technicals_for",
                        lambda syms: {"ABC": {"rsi14": 50.0}} if syms == ["ABC"] else {})
    merged = []
    monkeypatch.setattr(market, "merge_meta",
                        lambda sb_, updates, key, now: merged.append((key, updates)) or 1)
    n = market.refresh_analysis_new(sb, NOW)
    assert n == 2
    assert "meta" not in upserts[0][0]                       # _OMIT invariant holds
    assert [k for k, _ in merged] == ["f", "t"]
    # served request KEPT (only the 48 h prune delete fired)
    deletes = [p for m, p in log if m == "DELETE"]
    assert len(deletes) == 1 and deletes[0].startswith("analysis_requests?requested_at=lt.")


def test_refresh_analysis_new_prunes_invalid_and_urlquotes(monkeypatch):
    log = []
    sb = _req_sb([{"symbol": "M&M"}, {"symbol": "NOPE"}],
                 [{"nse_symbol": "OTHER", "name": "Other"}], [], log)
    monkeypatch.setattr(market, "fetch_spark", lambda syms: {})
    n = market.refresh_analysis_new(sb, NOW)
    assert n == 0
    deletes = [p for m, p in log if m == "DELETE"]
    assert "analysis_requests?symbol=eq.M%26M" in deletes    # & never hits the URL raw
    assert "analysis_requests?symbol=eq.NOPE" in deletes


def test_refresh_analysis_new_partial_failure_retries_only_missing_half(monkeypatch):
    calls = {"f": [], "t": []}
    sb = _req_sb([{"symbol": "ABC"}], [{"nse_symbol": "ABC", "name": "ABC Ltd"}],
                 [{"symbol": "ABC", "meta": {"t": {"rsi14": 50}, "t_at": NOW.isoformat()}}], [])
    monkeypatch.setattr(market, "fetch_fundamentals_for",
                        lambda syms: calls["f"].append(list(syms)) or {})   # Yahoo down
    monkeypatch.setattr(market, "fetch_technicals_for",
                        lambda syms: calls["t"].append(list(syms)) or {})
    assert market.refresh_analysis_new(sb, NOW) == 0
    assert calls["f"] == [["ABC"]] and calls["t"] == [[]]    # fresh t_at skipped


def test_refresh_analysis_new_served_symbol_costs_nothing(monkeypatch):
    fetched = []
    sb = _req_sb([{"symbol": "ABC"}], [{"nse_symbol": "ABC", "name": "ABC Ltd"}],
                 [{"symbol": "ABC", "meta": {"f_at": NOW.isoformat(), "t_at": NOW.isoformat()}}], [])
    monkeypatch.setattr(market, "fetch_fundamentals_for", lambda syms: fetched.append(list(syms)) or {})
    monkeypatch.setattr(market, "fetch_technicals_for", lambda syms: fetched.append(list(syms)) or {})
    monkeypatch.setattr(market, "fetch_spark", lambda syms: (_ for _ in ()).throw(AssertionError("no spark")))
    assert market.refresh_analysis_new(sb, NOW) == 0
    assert fetched == [[], []]


def test_equity_universe_orders_followed_requested_tagged_and_caps(monkeypatch):
    def sb(method, path, **kw):
        if path.startswith("follows"):
            return [{"target_id": "1"}]
        if path.startswith("story_companies"):
            return [{"company_id": 2}, {"company_id": 1}]
        if path.startswith("analysis_requests"):
            return [{"symbol": "M&M"}]
        if path.startswith("companies?select=id"):
            return [{"id": 1, "nse_symbol": "AAA", "name": "A"},
                    {"id": 2, "nse_symbol": "BBB", "name": "B"}]
        if path.startswith("companies?select=nse_symbol"):
            assert "M%26M" in path                           # quoted in.() value
            return [{"nse_symbol": "M&M", "name": "Mahindra"}]
        raise AssertionError(path)
    out = market.equity_universe(sb, NOW)
    assert out == [("AAA", "A"), ("M&M", "Mahindra"), ("BBB", "B")]
    monkeypatch.setattr(market, "EQUITY_CAP", 2)
    assert market.equity_universe(sb, NOW) == [("AAA", "A"), ("M&M", "Mahindra")]
