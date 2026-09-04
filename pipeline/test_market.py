"""market.py: pure-function checks, no network. Run: cd pipeline && py -3 -m pytest test_market.py"""
import pathlib
import re
from datetime import datetime, timedelta, timezone

import pytest

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


def test_upsert_splits_mixed_key_rows_into_matching_batches():
    """PGRST102: PostgREST rejects a bulk insert whose rows have different keys.
    gold_inr_row carries meta while its fxcom batch-mates don't — that broke
    the whole fxcom lane for 5 days (caught by the Health page, 28 Aug)."""
    seen = []
    now = datetime(2026, 8, 28, tzinfo=UTC)
    plain = market.row("USDINR", "fx", "USD/INR", market.parse_spark(SPARK["TCS.NS"]), now)
    gold = market.gold_inr_row(market.parse_spark(SPARK["TCS.NS"]),
                               market.parse_spark(SPARK["TCS.NS"]), now)
    market.upsert(lambda m, p, **kw: seen.append(kw["json"]), [plain, gold, plain])
    assert len(seen) == 2  # one batch per key-set
    for batch in seen:
        assert len({tuple(sorted(r)) for r in batch}) == 1


def test_time_filters_in_urls_use_z_not_offset():
    """'+00:00' in a URL decodes the + as a space -> Postgres 22007 -> the whole
    group fails. Broke analysis_requests serving and the equity prune."""
    src = pathlib.Path(market.__file__).read_text(encoding="utf-8")
    for ln in src.splitlines():
        if any(op in ln for op in ("=lt.", "=gte.", "=lte.", "=gt.")):
            assert ".isoformat()" not in ln, f"offset timestamp in URL filter: {ln.strip()}"


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


def test_refresh_records_status_and_honours_groups_off(monkeypatch):
    monkeypatch.setattr(market, "_last_run", {})
    monkeypatch.setattr(market, "_status", {})
    writes = []

    def sb(method, path, **kw):
        if method == "GET":
            return [{"value": {"groups_off": ["crypto"]}}]
        writes.append((path, kw["json"]))

    def bad(sb_, now):
        raise RuntimeError("yahoo down")

    monkeypatch.setattr(market, "GROUPS", (("index", bad), ("crypto", lambda s, n: 1),
                                           ("screener", lambda s, n: 2)))
    now = datetime(2026, 9, 2, 13, 0, tzinfo=UTC)
    counts = market.refresh(sb, now)
    assert counts == {"screener": 2}                 # crypto disabled, index failed
    assert "crypto" not in market._last_run          # off group runs promptly when re-enabled
    st = market._status
    assert st["index"] == {"ok": False, "ts": now.isoformat(), "ok_ts": None,
                           "err": "yahoo down", "fails": 1, "daily": False}
    assert st["screener"]["ok"] is True and st["screener"]["daily"] is True
    (path, rows), = [w for w in writes if w[0].startswith("app_config")]
    assert rows[0]["key"] == "market_status"
    assert rows[0]["value"]["groups"]["index"]["ok"] is False and "fund" in rows[0]["value"]


def test_refresh_status_fail_streak_and_recovery(monkeypatch):
    monkeypatch.setattr(market, "_status", {})
    flaky = {"n": 0}

    def fn(sb_, now):
        flaky["n"] += 1
        if flaky["n"] < 3:
            raise RuntimeError(f"fail {flaky['n']}")
        return 1

    monkeypatch.setattr(market, "GROUPS", (("fxcom", fn),))
    sb = lambda *a, **k: []  # noqa: E731  config read -> nothing off; writes swallowed
    t0 = datetime(2026, 9, 2, 13, 0, tzinfo=UTC)
    for lap in range(3):
        monkeypatch.setattr(market, "_last_run", {})
        market.refresh(sb, t0 + timedelta(minutes=20 * lap))
    st = market._status["fxcom"]
    assert st["ok"] is True and st["fails"] == 0 and st["err"] is None
    assert st["ok_ts"] == (t0 + timedelta(minutes=40)).isoformat()


def test_market_is_an_admin_switch():
    from run import SWITCHES
    assert "market" in SWITCHES


def test_all_groups_registered():
    assert [g for g, _ in market.GROUPS] == ["index", "equity", "fxcom", "crypto", "mf", "mf_new",
                                             "analysis_new", "worldmacro", "hazards",
                                             "fundamentals", "technicals",
                                             "macro", "nse", "bonds", "sentiment",
                                             "deep_new", "deep_warm",
                                             "screener", "screener_px"]


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
                    {"key": "STRATEGY INDICES", "index": "NIFTY ALPHA 50", "last": 1},
                    {"key": "FIXED INCOME INDICES", "index": "NIFTY GS 10YR", "last": 1}]}
    out = market.shape_indices(idx)  # thematic/strategy kept, fixed income not
    assert [o["index"] for o in out] == ["NIFTY IT", "NIFTY ALPHA 50"]
    assert out[0]["pct"] == -0.46


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
            if url.endswith("ipo-current-issue"):
                return R({"data": [{"symbol": "ABCIPO", "companyName": "ABC Ltd",
                                    "issueStartDate": "01-Sep-2026", "issueEndDate": "03-Sep-2026",
                                    "priceBand": "95-100", "issueSize": "1,200.00", "series": "EQ",
                                    "status": "Open"}]})
            if url.endswith("all-upcoming-issues"):
                return R(None, ok=False)  # one dead IPO list is fine
            if "live-analysis" in url:
                return R(None, ok=False)  # whole F&O family down -> old blob stays
            raise AssertionError(url)

    written = []
    monkeypatch.setattr(market, "_blob_sent", {})

    def sb(method, path, **kw):
        if method == "GET":
            if path.startswith("market_blobs"):
                return []
            return [{"nse_symbol": "TCS"}, {"nse_symbol": "HDFCBANK"}]
        written.append((path, kw["json"]))

    n = market.refresh_nse_blobs(sb, NOW, session=S())
    assert n == 4 and written[0][0] == "market_blobs?on_conflict=key"
    keys = {r["key"] for r in written[0][1]}
    # nse_indices and fno kept their old blobs; ipos lands on one live list.
    assert keys == {"results_calendar", "bulk_deals", "insider_trades", "ipos"}
    cal = next(r for r in written[0][1] if r["key"] == "results_calendar")["payload"]
    assert [c["symbol"] for c in cal] == ["HDFCBANK", "TCS"]
    ipos = next(r for r in written[0][1] if r["key"] == "ipos")["payload"]
    assert ipos["upcoming"] == [] and ipos["current"][0]["symbol"] == "ABCIPO"


# ---------- trader coverage: IPOs, F&O, bonds ----------

def test_shape_ipos_reads_lenient_fields_and_defaults_status():
    cur = {"data": [{"symbol": "ABC", "companyName": "ABC Ltd", "issueStartDate": "01-Sep-2026",
                     "issueEndDate": "03-Sep-2026", "priceBand": "95-100",
                     "issueSize": "1200 Cr", "series": "EQ", "status": "Open"},
                    {"noise": True}]}
    up = [{"sym": "XYZ", "company": "XYZ Ltd", "startDate": "10-Sep-2026"}]
    out = market.shape_ipos(cur, up)
    assert out["current"] == [{"symbol": "ABC", "company": "ABC Ltd", "open": "01-Sep-2026",
                              "close": "03-Sep-2026", "band": "95-100", "size": "1200 Cr",
                              "series": "EQ", "status": "Open"}]
    assert out["upcoming"][0]["symbol"] == "XYZ"
    assert out["upcoming"][0]["status"] == "upcoming"


def test_shape_oi_spurts_splits_gainers_and_losers():
    j = {"data": [{"symbol": "A", "avgInOI": "38.2", "ltp": "1,250.50", "pChange": 1.2},
                  {"symbol": "B", "avgInOI": -12.0},
                  {"symbol": "C"},  # no OI change -> dropped
                  {"symbol": "D", "avgInOI": 5.0}]}
    out = market.shape_oi_spurts(j)
    assert [r["symbol"] for r in out["oi_gainers"]] == ["A", "D"]
    assert out["oi_gainers"][0]["ltp"] == 1250.5
    assert [r["symbol"] for r in out["oi_losers"]] == ["B"]


def test_shape_variations_handles_flat_and_nested_payloads():
    flat = {"data": [{"symbol": "A", "pChange": "4.5", "ltp": 100}]}
    nested = {"FOSec": {"data": [{"symbol": "B", "perChange": -3.1}]}}
    assert market.shape_variations(flat) == [{"symbol": "A", "ltp": 100.0, "pct": 4.5}]
    assert market.shape_variations(nested)[0]["pct"] == -3.1


RBI_HOME = """<html><body><!-- CURRENT RATES START--><div class="grid_3">
<h3 class="accordionButton"><a role="button">Policy&nbsp; Rates</a></h3>
<table><tr><th> Policy Repo Rate </th><td> : 5.25% </td></tr>
<tr><th> Standing Deposit Facility Rate </th><td> : 5.00% </td></tr>
<tr><th style="width:50%"> Bank Rate </th><td style="width:50%"> : 5.50% </td></tr></table>
<table><tr><th style="width:50%"> CRR </th><td> : 3.00% </td></tr><tr><th> SLR </th><td> : 18.00% </td></tr></table>
<table><tr><th style="width:65%"> INR / 1 USD </th><td> : 94.4688 </td></tr></table>
<h3>Money Market</h3><table><tr><th style="width:45%">Call Rates</th><td> : 4.20% - 5.10% * </td></tr></table>
<div><span class="red">*</span><span class="subText"> as on <!--January 27, 2026--> September 03, 2026</span></div>
<h3>Government Securities Market</h3><table><tbody>
<tr><th> 6.20% GS 2029 </th><td>: 6.3784% #</td></tr>
<tr><th> 6.36% GS 2031 </th><td>: 6.5324% #</td></tr>
<tr><th> 6.94% GS 2036 </th><td>: 6.9682% #</td></tr>
<tr><th> 7.24% GS 2055 </th><td>: 7.5759% #</td></tr>
<tr><th> 91 day T-bills </th><td> : 5.2599%* </td></tr>
<tr><th> 364 day T-bills </th><td> : 5.9090%* </td></tr></tbody></table>
<div><span class="red">#</span><span class="subText"> as on <!--January 27, 2026--> September 03, 2026 </span></div>
</div><!-- CURRENT RATES END--></body></html>"""


def test_parse_rbi_home_reads_gsecs_rates_and_date():
    gsecs, rates, asof = market.parse_rbi_home(RBI_HOME, 2026)
    assert asof == "2026-09-03"
    assert [(g["tenor"], g["yield"]) for g in gsecs] == \
        [("3Y", 6.3784), ("5Y", 6.5324), ("10Y", 6.9682), ("29Y", 7.5759)]
    assert gsecs[0]["name"] == "6.20% GS 2029" and gsecs[0]["date"] == "2026-09-03"
    assert rates == {"repo": 5.25, "sdf": 5.0, "bank_rate": 5.5, "crr": 3.0, "slr": 18.0,
                     "tbill_91d": 5.2599, "tbill_364d": 5.909}
    assert market.parse_rbi_home("<html>maintenance</html>", 2026) == ([], {}, None)


def test_refresh_bonds_writes_gsec_curve_and_rbi_rates_with_day_over_day(monkeypatch):
    class R:
        text = RBI_HOME

        def raise_for_status(self):
            pass

    monkeypatch.setattr(market.requests, "get", lambda *a, **k: R())
    monkeypatch.setattr(market, "_blob_sent", {})
    written = []
    old = [{"payload": {"yields": [
        {"name": "6.94% GS 2036", "tenor": "10Y", "yield": 6.9, "date": "2026-09-02",
         "prev": 6.88, "chg_bp": 2.0},
        {"name": "6.36% GS 2031", "tenor": "5Y", "yield": 6.5, "date": "2026-09-03",
         "prev": 6.45, "chg_bp": 5.0}]}}]

    def sb(method, path, **kw):
        if method == "GET":
            return old
        written.append((path, kw["json"]))

    assert market.refresh_bonds(sb, NOW) == 2
    blobs = {r["key"]: r["payload"] for _, rows in written for r in rows}
    ys = {y["tenor"]: y for y in blobs["bonds"]["yields"]}
    assert ys["10Y"]["prev"] == 6.9 and ys["10Y"]["chg_bp"] == 6.8    # new day vs last blob
    assert ys["5Y"]["prev"] == 6.45 and ys["5Y"]["chg_bp"] == 5.0     # same day: keep yesterday's
    assert ys["3Y"]["prev"] is None and ys["3Y"]["chg_bp"] is None    # first sight
    assert blobs["rbi_rates"]["repo"] == 5.25 and blobs["rbi_rates"]["asof"] == "2026-09-03"

    class Blocked:
        text = "<html>Access Denied</html>"

        def raise_for_status(self):
            pass

    monkeypatch.setattr(market.requests, "get", lambda *a, **k: Blocked())
    with pytest.raises(RuntimeError):  # old blob stays, group goes red
        market.refresh_bonds(sb, NOW)


def test_refresh_crypto_marks_stablecoin_peg_and_mcap(monkeypatch):
    class R:
        def raise_for_status(self):
            pass

        def json(self):
            return {"bitcoin": {"inr": 7395017, "usd": 88000, "inr_24h_change": -0.19},
                    "tether": {"inr": 94.47, "usd": 0.999943, "inr_24h_change": 0.11,
                               "usd_market_cap": 183370476603.6}}

    monkeypatch.setattr(market.requests, "get", lambda *a, **k: R())
    rows = []
    monkeypatch.setattr(market, "upsert", lambda sb, r: rows.extend(r) or len(r))
    assert market.refresh_crypto(None, NOW) == 2
    by = {r["symbol"]: r for r in rows}
    assert "peg_pct" not in by["bitcoin"]["meta"]
    assert by["tether"]["meta"]["peg_pct"] == -0.006
    assert by["tether"]["meta"]["usd_mcap"] == 183370476603.6
    assert by["tether"]["name"] == "Tether (USDT)"


# ---------- write_blobs: egress suppression ----------

def test_write_blobs_skips_unchanged_payloads_and_retries_failures(monkeypatch):
    monkeypatch.setattr(market, "_blob_sent", {})
    written = []

    def sb(method, path, **kw):
        written.append(kw["json"])

    rows = [{"key": "flows", "payload": {"fii": 1}, "updated_at": NOW.isoformat()},
            {"key": "fno", "payload": {"hi52": 9}, "updated_at": NOW.isoformat()}]
    assert market.write_blobs(sb, rows) == 2
    # identical payloads again (off-hours lap): nothing written, updated_at untouched
    assert market.write_blobs(sb, rows) == 0
    assert len(written) == 1
    # one payload changes: only that row goes out
    rows2 = [{"key": "flows", "payload": {"fii": 2}, "updated_at": NOW.isoformat()},
             {"key": "fno", "payload": {"hi52": 9}, "updated_at": NOW.isoformat()}]
    assert market.write_blobs(sb, rows2) == 1
    assert [r["key"] for r in written[1]] == ["flows"]


def test_write_blobs_failed_upsert_is_not_suppressed(monkeypatch):
    monkeypatch.setattr(market, "_blob_sent", {})
    calls = {"n": 0}

    def sb(method, path, **kw):
        calls["n"] += 1
        if calls["n"] == 1:
            raise market.requests.RequestException("supabase blip")

    rows = [{"key": "bonds", "payload": {"yields": []}, "updated_at": NOW.isoformat()}]
    try:
        market.write_blobs(sb, rows)
        raise AssertionError("first write should have raised")
    except market.requests.RequestException:
        pass
    # hash was not stamped on failure -> the retry actually writes
    assert market.write_blobs(sb, rows) == 1 and calls["n"] == 2


# ---------- sentiment composites (fear/greed, risk, summary) ----------

FLOWS = {"fii": {"buy": 100.0, "sell": 642.71, "net": -542.71},
         "dii": {"buy": 100.0, "sell": 50.0, "net": 2124.14},
         "breadth": {"NIFTY 500": {"adv": 217, "dec": 276}}}
QROWS = {"^NSEI": {"symbol": "^NSEI", "price": 24252.0, "change_pct": 0.4,
                   "closes": [24000.0 + i * 20 for i in range(12)]},
         "^BSESN": {"symbol": "^BSESN", "price": 80000.0, "change_pct": 0.3, "closes": []},
         "^INDIAVIX": {"symbol": "^INDIAVIX", "price": 12.0, "change_pct": -1.0, "closes": []},
         "USDINR=X": {"symbol": "USDINR=X", "price": 95.7, "change_pct": 0.1, "closes": []}}


def test_fear_greed_blends_components_and_renormalizes_missing():
    fg = market.compute_fear_greed(QROWS, FLOWS, {"hi52": 34, "lo52": 12})
    assert set(fg["components"]) == {"vix", "breadth", "fii", "hi_lo", "momentum"}
    assert fg["components"]["vix"] == 88          # 12 on a 26->10 calm scale
    assert fg["components"]["breadth"] == 44      # 217/(217+276)
    assert fg["methodology_version"] == market.FG_VERSION
    assert 0 <= fg["score"] <= 100 and fg["label"]
    # VIX + hi/lo + momentum missing -> renormalize over what's left, not fake 0s
    fg2 = market.compute_fear_greed({"^NSEI": {"price": None, "closes": []}}, FLOWS, {})
    assert set(fg2["components"]) == {"breadth", "fii"}
    # a single component is an anecdote, not a score
    assert market.compute_fear_greed({}, {"fii": {"net": 100}}, {}) is None


def test_risk_index_points_the_other_way():
    risk = market.compute_risk_index(QROWS, FLOWS, {"spikes": [
        {"confidence": "high"}, {"confidence": "low"}]})
    assert risk["components"]["vix"] == 12        # calm VIX -> low risk
    assert risk["components"]["breadth"] == 56    # decliners' share
    assert risk["components"]["news"] == 33       # 1 high-conf spike of 3 saturating
    assert risk["methodology_version"] == market.RISK_VERSION
    assert risk["label"] in ("Low", "Elevated", "High")


def test_market_summary_is_deterministic_and_no_ai():
    fg = {"score": 58, "label": "Greed"}
    move = {"explained": [{"symbol": "TCS", "chg": 4.2, "title": "TCS wins mega deal"},
                          {"symbol": "INFY", "chg": -1.0, "title": "minor"}]}
    text = market.market_summary_text(QROWS, FLOWS, fg, move)
    assert text.startswith("NIFTY +0.4%, SENSEX +0.3%")
    assert "FII -543 cr / DII +2,124 cr" in text
    assert "TCS +4.2%" in text and "mega deal" in text
    assert text.endswith("Mood: greed (58)")
    # nothing available -> empty string, caller writes no blob
    assert market.market_summary_text({}, {}, None, {}) == ""


def test_refresh_sentiment_reads_db_only_and_writes_derived_blobs(monkeypatch):
    monkeypatch.setattr(market, "_blob_sent", {})
    written = []

    def sb(method, path, **kw):
        if path.startswith("quotes"):
            assert "kind=in.(index,fx)" in path
            return list(QROWS.values())
        if path.startswith("market_blobs?select=key,payload"):
            return [{"key": "flows", "payload": FLOWS}, {"key": "fno", "payload": {"hi52": 3, "lo52": 1}}]
        written.append((path, kw["json"]))

    n = market.refresh_sentiment(sb, NOW)
    assert n == 3
    rows = written[0][1]
    assert [r["key"] for r in rows] == ["fear_greed", "risk_index", "market_summary"]
    # derived blobs carry no computed_at: unchanged scores must suppress writes
    assert "computed_at" not in rows[0]["payload"]
    assert market.refresh_sentiment(sb, NOW) == 0  # identical inputs -> suppressed


# ---------- P4 context sources ----------

def test_parse_worldbank_keeps_latest_and_previous_per_indicator():
    payload = [{"lastupdated": "2026-07-13"}, [
        {"indicator": {"id": "NY.GDP.MKTP.KD.ZG"}, "date": "2025", "value": 7.5666},
        {"indicator": {"id": "NY.GDP.MKTP.KD.ZG"}, "date": "2024", "value": 7.0993},
        {"indicator": {"id": "NY.GDP.MKTP.KD.ZG"}, "date": "2023", "value": 7.21},
        {"indicator": {"id": "BN.CAB.XOKA.GD.ZS"}, "date": "2025", "value": None},
        {"indicator": {"id": "BN.CAB.XOKA.GD.ZS"}, "date": "2024", "value": -0.7},
        {"indicator": {"id": "SP.POP.TOTL"}, "date": "2025", "value": 1.4e9},
    ]]
    series, asof = market.parse_worldbank(payload)
    assert asof == "2026-07-13"
    assert series["NY.GDP.MKTP.KD.ZG"] == {"name": "GDP growth", "units": "%", "value": 7.57,
                                           "year": "2025", "prev": 7.1, "prev_year": "2024"}
    assert series["BN.CAB.XOKA.GD.ZS"]["value"] == -0.7 and series["BN.CAB.XOKA.GD.ZS"]["year"] == "2024"
    assert "SP.POP.TOTL" not in series
    assert market.parse_worldbank([{"message": "bad"}]) == ({}, None)


def test_refresh_worldmacro_writes_blob_or_raises(monkeypatch):
    class R:
        def raise_for_status(self):
            pass

        def json(self):
            return [{"lastupdated": "2026-07-13"},
                    [{"indicator": {"id": "FP.CPI.TOTL.ZG"}, "date": "2025", "value": 4.2}]]

    monkeypatch.setattr(market.requests, "get", lambda *a, **k: R())
    monkeypatch.setattr(market, "_blob_sent", {})
    written = []
    monkeypatch.setattr(market, "write_blobs", lambda sb, rows: written.extend(rows) or len(rows))
    assert market.refresh_worldmacro(None, NOW) == 1
    assert written[0]["key"] == "macro_context" and written[0]["payload"]["asof"] == "2026-07-13"

    class Empty(R):
        def json(self):
            return [{"lastupdated": "2026-07-13"}, []]

    monkeypatch.setattr(market.requests, "get", lambda *a, **k: Empty())
    with pytest.raises(RuntimeError):
        market.refresh_worldmacro(None, NOW)


def test_parse_usgs_and_refresh_hazards_publishes_empty_weeks(monkeypatch):
    feat = {"type": "Feature", "properties": {"mag": 5.1, "place": "115 km NE of Joshimath, India",
            "time": 1788423396417, "url": "https://earthquake.usgs.gov/x"},
            "geometry": {"type": "Point", "coordinates": [79.9, 31.2, 10.0]}}
    quakes = market.parse_usgs({"features": [feat, {"properties": {"mag": None}}]})
    assert quakes == [{"mag": 5.1, "place": "115 km NE of Joshimath, India",
                       "time": "2026-09-03T08:16:36.417000+00:00",
                       "url": "https://earthquake.usgs.gov/x", "lat": 31.2, "lon": 79.9}]

    class R:
        def raise_for_status(self):
            pass

        def json(self):
            return {"features": []}

    calls = []
    monkeypatch.setattr(market.requests, "get", lambda url, **k: calls.append(k["params"]) or R())
    monkeypatch.setattr(market, "_blob_sent", {})
    written = []
    monkeypatch.setattr(market, "write_blobs", lambda sb, rows: written.extend(rows) or len(rows))
    assert market.refresh_hazards(None, NOW) == 1
    assert written[0]["payload"] == {"quakes": []}
    assert calls[0]["minmagnitude"] == 4.5 and calls[0]["minlatitude"] == 5
