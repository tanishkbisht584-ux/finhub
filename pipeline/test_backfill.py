"""backfill_kaggle.py pure functions. Run: cd pipeline && py -3 -m pytest test_backfill.py"""
import backfill_kaggle as bk


def test_parse_num_commas_percent_blank():
    assert bk.parse_num("1,42,290") == 142290
    assert bk.parse_num("15.5%") == 15.5
    assert bk.parse_num("-66") == -66
    assert bk.parse_num("") is None
    assert bk.parse_num("-") is None
    assert bk.parse_num(None) is None


def test_fy_from_year_labels():
    assert bk.fy_from("Mar 2016") == "FY2016"
    assert bk.fy_from("2016") == "FY2016"
    assert bk.fy_from("FY2016") == "FY2016"
    assert bk.fy_from("garbage") is None


def test_map_row_uses_column_map():
    row = {"Symbol": "TCS", "Year": "Mar 2016", "Sales": "1,08,646",
           "Net Profit": "24,270", "OPM %": "28%", "Junk": "x"}
    m = {"symbol": "Symbol", "year": "Year", "sales": "Sales",
         "net_profit": "Net Profit", "opm": "OPM %"}
    sym, period, data = bk.map_row(row, m)
    assert (sym, period) == ("TCS", "FY2016")
    assert data == {"sales": 108646, "net_profit": 24270, "opm": 28}


def test_map_row_missing_key_fields():
    assert bk.map_row({"Symbol": "", "Year": "2016"}, {"symbol": "Symbol", "year": "Year"}) is None
    assert bk.map_row({"Symbol": "TCS", "Year": "??"}, {"symbol": "Symbol", "year": "Year"}) is None


def test_validate_overlap_flags_divergence():
    kaggle = {("TCS", "FY2024"): {"sales": 100, "net_profit": 20},
              ("TCS", "FY2025"): {"sales": 250, "net_profit": 20},  # sales off 2.5x
              ("INFY", "FY2010"): {"sales": 50}}                    # no yahoo overlap
    yahoo = {("TCS", "FY2024"): {"sales": 102, "net_profit": 21},
             ("TCS", "FY2025"): {"sales": 100, "net_profit": 21}}
    bad, checked = bk.validate_overlap(kaggle, yahoo)
    assert checked == 2
    assert len(bad) == 1 and bad[0][0] == ("TCS", "FY2025")


def test_rows_to_write_skips_existing_periods():
    kaggle = {("TCS", "FY2016"): {"sales": 1}, ("TCS", "FY2025"): {"sales": 2}}
    existing = {("TCS", "FY2025")}
    rows = bk.rows_to_write(kaggle, existing, "2026-08-29T00:00:00+00:00")
    assert len(rows) == 1
    r = rows[0]
    assert (r["symbol"], r["kind"], r["period"]) == ("TCS", "annual", "FY2016")
    assert r["data"] == {"sales": 1, "src": "kaggle"}
