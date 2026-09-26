"""033 screener breadth: the derived columns, no network.
Run: cd pipeline && py -3 -m pytest test_breadth.py"""
from datetime import date, datetime, timedelta, timezone

import bhav
import fundamentals as fu
import history
import stockanalysis as sa

NOW = datetime(2026, 9, 26, 12, 0, tzinfo=timezone.utc)


def annuals():
    out = {}
    for i, sales in enumerate([100, 120, 150, 180, 220, 270, 300, 330, 360, 400, 450]):
        out[f"FY{2015 + i}"] = {"sales": sales, "net_profit": sales // 2, "opm": 20.0 + i * 0.5,
                                "roe": 15.0 + i, "roce": 18.0 + i, "eps": 5.0 + i}
    out["FY2025"].update({"reserves": 240, "equity_cap": 10, "borrowings": 50, "total_assets": 500,
                          "current_assets": 200, "current_liabilities": 100, "inventory": 40,
                          "retained_earnings": 230, "pbt": 300, "interest": 10, "depreciation": 20,
                          "other_income": 30, "tax_pct": 25.0, "cfo": 200, "fcf": 150, "div_payout": 30.0,
                          "debtor_days": 40, "inventory_days": 30, "payable_days": 50, "wc_days": 20,
                          "book_value": 90.0})
    return out


QUARTERS = {"2026-06": {"eps": 4.0, "sales": 120, "net_profit": 60, "opm": 22.0},
            "2026-03": {"eps": 3.5, "sales": 110, "net_profit": 55, "opm": 21.0},
            "2025-12": {"eps": 3.5, "sales": 105, "net_profit": 52, "opm": 21.0},
            "2025-09": {"eps": 3.0, "sales": 100, "net_profit": 50, "opm": 20.0},
            "2025-06": {"eps": 3.0, "sales": 100, "net_profit": 50, "opm": 20.0}}


def test_altman_z_formula_and_lender_none():
    a = annuals()["FY2025"]
    # WC/TA .2, RE/TA .46, EBIT/TA .62, MCap/TL 2800/250, Sales/TA .9
    z = 1.2 * 0.2 + 1.4 * 230 / 500 + 3.3 * 310 / 500 + 0.6 * 2800 / 250 + 450 / 500
    assert fu.altman_z(a, 2800) == round(z, 2)
    assert fu.altman_z({k: v for k, v in a.items() if k != "current_assets"}, 2800) is None
    assert fu.altman_z(a, None) is None


def test_breadth_cols_ratios_growth_and_holders():
    shp = ({"promoters": 51.0, "fiis": 20.5, "diis": 10.0, "public": 18.5, "n_holders": 12000},
           {"promoters": 50.0, "fiis": 21.0})
    r = fu.screener_metrics_row("TCS", "TCS", annuals(), QUARTERS, 51.0, 280.0, NOW,
                                shares=1e8, shp=shp)
    assert r["current_ratio"] == 2.0 and r["quick_ratio"] == 1.6 and r["ccc_days"] == 20
    assert r["sales_1y"] == 12.5 and r["sales_cagr_10y"] == fu._cagr(100, 450, 10)
    assert r["sales_yoy_q"] == 20.0 and r["sales_qoq"] == round(120 / 110 * 100 - 100, 1)
    assert r["sales_ttm_cr"] == 435 and r["opm_q"] == 22.0 and r["eps_ttm"] == 14.0
    assert r["roa"] == round(225 / 500 * 100, 1) and r["asset_turnover"] == 0.9
    assert r["capex_cr"] == 50 and r["cash_conv"] == round(200 / 225 * 100, 1)
    assert r["fii_pct"] == 20.5 and r["promoter_chg_q"] == 1.0 and r["fii_chg_q"] == -0.5
    assert r["n_holders"] == 12000 and r["equity_cr"] == 250 and r["debt_cr"] == 50
    assert r["other_income_pct"] == 10.0 and r["altman_z"] is not None
    assert set(fu.SCREENER_COLS) - {"altman_z"} <= set(r)


def test_breadth_cols_absent_data_stays_one_bucket_without_z():
    r = fu.screener_metrics_row("NEW", "New", {"FY2025": {"sales": 10, "net_profit": 1}}, {}, None, 10.0, NOW)
    assert "altman_z" not in r and r["current_ratio"] is None and r["fii_pct"] is None
    assert set(fu.SCREENER_COLS) <= set(r) | {"altman_z"}


def test_mcap_buckets_sebi_ranks():
    rows = [{"symbol": f"S{i}", "mcap_cr": 1000 - i} for i in range(300)] + [{"symbol": "X", "mcap_cr": None}]
    fu.mcap_buckets(rows)
    by = {r["symbol"]: r["mcap_bucket"] for r in rows}
    assert by["S0"] == "LARGE" and by["S99"] == "LARGE" and by["S100"] == "MID"
    assert by["S249"] == "MID" and by["S250"] == "SMALL" and by["X"] is None


def test_sa_money_columns_scaled_to_crores():
    raw = {"RELIANCE": {"s": "NSE-RELIANCE", "n": "RIL", "enterpriseValue": 2.5e13, "cash": 1e12,
                        "revPerEmployee": 5e6, "grossMargin": 41.2, "priceDate": "2026-09-25"}}
    row = sa.sa_rows(raw, {"RELIANCE"}, NOW)[0]
    assert row["ev_cr"] == 2.5e6 and row["cash_cr"] == 1e5 and row["rev_per_employee_l"] == 50
    assert row["gross_margin"] == 41.2 and "altman_z" not in row
    assert "allTimeLow" in sa.SA_KEYS and "zScore" not in sa.NUM


def test_tape_metrics_from_window():
    d = [{"date": "2026-09-25", "deliv_pct": 60.0, "turnover_cr": 12.0, "trades": 1000},
         {"date": "2026-09-24", "deliv_pct": 40.0, "turnover_cr": 8.0, "trades": 3000},
         {"date": "2026-09-23", "deliv_pct": None, "turnover_cr": None, "trades": None}]
    m = bhav.tape_metrics({"d": d})
    assert m == {"deliv_pct_last": 60.0, "deliv_pct_avg22": 50.0, "deliv_vs_avg": 1.2,
                 "turnover_avg22_cr": 10.0, "trades_avg22": 2000}
    assert bhav.tape_metrics(None) == {"deliv_pct_last": None, "deliv_pct_avg22": None, "deliv_vs_avg": None,
                                       "turnover_avg22_cr": None, "trades_avg22": None}


def test_history_metrics_row():
    start = date(2025, 9, 26)
    dates = [start + timedelta(days=i) for i in range(60)]
    closes = [100 + i for i in range(40)] + [139 - i for i in range(20)]   # peak at day 39, then down
    nifty = {d: 50.0 + i for i, d in enumerate(dates)}
    r = history.metrics_row("TCS", dates, closes, nifty, macd_hist=0.4)
    assert r["days_since_hi52"] == 20 and r["days_since_lo52"] == 59
    assert r["max_dd_1y"] == round((120 / 139 - 1) * 100, 1) and r["macd_hist"] == 0.4
    assert 0 < r["up_days_pct_1y"] < 100 and r["vol_1y"] > 0 and r["vol_30d"] > 0
    assert -1 <= r["corr_nifty_1y"] <= 1
    short = history.metrics_row("X", dates[:5], closes[:5], {})
    assert short["vol_1y"] is None and short["symbol"] == "X"
