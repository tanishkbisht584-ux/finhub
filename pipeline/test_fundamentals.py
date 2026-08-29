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


def test_shape_ratings_normalizes_key_variants():
    rows = [{"creditRatingAgencyName": "CRISIL", "rating": "AAA/Stable",
             "date": "03-Jul-2026", "attchmntFile": "https://x/r.pdf"},
            {"cra": "ICRA", "crRating": "AA+", "crDate": "29-Jan-2026"},
            {"junk": True}]
    out = fu.shape_ratings({"data": rows})
    assert out[0] == {"agency": "CRISIL", "rating": "AAA/Stable",
                      "date": "03-Jul-2026", "url": "https://x/r.pdf"}
    assert out[1]["agency"] == "ICRA" and out[1]["rating"] == "AA+"
    assert len(out) == 2  # unkeyable row dropped


# ---------- SHP XBRL: FII/DII split (step A — patterns pending runner check) ----------

SHP_XBRL = """<html>
<ix:nonFraction name='in-bse-shp:ForeignPortfolioInvestorsCategoryI' contextRef='C1'>17.19</ix:nonFraction>
<ix:nonFraction name="in-bse-shp:MutualFunds">9.90</ix:nonFraction>
<ix:nonFraction name="in-bse-shp:InsuranceCompanies">6.20</ix:nonFraction>
<ix:nonNumeric name="in-bse-shp:CentralGovernmentStateGovernments">0.17</ix:nonNumeric>
<ix:nonFraction name="in-bse-shp:TotalNumberOfShareholders">46,51,863</ix:nonFraction>
<ix:nonFraction name="in-bse-shp:SomethingUnrelated">1.0</ix:nonFraction>
</html>"""


def test_parse_ix_facts_localnames_and_text():
    facts = fu.parse_ix_facts(SHP_XBRL)
    assert facts["ForeignPortfolioInvestorsCategoryI"] == "17.19"
    assert facts["TotalNumberOfShareholders"] == "46,51,863"
    assert "SomethingUnrelated" in facts


def test_map_shp_facts_splits_and_reports_unmapped():
    mapped, unmapped = fu.map_shp_facts(fu.parse_ix_facts(SHP_XBRL))
    assert mapped["fiis"] == 17.19
    assert mapped["diis"] == round(9.90 + 6.20, 2)  # MF + insurance summed
    assert mapped["govt"] == 0.17
    assert mapped["n_holders"] == 4651863
    assert "SomethingUnrelated" in unmapped


def test_map_shp_facts_empty():
    mapped, unmapped = fu.map_shp_facts({})
    assert mapped == {} and unmapped == []


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
