"""fundamentals.py: pure-function checks, no network. Run: cd pipeline && py -3 -m pytest test_fundamentals.py"""
from datetime import datetime, timezone

import fundamentals as fu

NOW = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
CR = 1e7  # raw INR per crore


def n(v):
    return {"raw": v}


def ts_payload(series):
    """Condensed fundamentals-timeseries payload: {type: [(asOfDate, raw)]}
    plus one value-less entry (Yahoo emits meta+timestamp only for those)."""
    results = [{"meta": {"type": [t]}, "timestamp": [1],
                t: [{"asOfDate": d, "periodType": "12M", "reportedValue": {"raw": v}}
                    for d, v in vals]} for t, vals in series.items()]
    results.append({"meta": {"type": ["annualNothingHere"]}, "timestamp": []})
    return {"timeseries": {"result": results}}


def industrial_ts():
    """2 FYs + 2 quarters (+ a balance-sheet-only quarter end) for a maker."""
    a = {"TotalRevenue": [("2026-03-31", 1000 * CR), ("2025-03-31", 800 * CR)],
         "CostOfRevenue": [("2026-03-31", 500 * CR), ("2025-03-31", 400 * CR)],
         "InterestExpense": [("2026-03-31", 30 * CR), ("2025-03-31", 25 * CR)],
         "InterestIncome": [("2026-03-31", 12 * CR), ("2025-03-31", 10 * CR)],
         "OtherNonOperatingIncomeExpenses": [("2026-03-31", 8 * CR), ("2025-03-31", 5 * CR)],
         "ReconciledDepreciation": [("2026-03-31", 60 * CR), ("2025-03-31", 50 * CR)],
         "PretaxIncome": [("2026-03-31", 190 * CR), ("2025-03-31", 140 * CR)],
         "TaxProvision": [("2026-03-31", 47 * CR), ("2025-03-31", 35 * CR)],
         "NetIncome": [("2026-03-31", 143 * CR), ("2025-03-31", 105 * CR)],
         "MinorityInterests": [("2026-03-31", -7 * CR)],  # Yahoo's deduction; Screener's PAT keeps it
         "BasicEPS": [("2026-03-31", 14.3), ("2025-03-31", 10.5)],
         "BasicAverageShares": [("2026-03-31", 10 * CR), ("2025-03-31", 10 * CR)],
         "TotalAssets": [("2026-03-31", 2000 * CR), ("2025-03-31", 1800 * CR)],
         "StockholdersEquity": [("2026-03-31", 900 * CR), ("2025-03-31", 800 * CR)],
         "CommonStock": [("2026-03-31", 50 * CR), ("2025-03-31", 50 * CR)],
         "TotalDebt": [("2026-03-31", 300 * CR), ("2025-03-31", 400 * CR)],
         "TotalLiabilitiesNetMinorityInterest": [("2026-03-31", 1100 * CR), ("2025-03-31", 1000 * CR)],
         "NetPPE": [("2026-03-31", 850 * CR), ("2025-03-31", 700 * CR)],
         "ConstructionInProgress": [("2026-03-31", 50 * CR)],
         "LongTermEquityInvestment": [("2026-03-31", 100 * CR), ("2025-03-31", 250 * CR)],
         "InvestmentinFinancialAssets": [("2026-03-31", 150 * CR)],
         "OtherShortTermInvestments": [("2026-03-31", 50 * CR)],
         "CurrentAssets": [("2026-03-31", 700 * CR), ("2025-03-31", 600 * CR)],
         "CurrentLiabilities": [("2026-03-31", 400 * CR), ("2025-03-31", 350 * CR)],
         "AccountsReceivable": [("2026-03-31", 110 * CR), ("2025-03-31", 90 * CR)],
         "Inventory": [("2026-03-31", 137 * CR), ("2025-03-31", 120 * CR)],
         "AccountsPayable": [("2026-03-31", 115 * CR), ("2025-03-31", 100 * CR)],
         "OperatingCashFlow": [("2026-03-31", 250 * CR), ("2025-03-31", 200 * CR)],
         "InvestingCashFlow": [("2026-03-31", -120 * CR), ("2025-03-31", -100 * CR)],
         "FinancingCashFlow": [("2026-03-31", -80 * CR), ("2025-03-31", -60 * CR)],
         "CapitalExpenditure": [("2026-03-31", -100 * CR), ("2025-03-31", -90 * CR)],
         "ChangesInCash": [("2026-03-31", 50 * CR), ("2025-03-31", 40 * CR)],
         "CashDividendsPaid": [("2026-03-31", -30 * CR), ("2025-03-31", -25 * CR)]}
    q = {"TotalRevenue": [("2026-06-30", 280 * CR), ("2026-03-31", 260 * CR)],
         "InterestExpense": [("2026-06-30", 8 * CR), ("2026-03-31", 8 * CR)],
         "InterestIncome": [("2026-06-30", 2 * CR), ("2026-03-31", 2 * CR)],
         "OtherNonOperatingIncomeExpenses": [("2026-06-30", 3 * CR), ("2026-03-31", 2 * CR)],
         "ReconciledDepreciation": [("2026-06-30", 15 * CR)],  # Mar quarter: none reported
         "PretaxIncome": [("2026-06-30", 57 * CR), ("2026-03-31", 51 * CR)],
         "TaxProvision": [("2026-06-30", 14 * CR), ("2026-03-31", 13 * CR)],
         "NetIncome": [("2026-06-30", 43 * CR), ("2026-03-31", 38 * CR)],
         "BasicAverageShares": [("2026-06-30", 10 * CR), ("2026-03-31", 10 * CR)],
         "TotalAssets": [("2025-12-31", 1900 * CR)]}  # balance-sheet-only asOfDate
    series = {f"annual{k}": v for k, v in a.items()}
    series.update({f"quarterly{k}": v for k, v in q.items()})
    series["trailingTotalRevenue"] = [("2026-06-30", 1020 * CR)]
    series["quarterlyUnmappedThing"] = [("2026-06-30", 1)]
    return ts_payload(series)


STATS = {"shares": 10 * CR, "book_value": 90.0}


def shaped():
    return fu.shape_statements(fu.parse_timeseries(industrial_ts()), STATS)


# ---------- FY labels ----------

def test_fy_label_march_end_is_that_calendar_year():
    assert fu.fy_label("2024-03-31") == "FY2024"


def test_fy_label_after_march_rolls_into_next_fy():
    assert fu.fy_label("2024-12-31") == "FY2025"
    assert fu.fy_label("2024-06-30") == "FY2025"


# ---------- statement parsing (Yahoo fundamentals-timeseries) ----------

def test_parse_timeseries_routes_prefixes_and_skips_empty_or_unmapped():
    ts = fu.parse_timeseries(industrial_ts())
    assert set(ts) == {"annual", "quarterly", "trailing"}
    assert ts["annual"]["2026-03-31"]["totalRevenue"] == 1000 * CR
    assert ts["annual"]["2026-03-31"]["cwip"] == 50 * CR
    assert ts["quarterly"]["2026-06-30"]["netIncome"] == 43 * CR
    assert ts["trailing"]["2026-06-30"] == {"totalRevenue": 1020 * CR}
    assert "unmappedThing" not in str(ts)
    assert fu.parse_timeseries({}) == {"annual": {}, "quarterly": {}, "trailing": {}}


def test_parse_stats_reported_shares_and_book_value():
    j = {"quoteSummary": {"result": [{"defaultKeyStatistics": {
        "sharesOutstanding": n(10 * CR), "bookValue": n(90.0)}}]}}
    assert fu.parse_stats(j) == {"shares": 10 * CR, "book_value": 90.0}
    assert fu.parse_stats({"quoteSummary": {"result": []}}) == {}


def test_shape_statements_pnl_in_crores_screener_way():
    annuals, _ = shaped()
    a = annuals["FY2026"]
    assert a["sales"] == 1000 and a["other_income"] == 20  # 8 non-operating + 12 interest earned
    # Screener's operating profit: pbt + interest + depreciation - other income
    assert a["op_profit"] == 190 + 30 + 60 - 20 and a["expenses"] == 1000 - 260
    assert a["opm"] == 26.0
    assert a["interest"] == 30 and a["depreciation"] == 60
    assert a["pbt"] == 190 and a["net_profit"] == 150  # total PAT: owners' 143 + minority 7
    assert annuals["FY2025"]["net_profit"] == 105  # no minority line: as reported
    assert a["tax_pct"] == round(47 / 190 * 100, 1)
    assert a["eps"] == 14.3  # reported BasicEPS, never inferred
    assert a["div_payout"] == 20.0  # 30 / 150
    assert a["end"] == "2026-03-31" and list(annuals) == ["FY2026", "FY2025"]


def test_shape_statements_balance_sheet_sums_like_screener():
    annuals, _ = shaped()
    a = annuals["FY2026"]
    assert a["equity_cap"] == 50 and a["reserves"] == 850
    assert a["borrowings"] == 300  # TotalDebt outranks the short+long sum
    assert a["other_liab"] == 2000 - 900 - 300  # liabilities side sums to total
    assert a["fixed_assets"] == 850 - 50 and a["cwip"] == 50  # CWIP split out of NetPPE
    assert a["investments"] == 100 + 150 + 50
    assert a["other_assets"] == 2000 - 800 - 50 - 300
    assert a["total_assets"] == 2000
    assert a["book_value"] == 90.0 and "book_value" not in annuals["FY2025"]


def test_shape_statements_cash_flow_and_fcf():
    a = shaped()[0]["FY2026"]
    assert a["cfo"] == 250 and a["cfi"] == -120 and a["cff"] == -80
    assert a["net_cf"] == 50 and a["fcf"] == 150  # cfo - |capex|


def test_shape_statements_ratio_inputs():
    a = shaped()[0]["FY2026"]
    assert a["debtor_days"] == round(110 / 1000 * 365)
    assert a["inventory_days"] == round(137 / 500 * 365)
    assert a["payable_days"] == round(115 / 500 * 365)
    assert a["wc_days"] == round((700 - 400) / 1000 * 365)
    assert a["roce"] == round((190 + 30) / (2000 - 400) * 100, 1)
    assert a["roe"] == round(143 / 900 * 100, 1)  # owners' share over owners' equity


def test_shape_statements_quarters_eps_fallback_and_no_fake_opm():
    _, quarters = shaped()
    assert list(quarters) == ["2026-06", "2026-03"]  # the BS-only Dec end is not a quarter
    q = quarters["2026-06"]
    assert q["sales"] == 280 and q["op_profit"] == 57 + 8 + 15 - 5 and q["opm"] == 26.8
    assert q["eps"] == 4.3  # no BasicEPS: net income / reported average shares
    assert "div_payout" not in q
    q2 = quarters["2026-03"]  # no depreciation reported -> no operating profit at all
    assert q2["net_profit"] == 38 and "op_profit" not in q2 and "opm" not in q2


def test_shape_statements_lender_layout():
    # ICICIBANK-shaped: revenue = interest earned, interest = a cost, operating
    # profit = financing profit (pbt + depreciation - other income), no WC days
    ts = fu.parse_timeseries(ts_payload({
        "annualTotalRevenue": [("2026-03-31", 160 * CR)],
        "annualInterestIncome": [("2026-03-31", 400 * CR)],
        "annualNetInterestIncome": [("2026-03-31", 100 * CR)],
        "annualNonInterestIncome": [("2026-03-31", 60 * CR)],
        "annualInterestExpense": [("2026-03-31", 250 * CR)],
        "annualReconciledDepreciation": [("2026-03-31", 5 * CR)],
        "annualPretaxIncome": [("2026-03-31", 90 * CR)],
        "annualTaxProvision": [("2026-03-31", 20 * CR)],
        "annualNetIncome": [("2026-03-31", 70 * CR)],
        "annualBasicEPS": [("2026-03-31", 7.0)],
        "annualTotalAssets": [("2026-03-31", 5000 * CR)],
        "annualStockholdersEquity": [("2026-03-31", 800 * CR)],
        "annualCommonStock": [("2026-03-31", 10 * CR)],
        "annualInvestmentsAndAdvances": [("2026-03-31", 900 * CR)],
        "annualAccountsReceivable": [("2026-03-31", 40 * CR)],
        "annualCurrentAssets": [("2026-03-31", 1000 * CR)],
        "annualCurrentLiabilities": [("2026-03-31", 900 * CR)]}))
    a = fu.shape_statements(ts, {})[0]["FY2026"]
    assert a["sales"] == 400 and a["interest"] == 250 and a["other_income"] == 60
    assert a["op_profit"] == 90 + 5 - 60 and a["expenses"] == 400 - 250 - 35
    assert a["opm"] == round(35 / 400 * 100, 1)
    assert a["investments"] == 900 and a["roe"] == round(70 / 800 * 100, 1)
    for gone in ("debtor_days", "wc_days", "roce"):
        assert gone not in a


def test_shape_statements_missing_lines_no_crash():
    ts = fu.parse_timeseries(ts_payload({
        "annualTotalRevenue": [("2026-03-31", 1000 * CR)],
        "annualNetIncome": [("2026-03-31", 143 * CR)]}))
    annuals, quarters = fu.shape_statements(ts, {})
    a = annuals["FY2026"]
    assert a["sales"] == 1000 and a["net_profit"] == 143 and "eps" not in a
    for gone in ("op_profit", "opm", "inventory_days", "wc_days", "roce", "total_assets"):
        assert gone not in a
    assert quarters == {}
    assert fu.shape_statements(fu.parse_timeseries({}), {}) == ({}, {})


def test_overwritable_keeps_kaggle_and_nse_periods():
    new = {"FY2026": {"sales": 1}, "FY2024": {"sales": 2}, "FY2023": {"sales": 3},
           "FY2022": {"sales": 4}}
    prior = {"FY2024": {"src": "yahoo"}, "FY2023": {"src": "kaggle"}, "FY2022": {"src": "nse"}}
    assert set(fu._overwritable(new, prior)) == {"FY2026", "FY2024"}


def test_complete_quarters_filing_rows_or_yahoo_with_op_profit():
    rows = {"2026-06": {"src": "yahoo_ts", "sales": 1},  # no op_profit: the filing may fill it
            "2026-03": {"src": "yahoo_ts", "op_profit": 5},
            "2024-12": {"src": "nse"}, "2023-09": {"src": "kaggle"}}
    assert fu._complete_quarters(rows) == {"2026-03", "2024-12", "2023-09"}


# ---------- summary: CAGR + pros/cons ----------

def series(vals, first_fy=2020, **extra):
    """{FY....: {sales, net_profit, ...}} oldest FY first in vals."""
    return {f"FY{first_fy + i}": {"sales": v, "net_profit": v // 2, **extra}
            for i, v in enumerate(vals)}


def test_cagr_doubling_over_5_years():
    # 100 -> 200 over 5 intervals = 14.87%
    annuals = series([100, 115, 130, 160, 180, 200])
    s = fu.compute_summary(annuals, {}, [])
    assert s["cagr"]["sales"]["y5"] == 14.9
    assert s["cagr"]["profit"]["y5"] == 14.9
    assert s["cagr"]["sales"]["y3"] == round(((200 / 130) ** (1 / 3) - 1) * 100, 1)
    assert "y10" not in s["cagr"]["sales"]  # only 6 years of data


def test_price_cagr_from_monthly_closes():
    # 121 monthly closes growing a steady 12%/yr; a few gaps forward-fill.
    closes = [100.0 * 1.12 ** (i / 12) for i in range(121)]
    closes[3] = closes[50] = None
    s = fu.compute_summary({}, {}, closes)
    assert s["cagr"]["price"] == {"y10": 12.0, "y5": 12.0, "y3": 12.0, "y1": 12.0}


def test_ttm_sales_growth_from_quarters():
    quarters = {"2026-06": {"sales": 130}, "2026-03": {"sales": 120},
                "2025-12": {"sales": 110}, "2025-09": {"sales": 100},
                "2025-06": {"sales": 100}, "2025-03": {"sales": 100},
                "2024-12": {"sales": 100}, "2024-09": {"sales": 100}}
    s = fu.compute_summary({}, quarters, [])
    assert s["cagr"]["sales"]["ttm"] == 15.0  # 460 vs 400


def test_pros_cons_good_company():
    annuals = series([100, 120, 150, 180, 220, 270], roe=22.0, roce=25.0,
                     borrowings=5, reserves=200, equity_cap=10, div_payout=25.0,
                     interest=1, op_profit=40, debtor_days=30)
    s = fu.compute_summary(annuals, {}, [])
    joined = " ".join(s["pros"]).lower()
    assert "debt" in joined            # almost debt-free
    assert "return on equity" in joined
    assert "profit growth" in joined
    assert s["cons"] == []


def test_pros_cons_shareholding_trend_rules():
    sh = {"2025-09": {"fiis": 10.0, "promoters": 55.0},
          "2025-12": {"fiis": 11.0, "promoters": 55.0},
          "2026-03": {"fiis": 12.0, "promoters": 51.0},
          "2026-06": {"fiis": 13.0, "promoters": 51.0}}
    s = fu.compute_summary(series([100, 120, 150, 180, 220, 270]), {}, [],
                           shareholding=sh)
    assert any("FII" in p for p in s["pros"])          # 3 straight rises
    assert any("Promoter holding" in c for c in s["cons"])  # 55 -> 51 = -4pp
    flat = {p: {"fiis": 10.0, "promoters": 55.0} for p in sh}
    s2 = fu.compute_summary(series([100, 120, 150, 180, 220, 270]), {}, [],
                            shareholding=flat)
    assert not any("FII" in p for p in s2["pros"])
    assert not any("Promoter holding" in c for c in s2["cons"])


def test_pros_cons_dividend_cut():
    annuals = series([100, 110, 120, 130, 140, 150],
                     eps=10.0, div_payout=40.0)
    annuals[max(annuals)]["div_payout"] = 10.0  # dps 4 -> 1: a cut
    s = fu.compute_summary(annuals, {}, [])
    assert any("Dividend" in c and "cut" in c.lower() for c in s["cons"])


def test_pros_cons_weak_company():
    annuals = series([100, 101, 102, 103, 104, 105], roe=4.0, roce=5.0,
                     borrowings=500, reserves=100, equity_cap=10, div_payout=0.0,
                     interest=60, op_profit=70, debtor_days=200)
    s = fu.compute_summary(annuals, {}, [])
    joined = " ".join(s["cons"]).lower()
    assert "sales growth" in joined
    assert "return on equity" in joined
    assert "interest" in joined        # low coverage
    assert "debtor days" in joined
    assert s["pros"] == []


# ---------- NSE deep: shareholding + docs ----------

def test_shape_shareholding_periods_and_floats():
    rows = [{"symbol": "TCS", "date": "30-Jun-2026", "pr_and_prgrp": "50.48",
             "public_val": "49.02", "employeeTrusts": "0.50"},
            {"symbol": "TCS", "date": "31-Mar-2026", "pr_and_prgrp": "50.50",
             "public_val": "49.50", "employeeTrusts": "-"}]
    sh = fu.shape_shareholding(rows)
    assert list(sh) == ["2026-06", "2026-03"]
    assert sh["2026-06"] == {"promoters": 50.48, "public": 49.02, "employee_trusts": 0.5}
    assert sh["2026-03"] == {"promoters": 50.5, "public": 49.5}  # dash dropped


def test_shape_shareholding_garbage_rows_skipped():
    assert fu.shape_shareholding([{"date": "not-a-date"}, {}]) == {}


def test_shape_docs():
    reports = {"data": [{"fromYr": "2025", "toYr": "2026", "fileName": "https://x/ar26.pdf"},
                        {"fromYr": "2024", "toYr": "2025", "fileName": "https://x/ar25.pdf"}]}
    anns = [{"desc": "Board Meeting", "an_dt": "28-Aug-2026 18:05:00",
             "attchmntFile": "https://x/a.pdf", "attchmntText": "Outcome of board meeting"},
            {"desc": None, "an_dt": None, "attchmntFile": None}]
    d = fu.shape_docs(reports, anns)
    assert d["annual_reports"] == [{"fy": "2026", "url": "https://x/ar26.pdf"},
                                   {"fy": "2025", "url": "https://x/ar25.pdf"}]
    assert d["announcements"][0] == {"date": "28-Aug-2026 18:05:00",
                                     "subject": "Board Meeting",
                                     "url": "https://x/a.pdf"}
    assert len(d["announcements"]) == 1  # empty row dropped


def test_shape_docs_splits_concalls_out_of_announcements():
    anns = [{"desc": "Transcript of Earnings Conference Call", "an_dt": "1", "attchmntFile": "u1"},
            {"desc": "Investor Presentation Q1", "an_dt": "2", "attchmntFile": "u2"},
            {"desc": "Analyst / Institutional Investor Meet intimation", "an_dt": "3", "attchmntFile": "u3"},
            {"desc": "Board Meeting outcome", "an_dt": "4", "attchmntFile": "u4"}]
    d = fu.shape_docs(None, anns)
    assert [c["url"] for c in d["concalls"]] == ["u1", "u2", "u3"]
    assert [a["url"] for a in d["announcements"]] == ["u4"]


def test_shape_docs_credit_ratings_from_rating_agency_filings():
    anns = [{"desc": "Credit Rating", "an_dt": "1", "attchmntFile": "u1",
             "attchmntText": "CRISIL Ratings reaffirms AAA/Stable"},
            {"desc": "Announcement under Regulation 30 (LODR)-Credit Rating", "an_dt": "2",
             "attchmntFile": "u2"},
            {"desc": "Intimation", "an_dt": "3", "attchmntFile": "u3",
             "attchmntText": "ICRA has assigned [ICRA]AA+ to the NCD programme"},
            {"desc": "Transcript of earnings call", "an_dt": "4", "attchmntFile": "u4"},
            {"desc": "Board Meeting outcome", "an_dt": "5", "attchmntFile": "u5"}]
    d = fu.shape_docs(None, anns)
    assert [r["url"] for r in d["credit_ratings"]] == ["u1", "u2", "u3"]
    assert d["credit_ratings"][0]["agency"] is None  # matched on "credit rating" itself
    assert d["credit_ratings"][2]["agency"] == "ICRA"
    assert [c["url"] for c in d["concalls"]] == ["u4"]
    assert [a["url"] for a in d["announcements"]] == ["u5"]
    assert "credit_ratings" not in fu.shape_docs(None, anns[3:])


# ---------- SHP XBRL: FII/DII split (plain XBRL, contexts probed 2026-08-29) ----------

def _shp(el, ctx, v):
    return f'<in-bse-shp:{el} contextRef="{ctx}">{v}</in-bse-shp:{el}>'


SHP_XBRL = f"""<?xml version="1.0"?><xbrli:xbrl>
{_shp("ShareholdingAsAPercentageOfTotalNumberOfShares", "ShareholdingOfPromoterAndPromoterGroup_ContextI", "0.5048")}
{_shp("ShareholdingAsAPercentageOfTotalNumberOfShares", "InstitutionsForeign_ContextI", "0.172")}
{_shp("ShareholdingAsAPercentageOfTotalNumberOfShares", "InstitutionsDomestic_ContextI", "0.2119")}
{_shp("ShareholdingAsAPercentageOfTotalNumberOfShares", "Governments_ContextI", "0.001")}
{_shp("ShareholdingAsAPercentageOfTotalNumberOfShares", "NonInstitutions_ContextI", "0.1104")}
{_shp("ShareholdingAsAPercentageOfTotalNumberOfShares", "MutualFundsOrUTI_ContextI", "0.1011")}
{_shp("ShareholdingAsAPercentageOfTotalNumberOfShares", "IndividualsOrHUF_Context15", "0.0012")}
{_shp("NumberOfShareholders", "ShareholdingPattern_ContextI", "4651863")}
{_shp("NumberOfShareholders", "Banks_ContextI", "131")}
</xbrli:xbrl>"""


def test_parse_shp_xml_category_totals_as_percent():
    m = fu.parse_shp_xml(SHP_XBRL)
    # Screener's rows: fiis = Institutions (Foreign), diis = Institutions
    # (Domestic), public = Non-institutions — verified against the crawl
    assert m == {"promoters": 50.48, "fiis": 17.2, "diis": 21.19,
                 "govt": 0.1, "public": 11.04, "n_holders": 4651863}


def test_parse_shp_xml_empty_or_alien():
    assert fu.parse_shp_xml("<xml></xml>") == {}


# ---------- screening engine ----------

def annuals_for_screen(**newest_extra):
    """6 growing FYs; newest carries eps/book value etc. for ratio math."""
    base = series([100, 120, 150, 180, 220, 270])  # 2020..2025, profit = sales//2
    newest = base["FY2025"]
    newest.update({"eps": 13.5, "net_profit": 135, "roe": 18.0, "roce": 22.0,
                   "opm": 21.0, "borrowings": 50, "reserves": 240, "equity_cap": 10,
                   "div_payout": 25.0, "book_value": 90.0, **newest_extra})
    return base


QUARTERS_EPS = {"2026-06": {"eps": 4.0}, "2026-03": {"eps": 3.5},
                "2025-12": {"eps": 3.5}, "2025-09": {"eps": 3.0}}


def row_for(**kw):
    args = {"sym": "TCS", "name": "TCS Ltd",
            "annuals": annuals_for_screen(), "quarters": QUARTERS_EPS,
            "promoter_pct": 50.5, "price": 280.0, "now": NOW,
            "shares": None, "dps_ttm": None}
    args.update(kw)
    return fu.screener_metrics_row(**args)


def test_ttm_eps_needs_four_quarters():
    assert fu.ttm_eps(QUARTERS_EPS) == 14.0
    assert fu.ttm_eps({k: QUARTERS_EPS[k] for k in list(QUARTERS_EPS)[:3]}) is None
    assert fu.ttm_eps({}) is None


def test_screener_row_pe_prefers_ttm_eps():
    r = row_for()
    assert r["pe"] == round(280.0 / 14.0, 2)
    r2 = row_for(quarters={})  # falls back to newest annual eps
    assert r2["pe"] == round(280.0 / 13.5, 2)


def test_screener_row_negative_eps_no_pe_no_div_yield():
    ann = annuals_for_screen(eps=-2.0, net_profit=-20)
    r = row_for(annuals=ann, quarters={})
    assert r["pe"] is None and r["div_yield"] is None
    # loss-makers still have shares (signs cancel) and therefore an mcap
    assert r["mcap_cr"] == round(280.0 * 10, 1)


def test_screener_row_mcap_from_np_over_eps():
    r = row_for()
    assert r["mcap_cr"] == round(280.0 * (135 / 13.5), 1)  # 2800 Cr


def test_screener_row_pb_book_value_then_equity_fallback():
    assert row_for()["pb"] == round(280.0 / 90.0, 2)
    ann = annuals_for_screen()
    del ann["FY2025"]["book_value"]
    r = row_for(annuals=ann)  # (reserves+equity_cap)/shares = 250/10 = 25/share
    assert r["pb"] == round(280.0 / 25.0, 2)


def test_screener_row_negative_equity_nulls_pb_and_de():
    ann = annuals_for_screen(reserves=-100, equity_cap=10)
    del ann["FY2025"]["book_value"]
    r = row_for(annuals=ann)
    assert r["pb"] is None and r["de"] is None


def test_screener_row_missing_borrowings_with_equity_is_de_zero():
    ann = annuals_for_screen()
    del ann["FY2025"]["borrowings"]
    assert row_for(annuals=ann)["de"] == 0.0
    assert row_for()["de"] == round(50 / 250, 2)


def test_screener_row_bank_without_opm_still_emits_row():
    ann = annuals_for_screen()
    del ann["FY2025"]["opm"]
    r = row_for(annuals=ann)
    assert r["opm"] is None and r["roe"] == 18.0


def test_screener_row_no_price_keeps_fundamental_metrics():
    r = row_for(price=None)
    assert r["price"] is None and r["pe"] is None and r["mcap_cr"] is None
    assert r["roe"] == 18.0 and r["sales_cagr_5y"] is not None


def test_screener_row_cagr_and_promoter():
    r = row_for()
    assert r["sales_cagr_5y"] == 22.0  # 100 -> 270 over 5y
    assert r["profit_cagr_3y"] is not None
    assert r["promoter_pct"] == 50.5


def test_screener_row_roe_falls_back_to_np_over_equity():
    # kaggle annuals carry no roe field; np/equity fills it (135/250 = 54%)
    ann = annuals_for_screen()
    del ann["FY2025"]["roe"]
    assert row_for(annuals=ann)["roe"] == round(135 / 250 * 100, 1)
    ann2 = annuals_for_screen(reserves=-100, equity_cap=10)
    del ann2["FY2025"]["roe"]
    assert row_for(annuals=ann2)["roe"] is None  # negative equity: no ROE


def test_screener_row_always_full_column_set():
    sparse = row_for(annuals={"FY2025": {"sales": 10}}, quarters={},
                     promoter_pct=None, price=None)
    assert set(sparse) == set(fu.SCREENER_COLS)


# ---------- results XBRL: the 2023-2025 quarterly hole ----------
# fixture condensed from the real RELIANCE Q3-FY25 filing (probe 2026-08-29)

def _fin(el, ctx, v):
    return f'<in-bse-fin:{el} contextRef="{ctx}" unitRef="INR">{v}</in-bse-fin:{el}>'


RESULTS_XML = f"""<?xml version="1.0"?><xbrli:xbrl>
<xbrli:context id="OneD"><xbrli:period><xbrli:startDate>2024-10-01</xbrli:startDate>
<xbrli:endDate>2024-12-31</xbrli:endDate></xbrli:period></xbrli:context>
<xbrli:context id="FourD"><xbrli:period><xbrli:startDate>2024-04-01</xbrli:startDate>
<xbrli:endDate>2024-12-31</xbrli:endDate></xbrli:period></xbrli:context>
{_fin("RevenueFromOperations", "OneD", "2438650000000.00")}
{_fin("RevenueFromOperations", "FourD", "7000000000000.00")}
{_fin("OtherIncome", "OneD", "42140000000.00")}
{_fin("FinanceCosts", "OneD", "61790000000.00")}
{_fin("DepreciationDepletionAndAmortisationExpense", "OneD", "131810000000.00")}
{_fin("ProfitBeforeTax", "OneD", "286430000000.00")}
{_fin("TaxExpense", "OneD", "68390000000.00")}
{_fin("ProfitLossForPeriod", "OneD", "219300000000.00")}
{_fin("BasicEarningsLossPerShareFromContinuingAndDiscontinuedOperations", "OneD", "13.70")}
</xbrli:xbrl>"""


def test_parse_results_xml_maps_quarter_from_matching_context():
    q = fu.parse_results_xml(RESULTS_XML, "01-Oct-2024", "31-Dec-2024")
    assert q["sales"] == 243865            # Cr, from the OneD context, not YTD
    assert q["other_income"] == 4214 and q["interest"] == 6179
    assert q["depreciation"] == 13181 and q["pbt"] == 28643
    assert q["net_profit"] == 21930 and q["eps"] == 13.7
    assert q["tax_pct"] == round(68390 / 286430 * 100, 1)
    # Screener-style operating profit: pbt + interest + depreciation - other income
    assert q["op_profit"] == 28643 + 6179 + 13181 - 4214
    assert q["expenses"] == q["sales"] - q["op_profit"]
    assert q["opm"] == round(q["op_profit"] / q["sales"] * 100, 1)
    assert q["end"] == "2024-12-31" and q["src"] == "nse"


def test_parse_results_xml_no_matching_context():
    assert fu.parse_results_xml(RESULTS_XML, "01-Jan-2024", "31-Mar-2024") == {}


def test_pick_results_filings_prefers_consolidated_skips_banks_and_known():
    rows = [
        {"fromDate": "01-Oct-2024", "toDate": "31-Dec-2024", "consolidated": "Consolidated",
         "bank": "N", "xbrl": "u-con"},
        {"fromDate": "01-Oct-2024", "toDate": "31-Dec-2024", "consolidated": "Non-Consolidated",
         "bank": "N", "xbrl": "u-std"},
        {"fromDate": "01-Jul-2024", "toDate": "30-Sep-2024", "consolidated": "Non-Consolidated",
         "bank": "N", "xbrl": "u-q2"},
        {"fromDate": "01-Apr-2024", "toDate": "30-Jun-2024", "consolidated": "Consolidated",
         "bank": "Y", "xbrl": "u-bank"},
        {"fromDate": "01-Jan-2024", "toDate": "31-Mar-2024", "consolidated": "Consolidated",
         "bank": "N", "xbrl": None},
        {"fromDate": "01-Oct-2023", "toDate": "31-Dec-2023", "consolidated": "Consolidated",
         "bank": "N", "xbrl": "u-known"},
    ]
    picked = fu.pick_results_filings(rows, have={"2023-12"}, cap=5)
    assert [(f["xbrl"], fu.quarter_of_nse(f["toDate"])) for f in picked] == \
        [("u-con", "2024-12"), ("u-q2", "2024-09"), ("u-bank", "2024-06")]


def test_is_bank_filing_flag_or_banking_url():
    assert fu.is_bank_filing({"bank": "B", "xbrl": "u"})
    assert fu.is_bank_filing({"xbrl": "https://x/INTEGRATED_FILING_BANKING_1.xml"})
    assert not fu.is_bank_filing({"bank": "N", "xbrl": "https://x/INDAS_1.xml"})


BANK_XML = f"""<?xml version="1.0"?><xbrli:xbrl>
<xbrli:context id="OneD"><xbrli:period><xbrli:startDate>2026-04-01</xbrli:startDate>
<xbrli:endDate>2026-06-30</xbrli:endDate></xbrli:period></xbrli:context>
{_fin("InterestEarned", "OneD", "905753300000")}
{_fin("OtherIncome", "OneD", "425350300000")}
{_fin("InterestExpended", "OneD", "476256300000")}
{_fin("OperatingExpenses", "OneD", "544887300000")}
{_fin("ProfitLossFromOrdinaryActivitiesBeforeTax", "OneD", "271931600000")}
{_fin("TaxExpense", "OneD", "68104700000")}
{_fin("ProfitLossForThePeriod", "OneD", "203826900000")}
{_fin("BasicEarningsPerShareAfterExtraordinaryItems", "OneD", "12.5")}
</xbrli:xbrl>"""


def test_parse_results_xml_bank_taxonomy_is_screeners_bank_layout():
    # HDFCBANK Jun-2026 integrated filing (probe 2026-09-15)
    q = fu.parse_results_xml(BANK_XML, "01-Apr-2026", "30-Jun-2026", bank=True)
    assert q["sales"] == 90575 and q["interest"] == 47626 and q["other_income"] == 42535
    assert q["pbt"] == 27193 and q["net_profit"] == 20383 and q["eps"] == 12.5
    assert q["op_profit"] == 27193 - 42535  # financing profit
    assert q["expenses"] == 90575 - 47626 - q["op_profit"]  # = opex + provisions
    assert "depreciation" not in q
    assert fu.parse_results_xml(BANK_XML, "01-Apr-2026", "30-Jun-2026") == {}  # industrial map: nothing


def test_integrated_rows_shape_like_legacy_filings():
    rows = [{"qe_Date": "31-MAR-2026", "consolidated": "Consolidated", "bank": "N",
             "type": "Integrated Filing- Financials", "xbrl": "https://x/INDAS_1.xml"},
            {"qe_Date": "31-DEC-2025", "consolidated": "Non-Consolidated",
             "type": "Integrated Filing- Financials", "xbrl": "https://x/INDAS_2.xml"},
            {"qe_Date": "31-MAR-2026", "type": "Integrated Filing- Governance", "xbrl": "https://x/g.xml"},
            {"qe_Date": "30-SEP-2025", "type": "Integrated Filing- Financials", "xbrl": "-"},
            {"qe_Date": "not a date", "type": "Integrated Filing- Financials", "xbrl": "https://x/z.xml"}]
    rows.append({"qe_Date": "30-JUN-2026", "consolidated": "Consolidated",
                 "type": "Integrated Filing- Financials",
                 "xbrl": "https://x/INTEGRATED_FILING_BANKING_9.xml"})
    out = fu.integrated_rows(rows)
    assert out == [
        {"fromDate": "01-Jan-2026", "toDate": "31-Mar-2026", "consolidated": "Consolidated",
         "bank": "N", "xbrl": "https://x/INDAS_1.xml"},
        {"fromDate": "01-Oct-2025", "toDate": "31-Dec-2025", "consolidated": "Non-Consolidated",
         "bank": "N", "xbrl": "https://x/INDAS_2.xml"},
        {"fromDate": "01-Apr-2026", "toDate": "30-Jun-2026", "consolidated": "Consolidated",
         "bank": "B", "xbrl": "https://x/INTEGRATED_FILING_BANKING_9.xml"}]
    # derived quarter start feeds the legacy picker and context matcher unchanged
    picked = fu.pick_results_filings(out, have=set(), cap=5)
    assert [fu.quarter_of_nse(f["toDate"]) for f in picked] == ["2026-06", "2026-03", "2025-12"]


def test_basis_ok_accepts_matching_overlap_rejects_standalone():
    prior = {"FY2023": {"sales": 876396, "src": "kaggle"},
             "FY2022": {"sales": 698672, "src": "kaggle"}}
    # TCS-like: same consolidated basis -> accept
    assert fu.basis_ok({"FY2023": {"sales": 225458}}, {"FY2023": {"sales": 225458, "src": "kaggle"}})
    # RELIANCE-like: Yahoo standalone is 40% below verified consolidated -> reject
    assert not fu.basis_ok({"FY2023": {"sales": 529773}}, prior)
    # no overlap year (post-2023 listing) -> nothing contradicts, accept
    assert fu.basis_ok({"FY2026": {"sales": 100}}, {})
    # prior rows that are themselves yahoo don't count as a reference
    assert fu.basis_ok({"FY2023": {"sales": 100}},
                       {"FY2023": {"sales": 900, "src": "yahoo"}})
    # reference lacks sales (pre-fix bank rows): eps is the fallback check —
    # HDFCBANK-like: yahoo eps 28.62 vs Screener's ~82 -> reject
    assert not fu.basis_ok({"FY2023": {"sales": 118057, "eps": 28.62}},
                           {"FY2023": {"eps": 82.4, "src": "kaggle"}})
    assert fu.basis_ok({"FY2023": {"eps": 80.1}},
                       {"FY2023": {"eps": 82.4, "src": "kaggle"}})


def test_ttm_dps_trailing_365_days():
    day = 86400
    now_ts = int(NOW.timestamp())
    divs = {str(now_ts - 30 * day): {"amount": 6.0},
            str(now_ts - 300 * day): {"amount": 4.0},
            str(now_ts - 400 * day): {"amount": 99.0}}  # outside the window
    assert fu.ttm_dps(divs, NOW) == 10.0
    assert fu.ttm_dps({}, NOW) is None


def test_screener_row_prefers_reported_shares_for_mcap_and_pb():
    # reported 12 Cr shares beats the np/eps inference (10 Cr)
    r = row_for(shares=12 * 1e7)
    assert r["mcap_cr"] == round(280.0 * 12, 1)
    r2 = row_for()  # no shares -> inference fallback stays
    assert r2["mcap_cr"] == round(280.0 * 10, 1)


def test_screener_row_div_yield_from_ttm_dps_only():
    assert row_for(dps_ttm=5.6)["div_yield"] == round(5.6 / 280.0 * 100, 2)
    # payout-derived approximation is gone: without dps_ttm there is no yield
    assert row_for()["div_yield"] is None


def test_warm_universe_priority_and_cap():
    ages = {"COLD1": "2026-08-01T00:00:00", "COLD2": "2026-08-10T00:00:00",
            "NIFTY": "2026-08-20T00:00:00", "FOLLOWED": "2026-08-14T00:00:00",
            "FRESH": "2026-08-29T11:00:00"}  # < 7d old at NOW -> excluded
    out = fu.warm_universe(ages, priority=["FOLLOWED", "NIFTY"], now=NOW, cap=3)
    # priority symbols first, then oldest-summary-first; fresh one dropped
    assert out == ["FOLLOWED", "NIFTY", "COLD1"]


def test_scale_px_rows_scales_price_linked_columns_only():
    rows = [{"symbol": "TCS", "price": 100.0, "pe": 20.0, "pb": 4.0, "mcap_cr": 1000.0},
            {"symbol": "INFY", "price": 200.0, "pe": None, "pb": 5.0, "mcap_cr": 2000.0},
            {"symbol": "NOPX", "price": None, "pe": 9.0, "pb": 1.0, "mcap_cr": 10.0}]
    out = fu.scale_px_rows(rows, {"TCS": 110.0, "NOPX": 50.0}, "T")
    assert len(out) == 1  # INFY has no new price; NOPX has no base to scale
    r = out[0]
    assert r["price"] == 110.0 and r["pe"] == 22.0 and r["pb"] == 4.4
    assert r["mcap_cr"] == 1100.0 and r["updated_at"] == "T"


# ---------- table rows ----------

def test_fundamentals_rows_shapes_and_pk():
    annuals = {"FY2026": {"sales": 10, "end": "2026-03-31"}}
    quarters = {"2026-06": {"sales": 3}}
    summary = {"cagr": {}, "pros": [], "cons": []}
    rows = fu.fundamentals_rows("TCS", annuals, quarters, summary, NOW,
                                shareholding={"2026-06": {"promoters": 50.5}},
                                docs={"announcements": []})
    keyed = {(r["symbol"], r["kind"], r["period"]): r for r in rows}
    assert ("TCS", "annual", "FY2026") in keyed
    assert ("TCS", "quarter", "2026-06") in keyed
    assert ("TCS", "summary", "latest") in keyed
    assert keyed[("TCS", "shareholding", "2026-06")]["data"] == {"promoters": 50.5}
    assert ("TCS", "docs", "latest") in keyed
    a = keyed[("TCS", "annual", "FY2026")]
    assert a["data"]["src"] == "yahoo_ts" and a["data"]["sales"] == 10
    assert all(r["updated_at"] == NOW.isoformat() for r in rows)


def test_fundamentals_rows_without_nse_pieces():
    rows = fu.fundamentals_rows("TCS", {"FY2026": {"sales": 10}}, {}, {}, NOW)
    assert {r["kind"] for r in rows} == {"annual"}
    # an NSE pass that found no documents still stamps the docs row (the warm
    # queue orders by it); a Yahoo-only pass (docs=None) does not
    rows = fu.fundamentals_rows("TCS", {}, {}, {}, NOW, docs={})
    assert [(r["kind"], r["data"]) for r in rows] == [("docs", {})]


def test_warm_universe_unseen_symbols_come_first():
    ages = {"OLD": "2026-08-01T00:00:00", "NEVER": "", "FRESH": "2026-08-29T11:00:00"}
    assert fu.warm_universe(ages, priority=[], now=NOW, cap=5) == ["NEVER", "OLD"]
