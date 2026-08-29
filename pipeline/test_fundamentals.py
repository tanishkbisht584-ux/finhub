"""fundamentals.py: pure-function checks, no network. Run: cd pipeline && py -3 -m pytest test_fundamentals.py"""
from datetime import datetime, timezone

import fundamentals as fu

NOW = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
CR = 1e7  # raw INR per crore


def n(v):
    return {"raw": v}


def stmt_fixture():
    """Condensed quoteSummary payload: 2 annual periods + 2 quarters, all six
    statement modules plus defaultKeyStatistics for shares/book value."""
    def pnl(end, rev, op, other, interest, pbt, tax, np_):
        return {"endDate": {"fmt": end}, "totalRevenue": n(rev), "operatingIncome": n(op),
                "totalOtherIncomeExpenseNet": n(other), "interestExpense": n(-interest),
                "incomeBeforeTax": n(pbt), "incomeTaxExpense": n(tax), "netIncome": n(np_),
                "costOfRevenue": n(rev // 2)}

    def bs(end, assets, cur_assets, cur_liab, equity, common, debt_st, debt_lt, ppe, inv_lt,
           receivables, inventory, payable):
        return {"endDate": {"fmt": end}, "totalAssets": n(assets),
                "totalCurrentAssets": n(cur_assets), "totalCurrentLiabilities": n(cur_liab),
                "totalStockholderEquity": n(equity), "commonStock": n(common),
                "shortLongTermDebt": n(debt_st), "longTermDebt": n(debt_lt),
                "propertyPlantEquipment": n(ppe), "longTermInvestments": n(inv_lt),
                "netReceivables": n(receivables), "inventory": n(inventory),
                "accountsPayable": n(payable), "totalLiab": n(assets - equity)}

    def cf(end, cfo, cfi, cff, capex, dep, div):
        return {"endDate": {"fmt": end}, "totalCashFromOperatingActivities": n(cfo),
                "totalCashflowsFromInvestingActivities": n(cfi),
                "totalCashFromFinancingActivities": n(cff), "changeInCash": n(cfo + cfi + cff),
                "capitalExpenditures": n(-capex), "depreciation": n(dep),
                "dividendsPaid": n(-div)}

    return {"quoteSummary": {"result": [{
        "incomeStatementHistory": {"incomeStatementHistory": [
            pnl("2026-03-31", 1000 * CR, 200 * CR, 20 * CR, 30 * CR, 190 * CR, 47 * CR, 143 * CR),
            pnl("2025-03-31", 800 * CR, 150 * CR, 15 * CR, 25 * CR, 140 * CR, 35 * CR, 105 * CR)]},
        "balanceSheetHistory": {"balanceSheetStatements": [
            bs("2026-03-31", 2000 * CR, 700 * CR, 400 * CR, 900 * CR, 50 * CR, 100 * CR,
               200 * CR, 800 * CR, 300 * CR, 110 * CR, 137 * CR, 115 * CR),
            bs("2025-03-31", 1800 * CR, 600 * CR, 350 * CR, 800 * CR, 50 * CR, 150 * CR,
               250 * CR, 700 * CR, 250 * CR, 90 * CR, 120 * CR, 100 * CR)]},
        "cashflowStatementHistory": {"cashflowStatements": [
            cf("2026-03-31", 250 * CR, -120 * CR, -80 * CR, 100 * CR, 60 * CR, 30 * CR),
            cf("2025-03-31", 200 * CR, -100 * CR, -60 * CR, 90 * CR, 50 * CR, 25 * CR)]},
        "incomeStatementHistoryQuarterly": {"incomeStatementHistory": [
            pnl("2026-06-30", 280 * CR, 60 * CR, 5 * CR, 8 * CR, 57 * CR, 14 * CR, 43 * CR),
            pnl("2026-03-31", 260 * CR, 55 * CR, 4 * CR, 8 * CR, 51 * CR, 13 * CR, 38 * CR)]},
        "balanceSheetHistoryQuarterly": {"balanceSheetStatements": []},
        "cashflowStatementHistoryQuarterly": {"cashflowStatements": []},
        "defaultKeyStatistics": {"sharesOutstanding": n(10 * CR), "bookValue": n(90.0)},
    }]}}


# ---------- FY labels ----------

def test_fy_label_march_end_is_that_calendar_year():
    assert fu.fy_label("2024-03-31") == "FY2024"


def test_fy_label_after_march_rolls_into_next_fy():
    assert fu.fy_label("2024-12-31") == "FY2025"
    assert fu.fy_label("2024-06-30") == "FY2025"


# ---------- statement parsing ----------

def test_parse_statements_pnl_in_crores():
    annuals, _ = fu.parse_statements(stmt_fixture())
    a = annuals["FY2026"]
    assert a["sales"] == 1000 and a["op_profit"] == 200 and a["expenses"] == 800
    assert a["opm"] == 20.0
    assert a["other_income"] == 20 and a["interest"] == 30
    assert a["depreciation"] == 60  # from the cash-flow statement
    assert a["pbt"] == 190 and a["net_profit"] == 143
    assert a["tax_pct"] == round(47 / 190 * 100, 1)
    assert a["eps"] == round(143 * 1e7 / (10 * 1e7), 2)  # Cr back to rupees / shares
    assert a["div_payout"] == round(30 / 143 * 100, 1)
    assert a["end"] == "2026-03-31"


def test_parse_statements_balance_sheet():
    annuals, _ = fu.parse_statements(stmt_fixture())
    a = annuals["FY2026"]
    assert a["equity_cap"] == 50 and a["reserves"] == 850  # equity - common stock
    assert a["borrowings"] == 300
    assert a["other_liab"] == 2000 - 900 - 300  # totalLiab - borrowings
    assert a["fixed_assets"] == 800 and a["investments"] == 300
    assert a["other_assets"] == 2000 - 800 - 300
    assert a["total_assets"] == 2000


def test_parse_statements_cash_flow_and_fcf():
    annuals, _ = fu.parse_statements(stmt_fixture())
    a = annuals["FY2026"]
    assert a["cfo"] == 250 and a["cfi"] == -120 and a["cff"] == -80
    assert a["net_cf"] == 50
    assert a["fcf"] == 150  # cfo - capex


def test_parse_statements_ratio_inputs():
    annuals, _ = fu.parse_statements(stmt_fixture())
    a = annuals["FY2026"]
    assert a["debtor_days"] == round(110 / 1000 * 365)
    assert a["inventory_days"] == round(137 / 500 * 365)
    assert a["payable_days"] == round(115 / 500 * 365)
    assert a["wc_days"] == round((700 - 400) / 1000 * 365)
    assert a["roce"] == round((190 + 30) / (2000 - 400) * 100, 1)
    assert a["roe"] == round(143 / 900 * 100, 1)


def test_parse_statements_quarters():
    _, quarters = fu.parse_statements(stmt_fixture())
    q = quarters["2026-06"]
    assert q["sales"] == 280 and q["op_profit"] == 60 and q["opm"] == round(60 / 280 * 100, 1)
    assert q["net_profit"] == 43 and q["eps"] == round(43 * 1e7 / (10 * 1e7), 2)
    assert "div_payout" not in q
    assert list(quarters) == ["2026-06", "2026-03"]


def test_parse_statements_bank_missing_lines_no_crash():
    j = stmt_fixture()
    r = j["quoteSummary"]["result"][0]
    for s in r["incomeStatementHistory"]["incomeStatementHistory"]:
        del s["costOfRevenue"], s["operatingIncome"]
    for s in r["balanceSheetHistory"]["balanceSheetStatements"]:
        del s["inventory"], s["totalCurrentAssets"], s["totalCurrentLiabilities"]
    annuals, _ = fu.parse_statements(j)
    a = annuals["FY2026"]
    assert a["sales"] == 1000 and a["net_profit"] == 143
    for gone in ("op_profit", "opm", "inventory_days", "wc_days", "roce"):
        assert gone not in a


def test_parse_statements_empty_payload():
    assert fu.parse_statements({"quoteSummary": {"result": []}}) == ({}, {})
    assert fu.parse_statements({}) == ({}, {})


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


def test_shape_ratings_filters_global_feed_by_symbol():
    # real corporate-credit-rating shape (probe 2026-08-29): a global recent-
    # filings list; the symbol param is ignored server-side.
    rows = [{"Symbol": "RELIANCE", "NameOfCRAgency": "CRISIL Ratings Limited",
             "CreditRating": "AAA", "RatingAction": "Reaffirm", "DateofCR": "28-08-2026"},
            {"Symbol": "RELIANCE", "NameOfCRAgency": "ICRA", "CreditRating": "AA+",
             "RatingAction": "", "DateofCR": "29-01-2026"},
            {"Symbol": "Not listed", "NameOfCRAgency": "CRISIL Ratings Limited",
             "CreditRating": "AAA", "DateofCR": "28-08-2026"},
            {"Symbol": "TCS", "NameOfCRAgency": "CARE", "CreditRating": "AAA"}]
    out = fu.shape_ratings(rows, "RELIANCE")
    assert len(out) == 2
    assert out[0] == {"agency": "CRISIL Ratings Limited", "rating": "AAA (Reaffirm)",
                      "date": "28-08-2026", "url": None}
    assert out[1]["rating"] == "AA+"
    assert fu.shape_ratings(rows, "WIPRO") == []


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
    args = {"sym": "TCS", "name": "TCS Ltd", "sector": "IT",
            "annuals": annuals_for_screen(), "quarters": QUARTERS_EPS,
            "promoter_pct": 50.5, "price": 280.0, "now": NOW}
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


def test_screener_row_cagr_and_div_yield():
    r = row_for()
    assert r["sales_cagr_5y"] == 22.0  # 100 -> 270 over 5y
    assert r["profit_cagr_3y"] is not None
    assert r["div_yield"] == round(25.0 * 13.5 / 100 / 280.0 * 100, 2)
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
        [("u-con", "2024-12"), ("u-q2", "2024-09")]


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
    assert a["data"]["src"] == "yahoo" and a["data"]["sales"] == 10
    assert all(r["updated_at"] == NOW.isoformat() for r in rows)


def test_fundamentals_rows_without_nse_pieces():
    rows = fu.fundamentals_rows("TCS", {"FY2026": {"sales": 10}}, {}, {}, NOW)
    assert {r["kind"] for r in rows} == {"annual"}
