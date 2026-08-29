"""backfill_kaggle.py pure functions. Run: cd pipeline && py -3 -m pytest test_backfill.py"""
import backfill_kaggle as bk


def test_parse_num_commas_percent_blank():
    assert bk.parse_num("1,42,290") == 142290
    assert bk.parse_num("15.5%") == 15.5
    assert bk.parse_num("-66") == -66
    assert bk.parse_num("") is None
    assert bk.parse_num("-") is None
    assert bk.parse_num(None) is None


def test_fy_of_handles_iso_month_names_and_fy_rollover():
    assert bk.fy_of("2023-03-01") == "FY2023"
    assert bk.fy_of("2023-12-01") == "FY2024"   # Dec year-end falls in FY2024
    assert bk.fy_of("Mar 2023") == "FY2023"
    assert bk.fy_of("Dec 2023") == "FY2024"
    assert bk.fy_of("TTM") is None
    assert bk.fy_of("") is None


def test_quarter_of():
    assert bk.quarter_of("2023-09-01") == "2023-09"
    assert bk.quarter_of("Sep 2023") == "2023-09"
    assert bk.quarter_of("TTM") is None


ANNUAL_CSV = """,2022-03-01,2023-03-01,2023-09-01,TTM
Sales,613.0,702.0,380.0,718
EPS in Rs,10.1,13.5,7.0,14
Made Up Row,1,2,3,4
"""

QUARTER_CSV = """,2023-06-01,2023-09-01
Sales,191.0,200.0
OPM %,13.6,15.0
"""

SHP_CSV = """,2023-06-01,2023-09-01
Promoters,44.83,44.95
FIIs,0.72,0.72
DIIs,0.0,0.1
No. of Shareholders,25530.0,26100.0
"""


def test_parse_transposed_annual_filters_partial_year_and_ttm():
    out = bk.parse_transposed(ANNUAL_CSV, annual=True)
    # dominant month is March: the stray Sep half-year column and TTM both drop
    assert set(out) == {"FY2022", "FY2023"}
    assert out["FY2023"] == {"sales": 702, "eps": 13.5}  # unmapped label skipped


def test_parse_transposed_quarterly():
    out = bk.parse_transposed(QUARTER_CSV, annual=False)
    assert out == {"2023-06": {"sales": 191, "opm": 13.6},
                   "2023-09": {"sales": 200, "opm": 15}}


def test_parse_transposed_shareholding_has_fii_dii():
    out = bk.parse_transposed(SHP_CSV, annual=False)
    assert out["2023-09"]["promoters"] == 44.95
    assert out["2023-09"]["fiis"] == 0.72
    assert out["2023-09"]["diis"] == 0.1
    assert out["2023-09"]["n_holders"] == 26100


def test_validate_overlap_flags_divergence():
    kaggle = {("TCS", "annual", "FY2024"): {"sales": 100, "net_profit": 20},
              ("TCS", "annual", "FY2025"): {"sales": 250, "net_profit": 20},
              ("INFY", "annual", "FY2010"): {"sales": 50}}
    yahoo = {("TCS", "annual", "FY2024"): {"sales": 102, "net_profit": 21},
             ("TCS", "annual", "FY2025"): {"sales": 100, "net_profit": 21}}
    bad, checked = bk.validate_overlap(kaggle, yahoo)
    assert checked == 2
    assert len(bad) == 1 and bad[0][0] == ("TCS", "annual", "FY2025")


def test_rows_to_write_skips_existing_keys():
    items = {("TCS", "annual", "FY2016"): {"sales": 1},
             ("TCS", "annual", "FY2025"): {"sales": 2},
             ("TCS", "shareholding", "2023-09"): {"promoters": 44.95},
             ("TCS", "quarter", "2023-09"): {}}
    existing = {("TCS", "annual", "FY2025")}
    rows = bk.rows_to_write(items, existing, "2026-08-29T00:00:00+00:00")
    keyed = {(r["symbol"], r["kind"], r["period"]): r for r in rows}
    assert set(keyed) == {("TCS", "annual", "FY2016"), ("TCS", "shareholding", "2023-09")}
    assert keyed[("TCS", "annual", "FY2016")]["data"] == {"sales": 1, "src": "kaggle"}
    # shareholding rows carry no src tag (matches pipeline-written rows)
    assert keyed[("TCS", "shareholding", "2023-09")]["data"] == {"promoters": 44.95}
