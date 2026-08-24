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
    assert market.interval_minutes("nse", ist(2026, 8, 22, 10, 0)) == 60
    assert market.interval_minutes("macro", ist(2026, 8, 22, 10, 0)) == 1440


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
        if path.startswith("analysis_requests"):
            return []
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
    sql = pathlib.Path(__file__).with_name("migrations").joinpath("011_market_upgrade.sql").read_text(encoding="utf-8")
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


def test_all_groups_registered():
    assert [g for g, _ in market.GROUPS] == ["index", "equity", "fxcom", "crypto", "mf", "mf_new",
                                             "analysis_new", "fundamentals", "technicals",
                                             "macro", "nse"]


def test_refresh_mf_new_fetches_only_unquoted_follows(monkeypatch):
    fetched = []
    monkeypatch.setattr(market, "fetch_mf_rows", lambda sb, codes, now: fetched.append(codes) or len(codes))

    def sb(method, path, **kw):
        if path.startswith("quotes"):
            return [{"symbol": "MF:120503"}]
        return [{"target_id": "120503"}, {"target_id": "999"}, {"target_id": "x"}]

    assert market.refresh_mf_new(sb, datetime(2026, 8, 22, tzinfo=UTC)) == 1
    assert fetched == [[999]]
    monkeypatch.setattr(market, "followed_mf", lambda sb: [120503])
    assert market.refresh_mf_new(sb, datetime(2026, 8, 22, tzinfo=UTC)) == 0  # nothing new, no fetch


# ---------- phase 3: MF ----------

MF = {"meta": {"fund_house": "Axis Mutual Fund", "scheme_category": "Equity Scheme - ELSS",
               "scheme_name": "Axis ELSS Tax Saver Fund - Direct Plan - Growth Option"},
      # newest first, 300 days: nav climbs 100 -> 130 one per day
      "data": [{"date": (datetime(2026, 8, 21) - timedelta(days=i)).strftime("%d-%m-%Y"),
                "nav": f"{130 - i * 0.1:.4f}"} for i in range(300)]}


def test_parse_mf_closes_returns_and_name():
    p, meta = market.parse_mf(MF)
    assert p.price == 130.0 and p.prev == 129.9 and len(p.closes) == 30
    assert p.closes[0] < p.closes[-1]  # oldest first
    assert p.as_of.startswith("2026-08-21")
    assert meta["ret_1m"] == round((130 / (130 - 2.1) - 1) * 100, 1)
    assert meta["ret_1y"] == round((130 / (130 - 25.0) - 1) * 100, 1)
    assert market.short_mf_name(MF["meta"]["scheme_name"]) == "Axis ELSS Tax Saver Fund"
    assert market.parse_mf({"data": [{"date": "bad", "nav": "x"}]}) is None


def test_refresh_mf_merges_followed_schemes(monkeypatch):
    seen = {"codes": [], "rows": []}

    class R:
        def __init__(self, code):
            self.code = code

        def raise_for_status(self):
            pass

        def json(self):
            return MF

    monkeypatch.setattr(market.requests, "get",
                        lambda url, headers, timeout: seen["codes"].append(int(url.rsplit("/", 1)[1])) or R(url))
    monkeypatch.setattr(market.time, "sleep", lambda s: None)

    def sb(method, path, **kw):
        if method == "GET":
            return [{"target_id": "999"}, {"target_id": "120503"}, {"target_id": "nope"}]
        seen["rows"] += kw["json"]

    n = market.refresh_mf(sb, datetime(2026, 8, 22, tzinfo=UTC))
    assert n == len(market.DEFAULT_MF) + 1 and 999 in seen["codes"]
    r = seen["rows"][0]
    assert r["symbol"].startswith("MF:") and r["kind"] == "mf" and len(r["closes"]) == 30
    assert r["meta"]["scheme_code"] == market.DEFAULT_MF[0]


# ---------- phase 3: macro ----------

def test_parse_fred_skips_missing_and_reports_delta():
    obs = [{"date": "2026-08-01", "value": "4.33"}, {"date": "2026-07-01", "value": "."},
           {"date": "2026-06-01", "value": "4.58"}]
    p, meta = market.parse_fred(obs)
    assert p.price == 4.33 and p.prev == 4.58 and p.change_pct is None
    assert meta == {"period": "2026-08-01", "delta": -0.25}
    assert p.closes == [4.58, 4.33]
    assert market.parse_fred([{"date": "x", "value": "."}]) is None


def test_refresh_macro_is_a_noop_without_a_key(monkeypatch):
    monkeypatch.delenv("FRED_API_KEY", raising=False)
    monkeypatch.setattr(market.requests, "get", lambda *a, **k: (_ for _ in ()).throw(AssertionError("no call")))
    assert market.refresh_macro(lambda *a, **k: None, datetime(2026, 8, 22, tzinfo=UTC)) == 0


# ---------- phase 3: NSE blobs ----------

NOW = ist(2026, 8, 22, 12, 0)
EVENTS = [{"symbol": "TCS", "company": "TCS Ltd", "purpose": "Financial Results", "date": "28-Aug-2026"},
          {"symbol": "TCS", "company": "TCS Ltd", "purpose": "Dividend", "date": "28-Aug-2026"},
          {"symbol": "NOPE", "company": "Unknown", "purpose": "Financial Results", "date": "28-Aug-2026"},
          {"symbol": "INFY", "company": "Infosys", "purpose": "Financial Results/Other business matters", "date": "20-Sep-2026"},
          {"symbol": "SBIN", "company": "SBI", "purpose": "Fund Raising", "date": "25-Aug-2026"}]
MEETINGS = [{"bm_symbol": "TCS", "sm_name": "TCS Ltd", "bm_purpose": "Financial Results", "bm_date": "28-Aug-2026"},
            {"bm_symbol": "HDFCBANK", "sm_name": "HDFC Bank", "bm_purpose": "Financial Results", "bm_date": "23-Aug-2026"}]


def test_results_calendar_filters_window_purpose_known_and_dedupes():
    cal = market.results_calendar(EVENTS, MEETINGS, {"TCS", "INFY", "SBIN", "HDFCBANK"}, NOW)
    assert [(r["symbol"], r["date"]) for r in cal] == [("HDFCBANK", "2026-08-23"), ("TCS", "2026-08-28")]
    assert cal[1]["purpose"] == "Financial Results" and cal[1]["company"] == "TCS Ltd"


def test_shape_deals_values_sorted_and_capped():
    j = {"as_on_date": "21-Aug-2026",
         "BULK_DEALS_DATA": [{"buySell": "BUY", "clientName": "X", "name": "A", "qty": "14000", "symbol": "A", "watp": "84.1", "date": "21-Aug-2026"},
                             {"buySell": "sell", "clientName": "Y", "name": "B", "qty": "bad", "symbol": "B", "watp": "1"}],
         "BLOCK_DEALS_DATA": [{"buySell": "BUY", "clientName": "Z", "name": "C", "qty": "142857", "symbol": "C", "watp": "560"}]}
    d = market.shape_deals(j, cap=5)
    assert d["as_on"] == "21-Aug-2026"
    assert [x["symbol"] for x in d["deals"]] == ["C", "A"]  # bad qty dropped, value-desc
    assert d["deals"][0]["type"] == "block" and d["deals"][0]["value"] == 142857 * 560
    assert d["deals"][1]["side"] == "BUY"


PIT_DOC = ("<html xmlns:ix='x'><body>"
           "<ix:nonNumeric name='in-bse-co:NameOfThePerson' contextRef='M'>A</ix:nonNumeric>"
           "<ix:nonNumeric name='in-bse-co:CategoryOfPerson'>Promoter</ix:nonNumeric>"
           "<ix:nonFraction name='in-bse-co:SecuritiesAcquiredOrDisposedNumberOfSecurity'>"
           "<b>100</b></ix:nonFraction>"
           "<ix:nonNumeric name='in-bse-co:SecuritiesAcquiredOrDisposedTransactionType'>Buy</ix:nonNumeric>"
           "<ix:nonNumeric name='in-bse-co:DateOfAllotmentAdviceOrAcquisitionOfSharesOrSaleOfSharesSpecifyFromDate'>"
           "20-08-2026</ix:nonNumeric></body></html>")


def test_shape_insider_and_indices():
    pit = {"data": [{"symbol": "TCS", "companyName": "TCS", "appId": "1", "ixbrl": "http://x/1.html"},
                    {"symbol": "ZZZ", "appId": "2", "ixbrl": "http://x/2.html"},
                    {"symbol": "TCS", "appId": "3", "ixbrl": "http://x/3.html"}]}
    fetched = []

    def fetch(u):
        fetched.append(u)
        return PIT_DOC

    ins = market.shape_insider(pit, {"TCS"}, prev=[{"appId": "3", "person": "old"}], fetch=fetch)
    assert fetched == ["http://x/1.html"]  # ZZZ unknown, appId 3 already in the blob
    assert len(ins) == 2 and ins[1]["person"] == "old"
    assert ins[0] == {"appId": "1", "symbol": "TCS", "company": "TCS", "person": "A",
                      "category": "Promoter", "qty": "100", "side": "Buy", "date": "20-08-2026"}
    idx = {"data": [{"key": "SECTORAL INDICES", "index": "NIFTY IT", "last": 30532, "percentChange": -0.46, "pe": "28", "advances": "3", "declines": "7"},
                    {"key": "STRATEGY INDICES", "index": "NIFTY ALPHA 50", "last": 1}]}
    out = market.shape_indices(idx)
    assert [o["index"] for o in out] == ["NIFTY IT"] and out[0]["pct"] == -0.46


def test_refresh_nse_blobs_isolates_one_dead_endpoint(monkeypatch):
    class R:
        def __init__(self, payload, ok=True):
            self.p, self.ok_ = payload, ok
            self.headers = {"content-type": "application/json; charset=utf-8" if ok else "text/html"}
            self.status_code = 200 if ok else 403

        def raise_for_status(self):
            if not self.ok_:
                raise market.requests.HTTPError("403")

        def json(self):
            return self.p

    class S:
        def get(self, url, params=None, timeout=None):
            if url.endswith("allIndices"):
                return R(None, ok=False)  # Akamai day
            if url.endswith("event-calendar"):
                return R(EVENTS)
            if url.endswith("corporate-board-meetings"):
                return R(MEETINGS)
            if url.endswith("snapshot-capital-market-largedeal"):
                return R({"as_on_date": "21-Aug-2026", "BULK_DEALS_DATA": [], "BLOCK_DEALS_DATA": []})
            if url.endswith("corporates-pit-gg"):
                assert params["from_date"] < params["to_date"]
                return R({"data": []})
            raise AssertionError(url)

    written = []

    def sb(method, path, **kw):
        if method == "GET":
            if path.startswith("market_blobs"):
                return []
            return [{"nse_symbol": "TCS"}, {"nse_symbol": "HDFCBANK"}]
        written.append((path, kw["json"]))

    n = market.refresh_nse_blobs(sb, NOW, session=S())
    assert n == 3 and written[0][0] == "market_blobs?on_conflict=key"
    keys = {r["key"] for r in written[0][1]}
    assert keys == {"results_calendar", "bulk_deals", "insider_trades"}  # nse_indices kept its old blob
    cal = next(r for r in written[0][1] if r["key"] == "results_calendar")["payload"]
    assert [c["symbol"] for c in cal] == ["HDFCBANK", "TCS"]
