"""fixup_snapshot.py pure functions. Run: cd pipeline && py -3 -m pytest test_fixup.py"""
from datetime import date

import fixup_snapshot as fx

# DRREDDY-style: 5:1 split effective Oct-2024 (ts 1727721000)
SPLITS = {"1727721000": {"numerator": 5.0, "denominator": 1.0}}
DIVS = {"1500263100": {"amount": 4.0},   # Jul-2017 -> FY2018
        "1531712700": {"amount": 4.0},   # Jul-2018 -> FY2019
        "1721898900": {"amount": 8.0}}   # Jul-2024 -> FY2025


def test_cum_split_factor_before_and_after():
    assert fx.cum_split_factor(SPLITS, date(2023, 3, 31)) == 5.0  # pre-split FY
    assert fx.cum_split_factor(SPLITS, date(2025, 3, 31)) == 1.0  # post-split FY
    assert fx.cum_split_factor({}, date(2023, 3, 31)) == 1.0


def test_cum_split_factor_compounds():
    two = {**SPLITS, "1600000000": {"numerator": 2.0, "denominator": 1.0}}  # Sep-2020
    assert fx.cum_split_factor(two, date(2019, 3, 31)) == 10.0
    assert fx.cum_split_factor(two, date(2022, 3, 31)) == 5.0


def test_period_end_dates():
    assert fx.period_end("annual", "FY2023") == date(2023, 3, 31)
    assert fx.period_end("quarter", "2023-09") == date(2023, 9, 30)
    assert fx.period_end("quarter", "2023-12") == date(2023, 12, 31)


def test_fy_dps_buckets_by_indian_fy():
    dps = fx.fy_dps(DIVS)
    assert dps["FY2018"] == 4.0 and dps["FY2019"] == 4.0 and dps["FY2025"] == 8.0


def test_adjust_rows_divides_per_share_fields_only_for_kaggle_pre_split():
    rows = [
        {"kind": "annual", "period": "FY2023",
         "data": {"sales": 1000, "eps": 455.0, "book_value": 500.0, "src": "kaggle"}},
        {"kind": "quarter", "period": "2023-09",
         "data": {"sales": 250, "eps": 120.0, "src": "kaggle"}},
        {"kind": "annual", "period": "FY2025",  # post-split: factor 1, untouched
         "data": {"sales": 1200, "eps": 95.0, "src": "kaggle"}},
        {"kind": "annual", "period": "FY2022",  # yahoo row: never touched
         "data": {"sales": 900, "eps": 400.0, "src": "yahoo"}},
        {"kind": "annual", "period": "FY2021",  # already adjusted: skipped
         "data": {"eps": 80.0, "src": "kaggle", "split_adj": 5.0}},
    ]
    out = fx.adjust_rows(rows, SPLITS)
    by = {(r["kind"], r["period"]): r["data"] for r in out}
    assert set(by) == {("annual", "FY2023"), ("quarter", "2023-09")}
    a = by[("annual", "FY2023")]
    assert a["eps"] == 91.0 and a["book_value"] == 100.0 and a["sales"] == 1000
    assert a["split_adj"] == 5.0
    assert by[("quarter", "2023-09")]["eps"] == 24.0


def test_add_div_payout_only_where_missing_and_eps_positive():
    rows = [{"kind": "annual", "period": "FY2018", "data": {"eps": 20.0, "src": "kaggle"}},
            {"kind": "annual", "period": "FY2019",
             "data": {"eps": 20.0, "div_payout": 33.0, "src": "kaggle"}},
            {"kind": "annual", "period": "FY2025", "data": {"eps": -5.0, "src": "kaggle"}}]
    out = fx.add_div_payout(rows, fx.fy_dps(DIVS))
    by = {r["period"]: r["data"] for r in out}
    assert list(by) == ["FY2018"]
    assert by["FY2018"]["div_payout"] == 20.0  # 4/20 = 20%
