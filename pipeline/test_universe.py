"""036 universe widening: SME tape rows, BSE-only rows, the yf ticker rule.
Run: cd pipeline && py -3 -m pytest test_universe.py"""
from datetime import date

import bhav
import market
from test_bhav import TCS


def test_yf_ticker_rule():
    assert market.yf("TCS") == "TCS.NS"
    assert market.yf("M&M") == "M&M.NS"
    assert market.yf("BSE:500010") == "500010.BO"
    assert market.yf("^NSEI") == "^NSEI"


def test_tape_rows_sme_series_carry_board_and_price():
    sme = {**TCS, "SYMBOL": "AAKAAR", "SERIES": "SM", "CLOSE_PRICE": "70.00"}
    rows = {r["symbol"]: r for r in bhav.tape_rows([TCS, sme, {**TCS, "SYMBOL": "X", "SERIES": "BE"}],
                                                     {"TCS": None, "AAKAAR": None, "X": None})}
    assert set(rows) == {"TCS", "AAKAAR"}
    assert rows["AAKAAR"]["board"] == "SME" and rows["AAKAAR"]["price"] == 70.0
    assert "board" not in rows["TCS"] and "price" not in rows["TCS"]   # mainboard price stays fundamentals.py's


def _bse(scrip, isin, name, val):
    return {"FinInstrmTp": "STK", "FinInstrmId": scrip, "ISIN": isin, "FinInstrmNm": name, "TckrSymb": name[:6],
            "TtlTradgVol": "1000", "TtlTrfVal": str(val), "PrvsClsgPric": "9", "OpnPric": "10", "HghPric": "11",
            "LwPric": "9", "ClsPric": "10", "TtlNbOfTxsExctd": "50"}


def test_bse_only_rows_skip_nse_isins_thin_names_and_seed_companies():
    cm = [_bse("500010", "INE001A01036", "HDFC", 5e7),        # ISIN known on NSE: not BSE-only
          _bse("512345", "INE999Z01010", "Tiny Co", 1e5),      # ₹1 L a day: too thin
          _bse("523456", "INE888Z01010", "Bigger Co", 5e6),    # qualifies
          _bse("534567", "INE777Z01010", "Old Friend", 1e5)]   # thin but already ours: kept
    rows, comps = bhav.bse_only_rows(cm, {}, date(2026, 9, 25), {"INE001A01036": "HDFC"},
                                     {"BSE:534567": None}, {"BSE:534567"})
    assert [r["symbol"] for r in rows] == ["BSE:523456", "BSE:534567"]
    assert rows[0]["board"] == "BSE" and rows[0]["price"] == 10.0 and rows[0]["name"] == "Bigger Co"
    assert rows[0]["tape_bse"]["d"][0]["date"] == "2026-09-25"
    assert comps == [{"nse_symbol": "BSE:523456", "name": "Bigger Co", "board": "BSE"}]
