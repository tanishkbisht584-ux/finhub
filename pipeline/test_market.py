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
    assert [g for g, _ in market.GROUPS] == ["index", "equity", "fxcom", "crypto", "global", "mf", "mf_new",
                                             "analysis_new", "worldmacro", "hazards", "wikidata", "cpi", "polymarket", "cb_rates", "calendar", "participant_oi", "shipping", "monsoon",
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
         "pcr": 1.1,
         "breadth": {"NIFTY 500": {"adv": 217, "dec": 276}}}
POI = {"rows": {"FII": {"fut_idx_long": 100000, "fut_idx_short": 60000,
                        "net_fut_idx": 40000}}}
QROWS = {"^NSEI": {"symbol": "^NSEI", "price": 24252.0, "change_pct": 0.4,
                   "closes": [24000.0 + i * 20 for i in range(12)]},
         "^BSESN": {"symbol": "^BSESN", "price": 80000.0, "change_pct": 0.3, "closes": []},
         "^INDIAVIX": {"symbol": "^INDIAVIX", "price": 12.0, "change_pct": -1.0, "closes": []},
         "GC=F": {"symbol": "GC=F", "price": 4624.0, "change_pct": 0.2,
                  "closes": [4600.0 + i for i in range(12)]},
         "USDINR=X": {"symbol": "USDINR=X", "price": 95.7, "change_pct": 0.1, "closes": []}}


def test_fear_greed_blends_components_and_renormalizes_missing():
    fg = market.compute_fear_greed(QROWS, FLOWS, {"hi52": 34, "lo52": 12}, POI)
    assert set(fg["components"]) == {"vix", "breadth", "fii", "hi_lo", "momentum",
                                    "pcr", "fii_pos", "nifty_gold"}
    assert fg["components"]["vix"] == 88          # 12 on a 26->10 calm scale
    assert fg["components"]["breadth"] == 44      # 217/(217+276)
    assert fg["components"]["pcr"] == 50          # 1.1 on the 0.7->1.5 band
    assert fg["components"]["fii_pos"] == 71      # (100k-60k)/160k = 0.25 tilt
    # NIFTY +0.92% vs gold +0.24% over the window -> mildly greedy
    assert 50 < fg["components"]["nifty_gold"] <= 60
    assert fg["methodology_version"] == market.FG_VERSION
    assert 0 <= fg["score"] <= 100 and fg["label"]
    # VIX + hi/lo + momentum + poi missing -> renormalize, not fake 0s
    fg2 = market.compute_fear_greed({"^NSEI": {"price": None, "closes": []}}, FLOWS, {})
    assert set(fg2["components"]) == {"breadth", "fii", "pcr"}
    # a single component is an anecdote, not a score
    assert market.compute_fear_greed({}, {"fii": {"net": 100}}, {}) is None


def test_compute_correlations_matrix_shape_and_bounds():
    corr = market.compute_correlations(QROWS)
    assert corr["assets"] == ["NIFTY", "Gold"]    # only two carry >=10 returns
    m = corr["matrix"]
    assert m[0][0] == 1.0 and m[1][1] == 1.0
    assert m[0][1] == m[1][0] and -1.0 <= m[0][1] <= 1.0
    assert corr["window_d"] == 11
    # one usable asset is not a matrix
    assert market.compute_correlations({"^NSEI": QROWS["^NSEI"]}) is None


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
            assert "kind=in.(index,fx,commodity)" in path
            return list(QROWS.values())
        if path.startswith("market_blobs?select=key,payload"):
            assert "participant_oi" in path
            return [{"key": "flows", "payload": FLOWS}, {"key": "fno", "payload": {"hi52": 3, "lo52": 1}},
                    {"key": "participant_oi", "payload": POI}]
        written.append((path, kw["json"]))

    n = market.refresh_sentiment(sb, NOW)
    assert n == 4
    rows = written[0][1]
    assert [r["key"] for r in rows] == ["fear_greed", "risk_index", "market_summary",
                                       "correlation"]
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


# ---------- Wikidata aliases ----------

def _wd(ticker, label, alts=""):
    return {"ticker": {"value": ticker}, "itemLabel": {"value": label},
            "alts": {"value": alts}}


def test_parse_wikidata_aliases_shapes():
    payload = {"results": {"bindings": [
        _wd("SJVN", "SJVN", "Satluj Jal Vidyut Nigam|SJVN Limited|SJVNL"),
        _wd("bandhanbnk", "Bandhan Bank"),
        {"itemLabel": {"value": "no ticker row"}},
    ]}}
    out = market.parse_wikidata_aliases(payload)
    assert out["SJVN"] == ["SJVN", "Satluj Jal Vidyut Nigam", "SJVN Limited", "SJVNL"]
    assert out["BANDHANBNK"] == ["Bandhan Bank"]
    assert len(out) == 2
    assert market.parse_wikidata_aliases({}) == {}


def test_refresh_wikidata_merges_only_new_and_raises_on_empty(monkeypatch):
    class R:
        def raise_for_status(self):
            pass

        def json(self):
            return {"results": {"bindings": [
                _wd("SJVN", "SJVN", "Satluj Jal Vidyut Nigam|SJVNL|x"),
                _wd("TCS", "Tata Consultancy Services", "TCS"),
            ]}}

    monkeypatch.setattr(market.requests, "get", lambda *a, **k: R())
    patches = []

    def sb(method, path, **kw):
        if method == "GET":
            return [{"id": 1, "name": "SJVN", "nse_symbol": "SJVN",
                     "aliases": ["sjvnl"]},
                    {"id": 2, "name": "Tata Consultancy Services", "nse_symbol": "TCS",
                     "aliases": []},
                    {"id": 3, "name": "Unknown Co", "nse_symbol": "NOPE", "aliases": []}]
        patches.append((path, kw["json"]))

    assert market.refresh_wikidata(sb, NOW) == 1
    # SJVN gains only the long new name: label==name, sjvnl already there, "x" too short.
    # TCS gains nothing (label==name, alt==symbol) -> no PATCH at all.
    assert patches == [("companies?id=eq.1",
                        {"aliases": ["satluj jal vidyut nigam", "sjvnl"]})]

    class Empty(R):
        def json(self):
            return {"results": {"bindings": []}}

    monkeypatch.setattr(market.requests, "get", lambda *a, **k: Empty())
    with pytest.raises(RuntimeError):
        market.refresh_wikidata(sb, NOW)


# ---------- MOSPI CPI ----------

def _cpi_row(state, sector, group, sub, idx, infl, month="December", year=2025):
    return {"state": state, "sector": sector, "group": group, "subgroup": sub,
            "index": idx, "inflation": infl, "month": month, "year": year}


def test_parse_mospi_cpi_picks_newest_all_india_general():
    pages = [
        {"data": [_cpi_row("All India", "Rural", "Consumer Food Price",
                           "Consumer Food Price-Overall", "198.5", "-3.03")]},
        {"data": [_cpi_row("All India", "Rural", "General", "General-Overall", "199.9", "0.76"),
                  _cpi_row("All India", "Urban", "General", "General-Overall", "195.9", "2.03"),
                  _cpi_row("All India", "Combined", "General", "General-Overall", "198.0", "1.33"),
                  _cpi_row("Kerala", "Combined", "General", "General-Overall", "205.0", "2.0"),
                  # an older month must not leak into the result
                  _cpi_row("All India", "Combined", "General", "General-Overall",
                           "197.0", "1.10", month="November")]},
    ]
    out = market.parse_mospi_cpi(pages)
    assert out["period"] == "2025-12"
    assert out["Combined"] == {"index": 198.0, "inflation": 1.33}
    assert out["Rural"]["inflation"] == 0.76 and out["Urban"]["inflation"] == 2.03
    assert market.parse_mospi_cpi([{"data": []}]) is None


def test_refresh_cpi_upserts_with_prev_month_and_raises_when_absent(monkeypatch):
    calls = {"n": 0}

    class R:
        def raise_for_status(self):
            pass

        def json(self):
            return {"data": [
                _cpi_row("All India", "Combined", "General", "General-Overall", "198.0", "1.33"),
                _cpi_row("All India", "Rural", "General", "General-Overall", "199.9", "0.76"),
                _cpi_row("All India", "Urban", "General", "General-Overall", "195.9", "2.03")]}

    class Sess:
        def get(self, *a, **k):
            calls["n"] += 1
            return R()

    monkeypatch.setattr(market, "_legacy_tls_session", lambda: Sess())
    rows = []
    monkeypatch.setattr(market, "upsert", lambda sb, r: rows.extend(r) or len(r))

    def sb(method, path, **kw):
        return [{"price": 1.10, "meta": {"period": "2025-11"}}]

    assert market.refresh_cpi(sb, NOW) == 1
    assert calls["n"] == 1  # all three sectors on page 1 -> stops early
    r = rows[0]
    assert r["symbol"] == "MACRO:MOSPI_CPI" and r["price"] == 1.33 and r["prev_close"] == 1.10
    assert r["meta"]["delta"] == 0.23 and r["meta"]["period"] == "2025-12"
    assert r["meta"]["index"] == 198.0

    class Empty:
        def get(self, *a, **k):
            return type("E", (), {"raise_for_status": lambda s: None,
                                  "json": lambda s: {"data": []}})()

    monkeypatch.setattr(market, "_legacy_tls_session", lambda: Empty())
    with pytest.raises(RuntimeError):
        market.refresh_cpi(sb, NOW)


# ---------- boot rehydration ----------

def test_refresh_rehydrates_last_run_from_status_row(monkeypatch):
    """A new CI process must not re-fire daily groups that already ran today —
    _last_run seeds from the market_status row's per-group ts on first call."""
    from datetime import timedelta
    calls = []
    monkeypatch.setattr(market, "GROUPS", (("mf", lambda sb, now: calls.append("mf") or 1),
                                           ("crypto", lambda sb, now: calls.append("crypto") or 1)))
    monkeypatch.setattr(market, "_last_run", {})
    monkeypatch.setattr(market, "_status", {})
    ts = (NOW - timedelta(minutes=1)).isoformat()

    def sb(method, path, **kw):
        if "market_status" in path:
            return [{"value": {"groups": {"mf": {"ok": True, "ts": ts},
                                          "crypto": {"ok": True, "ts": ts}}}}]
        return []

    assert market.refresh(sb, NOW) == {}  # both ran a minute ago: nothing due
    assert calls == [] and market._last_run["mf"].isoformat() == ts

    # first-ever run (no status row): everything fires as before
    monkeypatch.setattr(market, "_last_run", {})
    monkeypatch.setattr(market, "_status", {})
    monkeypatch.setattr(market, "_blob_sent", {})

    def sb2(method, path, **kw):
        return [] if method == "GET" else None

    counts = market.refresh(sb2, NOW)
    assert set(calls) == {"mf", "crypto"} and counts == {"mf": 1, "crypto": 1}


# ---------- global layer ----------

def test_refresh_global_prefixes_adrs_and_marks_meta_global(monkeypatch):
    spark = {s: {"close": [100.0, 101.0], "timestamp": [1, 2]}
             for s in list(market.GLOBAL_INDICES) + list(market.ADRS)}
    monkeypatch.setattr(market, "fetch_spark", lambda syms, rng="5d": spark)
    rows = []
    monkeypatch.setattr(market, "upsert", lambda sb, r: rows.extend(r) or len(r))
    assert market.refresh_global(None, NOW) == len(spark)
    by = {r["symbol"]: r for r in rows}
    assert by["^GSPC"]["kind"] == "index" and by["^GSPC"]["meta"] == {"global": True}
    # bare "INFY" is the NSE equity row (quotes PK) - the ADR must never use it
    assert "INFY" not in by and by["ADR:INFY"]["meta"] == {"global": True, "adr": True}
    assert by["ADR:INFY"]["kind"] == "index" and by["ADR:INFY"]["currency"] == "USD"


def test_refresh_macro_scales_trade_series(monkeypatch):
    class R:
        def raise_for_status(self):
            pass

        def json(self):
            return {"observations": [{"date": "2026-06-01", "value": "38000000000"},
                                     {"date": "2026-05-01", "value": "36500000000"}]}

    monkeypatch.setattr(market.requests, "get", lambda *a, **k: R())
    monkeypatch.setenv("FRED_API_KEY", "k")
    monkeypatch.setattr(market, "MACRO_SERIES",
                        {"XTEXVA01INM667S": ("India exports, goods", "USD bn", 1e-9)})
    rows = []
    monkeypatch.setattr(market, "upsert", lambda sb, r: rows.extend(r) or len(r))
    assert market.refresh_macro(None, NOW) == 1
    r = rows[0]
    assert r["price"] == 38.0 and r["prev_close"] == 36.5
    assert r["closes"] == [36.5, 38.0] and r["meta"]["delta"] == 1.5
    assert r["meta"]["units"] == "USD bn"


def test_parse_polymarket_filters_themes_and_handles_multi_outcome():
    rows = [
        {"question": "Will the Fed decrease interest rates by 25 bps in September?",
         "slug": "fed-sep", "outcomes": '["Yes", "No"]',
         "outcomePrices": '["0.0065", "0.9935"]', "endDate": "2026-09-16T00:00:00Z"},
        {"question": "Who wins the 2026 celebrity dance-off?", "slug": "dance",
         "outcomes": '["A", "B"]', "outcomePrices": '["0.5", "0.5"]'},
        {"question": "Highest inflation print of 2026?", "slug": "cpi-race",
         "outcomes": '["Q3", "Q4"]', "outcomePrices": '["0.3", "0.7"]'},
        {"question": "Oil above $100?", "slug": "bad", "outcomes": "not json",
         "outcomePrices": "[]"},
    ]
    out = market.parse_polymarket(rows)
    assert [m["slug"] for m in out] == ["fed-sep", "cpi-race"]
    assert out[0]["label"] == "Yes" and out[0]["pct"] == 1 and out[0]["end"] == "2026-09-16"
    assert out[1]["label"] == "Q4" and out[1]["pct"] == 70
    assert market.parse_polymarket([]) == []


def test_refresh_polymarket_writes_blob_or_raises(monkeypatch):
    class R:
        def raise_for_status(self):
            pass

        def json(self):
            return [{"question": "Fed rate cut?", "slug": "s", "outcomes": '["Yes", "No"]',
                     "outcomePrices": '["0.4", "0.6"]', "endDate": "2026-09-16"}]

    monkeypatch.setattr(market.requests, "get", lambda *a, **k: R())
    monkeypatch.setattr(market, "_blob_sent", {})
    written = []
    monkeypatch.setattr(market, "write_blobs", lambda sb, rows: written.extend(rows) or 1)
    assert market.refresh_polymarket(None, NOW) == 1
    assert written[0]["key"] == "predictions" and written[0]["payload"]["markets"][0]["pct"] == 40

    class Empty(R):
        def json(self):
            return []

    monkeypatch.setattr(market.requests, "get", lambda *a, **k: Empty())
    with pytest.raises(RuntimeError):
        market.refresh_polymarket(None, NOW)


BIS_CSV = (
    "FREQ,REF_AREA,UNIT_MEASURE,UNIT_MULT,TIME_FORMAT,COMPILATION,DECIMALS,SOURCE_REF,"
    "SUPP_INFO_BREAKS,TITLE,TIME_PERIOD,OBS_VALUE,OBS_STATUS,OBS_CONF,OBS_PRE_BREAK\n"
    'D,CN,368,0,,"From 20 Aug 2019 onwards: Loan Prime Rate (1 year), earlier: lending rate",4,'
    "People's Bank of China,, Central bank policy rates - China - Daily,2026-09-01,3,A,F,\n"
    "D,IN,368,0,,Policy repo rate,2,RBI,, Central bank policy rates - India,2026-07-23,5.25,A,F,\n"
    "D,US,368,0,,Midpoint of the target range,4,Fed,, Central bank policy rates - US,2026-09-01,,A,F,\n"
    "D,ZZ,368,0,,unknown area,2,x,, x,2026-09-01,1,A,F,\n")


def test_parse_bis_handles_commas_in_title_and_blank_values():
    out = market.parse_bis(BIS_CSV)
    assert out == {"CN": {"name": "PBoC 1y LPR", "rate": 3.0, "asof": "2026-09-01"},
                   "IN": {"name": "RBI repo", "rate": 5.25, "asof": "2026-07-23"}}  # US blank, ZZ unknown
    assert market.parse_bis("") == {}


def test_refresh_cb_rates_writes_blob_or_raises(monkeypatch):
    class R:
        text = BIS_CSV

        def raise_for_status(self): pass
    monkeypatch.setattr(market.requests, "get", lambda *a, **k: R())
    monkeypatch.setattr(market, "_blob_sent", {})
    written = []
    monkeypatch.setattr(market, "write_blobs", lambda sb, rows: written.extend(rows) or 1)
    assert market.refresh_cb_rates(None, NOW) == 1
    assert written[0]["key"] == "cb_rates" and written[0]["payload"]["rates"]["IN"]["rate"] == 5.25
    assert written[0]["payload"]["asof"] == NOW.date().isoformat()

    class Empty(R):
        text = "FREQ,REF_AREA,OBS_VALUE\n"
    monkeypatch.setattr(market.requests, "get", lambda *a, **k: Empty())
    with pytest.raises(RuntimeError):
        market.refresh_cb_rates(None, NOW)


def test_india_events_rule_rolls_weekends_and_quarter_ends():
    from datetime import date
    ev = {(e["date"], e["name"]) for e in market.india_events(date(2026, 8, 22))}
    assert ("2026-09-14", "India CPI + IIP (MOSPI)") in ev      # 12 Sep 2026 is a Saturday
    assert ("2026-08-31", "India GDP, quarterly (MOSPI)") in ev  # last working day of Aug
    assert ("2026-10-12", "India CPI + IIP (MOSPI)") in ev
    assert ("2026-10-07", "RBI MPC decision") in ev


def test_refresh_calendar_merges_sources_and_trims_window(monkeypatch):
    calls = []

    class R:
        def raise_for_status(self): pass
        def json(self): return {"release_dates": [{"date": "2026-09-11"}, {"date": "2026-11-10"}]}
    monkeypatch.setattr(market.requests, "get", lambda *a, **k: calls.append(k["params"]) or R())
    monkeypatch.setenv("FRED_API_KEY", "k1,k2")
    monkeypatch.setattr(market, "_blob_sent", {})
    written = []
    monkeypatch.setattr(market, "write_blobs", lambda sb, rows: written.extend(rows) or 1)
    assert market.refresh_calendar(None, NOW) == 1  # NOW = 22 Aug 2026 IST
    ev = written[0]["payload"]["events"]
    assert [c["api_key"] for c in calls] == ["k1"] * len(market.FRED_RELEASES)
    assert ev == sorted(ev, key=lambda e: e["date"]) and ev[0]["date"] >= "2026-08-22"
    names = {e["name"] for e in ev}
    assert {"US CPI", "FOMC decision", "India CPI + IIP (MOSPI)", "India GDP, quarterly (MOSPI)"} <= names
    assert all(e["date"] <= "2026-10-06" for e in ev)          # 45-day window: 2026-11-10 and RBI 7 Oct trimmed
    assert "RBI MPC decision" not in names

    monkeypatch.delenv("FRED_API_KEY")
    calls.clear()
    written.clear()
    market.refresh_calendar(None, NOW)
    assert calls == [] and any(e["region"] == "IN" for e in written[0]["payload"]["events"])


POI_CSV = (
    '""Participant wise Open Interest (no. of contracts) in Equity Derivatives as on Sep 03, 2026"",,,,,,,,,,,,,,\n'
    "Client Type,Future Index Long,Future Index Short,Future Stock Long,Future Stock Short       ,"
    "Option Index Call Long,Option Index Put Long,Option Index Call Short,Option Index Put Short,"
    "Option Stock Call Long,Option Stock Put Long,Option Stock Call Short,Option Stock Put Short,"
    "Total Long Contracts      ,Total Short Contracts\n"
    "Client,261619,55623,3385672,209099,3751431,2367385,3368894,3169,1,2,3,4,12641969,9132988\n"
    "FII,33502,268604,3467706,2857809,1,2,3,4,5,6,7,8,5470310,4814011\n"
    "TOTAL,385477,385477,7989438,7989438,1,2,3,4,5,6,7,8,23205519,23205519\n")


def test_parse_participant_oi_strips_headers_and_drops_total():
    out = market.parse_participant_oi(POI_CSV)
    assert set(out) == {"Client", "FII"}
    assert out["FII"]["net_fut_idx"] == 33502 - 268604 and out["FII"]["total_short"] == 4814011
    assert out["Client"]["opt_idx_put_short"] == 3169
    assert market.parse_participant_oi("") == {} and market.parse_participant_oi("<html>blocked</html>") == {}


def test_refresh_participant_oi_steps_back_and_sets_prev(monkeypatch):
    urls = []

    class R:
        def __init__(self, url):
            self.status_code = 200 if url.endswith("21082026.csv") else 404
            self.text = POI_CSV if self.status_code == 200 else "not found"
    monkeypatch.setattr(market.requests, "get", lambda url, **k: urls.append(url) or R(url))
    monkeypatch.setattr(market, "_blob_sent", {})
    written = []
    monkeypatch.setattr(market, "write_blobs", lambda sb, rows: written.extend(rows) or 1)
    old = {"date": "2026-08-20", "rows": {"FII": {"net_fut_idx": -100000}}}
    sb = lambda *a, **k: [{"payload": old}]
    assert market.refresh_participant_oi(sb, NOW) == 1  # NOW = 22 Aug IST; 22nd 404s, 21st serves
    assert len(urls) == 2
    p = written[0]["payload"]
    assert p["date"] == "2026-08-21" and p["rows"]["FII"]["prev_net_fut_idx"] == -100000
    assert p["rows"]["Client"]["prev_net_fut_idx"] is None  # no old row for Client

    monkeypatch.setattr(market.requests, "get", lambda url, **k: R("x"))
    with pytest.raises(RuntimeError):
        market.refresh_participant_oi(sb, NOW)


def _pw_rows(pid, n, total, start_day=1):
    return [{"portid": pid, "date": f"2026-08-{start_day + i:02d}", "n_total": total, "n_tanker": 1}
            for i in range(n)]


def test_shape_shipping_week_vs_month_and_latest_port():
    chokes = (_pw_rows("chokepoint6", 30, 20)            # Aug 1-30: 20 a day
              + _pw_rows("chokepoint6", 7, 10, 31)       # Aug 31-37 (fake days): 10 a day
              + _pw_rows("chokepoint1", 3, 5)
              + [{"portid": "chokepoint9", "date": "2026-08-01", "n_total": 1}])
    chokes[-2]["date"] = 1756598400000  # epoch ms parses too
    ports = [{"portid": "port776", "date": "2026-08-27", "portcalls": 10, "import": 1.0, "export": 2.0},
             {"portid": "port776", "date": "2026-08-28", "portcalls": 14, "import": 3.0, "export": 4.0},
             {"portid": "port999", "date": "2026-08-28", "portcalls": 99}]
    c, p = market.shape_shipping(chokes, ports)
    hormuz = next(x for x in c if x["name"] == "Hormuz")
    assert (hormuz["avg7"], hormuz["avg30"], hormuz["pct"]) == (10.0, 20.0, -50.0)
    suez = next(x for x in c if x["name"] == "Suez")
    assert suez["pct"] is None and suez["avg30"] is None and suez["n_total"] == 5
    assert [x["name"] for x in c] == ["Hormuz", "Suez"]  # unknown chokepoint9 dropped
    assert p == [{"name": "JNPT", "date": "2026-08-28", "portcalls": 14, "import": 3.0, "export": 4.0}]


def test_refresh_shipping_publishes_partial_or_raises(monkeypatch):
    class R:
        def __init__(self, layer): self.layer = layer
        def raise_for_status(self): pass
        def json(self):
            if "Ports" in self.layer:
                raise RuntimeError("ports layer down")
            return {"features": [{"attributes": r} for r in _pw_rows("chokepoint6", 3, 50)]}
    monkeypatch.setattr(market.requests, "get", lambda url, **k: R(url))
    monkeypatch.setattr(market, "_blob_sent", {})
    written = []
    monkeypatch.setattr(market, "write_blobs", lambda sb, rows: written.extend(rows) or 1)
    assert market.refresh_shipping(None, NOW) == 1
    pl = written[0]["payload"]
    assert pl["ports"] == [] and pl["chokepoints"][0]["n_total"] == 50 and pl["asof"] == "2026-08-03"

    class Empty(R):
        def json(self): return {"features": []}
    monkeypatch.setattr(market.requests, "get", lambda url, **k: Empty(url))
    with pytest.raises(RuntimeError):
        market.refresh_shipping(None, NOW)


IMD_HTML = r"""
"areas": [
    {"title": "REGION : NORTH WEST INDIA", "id": "0", "color": "#C0C0C0", "info": "-1%",
     "balloonText": "<h6>REGION : NORTH WEST INDIA<\/h6> <p><em>Departure : -1%<\/br>Actual : 500 mm<\/br>Normal : 505 mm<\/em><\/p>"},
    {"title": "REGION : SOUTH PENINSULA", "id": "0", "color": "#C0C0C0", "info": "No Data",
     "balloonText": "<h6>x<\/h6> <p><em>Departure : No Data<\/em><\/p>"},
    {"title": "GUJARAT REGION      ", "id": "12", "color": "#FFFF01", "info": "-95%",
     "balloonText": "<h6>GUJARAT REGION<\/h6> <p><em>Departure : -95%<\/br>Actual : 10 mm<\/br>Normal : 200 mm<\/em><\/p>"},
    {"title": "KERALA", "id": "30", "color": "#0000FF", "info": "+40%"},
    {"title": "ASSAM & MEGHALAYA", "id": "3", "color": "#FFFF01", "info": "-20%",
     "balloonText": "<h6>ASSAM & MEGHALAYA<\/h6> <p><em>Departure : -20%<\/br>Actual : 1 mm<\/br>Normal : 2 mm<\/em><\/p>"},
    {"title": "COUNTRY : INDIA", "id": "0", "color": "#68DE58", "info": "-13%",
     "balloonText": "<h6>COUNTRY : INDIA<\/h6> <p><em>Departure : -13%<\/br>Actual : 629.7 mm<\/br>Normal : 727.9 mm<\/em><\/p>"}
]"""


def test_parse_imd_country_regions_and_extremes():
    p = market.parse_imd(IMD_HTML)
    assert p["country"] == {"dep_pct": -13, "actual_mm": 629.7, "normal_mm": 727.9}
    assert p["regions"] == [{"name": "North West India", "dep_pct": -1}]  # "No Data" region skipped
    assert [s["name"] for s in p["worst"]] == ["Gujarat Region", "Assam & Meghalaya", "Kerala"]
    assert p["best"][0] == {"name": "Kerala", "dep_pct": 40}  # no balloon still counts
    assert market.parse_imd("") is None and market.parse_imd("<html>maintenance</html>") is None


def test_refresh_monsoon_writes_blob_or_raises(monkeypatch):
    class R:
        text = IMD_HTML

        def raise_for_status(self): pass
    monkeypatch.setattr(market.requests, "get", lambda *a, **k: R())
    monkeypatch.setattr(market, "_blob_sent", {})
    written = []
    monkeypatch.setattr(market, "write_blobs", lambda sb, rows: written.extend(rows) or 1)
    assert market.refresh_monsoon(None, NOW) == 1
    pl = written[0]["payload"]
    assert pl["country"]["dep_pct"] == -13 and pl["asof"] == "2026-08-22"

    class Empty(R):
        text = "<html></html>"
    monkeypatch.setattr(market.requests, "get", lambda *a, **k: Empty())
    with pytest.raises(RuntimeError):
        market.refresh_monsoon(None, NOW)
