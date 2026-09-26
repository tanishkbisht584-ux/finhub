"""034 fno_chain: chain_of / chain_rows / max_pain, no network.
Run: cd pipeline && py -3 -m pytest test_chain.py"""
from datetime import date

import bhav
from test_bhav import fo_row

DAY = date(2026, 9, 25)


def rows():
    return [
        fo_row("TCS", "STF", "2026-09-29", close="2095", prev="2191.5", oi="6930000", chg="120000", vol="6930"),
        fo_row("TCS", "STF", "2026-10-27", close="2106.9", prev="2202.7", oi="500", chg="-20"),
        *[fo_row("TCS", "STO", "2026-09-29", strike=str(k), opt="CE", oi=str(oi), close="10", chg="5")
          for k, oi in ((2000, 100), (2100, 300), (2200, 900), (2300, 0))],
        *[fo_row("TCS", "STO", "2026-09-29", strike=str(k), opt="PE", oi=str(oi), close="12", chg="-3")
          for k, oi in ((2000, 800), (2100, 600), (2200, 200), (2300, 0))],
        fo_row("TCS", "STO", "2026-10-27", strike="2100", opt="CE", oi="50", close="40"),
        fo_row("TCS", "STO", "2026-09-01", strike="2100", opt="CE", oi="999"),        # expired: dropped
        fo_row("NIFTY", "IDF", "2026-09-29", close="25000", prev="24900", oi="100", und="24950"),
        fo_row("NIFTY", "IDO", "2026-09-29", strike="25000", opt="CE", oi="10", close="100", und="24950"),
        fo_row("NIFTY", "IDO", "2026-10-06", strike="25000", opt="PE", oi="20", close="90", und="24950"),
        fo_row("UNKNOWN", "STO", "2026-09-29", strike="10", opt="CE", oi="1"),
    ]


def test_chain_of_every_expiry_every_live_strike():
    d = bhav.chain_of([r for r in rows() if r["TckrSymb"] == "TCS"], DAY)
    assert d["u"] == 2104.98 and d["lot"] == 225
    assert [e["e"] for e in d["exp"]] == ["2026-09-29", "2026-10-27"]
    near = d["exp"][0]
    assert near["fut"] == [2095.0, 2191.5, 6930000, 120000, 6930]
    assert [s[0] for s in near["s"]] == [2000, 2100, 2200]            # 2300 had zero OI both sides
    assert near["s"][1] == [2100.0, 10.0, 300, 5, 10, 12.0, 600, -3, 10]
    assert near["pcr"] == round(1600 / 1300, 2) and d["pcr"] == near["pcr"]
    assert d["max_ce"] == 2200 and d["max_pe"] == 2000
    later = d["exp"][1]
    assert later["fut"][0] == 2106.9 and later["s"] == [[2100.0, 40.0, 50, 100, 10, None, 0, 0, 0]]
    assert later["pcr"] == 0.0   # calls only: 0 / 50, not unknown


def test_max_pain_is_the_least_payout_strike():
    s = [[100, None, 0, 0, 0, None, 1000, 0, 0],   # heavy puts at 100
         [110, None, 500, 0, 0, None, 500, 0, 0],
         [120, None, 1000, 0, 0, None, 0, 0, 0]]   # heavy calls at 120
    assert bhav.max_pain(s) == 110
    assert bhav.max_pain([]) is None


def test_chain_rows_known_stocks_plus_indices():
    out = {r["symbol"]: r for r in bhav.chain_rows(rows(), DAY, {"TCS"})}
    assert set(out) == {"TCS", "NIFTY"}                       # UNKNOWN dropped, index kept without `known`
    n = out["NIFTY"]
    assert n["asof"] == "2026-09-25" and [e["e"] for e in n["data"]["exp"]] == ["2026-09-29", "2026-10-06"]
    assert n["data"]["exp"][0]["fut"][0] == 25000.0 and n["data"]["max_pain"] == 25000
