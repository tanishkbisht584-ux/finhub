"""Deep fundamentals (2026-08-29): Screener-style statement history into the
`fundamentals` table (migration 016) — annual/quarter P&L + balance sheet +
cash flow + ratios, plus a derived `summary` row (CAGR blocks, rule-based
pros/cons). One row per (symbol, kind, period); accumulation is a plain PK
upsert, so history grows forever even though Yahoo only serves ~4 years.

Sources (2026-09-15): Yahoo's fundamentals-timeseries endpoint for statements
(CONSOLIDATED — the legacy quoteSummary *History modules served standalone
figures for ~1/3 of .NS symbols and their BS/CF modules went dark, which is
why tables stalled at FY2023), quoteSummary defaultKeyStatistics for the
reported share count + book value, Yahoo monthly chart for price CAGR, NSE for
shareholding / results XBRL / documents. Driven by the same analysis_requests
rows market.refresh_analysis_new reads — opening a stock page is the trigger;
the whole screener_metrics universe pre-warms daily, biggest names first.
"""
import re
import time
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

import requests

import fund_audit
from market import (BROWSER_UA, IST, NSE_API, QS_URL, TIMEOUT, fetch_spark,
                    nse_session, parse_nse_date, parse_spark, upsert,
                    yahoo_session)

CR = 1e7  # raw INR per crore

STMT_MODULES = "defaultKeyStatistics"  # reported shares + ₹/share book value only

# Yahoo fundamentals-timeseries: the maintained endpoint Yahoo's own pages
# render (probed 2026-09-15 from this machine: RELIANCE FY2024 revenue
# 901,064 Cr = Screener's consolidated figure; covers banks; 4 FYs + ~5
# quarters + trailing). Type stems are mapped onto the legacy field names so
# _pnl/_bs/_cf/_ratios read one flat dict per period, whatever the source.
TS_URL = "https://query2.finance.yahoo.com/ws/fundamentals-timeseries/v1/finance/timeseries/"
TS_PNL = {
    "TotalRevenue": "totalRevenue", "CostOfRevenue": "costOfRevenue",
    "InterestExpense": "interestExpense", "InterestIncome": "interestIncome",
    "OtherNonOperatingIncomeExpenses": "totalOtherIncomeExpenseNet",
    "ReconciledDepreciation": "depreciation", "PretaxIncome": "incomeBeforeTax",
    "TaxProvision": "incomeTaxExpense", "NetIncome": "netIncome",
    "MinorityInterests": "minorityInterests",  # Yahoo's NetIncome is the owners' share
    "BasicEPS": "basicEps", "BasicAverageShares": "basicAverageShares",
    "NetInterestIncome": "netInterestIncome", "NonInterestIncome": "nonInterestIncome",
}
TS_BS_CF = {
    "TotalAssets": "totalAssets", "StockholdersEquity": "totalStockholderEquity",
    "CommonStock": "commonStock", "TotalDebt": "totalDebt",
    "CurrentDebt": "shortLongTermDebt", "LongTermDebt": "longTermDebt",
    "TotalLiabilitiesNetMinorityInterest": "totalLiab",
    "NetPPE": "propertyPlantEquipment", "ConstructionInProgress": "cwip",
    "LongTermEquityInvestment": "longTermInvestments",
    "InvestmentinFinancialAssets": "financialInvestments",
    "OtherShortTermInvestments": "shortTermInvestments",
    "InvestmentsAndAdvances": "investmentsAndAdvances",  # banks
    "CurrentAssets": "totalCurrentAssets", "CurrentLiabilities": "totalCurrentLiabilities",
    "AccountsReceivable": "netReceivables", "Inventory": "inventory",
    "AccountsPayable": "accountsPayable",
    "OperatingCashFlow": "totalCashFromOperatingActivities",
    "InvestingCashFlow": "totalCashflowsFromInvestingActivities",
    "FinancingCashFlow": "totalCashFromFinancingActivities",
    "CapitalExpenditure": "capitalExpenditures", "ChangesInCash": "changeInCash",
    "CashDividendsPaid": "dividendsPaid",
}
TS_TO_LEGACY = {**TS_PNL, **TS_BS_CF}
TS_TYPES = ",".join([f"{p}{t}" for p in ("annual", "quarterly") for t in TS_TO_LEGACY]
                    + [f"trailing{t}" for t in TS_PNL])

DEEP_MAX_AGE_D = 7   # summary row younger than this: skip the symbol
DEEP_NEW_CAP = 5     # requested-symbol deep fetches per 5-min pass

# process-lifetime failure tallies, mirrored to the app_config `market_status`
# row by market.refresh — a basis-gate spike is a number, not a stdout grep
counters = {"basis_drop": 0, "results_fail": 0, "chart_fail": 0,
            "sym_fail": 0, "shp_fail": 0, "ts_fail": 0, "junk_deleted": 0}


def fy_label(end):
    """Indian FY the end date falls in: Mar 2024 -> FY2024, Dec 2024 -> FY2025."""
    y, m = int(end[:4]), int(end[5:7])
    return f"FY{y if m <= 3 else y + 1}"


def _cr(v):
    return round(v / CR) if v is not None else None


def _pct(a, b, nd=1):
    return round(a / b * 100, nd) if a is not None and b else None


def _stmt_map(module, list_key, j):
    r = ((j.get("quoteSummary") or {}).get("result") or [{}])[0]
    out = {}
    for s in (r.get(module) or {}).get(list_key) or []:
        end = (s.get("endDate") or {}).get("fmt")
        if end:
            out[end] = {k: (v or {}).get("raw") if isinstance(v, dict) else v
                        for k, v in s.items() if k != "endDate"}
    return out


def _is_lender(s):
    """Banks/NBFCs: a positive net interest income (Yahoo derives it only for
    lenders — IRFC's lease book comes back negative and stays industrial)."""
    return (s.get("netInterestIncome") or 0) > 0 and s.get("interestIncome") is not None


def _pnl(s, shares):
    """One period's P&L the Screener way — the same derivation as the NSE XBRL
    parser and the kaggle rows, so FY seams between sources stay consistent.
    Industrials: other income = non-operating income + interest earned;
    operating profit = pbt + interest + depreciation - other income. Lenders
    (Screener's bank layout, matches the kaggle rows to the crore for
    ICICIBANK): revenue = interest earned, interest = a cost, other income =
    non-interest income, operating profit = financing profit = pbt +
    depreciation - other income. No depreciation reported (some quarterly
    filings) -> no op_profit/opm rather than a wrong one. Net profit is the
    TOTAL PAT (Screener's row, what the kaggle and NSE rows carry: RELIANCE
    FY2023 74,088), so Yahoo's owners-share NetIncome gets the minority
    interest it deducted added back; EPS stays the reported per-share figure."""
    rev, pbt, tax, np_ = (s.get("totalRevenue"), s.get("incomeBeforeTax"),
                          s.get("incomeTaxExpense"), s.get("netIncome"))
    if np_ is not None and s.get("minorityInterests") is not None:
        np_ -= s["minorityInterests"]  # Yahoo reports the deduction as a negative
    interest = abs(s["interestExpense"]) if s.get("interestExpense") is not None else None
    dep, other, earned = s.get("depreciation"), s.get("totalOtherIncomeExpenseNet"), s.get("interestIncome")
    if _is_lender(s):
        rev, other = earned, s.get("nonInterestIncome")
        if other is None and s.get("totalRevenue") is not None:
            other = s["totalRevenue"] - s["netInterestIncome"]
        op = pbt + dep - (other or 0) if pbt is not None and dep is not None else None
        expenses = rev - (interest or 0) - op if op is not None else None
    else:
        if earned is not None:
            other = (other or 0) + earned
        op = pbt + (interest or 0) + dep - (other or 0) if pbt is not None and dep is not None else None
        expenses = rev - op if rev is not None and op is not None else None
    eps = s.get("basicEps")
    if eps is None and np_ is not None:  # reported average shares, then the reported count
        base = s.get("basicAverageShares") or shares
        eps = np_ / base if base else None
    return {"sales": _cr(rev), "op_profit": _cr(op), "expenses": _cr(expenses),
            "opm": _pct(op, rev), "other_income": _cr(other),
            "interest": _cr(interest), "depreciation": _cr(dep),
            "pbt": _cr(pbt), "tax_pct": _pct(tax, pbt), "net_profit": _cr(np_),
            "eps": round(eps, 2) if eps is not None else None}


def _bs(s):
    """Screener's sheet: equity + reserves + borrowings + other liabilities =
    total = fixed assets + CWIP + investments + other assets."""
    equity, common = s.get("totalStockholderEquity"), s.get("commonStock")
    debt = s.get("totalDebt") or sum(s.get(k) or 0 for k in ("shortLongTermDebt", "longTermDebt")) or None
    total, liab = s.get("totalAssets"), s.get("totalLiab")
    ppe, cwip = s.get("propertyPlantEquipment"), s.get("cwip")
    if ppe is not None and cwip:  # Yahoo's NetPPE carries CWIP; Screener shows them apart
        ppe -= cwip
    inv = s.get("investmentsAndAdvances") or sum(
        s.get(k) or 0 for k in ("longTermInvestments", "financialInvestments",
                                "shortTermInvestments")) or None
    if total is not None and equity is not None:
        other_liab = total - equity - (debt or 0)
    else:
        other_liab = liab - debt if liab is not None and debt is not None else None
    return {"equity_cap": _cr(common),
            "reserves": _cr(equity - common) if equity is not None and common is not None else None,
            "borrowings": _cr(debt), "other_liab": _cr(other_liab),
            "fixed_assets": _cr(ppe), "cwip": _cr(cwip), "investments": _cr(inv),
            "other_assets": _cr(total - (ppe or 0) - (cwip or 0) - (inv or 0)) if total is not None else None,
            "total_assets": _cr(total)}


def _cf(s):
    cfo = s.get("totalCashFromOperatingActivities")
    capex = s.get("capitalExpenditures")
    return {"cfo": _cr(cfo), "cfi": _cr(s.get("totalCashflowsFromInvestingActivities")),
            "cff": _cr(s.get("totalCashFromFinancingActivities")),
            "net_cf": _cr(s.get("changeInCash")),
            "fcf": _cr(cfo - abs(capex)) if cfo is not None and capex is not None else None}


def _ratios(pnl_s, bs_s):
    rev, cogs = pnl_s.get("totalRevenue"), pnl_s.get("costOfRevenue")
    cur_a, cur_l = bs_s.get("totalCurrentAssets"), bs_s.get("totalCurrentLiabilities")
    pbt, interest = pnl_s.get("incomeBeforeTax"), pnl_s.get("interestExpense")
    total, equity = bs_s.get("totalAssets"), bs_s.get("totalStockholderEquity")

    def days(num, den):
        return round(num / den * 365) if num is not None and den else None

    r = {"debtor_days": days(bs_s.get("netReceivables"), rev),
         "inventory_days": days(bs_s.get("inventory"), cogs),
         "payable_days": days(bs_s.get("accountsPayable"), cogs),
         "wc_days": days(cur_a - cur_l, rev) if cur_a is not None and cur_l is not None else None,
         "roe": _pct(pnl_s.get("netIncome"), equity)}
    if pbt is not None and total is not None and cur_l is not None and total != cur_l:
        r["roce"] = round((pbt + abs(interest or 0)) / (total - cur_l) * 100, 1)
    elif pbt is not None and cur_l is None and equity is not None:
        # ponytail: Yahoo serves no CurrentLiabilities for ~360 non-lender symbols;
        # capital employed = net worth + debt is p50 1.3 / p90 8 pts off the CL
        # form (measured 17 Sep 2026); upgrade = NSE balance-sheet XBRL
        debt = bs_s.get("totalDebt") or sum(bs_s.get(k) or 0 for k in ("shortLongTermDebt", "longTermDebt"))
        if equity + debt > 0:
            r["roce"] = round((pbt + abs(interest or 0)) / (equity + debt) * 100, 1)
    return r


def parse_stats(j):
    """defaultKeyStatistics -> {shares, book_value}: the REPORTED share count
    and per-share book value (never inferred from np/eps)."""
    r = ((j.get("quoteSummary") or {}).get("result") or [{}])[0]
    stats = r.get("defaultKeyStatistics") or {}
    out = {}
    shares = (stats.get("sharesOutstanding") or {}).get("raw")
    if shares:
        out["shares"] = shares
    bv = (stats["bookValue"] or {}).get("raw") \
        if isinstance(stats.get("bookValue"), dict) else stats.get("bookValue")
    if bv is not None:
        out["book_value"] = bv
    return out


def parse_timeseries(j):
    """timeseries payload -> {"annual": {end: {legacyKey: raw}}, "quarterly":
    {...}, "trailing": {...}}. Each result carries one type; entries with only
    meta+timestamp (no value list) are skipped, as are types we don't map."""
    out = {"annual": {}, "quarterly": {}, "trailing": {}}
    for res in ((j.get("timeseries") or {}).get("result") or []):
        t = ((res.get("meta") or {}).get("type") or [""])[0] or ""
        prefix = next((p for p in out if t.startswith(p)), None)
        legacy = TS_TO_LEGACY.get(t[len(prefix):]) if prefix else None
        if not legacy:
            continue
        for x in res.get(t) or []:
            end = (x or {}).get("asOfDate")
            raw = ((x or {}).get("reportedValue") or {}).get("raw")
            if end and raw is not None:
                out[prefix].setdefault(end, {})[legacy] = raw
    return out


def shape_statements(ts, stats):
    """(annuals {FY2026: {...}}, quarters {2026-06: {...}}) in ₹ Cr, nulls
    dropped, newest first. A quarter with neither sales nor profit (a
    balance-sheet-only asOfDate) is not a quarter."""
    shares, bv = stats.get("shares"), stats.get("book_value")
    annuals = {}
    for end in sorted(ts.get("annual") or {}, reverse=True):
        s = ts["annual"][end]
        d = {**_pnl(s, shares), "end": end, **_bs(s), **_cf(s)}
        ratios = _ratios(s, s)
        if _is_lender(s):  # Screener shows lenders ROE only — no working-capital days, no ROCE
            ratios = {"roe": ratios.get("roe")}
        d.update(ratios)
        np_, div = d.get("net_profit"), s.get("dividendsPaid")
        if np_ and div is not None:
            d["div_payout"] = round(abs(div) / CR / np_ * 100, 1)
        annuals[fy_label(end)] = {k: v for k, v in d.items() if v is not None}
    quarters = {}
    for end in sorted(ts.get("quarterly") or {}, reverse=True):
        d = {**_pnl(ts["quarterly"][end], shares), "end": end}
        if d.get("sales") is not None or d.get("net_profit") is not None:
            quarters[end[:7]] = {k: v for k, v in d.items() if v is not None}
    if bv is not None and annuals:
        annuals[next(iter(annuals))]["book_value"] = bv
    return annuals, quarters


# ---------- summary: CAGRs + rule-based pros/cons ----------

def _cagr(first, last, years):
    # both ends must be positive: a negative base under a fractional exponent
    # is a complex number, and a loss year has no meaningful CAGR anyway
    if not first or not last or first <= 0 or last <= 0 or years <= 0:
        return None
    return round(((last / first) ** (1 / years) - 1) * 100, 1)


def _cagr_block(annuals, field):
    """{y10,y5,y3} over the annual series (dict keyed FY..., any order)."""
    vals = [annuals[k].get(field) for k in sorted(annuals)]
    vals = [v for v in vals if v is not None]
    out = {}
    for label, yrs in (("y10", 10), ("y5", 5), ("y3", 3)):
        if len(vals) > yrs:
            c = _cagr(vals[-1 - yrs], vals[-1], yrs)
            if c is not None:
                out[label] = c
    return out


def _ttm_growth(quarters, field):
    vals = [quarters[k].get(field) for k in sorted(quarters, reverse=True)]
    vals = [v for v in vals if v is not None]
    if len(vals) < 8:
        return None
    cur, prev = sum(vals[:4]), sum(vals[4:8])
    return _pct(cur - prev, prev)


def _latest(annuals, field, back=0):
    keys = sorted(annuals, reverse=True)
    if back >= len(keys):
        return None
    return annuals[keys[back]].get(field)


def _avg3(annuals, field):
    vals = [v for v in (_latest(annuals, field, i) for i in range(3)) if v is not None]
    return sum(vals) / len(vals) if vals else None


def pros_cons(annuals, shareholding=None):
    """Screener-style rule bullets. Deliberately few and blunt — every rule is
    a plain threshold a reader can verify from the tables below it."""
    pros, cons = [], []
    sh = [v for _, v in sorted((shareholding or {}).items())]  # oldest first
    fii = [v["fiis"] for v in sh if v.get("fiis") is not None][-4:]
    if len(fii) >= 4 and all(b > a for a, b in zip(fii, fii[1:])):
        pros.append("FIIs have been increasing their stake "
                    f"({fii[0]}% → {fii[-1]}% over recent quarters)")
    prom = [v["promoters"] for v in sh if v.get("promoters") is not None][-4:]
    if len(prom) >= 4 and prom[-1] < prom[0] - 2:
        cons.append(f"Promoter holding has decreased: {prom[0]}% → {prom[-1]}%")
    # dps back-derived from payout × eps; a >20% y/y drop reads as a cut
    dps = [(k, a["div_payout"] * a["eps"] / 100) for k, a in sorted(annuals.items())
           if a.get("div_payout") is not None and a.get("eps")]
    if len(dps) >= 2 and dps[-1][1] < dps[-2][1] * 0.8:
        cons.append(f"Dividend was cut in {dps[-1][0]} "
                    f"(₹{round(dps[-2][1], 1)} → ₹{round(dps[-1][1], 1)}/share)")
    borrowings, equity = _latest(annuals, "borrowings"), \
        (_latest(annuals, "reserves") or 0) + (_latest(annuals, "equity_cap") or 0)
    if borrowings is not None and equity > 0 and borrowings / equity < 0.05:
        pros.append("Company is almost debt free")
    profit5 = _cagr_block(annuals, "net_profit").get("y5")
    if profit5 is not None and profit5 > 15:
        pros.append(f"Company has delivered good profit growth of {profit5}% CAGR over last 5 years")
    roe3 = _avg3(annuals, "roe")
    if roe3 is not None:
        if roe3 > 15:
            pros.append(f"Company has a good return on equity (ROE) track record: 3 years ROE {round(roe3, 1)}%")
        elif roe3 < 10:
            cons.append(f"Company has a low return on equity of {round(roe3, 1)}% over last 3 years")
    payout3 = _avg3(annuals, "div_payout")
    if payout3 is not None and payout3 > 20:
        pros.append(f"Company has been maintaining a healthy dividend payout of {round(payout3, 1)}%")
    elif (payout3 or 0) < 10 and (_latest(annuals, "net_profit") or 0) > 0 and len(annuals) >= 3:
        cons.append(f"Dividend payout has been low at {round(payout3 or 0, 1)}% of profits over last 3 years")
    sales5 = _cagr_block(annuals, "sales").get("y5")
    if sales5 is not None and sales5 < 10:
        cons.append(f"The company has delivered a poor sales growth of {sales5}% over past five years")
    op, interest = _latest(annuals, "op_profit"), _latest(annuals, "interest")
    if op is not None and interest and op / interest < 2:
        cons.append("Company might not be able to cover its interest payments (low interest coverage)")
    dd = _latest(annuals, "debtor_days")
    if dd is not None and dd > 120:
        cons.append(f"Debtor days are high at {dd}")
    return pros, cons


def compute_summary(annuals, quarters, monthly_closes, shareholding=None):
    """The one-read header row: CAGR blocks + pros/cons + latest headline ratios."""
    cagr = {"sales": _cagr_block(annuals, "sales"), "profit": _cagr_block(annuals, "net_profit")}
    ttm = _ttm_growth(quarters, "sales")
    if ttm is not None:
        cagr["sales"]["ttm"] = ttm
    ttm_p = _ttm_growth(quarters, "net_profit")
    if ttm_p is not None:
        cagr["profit"]["ttm"] = ttm_p
    closes, price = list(monthly_closes or []), {}
    for i in range(1, len(closes)):  # forward-fill: gaps must not shift the axis
        if closes[i] is None:
            closes[i] = closes[i - 1]
    if closes and closes[-1] is not None:
        for label, months in (("y10", 120), ("y5", 60), ("y3", 36), ("y1", 12)):
            if len(closes) > months and closes[-1 - months]:
                c = _cagr(closes[-1 - months], closes[-1], months / 12)
                if c is not None:
                    price[label] = c
    if price:
        cagr["price"] = price
    roe = {}
    for label, back in (("y10", 10), ("y5", 5), ("y3", 3)):
        vals = [v for v in (_latest(annuals, "roe", i) for i in range(back)) if v is not None]
        if len(vals) >= min(back, 3):
            roe[label] = round(sum(vals) / len(vals), 1)
    last_roe = _latest(annuals, "roe")
    if last_roe is not None:
        roe["last"] = last_roe
    if roe:
        cagr["roe"] = roe
    pros, cons = pros_cons(annuals, shareholding)
    s = {"cagr": cagr, "pros": pros, "cons": cons}
    for k in ("roce", "book_value"):
        v = _latest(annuals, k)
        if v is not None:
            s[k] = v
    return s


# ---------- NSE deep: shareholding + document links ----------

def shape_shareholding(rows):
    """corporate-share-holdings-master rows -> {'2026-06': {promoters, public,
    employee_trusts}}. NSE serves the split as strings, '-' where absent; the
    FII/DII breakdown lives in per-quarter XBRL and is deliberately skipped."""
    out = {}
    for r in rows or []:
        d = parse_nse_date(r.get("date"))
        if not d:
            continue
        row = {}
        for key, field in (("promoters", "pr_and_prgrp"), ("public", "public_val"),
                           ("employee_trusts", "employeeTrusts")):
            try:
                row[key] = round(float(r.get(field)), 2)
            except (TypeError, ValueError):
                continue
        if row:
            out[f"{d.year}-{d.month:02d}"] = row
    return out


CONCALL_RE = re.compile(
    r"transcript|earnings\s+(conference\s+)?call|concall|con\.?\s*call"
    r"|analyst.{0,30}(meet|call)|investor\s+(presentation|meet)", re.I)
# NSE's corporate-credit-rating endpoint is a global few-days feed (every
# symbol's list came back empty for weeks) — the agencies' own filings inside
# the announcements window are the reliable source, so route those instead.
RATING_RE = re.compile(
    r"credit\s+rating|\b(CRISIL|ICRA|CARE(?:\s+Ratings)?|India\s+Ratings|Ind-Ra"
    r"|Brickwork|Acuit[eé]|Infomerics)\b", re.I)


def shape_docs(reports, announcements, cap=20):
    """{annual_reports: [{fy,url}], announcements: [{date,subject,url}],
    concalls: [...], credit_ratings: [{agency,rating,date,url}]}. Concall-ish
    announcements (transcripts, PPTs, analyst meets) and rating-agency filings
    move to their own lists, Screener-style."""
    ars = [{"fy": r.get("toYr"), "url": r.get("fileName")}
           for r in (reports or {}).get("data") or [] if r.get("fileName")]
    anns, calls, ratings = [], [], []
    for a in announcements or []:
        subject = a.get("desc") or a.get("attchmntText")
        if not subject:
            continue
        row = {"date": a.get("an_dt"), "subject": subject, "url": a.get("attchmntFile")}
        m = RATING_RE.search(subject) or RATING_RE.search(a.get("attchmntText") or "")
        if m:
            ratings.append({"agency": m.group(1), "rating": subject,
                            "date": row["date"], "url": row["url"]})
        elif CONCALL_RE.search(subject):
            calls.append(row)
        else:
            anns.append(row)
    out = {"annual_reports": ars, "announcements": anns[:cap], "concalls": calls[:12]}
    if ratings:
        out["credit_ratings"] = ratings[:8]
    return out


# SHP plain-XBRL: one percentage element repeated per category context; the
# context ids are semantic totals (probed against the real RELIANCE Jun-2026
# filing, values match Screener's rows). Fractions of 1 -> percent.
SHP_CONTEXTS = {
    "promoters": "ShareholdingOfPromoterAndPromoterGroup_ContextI",
    "fiis": "InstitutionsForeign_ContextI",
    "diis": "InstitutionsDomestic_ContextI",
    "govt": "Governments_ContextI",
    "public": "NonInstitutions_ContextI",  # Screener's "Public" row
}
SHP_PCT_EL = "ShareholdingAsAPercentageOfTotalNumberOfShares"


def parse_ix_facts(html):
    """{localname: text} for every ix:nonNumeric/nonFraction fact — the same
    regex approach as market.parse_pit_xbrl, kept generic. First value wins."""
    out = {}
    for name, val in re.findall(
            r"<ix:non(?:Numeric|Fraction)[^>]*name=['\"]([^'\"]+)['\"][^>]*>(.*?)"
            r"</ix:non(?:Numeric|Fraction)>", html, re.S):
        key = name.split(":")[-1]
        if key not in out:
            out[key] = re.sub(r"<[^>]+>", "", val).strip()
    return out


def parse_shp_xml(xml):
    """One SHP filing -> {promoters, fiis, diis, govt, public, n_holders}."""
    by_ctx = {}
    for m in re.finditer(
            rf"<[\w.-]+:{SHP_PCT_EL} contextRef=\"([^\"]+)\"[^>]*>([^<]*)<", xml):
        by_ctx.setdefault(m.group(1), m.group(2).strip())
    out = {}
    for key, ctx in SHP_CONTEXTS.items():
        try:
            out[key] = round(float(by_ctx[ctx]) * 100, 2)
        except (KeyError, ValueError):
            continue
    if "promoters" in out:
        # a category the filing omits is a nil holding (small caps with no
        # foreign or no domestic institutions leave the context out), not an
        # unknown: 567 symbols sat on shp.split for that on 19 Sep 2026
        for key in ("fiis", "diis", "govt"):
            out.setdefault(key, 0.0)
    m = re.search(r"<[\w.-]+:NumberOfShareholders contextRef="
                  r"\"ShareholdingPattern_ContextI\"[^>]*>([^<]*)<", xml)
    if m:
        try:
            out["n_holders"] = int(float(m.group(1)))
        except ValueError:
            pass
    return out


def enrich_shareholding(sh, master_rows, fetch, cap=4):
    """Merge the FII/DII split from filings' XBRL into periods that lack it —
    walks newest-first so history back to ~2021 drains over passes, `cap` doc
    fetches per pass. Failures leave the master's promoter/public untouched."""
    if not sh or not master_rows:
        return sh
    fetched = 0
    for row in master_rows:  # API order is newest-first
        d = parse_nse_date(row.get("date"))
        period = f"{d.year}-{d.month:02d}" if d else None
        if not period or period not in sh or "fiis" in sh[period]:
            continue
        if fetched >= cap:
            break
        url = row.get("xbrl")
        if not url:
            continue
        try:
            mapped = parse_shp_xml(fetch(url))
        except Exception as e:
            counters["shp_fail"] += 1
            print(f"FUND SHP xbrl {period}: {e}")
            continue
        fetched += 1
        if mapped:
            sh[period] = {**sh[period], **mapped}
    return sh


# ---------- results XBRL: fills the 2023-2025 quarterly hole ----------
# in-bse-fin taxonomy element -> our quarter field (verified against the real
# RELIANCE Q3-FY25 filing via the probe workflow, 2026-08-29). Values are raw
# rupees; /1e7 to Cr. op_profit/expenses/opm derived the Screener way.

RESULTS_ELEMENTS = {
    "RevenueFromOperations": "sales",
    "OtherIncome": "other_income",
    "FinanceCosts": "interest",
    "DepreciationDepletionAndAmortisationExpense": "depreciation",
    "ProfitBeforeTax": "pbt",
    "TaxExpense": "_tax",
    "ProfitLossForPeriod": "net_profit",
    "BasicEarningsLossPerShareFromContinuingAndDiscontinuedOperations": "eps",
}
# Banks file under the BANKING taxonomy (NSE flags them "B"; the integrated
# feed's xml URL carries BANKING). Verified on HDFCBANK's Dec-2024 and
# Jun-2026 filings (probe 2026-09-15): Screener's bank rows — revenue =
# interest earned, interest = a cost, financing profit = pbt - other income.
BANK_ELEMENTS = {
    "InterestEarned": "sales",
    "OtherIncome": "other_income",
    "InterestExpended": "interest",
    "ProfitLossFromOrdinaryActivitiesBeforeTax": "pbt",
    "TaxExpense": "_tax",
    "ProfitLossForThePeriod": "net_profit",
    "BasicEarningsPerShareAfterExtraordinaryItems": "eps",
}


def is_bank_filing(row):
    return row.get("bank") in ("Y", "B") or "BANKING" in (row.get("xbrl") or "").upper()


def _nse_dmy(s):
    d = parse_nse_date(s)
    return d.isoformat() if d else None


def quarter_of_nse(to_date):
    d = parse_nse_date(to_date)
    return f"{d.year}-{d.month:02d}" if d else None


def fy_of_nse(to_date):
    d = parse_nse_date(to_date)
    return fy_label(d.isoformat()) if d else None


def parse_results_xml(xml, from_date, to_date, bank=False):
    """One filing's XBRL -> our quarter dict, reading only facts whose context
    period matches the filing's own quarter (YTD contexts are ignored). Same
    element names in the legacy in-bse-fin and the SEBI in-capmkt taxonomy."""
    elements = BANK_ELEMENTS if bank else RESULTS_ELEMENTS
    want = (_nse_dmy(from_date), _nse_dmy(to_date))
    if not all(want):
        return {}
    ctxs = set()
    for m in re.finditer(
            r"<xbrli:context id=\"([^\"]+)\">.*?<xbrli:startDate>([^<]+)</xbrli:startDate>\s*"
            r"<xbrli:endDate>([^<]+)</xbrli:endDate>", xml, re.S):
        if (m.group(2).strip(), m.group(3).strip()) == want:
            ctxs.add(m.group(1))
    if not ctxs:
        return {}
    raw = {}
    for m in re.finditer(
            r"<[\w.-]+:(\w+) contextRef=\"([^\"]+)\"[^>]*>([^<]*)<", xml):
        field = elements.get(m.group(1))
        if field and m.group(2) in ctxs and field not in raw:
            try:
                raw[field] = float(m.group(3))
            except ValueError:
                continue
    if "sales" not in raw or "net_profit" not in raw:
        return {}
    q = {"sales": _cr(raw["sales"]), "other_income": _cr(raw.get("other_income")),
         "interest": _cr(raw.get("interest")), "depreciation": _cr(raw.get("depreciation")),
         "pbt": _cr(raw.get("pbt")), "net_profit": _cr(raw["net_profit"]),
         "eps": round(raw["eps"], 2) if raw.get("eps") is not None else None,
         "tax_pct": _pct(raw.get("_tax"), raw.get("pbt"))}
    if q["pbt"] is not None and bank:  # financing profit; interest is a cost
        q["op_profit"] = q["pbt"] - (q["other_income"] or 0)
        q["expenses"] = q["sales"] - (q["interest"] or 0) - q["op_profit"]
        q["opm"] = _pct(q["op_profit"], q["sales"])
    elif q["pbt"] is not None:
        q["op_profit"] = q["pbt"] + (q["interest"] or 0) + (q["depreciation"] or 0) \
            - (q["other_income"] or 0)
        q["expenses"] = q["sales"] - q["op_profit"]
        q["opm"] = _pct(q["op_profit"], q["sales"])
    q["end"] = _nse_dmy(to_date)
    q["src"] = "nse"
    return {k: v for k, v in q.items() if v is not None}


INTEGRATED_TYPE = "Integrated Filing- Financials"


def quarter_start(end):
    """First day of the quarter a quarter-end date falls in."""
    return end.replace(month=end.month - (end.month - 1) % 3, day=1)


def integrated_rows(rows):
    """integrated-filing-results rows -> legacy-shaped filing rows. SEBI's
    Integrated Filing regime took over from the Mar-2025 quarter and NSE's
    legacy corporates-financial-results listing stopped at Dec-2024 (probed
    2026-09-15: RELIANCE's 130 rows end there) — which is why no 2025 quarter
    ever landed. The new rows carry only `qe_Date`; the quarter's start is
    derived so parse_results_xml can pick the current-quarter context. Rows
    whose `xbrl` is not a real .xml are placeholders."""
    out = []
    for r in rows or []:
        kind = str(r.get("type") or "")
        if kind and "financial" not in kind.lower():
            continue  # governance filings share the feed
        end = parse_nse_date(r.get("qe_Date") or r.get("toDate"))
        xbrl = (r.get("xbrl") or "").strip()
        if not end or not xbrl.lower().endswith(".xml"):
            continue
        con = str(r.get("consolidated") or "").strip().lower()
        out.append({"fromDate": quarter_start(end).strftime("%d-%b-%Y"),
                    "toDate": end.strftime("%d-%b-%Y"),
                    "consolidated": "Consolidated" if con.startswith("consol") or con in ("y", "yes", "true")
                    else "Non-Consolidated",
                    "bank": "B" if "BANKING" in xbrl.upper() else "N", "xbrl": xbrl})
    return out


def pick_results_filings(rows, have, cap=2, keyfn=quarter_of_nse):
    """Newest-first filings worth fetching: consolidated preferred per period,
    known periods skipped. Banks are parsed with BANK_ELEMENTS."""
    by_q = {}
    for r in rows or []:
        period = keyfn(r.get("toDate"))
        if not period or period in have or not r.get("xbrl"):
            continue
        cur = by_q.get(period)
        if cur is None or (cur.get("consolidated") != "Consolidated"
                           and r.get("consolidated") == "Consolidated"):
            by_q[period] = r
    return [by_q[p] for p in sorted(by_q, reverse=True)][:cap]


def fetch_results_quarters(sym, session, have, cap=2, period="Quarterly",
                           keyfn=quarter_of_nse):
    """{period key: parsed dict} for missing periods, cap XBRL doc fetches per
    pass — gaps drain over successive passes. period='Annual' + keyfn=fy_of_nse
    yields full-year consolidated P&L rows through the same parser."""
    r = session.get(NSE_API + "corporates-financial-results",
                    params={"index": "equities", "symbol": sym, "period": period},
                    timeout=25)
    r.raise_for_status()
    rows = r.json()
    rows = (rows.get("data") if isinstance(rows, dict) else rows) or []
    if period == "Quarterly":  # the SEBI integrated-filing feed holds Mar-2025 onward
        try:
            r2 = session.get(NSE_API + "integrated-filing-results",
                             params={"index": "equities", "symbol": sym, "period": "Quarterly",
                                     "period_ended": "Quarterly", "type": INTEGRATED_TYPE},
                             timeout=25)
            r2.raise_for_status()
            j2 = r2.json()
            rows = integrated_rows((j2.get("data") if isinstance(j2, dict) else j2) or []) + rows
        except Exception as e:
            print(f"FUND integrated listing {sym}: {e}")
    out = {}
    for f in pick_results_filings(rows, have, cap, keyfn):
        try:
            q = parse_results_xml(session.get(f["xbrl"], timeout=25).text,
                                  f.get("fromDate"), f.get("toDate"), bank=is_bank_filing(f))
            if q:
                out[keyfn(f["toDate"])] = q
        except Exception as e:
            print(f"FUND results xbrl {sym} {f.get('toDate')}: {e}")
    return out


def fetch_nse_deep(sym, session):
    """(shareholding, docs) for one symbol; every piece fails independently and
    just leaves its section empty. Shapes verified by the probe workflow
    (2026-08-29 run)."""
    def get(path, **params):
        r = session.get(NSE_API + path, params=params, timeout=25)
        r.raise_for_status()
        if "json" not in r.headers.get("content-type", ""):
            raise RuntimeError(f"non-JSON {r.status_code}")
        return r.json()

    sh, reports, anns = {}, None, None
    try:
        master = get("corporate-share-holdings-master", index="equities", symbol=sym)
        sh = shape_shareholding(master)
        sh = enrich_shareholding(sh, master, lambda u: session.get(u, timeout=25).text)
    except Exception as e:
        print(f"FUND NSE shareholding {sym}: {e}")
    try:
        reports = get("annual-reports", index="equities", symbol=sym)
    except Exception as e:
        print(f"FUND NSE reports {sym}: {e}")
    try:  # ~2y window so more than one page of concalls/announcements lands
        ist = datetime.now(IST)
        anns = get("corporate-announcements", index="equities", symbol=sym,
                   from_date=(ist - timedelta(days=730)).strftime("%d-%m-%Y"),
                   to_date=ist.strftime("%d-%m-%Y"))
        if isinstance(anns, dict):
            anns = anns.get("data")
    except Exception as e:
        print(f"FUND NSE announcements {sym}: {e}")
    docs = shape_docs(reports, anns)
    if not any(docs.get(k) for k in ("annual_reports", "announcements", "concalls",
                                     "credit_ratings")):
        docs = {}
    return sh, docs


# ---------- table rows ----------

def fundamentals_rows(sym, annuals, quarters, summary, now, src="yahoo_ts",
                      shareholding=None, docs=None):
    ts = now.isoformat()
    rows = [{"symbol": sym, "kind": "annual", "period": p, "data": {"src": src, **d},
             "updated_at": ts} for p, d in annuals.items()]  # d's own src wins
    rows += [{"symbol": sym, "kind": "quarter", "period": p, "data": {"src": src, **d},
              "updated_at": ts} for p, d in quarters.items()]
    rows += [{"symbol": sym, "kind": "shareholding", "period": p, "data": d,
              "updated_at": ts} for p, d in (shareholding or {}).items()]
    if docs is not None:  # {} on an NSE pass that found nothing: the row's
        # updated_at is the "NSE pieces ran" stamp refresh_deep_warm orders by
        rows.append({"symbol": sym, "kind": "docs", "period": "latest",
                     "data": docs, "updated_at": ts})
    if summary:
        rows.append({"symbol": sym, "kind": "summary", "period": "latest",
                     "data": summary, "updated_at": ts})
    return rows


# ---------- fetchers (network; kept thin, everything above is pure) ----------

def fetch_statements(sym, now=None):
    """(annuals, quarters, stats): one timeseries GET (statements, 5y window
    — Yahoo serves 4 FYs + ~5 quarters regardless) + one quoteSummary GET for
    the reported shares/book value."""
    session, crumb = yahoo_session()
    now = now or datetime.now(timezone.utc)
    p2 = int(now.timestamp())

    def get(url, params):
        nonlocal session, crumb
        r = session.get(url, params={**params, "crumb": crumb}, timeout=TIMEOUT)
        if r.status_code == 401:  # crumb expired mid-run: one refresh, retry once
            session, crumb = yahoo_session(force=True)
            r = session.get(url, params={**params, "crumb": crumb}, timeout=TIMEOUT)
        r.raise_for_status()
        return r.json()

    ts = parse_timeseries(get(f"{TS_URL}{sym}.NS", {"type": TS_TYPES, "period1": p2 - 5 * 366 * 86400,
                                                    "period2": p2}))
    stats = parse_stats(get(f"{QS_URL}{sym}.NS", {"modules": STMT_MODULES}))
    if not stats.get("shares"):  # reported average shares beat no shares at all
        newest = next(iter(sorted(ts["annual"], reverse=True)), None)
        avg = ts["annual"].get(newest, {}).get("basicAverageShares") if newest else None
        if avg:
            stats["shares"] = avg
    annuals, quarters = shape_statements(ts, stats)
    return annuals, quarters, stats


def ttm_dps(dividends, now):
    """Per-share dividends paid in the trailing 365 days — Screener's
    current-yield basis, not a fiscal-year bucket."""
    cutoff = now.timestamp() - 365 * 86400
    vals = [d.get("amount") or 0 for ts, d in (dividends or {}).items()
            if int(ts) >= cutoff]
    return round(sum(vals), 2) if vals else None


def fetch_chart_deep(sym, now):
    """(monthly closes 10y, trailing-12M dps) — one chart call."""
    r = requests.get(f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}.NS",
                     params={"range": "10y", "interval": "1mo", "events": "div"},
                     headers=BROWSER_UA, timeout=TIMEOUT)
    r.raise_for_status()
    res = r.json()["chart"]["result"][0]
    closes = (res.get("indicators", {}).get("quote") or [{}])[0].get("close") or []
    return closes, ttm_dps((res.get("events") or {}).get("dividends"), now)


def _existing_fresh(sb, symbols, now):
    """Symbols whose summary row is younger than DEEP_MAX_AGE_D."""
    if not symbols:
        return set()
    cutoff = (now - timedelta(days=DEEP_MAX_AGE_D)).strftime("%Y-%m-%dT%H:%M:%SZ")
    rows = sb("GET", "fundamentals?select=symbol&kind=eq.summary"
                     f"&updated_at=gte.{cutoff}")
    return {r["symbol"] for r in rows} & set(symbols)


def basis_ok(yahoo_annuals, prior_annuals, tol=0.10):
    """Yahoo's legacy statement modules serve STANDALONE (or, for banks, a
    different revenue definition) for some .NS symbols — measured 2026-08-29:
    RELIANCE FY2023 came back 529,773 vs the verified consolidated 876,396.
    Gate: compare the newest overlap year against a non-yahoo (kaggle/nse)
    prior row; >tol sales divergence rejects ALL Yahoo statement data for the
    symbol (NSE consolidated XBRL fills instead). No reference year = accept."""
    for field in ("sales", "eps"):  # eps catches banks whose ref lacks sales
        for period in sorted(set(yahoo_annuals) & set(prior_annuals), reverse=True):
            ref = prior_annuals[period]
            if (ref.get("src") or "").startswith("yahoo") or not ref.get(field):
                continue
            yv = yahoo_annuals[period].get(field)
            if not yv:
                continue
            return abs(yv - ref[field]) / abs(ref[field]) <= tol
    return True


def _overwritable(new, prior):
    """Periods a fresh Yahoo pull may (re)write: absent or yahoo-sourced.
    kaggle rows are Screener's own numbers (split-adjusted per-share history)
    and nse rows are the consolidated filing itself — both outrank a Yahoo
    restatement of the same period."""
    return {p: d for p, d in new.items()
            if ((prior.get(p) or {}).get("src") or "yahoo").startswith("yahoo")}


def _complete_quarters(rows):
    """Periods the NSE XBRL filler need not fetch: filing/kaggle rows, or
    Yahoo rows that already carry operating profit (a Yahoo quarter without
    depreciation has no op_profit/opm — the filing fills those cells)."""
    return {p for p, d in rows.items()
            if d.get("src") in ("nse", "kaggle") or d.get("op_profit") is not None}


def _junk(d):
    """A legacy-Yahoo row with zero sales and zero profit: Yahoo answered an
    empty period and the old code stored it — renders as a fake 0 column.
    Deleted on the symbol's next pass (rule shown to and approved by Tanis,
    15 Sep 2026: 23 rows). Nothing from kaggle/nse/yahoo_ts is ever deleted."""
    return (d.get("src") == "yahoo" and not d.get("sales") and not d.get("net_profit"))


def deep_fetch(sb, symbols, now, nse=True, q_cap=2, yahoo=True):
    """nse=False = Yahoo-only (statements + chart) — runnable from machines
    NSE blocks; the NSE pieces (shareholding/results/docs) drain via CI. A
    Yahoo miss never skips the NSE pieces for that symbol. yahoo=False = NSE
    pieces + re-audit only; the Yahoo statements stay as stored (the chart
    call still runs: one request, and compute_summary needs closes). Every
    pass ends with the symbol's audit (fund_audit.audit_symbol) written into
    its summary row, computed on the very rows just merged. `q_cap` = NSE
    XBRL docs per pass (the warm/drain raise it for symbols with holes)."""
    n = 0
    nse_s = nse_session() if symbols and nse else None
    for sym in symbols:
        try:
            qsym = quote(sym, safe="")  # M&M: '&' would split the query string
            annuals, quarters, stats = {}, {}, {}
            if yahoo:
                try:
                    annuals, quarters, stats = fetch_statements(sym, now)
                except Exception as e:
                    counters["ts_fail"] += 1
                    print(f"FUND statements {sym}: {e}")
                    if getattr(getattr(e, "response", None), "status_code", None) == 429:
                        time.sleep(2)
            # merge with what the table already holds (kaggle/nse/older yahoo
            # rows) for the CAGR math — the upsert itself never deletes periods.
            prior = {r["period"]: r["data"] for r in
                     sb("GET", f"fundamentals?select=period,data&kind=eq.annual&symbol=eq.{qsym}")}
            prior_q = {r["period"]: {k: v for k, v in r.items() if k != "period" and v is not None}
                       for r in sb("GET", "fundamentals?select=period,src:data->src,"
                                          "op_profit:data->op_profit,sales:data->sales,"
                                          "net_profit:data->net_profit,eps:data->eps,"
                                          "expenses:data->expenses,interest:data->interest"
                                          f"&kind=eq.quarter&symbol=eq.{qsym}")}
            for kind, rows in (("annual", prior), ("quarter", prior_q)):
                for p in [p for p, d in rows.items() if _junk(d)]:
                    sb("DELETE", f"fundamentals?symbol=eq.{qsym}&kind=eq.{kind}&period=eq.{p}")
                    del rows[p]
                    counters["junk_deleted"] += 1
            basis_drop = False
            if annuals and not basis_ok(annuals, prior):
                # standalone/mis-defined Yahoo statements: never written; the
                # NSE consolidated XBRL below is the only statement source.
                counters["basis_drop"] += 1
                basis_drop = True
                print(f"FUND basis mismatch {sym}: yahoo statements dropped")
                annuals, quarters = {}, {}
            annuals, quarters = _overwritable(annuals, prior), _overwritable(quarters, prior_q)
            shareholding, docs = {}, None
            if nse:
                try:  # NSE results XBRL fills quarters Yahoo doesn't serve
                      # complete (older ones, no-depreciation ones), q_cap doc
                      # fetches per pass — the gap drains over passes.
                    quarters.update(fetch_results_quarters(
                        sym, nse_s, _complete_quarters(prior_q) | _complete_quarters(quarters),
                        cap=q_cap))
                    # annual filings fill FYs Yahoo couldn't provide (basis
                    # mismatch) — full-year consolidated P&L, same parser.
                    missing_fy = fetch_results_quarters(
                        sym, nse_s, set(prior) | set(annuals), cap=q_cap,
                        period="Annual", keyfn=fy_of_nse)
                    annuals.update(missing_fy)
                except Exception as e:
                    counters["results_fail"] += 1
                    print(f"FUND results {sym}: {e}")
                shareholding, docs = fetch_nse_deep(sym, nse_s)
            closes, dps = [], None
            try:
                closes, dps = fetch_chart_deep(sym, now)
            except Exception as e:
                counters["chart_fail"] += 1
                print(f"FUND chart {sym}: {e}")
            prior_sh, docs_at = {}, None
            for r in sb("GET", "fundamentals?select=kind,period,data,updated_at"
                               f"&kind=in.(shareholding,docs)&symbol=eq.{qsym}"):
                if r["kind"] == "shareholding":
                    prior_sh[r["period"]] = r["data"]
                else:  # the docs stamp is read even on a Yahoo-only pass
                    docs_at = r.get("updated_at")
            all_a, all_q = {**prior, **annuals}, {**prior_q, **quarters}
            all_sh = {**prior_sh, **shareholding}
            summary = compute_summary(all_a, all_q, closes, shareholding=all_sh)
            if stats.get("shares"):
                summary["shares"] = stats["shares"]
            if dps is not None:
                summary["dps_ttm"] = dps
            summary["audit"] = fund_audit.audit_symbol(
                all_a, all_q, all_sh, now.isoformat() if docs is not None else docs_at,
                basis_drop, now, complete_q=_complete_quarters(all_q))
            n += upsert(sb, fundamentals_rows(sym, annuals, quarters, summary, now,
                                              shareholding=shareholding, docs=docs),
                        table="fundamentals", key="symbol,kind,period")
        except Exception as e:
            counters["sym_fail"] += 1
            print(f"FUND {sym}: {e}")
        time.sleep(0.5)
    return n


# ---------- screening engine: fundamentals -> screener_metrics, daily ----------

SCREENER_COLS = ("symbol", "name", "price", "mcap_cr", "pe", "pb",
                 "div_yield", "roe", "roce", "de", "opm",
                 "sales_cagr_3y", "profit_cagr_3y", "sales_cagr_5y",
                 "profit_cagr_5y", "promoter_pct", "updated_at")


def ttm_eps(quarters):
    """Sum of the newest 4 quarterly eps; None unless all 4 are present."""
    vals = [quarters[k].get("eps") for k in sorted(quarters, reverse=True)[:4]]
    vals = [v for v in vals if v is not None]
    return round(sum(vals), 2) if len(vals) == 4 else None


def screener_metrics_row(sym, name, annuals, quarters, promoter_pct, price, now,
                         shares=None, dps_ttm=None):
    """One screener_metrics row; every SCREENER_COLS key always present (None
    where uncomputable) so upsert() lands in one PGRST102 bucket. `shares` is
    the REPORTED count (defaultKeyStatistics) and `dps_ttm` real trailing
    dividends — inference is a fallback only. sector/industry are not ours:
    stockanalysis.py owns them (migration 022) and the merge upsert keeps them."""
    eps_used = ttm_eps(quarters) or _latest(annuals, "eps")
    np_, eps_a = _latest(annuals, "net_profit"), _latest(annuals, "eps")
    shares_cr = shares / 1e7 if shares else None
    if shares_cr is None and np_ is not None and eps_a:
        # ponytail fallback: np/eps overstates shares when consolidated net
        # profit includes minority interest (RELIANCE +11%) — reported shares
        # replace this the first time a deep pass runs.
        shares_cr = np_ / eps_a
    equity = (_latest(annuals, "reserves") or 0) + (_latest(annuals, "equity_cap") or 0) \
        if _latest(annuals, "reserves") is not None or _latest(annuals, "equity_cap") is not None \
        else None
    borrowings = _latest(annuals, "borrowings")
    bv = _latest(annuals, "book_value")  # reported ₹/share when a deep pass ran
    if bv is None and equity is not None and equity > 0 and shares_cr:
        bv = equity / shares_cr
    r = {"symbol": sym, "name": name, "price": price,
         "mcap_cr": round(price * shares_cr, 1) if price and shares_cr and shares_cr > 0 else None,
         "pe": round(price / eps_used, 2) if price and eps_used and eps_used > 0 else None,
         "pb": round(price / bv, 2) if price and bv and bv > 0 else None,
         "div_yield": round(dps_ttm / price * 100, 2) if price and dps_ttm else None,
         # kaggle annuals carry no roe field — np/equity fills it
         "roe": _latest(annuals, "roe") if _latest(annuals, "roe") is not None
             else (round(np_ / equity * 100, 1)
                   if np_ is not None and equity is not None and equity > 0 else None),
         "roce": _latest(annuals, "roce"),
         "de": (round((borrowings or 0) / equity, 2)
                if equity is not None and equity > 0 else None),
         "opm": _latest(annuals, "opm"),
         "promoter_pct": promoter_pct, "updated_at": now.isoformat()}
    for field, col in (("sales", "sales_cagr"), ("net_profit", "profit_cagr")):
        block = _cagr_block(annuals, field)
        r[f"{col}_3y"] = block.get("y3")
        r[f"{col}_5y"] = block.get("y5")
    return r


def refresh_screener(sb, now):
    """Daily 18:00 IST: every symbol with >=1 annual row gets a metrics row.
    Projected jsonb selects (never select=data) keep egress small; a spark
    miss falls back to the previous stored price instead of nulling it."""
    fields = ("sales", "net_profit", "eps", "opm", "roe", "roce", "borrowings",
              "reserves", "equity_cap", "div_payout", "book_value")
    sel = ",".join(f"{f}:data->{f}" for f in fields)
    annuals, quarters, sh = {}, {}, {}
    for r in sb("GET", f"fundamentals?select=symbol,period,{sel}"
                       "&kind=eq.annual&order=symbol,period"):
        annuals.setdefault(r["symbol"], {})[r["period"]] = \
            {k: v for k, v in r.items() if k not in ("symbol", "period") and v is not None}
    for r in sb("GET", "fundamentals?select=symbol,period,eps:data->eps"
                       "&kind=eq.quarter&order=symbol,period"):
        if r.get("eps") is not None:
            quarters.setdefault(r["symbol"], {})[r["period"]] = {"eps": r["eps"]}
    for r in sb("GET", "fundamentals?select=symbol,period,promoters:data->promoters"
                       "&kind=eq.shareholding&order=symbol,period"):
        if r.get("promoters") is not None:
            sh[r["symbol"]] = r["promoters"]  # ordered asc: last write = newest
    summ = {r["symbol"]: r for r in
            sb("GET", "fundamentals?select=symbol,shares:data->shares,"
                      "dps_ttm:data->dps_ttm&kind=eq.summary&order=symbol")}
    if not annuals:
        return 0
    names = {c["nse_symbol"]: c.get("name") for c in
             sb("GET", "companies?select=nse_symbol,name") if c.get("nse_symbol")}
    prev = {r["symbol"]: r["price"] for r in
            sb("GET", "screener_metrics?select=symbol,price")}
    syms = sorted(annuals)
    data = fetch_spark([f"{s}.NS" for s in syms])
    rows = []
    for s in syms:
        p = parse_spark(data.get(f"{s}.NS", {}) or {})
        price = p.price if p else prev.get(s)
        rows.append(screener_metrics_row(s, names.get(s), annuals[s],
                                         quarters.get(s, {}), sh.get(s), price, now,
                                         shares=summ.get(s, {}).get("shares"),
                                         dps_ttm=summ.get(s, {}).get("dps_ttm")))
    return upsert(sb, rows, table="screener_metrics", key="symbol")


def scale_px_rows(rows, prices, ts):
    """Intraday refresh without re-reading fundamentals: scale the price-linked
    columns by new/old price. Rows without both prices are left alone."""
    out = []
    for r in rows:
        new = prices.get(r["symbol"])
        old = r.get("price")
        if not new or not old:
            continue
        k = new / old
        out.append({"symbol": r["symbol"], "price": round(new, 2),
                    "pe": round(r["pe"] * k, 2) if r.get("pe") is not None else None,
                    "pb": round(r["pb"] * k, 2) if r.get("pb") is not None else None,
                    "mcap_cr": round(r["mcap_cr"] * k, 1) if r.get("mcap_cr") is not None else None,
                    "updated_at": ts})
    return out


def refresh_screener_px(sb, now):
    """Hourly during market hours: fresher screen prices between the daily
    18:00 rebuilds. ~1MB egress a pass (small row read + spark batches)."""
    from market import market_hours
    if not market_hours(now):
        return 0
    rows = sb("GET", "screener_metrics?select=symbol,price,pe,pb,mcap_cr")
    if not rows:
        return 0
    data = fetch_spark([f"{r['symbol']}.NS" for r in rows if r.get("price")])
    prices = {}
    for r in rows:
        p = parse_spark(data.get(f"{r['symbol']}.NS", {}) or {})
        if p:
            prices[r["symbol"]] = p.price
    out = scale_px_rows(rows, prices, now.isoformat())
    return upsert(sb, out, table="screener_metrics", key="symbol") if out else 0


def refresh_deep_new(sb, now):
    """Every 5 min: deep statements for symbols users opened (analysis_requests,
    same rows market.refresh_analysis_new reads — no extra request table)."""
    reqs = [r["symbol"] for r in sb("GET", "analysis_requests?select=symbol&order=requested_at")]
    todo = [s for s in reqs if s not in _existing_fresh(sb, reqs, now)][:DEEP_NEW_CAP]
    return deep_fetch(sb, todo, now) if todo else 0


WARM_CAP = 60  # daily 17:30 pass: the top-50 + followed names (~7 min); the
               # universe itself drains through refresh_deep_drain every 5 min


def warm_universe(ages, priority, now, cap, deficit=None, max_age_d=DEEP_MAX_AGE_D):
    """Symbols to deep-warm today: priority names first, then the largest
    fixable deficit (fund_audit; never-audited = INF), oldest first within a
    tie; anything refreshed within max_age_d is skipped. `ages` is
    {symbol: updated_at iso or ''} — iso strings compare fine."""
    cutoff = (now - timedelta(days=max_age_d)).isoformat()
    stale = {s for s, at in ages.items() if (at or "") < cutoff}
    out = [s for s in priority if s in stale]
    deficit = deficit or {}
    rest = sorted((s for s in stale if s not in set(priority)),
                  key=lambda s: (-deficit.get(s, fund_audit.INF), ages.get(s) or "", s))
    return (out + rest)[:cap]


def load_audits(sb):
    """(audits {symbol: audit|None}, ages {symbol: docs updated_at or ''},
    lrd {symbol: SA lastReportDate}) for the quoted screener universe — the
    one read (~1 MB) both the warm ordering and the rollup need. Unquoted
    rows (price null = no NSE mainboard quote: the ~750 SME-board names
    stockanalysis lists) are outside the panel: Yahoo 404s and the NSE
    corporate APIs are empty for them, so they could never be complete."""
    audits = {r["symbol"]: None for r in
              sb("GET", "screener_metrics?select=symbol&price=not.is.null&order=symbol")}
    lrd = {r["symbol"]: r.get("lrd") for r in
           sb("GET", "screener_metrics?select=symbol,lrd:sa->>lastReportDate"
                     "&price=not.is.null&order=symbol")}
    for r in sb("GET", "fundamentals?select=symbol,audit:data->audit&kind=eq.summary&order=symbol"):
        if r["symbol"] in audits:
            audits[r["symbol"]] = r.get("audit") or None
    ages = {s: "" for s in audits}
    for r in sb("GET", "fundamentals?select=symbol,updated_at&kind=eq.docs&order=symbol"):
        if r["symbol"] in ages:
            ages[r["symbol"]] = r["updated_at"]
    return audits, ages, lrd


def write_rollup(sb, audits, lrd, now):
    """The Health/admin summary in app_config `fund_audit`, keeping the
    previous pct so ops can alert on a drop."""
    prev = None
    try:
        rows = sb("GET", "app_config?select=value&key=eq.fund_audit")
        stored = (rows[0]["value"] if rows else {}) or {}
        # day-over-day: an intra-day rewrite (deep_drain every ~2 h) keeps the
        # earlier day's figure, so the ops drop alert and "Prev day" stay true
        same_day = str(stored.get("at") or "")[:10] == now.strftime("%Y-%m-%d")
        prev = stored.get("prev_pct") if same_day else stored.get("pct_complete")
    except Exception:
        pass
    roll = fund_audit.rollup(((s, a, lrd.get(s)) for s, a in audits.items()), now, prev_pct=prev)
    upsert(sb, [{"key": "fund_audit", "value": roll, "updated_at": now.isoformat()}],
           table="app_config", key="key")
    return roll


def refresh_deep_warm(sb, now):
    """Daily 17:30 IST: the 50 biggest names and followed companies, then
    whatever largest-deficit symbols fit in WARM_CAP (fund_audit verdicts;
    never-audited first, oldest docs stamp within a tie). Writes the rollup
    before fetching, so Health shows the state the pass started from. The
    universe converges through refresh_deep_drain below."""
    audits, ages, lrd = load_audits(sb)
    write_rollup(sb, audits, lrd, now)
    deficits = {s: fund_audit.deficit(a, now, lrd.get(s))[0] for s, a in audits.items()}
    holes = {s: sum(1 for c in fund_audit.deficit(a, now, lrd.get(s))[1] if c.startswith("q."))
             for s, a in audits.items() if a}
    priority = [r["symbol"] for r in
                sb("GET", "screener_metrics?select=symbol&order=mcap_cr.desc.nullslast&limit=50")]
    followed = [int(f["target_id"]) for f in
                sb("GET", "follows?select=target_id&target_type=eq.company")
                if str(f["target_id"]).isdigit()]
    for i in range(0, len(followed), 200):
        chunk = ",".join(str(c) for c in followed[i:i + 200])
        priority = [c["nse_symbol"] for c in
                    sb("GET", f"companies?select=nse_symbol&id=in.({chunk})")
                    if c.get("nse_symbol")] + priority
    todo = warm_universe(ages, list(dict.fromkeys(priority)), now, WARM_CAP, deficit=deficits)
    # any quarter hole gets the deeper NSE drain (4 filings a pass): 5 Yahoo
    # quarters + 2 filings still fall short of MIN_Q, so q_cap=2 meant a second
    # pass a week later. 250 x 4 = 1,000 XBRL fetches/day at most — watch
    # counters["results_fail"]
    deep = [s for s in todo if holes.get(s, 0) >= 1]
    n = deep_fetch(sb, [s for s in todo if s not in set(deep)], now)
    return n + deep_fetch(sb, deep, now, q_cap=4)


# ---------- the loop: a few symbols every 5 min, forever ----------

DRAIN_CAP = 16       # symbols per 5-min lap off-hours (~2 min of fetching; 8 ran
                     # 14 h with zero Yahoo/NSE refusals, raised 18 Sep 2026)
DRAIN_CAP_MKT = 3    # during NSE hours: quotes/alerts laps must not wait
DRAIN_REFRESH_S = 7200  # rebuild the queue (one ~1 MB load_audits) every 2 h
DRAIN_GAP_D = 1      # a symbol is eligible again a day after its last NSE pass
_drain = {"at": None, "todo": []}  # run.py memo idiom: None = never built
                                   # (monotonic() counts from boot, so 0.0 lies)


def refresh_deep_drain(sb, now, cap=DRAIN_CAP):
    """Every 5 min in CI (market.GROUPS "deep_drain"): the next `cap` symbols
    of a deficit-ordered queue — never-audited first, then the most fixable
    gaps, staleness recomputed from SA's lastReportDate at rebuild time, so a
    fresh filing surfaces within a day. ~3,600 symbols/day revisits the
    2.5k quoted universe daily, spread out instead of one 30-min
    burst that paused the feed laps. Yahoo is re-hit only for a Yahoo-fixable
    gap or statements older than DEEP_MAX_AGE_D; NSE-only gaps run the NSE
    pieces and re-audit from stored rows. Egress: the 2-hourly rebuild is
    ~1 MB (~0.5 GB/month with CI process boots), the rollup rides on it.
    # ponytail: no backoff — a symbol whose gap no source can fill is retried
    # daily (~8 calls); add exponential backoff on an unchanged audit if
    # counters["results_fail"] climbs."""
    if _drain["at"] is None or time.monotonic() - _drain["at"] > DRAIN_REFRESH_S:
        audits, ages, lrd = load_audits(sb)
        write_rollup(sb, audits, lrd, now)
        verdict = {s: fund_audit.deficit(a, now, lrd.get(s)) for s, a in audits.items()}
        order = warm_universe(ages, [], now, 10 ** 6, max_age_d=DRAIN_GAP_D,
                              deficit={s: d for s, (d, _) in verdict.items()})
        _drain.update(at=time.monotonic(),
                      todo=[(s, verdict[s][1], (audits.get(s) or {}).get("at") or "")
                            for s in order if verdict[s][0] > 0])
    batch, _drain["todo"] = _drain["todo"][:cap], _drain["todo"][cap:]
    old = (now - timedelta(days=DEEP_MAX_AGE_D)).isoformat()
    full = [s for s, codes, at in batch
            if at < old or any(fund_audit.FIXER.get(c, "yahoo") == "yahoo" for c in codes)]
    nse_only = [s for s, _, _ in batch if s not in set(full)]
    n = deep_fetch(sb, full, now, q_cap=4) if full else 0
    return n + (deep_fetch(sb, nse_only, now, q_cap=4, yahoo=False) if nse_only else 0)
