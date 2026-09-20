"""bhav group: full-bhavcopy tape entries + rolling window, F&O ladder and
nearest-expiry chain, the daily refresh with fetches faked. No network."""
from datetime import date, datetime, timezone

import bhav
import market

NOW = datetime(2026, 9, 18, 14, 30, tzinfo=timezone.utc)  # 20:00 IST Fri 18 Sep
TCS = {"SYMBOL": "TCS", "SERIES": "EQ", "DATE1": "18-Sep-2026", "PREV_CLOSE": "2190.00",
       "OPEN_PRICE": "2177.20", "HIGH_PRICE": "2177.30", "LOW_PRICE": "2101.20", "LAST_PRICE": "2105.00",
       "CLOSE_PRICE": "2105.00", "AVG_PRICE": "2117.95", "TTL_TRD_QNTY": "6875428",
       "TURNOVER_LACS": "145618.29", "NO_OF_TRADES": "188367", "DELIV_QTY": "3972356", "DELIV_PER": "57.78"}


def fo_row(sym, typ, expiry, strike="", opt="", close="100", prev="90", oi="1000", chg="100", vol="10", und="2104.98"):
    return {"TckrSymb": sym, "FinInstrmTp": typ, "XpryDt": expiry, "StrkPric": strike, "OptnTp": opt,
            "ClsPric": close, "PrvsClsgPric": prev, "OpnIntrst": oi, "ChngInOpnIntrst": chg,
            "TtlTradgVol": vol, "UndrlygPric": und, "NewBrdLotQty": "225"}


def test_tape_entry_reads_the_full_bhavcopy_row():
    e = bhav.tape_entry(TCS)
    assert e == {"date": "2026-09-18", "prev": 2190.0, "open": 2177.2, "high": 2177.3, "low": 2101.2,
                 "close": 2105.0, "vwap": 2117.95, "vol": 6875428, "turnover_cr": 1456.18, "trades": 188367,
                 "deliv_qty": 3972356, "deliv_pct": 57.78}
    assert bhav.tape_entry({"DATE1": "junk"}) is None


def test_merge_tape_dedupes_dates_orders_newest_first_and_caps():
    prev = {"asof": "2026-09-17", "d": [{"date": f"2026-08-{d:02d}", "vol": d} for d in range(31, 1, -1)]}
    e = {"date": "2026-09-18", "vol": 1}
    t = bhav.merge_tape(prev, e)
    assert t["asof"] == "2026-09-18" and t["d"][0] is e and len(t["d"]) == bhav.TAPE_DAYS
    again = bhav.merge_tape(t, {"date": "2026-09-18", "vol": 2})  # same session re-pulled: replaced
    assert again["d"][0]["vol"] == 2 and len(again["d"]) == bhav.TAPE_DAYS
    assert bhav.merge_tape(None, e) == {"asof": "2026-09-18", "d": [e]}


def test_fno_of_ladder_pcr_max_strikes_and_chain_window():
    rows = [
        fo_row("TCS", "STF", "2026-10-27", close="2106.9", prev="2202.7", oi="500", chg="-20"),
        fo_row("TCS", "STF", "2026-09-29", close="2095", prev="2191.5", oi="6930000", chg="120000", vol="6930"),
        # nearest expiry chain: strikes 2000..2400 step 100, CE OI peaks at 2200, PE OI at 2000
        *[fo_row("TCS", "STO", "2026-09-29", strike=str(k), opt="CE", oi=str(oi), close="10")
          for k, oi in ((2000, 100), (2100, 300), (2200, 900), (2300, 400), (2400, 50))],
        *[fo_row("TCS", "STO", "2026-09-29", strike=str(k), opt="PE", oi=str(oi), close="12")
          for k, oi in ((2000, 800), (2100, 600), (2200, 200), (2300, 20), (2400, 5))],
        fo_row("TCS", "STO", "2026-10-27", strike="2100", opt="CE", oi="999999"),  # later expiry: ignored
        fo_row("TCS", "STO", "2026-09-01", strike="2100", opt="CE", oi="999999"),  # expired: ignored
    ]
    f = bhav.fno_of(rows, date(2026, 9, 18))
    assert f["underlying"] == 2104.98 and f["expiry"] == "2026-09-29"
    assert [x["expiry"] for x in f["futures"]] == ["2026-09-29", "2026-10-27"]  # sorted
    assert f["futures"][0]["chg_pct"] == -4.4 and f["futures"][0]["oi"] == 6930000 and f["futures"][0]["lot"] == 225
    assert f["ce_oi"] == 1750 and f["pe_oi"] == 1625 and f["pcr"] == 0.93
    assert f["max_ce"] == 2200 and f["max_pe"] == 2000 and f["max_ce_oi"] == 900 and f["max_pe_oi"] == 800
    assert [s["strike"] for s in f["chain"]] == [2000, 2100, 2200, 2300, 2400]  # all within ±6 of ATM
    assert f["chain"][1] == {"strike": 2100.0, "ce_oi": 300, "ce_oi_chg": 100, "ce_ltp": 10.0, "ce_vol": 10,
                             "pe_oi": 600, "pe_oi_chg": 100, "pe_ltp": 12.0, "pe_vol": 10}
    assert bhav.fno_of([fo_row("X", "STO", "2026-09-29", strike="1", opt="CE")], date(2026, 9, 18)) is None


def test_fno_chain_window_is_six_strikes_each_side():
    rows = [fo_row("A", "STF", "2026-09-29", und="1000")]
    rows += [fo_row("A", "STO", "2026-09-29", strike=str(k), opt="CE", oi="1") for k in range(500, 1600, 50)]
    f = bhav.fno_of(rows, date(2026, 9, 18))
    assert len(f["chain"]) == 12 and f["chain"][0]["strike"] == 700 and f["chain"][-1]["strike"] == 1250


def test_refresh_bhav_weekend_and_unpublished_are_noops(monkeypatch):
    assert bhav.refresh_bhav(None, NOW, day=date(2026, 9, 19)) == 0  # Saturday
    monkeypatch.setattr(bhav, "fetch_full", lambda d, session=None: None)
    assert bhav.refresh_bhav(None, NOW, day=date(2026, 9, 18)) == 0


def test_refresh_bhav_writes_tape_for_known_symbols_and_fno(monkeypatch):
    full = [TCS, {**TCS, "SYMBOL": "UNKNOWN"}, {**TCS, "SYMBOL": "TCS", "SERIES": "BE"}]
    fo = [fo_row("TCS", "STF", "2026-09-29"), fo_row("NOPE", "STF", "2026-09-29")]
    monkeypatch.setattr(bhav, "fetch_full", lambda d, session=None: full)
    monkeypatch.setattr(bhav, "fetch_fo", lambda d, session=None: fo)
    monkeypatch.setattr(bhav, "refresh_bse", lambda sb_, d: 0)
    posts = []

    def sb(method, path, **kw):
        if method == "GET":
            return [{"symbol": "TCS", "tape": {"asof": "2026-09-17", "d": [{"date": "2026-09-17", "vol": 5}]}},
                    {"symbol": "INFY", "tape": None}]
        posts.append(kw["json"])

    monkeypatch.setattr(market, "upsert", lambda sb_, rows, table, key: posts.append(rows) or len(rows))
    assert bhav.refresh_bhav(sb, NOW, day=date(2026, 9, 18)) == 2
    tape, fno = posts
    assert [r["symbol"] for r in tape] == ["TCS"]                      # EQ only, known only
    assert [e["date"] for e in tape[0]["tape"]["d"]] == ["2026-09-18", "2026-09-17"]
    assert [r["symbol"] for r in fno] == ["TCS"] and fno[0]["fno"]["futures"][0]["expiry"] == "2026-09-29"


def test_group_registered_daily():
    assert "bhav" in dict(market.GROUPS) and market.DAILY_SLOT["bhav"] == (19, 30)


def test_fno_max_oi_ignores_far_stale_strikes():
    rows = [fo_row("TCS", "STF", "2026-09-29", und="2105"),
            fo_row("TCS", "STO", "2026-09-29", strike="2800", opt="PE", oi="999999"),   # 33% away: ignored
            fo_row("TCS", "STO", "2026-09-29", strike="2000", opt="PE", oi="500"),
            fo_row("TCS", "STO", "2026-09-29", strike="2200", opt="CE", oi="700")]
    f = bhav.fno_of(rows, date(2026, 9, 18))
    assert f["max_pe"] == 2000 and f["max_pe_oi"] == 500 and f["max_ce"] == 2200


BSE_TCS = {"FinInstrmTp": "STK", "FinInstrmId": "532540", "ISIN": "INE467B01029", "TckrSymb": "TCS", "SctySrs": "A",
           "OpnPric": "2170.00", "HghPric": "2178.00", "LwPric": "2100.10", "ClsPric": "2101.00", "PrvsClsgPric": "2189.00",
           "TtlTradgVol": "340214", "TtlTrfVal": "722507049.00", "TtlNbOfTxsExctd": "25282"}


def test_tape_bse_entry_and_rows_join_by_isin():
    deliv = {"532540": (208459, 340214, 61.27)}
    e = bhav.tape_bse_entry(BSE_TCS, deliv, date(2026, 9, 18))
    assert e == {"date": "2026-09-18", "prev": 2189.0, "open": 2170.0, "high": 2178.0, "low": 2100.1, "close": 2101.0,
                 "vwap": 2123.68, "vol": 340214, "turnover_cr": 72.25, "trades": 25282, "deliv_qty": 208459, "deliv_pct": 61.27}
    cm = [BSE_TCS, {**BSE_TCS, "ISIN": "INE000000000"}, {**BSE_TCS, "FinInstrmTp": "IDX"}]
    rows = bhav.tape_bse_rows(cm, deliv, date(2026, 9, 18), {"INE467B01029": "TCS"},
                              {"TCS": {"asof": "2026-09-17", "d": [{"date": "2026-09-17", "vol": 1}]}})
    assert [r["symbol"] for r in rows] == ["TCS"]
    assert [x["date"] for x in rows[0]["tape_bse"]["d"]] == ["2026-09-18", "2026-09-17"]
    # no delivery file: the day still lands, delivery fields empty
    e2 = bhav.tape_bse_entry(BSE_TCS, {}, date(2026, 9, 18))
    assert e2["vol"] == 340214 and e2["deliv_qty"] is None and e2["deliv_pct"] is None


def test_refresh_bhav_runs_bse_after_nse_and_survives_its_failure(monkeypatch):
    monkeypatch.setattr(bhav, "fetch_full", lambda d, session=None: [TCS])
    monkeypatch.setattr(bhav, "fetch_fo", lambda d, session=None: None)
    monkeypatch.setattr(bhav, "refresh_bse", lambda sb, d: (_ for _ in ()).throw(RuntimeError("bse down")))
    monkeypatch.setattr(market, "upsert", lambda sb_, rows, table, key: len(rows))
    sb = lambda method, path, **kw: [{"symbol": "TCS", "tape": None}]
    assert bhav.refresh_bhav(sb, NOW, day=date(2026, 9, 18)) == 1   # NSE row written, BSE failure logged
