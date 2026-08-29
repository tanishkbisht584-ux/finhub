"""Deep fundamentals (2026-08-29): Screener-style statement history into the
`fundamentals` table (migration 016) — annual/quarter P&L + balance sheet +
cash flow + ratios, plus a derived `summary` row (CAGR blocks, rule-based
pros/cons). One row per (symbol, kind, period); accumulation is a plain PK
upsert, so history grows forever even though Yahoo only serves ~4 years.

Sources: Yahoo quoteSummary statement modules (same crumb dance as market.py),
Yahoo monthly chart for price CAGR. NSE shareholding/docs land here in a later
phase. Driven by the same analysis_requests rows market.refresh_analysis_new
reads — opening a stock page is the trigger; Nifty50 + followed pre-warm daily.

ponytail: Yahoo's *History modules are legacy and could go dark; the swap
target is the timeseries endpoint, isolated inside fetch_statements.
"""
import re
import time
from datetime import datetime, timedelta

import requests

from market import (BROWSER_UA, IST, NSE_API, QS_URL, TIMEOUT, fetch_spark,
                    nse_session, parse_nse_date, parse_spark, upsert,
                    yahoo_session)

CR = 1e7  # raw INR per crore

STMT_MODULES = ("incomeStatementHistory,balanceSheetHistory,cashflowStatementHistory,"
                "incomeStatementHistoryQuarterly,defaultKeyStatistics")

DEEP_MAX_AGE_D = 7   # summary row younger than this: skip the symbol
DEEP_NEW_CAP = 5     # requested-symbol deep fetches per 5-min pass


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


def _pnl(s, shares, quarterly=False):
    rev, op = s.get("totalRevenue"), s.get("operatingIncome")
    pbt, tax, np_ = s.get("incomeBeforeTax"), s.get("incomeTaxExpense"), s.get("netIncome")
    interest = s.get("interestExpense")
    d = {"sales": _cr(rev), "op_profit": _cr(op),
         "expenses": _cr(rev - op) if rev is not None and op is not None else None,
         "opm": _pct(op, rev), "other_income": _cr(s.get("totalOtherIncomeExpenseNet")),
         "interest": _cr(abs(interest)) if interest is not None else None,
         "pbt": _cr(pbt), "tax_pct": _pct(tax, pbt), "net_profit": _cr(np_),
         "eps": round(np_ / shares, 2) if np_ is not None and shares else None}
    return d


def _bs(s):
    equity, common = s.get("totalStockholderEquity"), s.get("commonStock")
    debt = sum(s.get(k) or 0 for k in ("shortLongTermDebt", "longTermDebt")) or None
    total, liab = s.get("totalAssets"), s.get("totalLiab")
    ppe = s.get("propertyPlantEquipment")
    inv = sum(s.get(k) or 0 for k in ("longTermInvestments", "shortTermInvestments")) or None
    return {"equity_cap": _cr(common),
            "reserves": _cr(equity - common) if equity is not None and common is not None else None,
            "borrowings": _cr(debt),
            "other_liab": _cr(liab - debt) if liab is not None and debt is not None else None,
            "fixed_assets": _cr(ppe), "investments": _cr(inv),
            "other_assets": _cr(total - (ppe or 0) - (inv or 0)) if total is not None else None,
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
    return r


def parse_statements(j):
    """(annuals {FY2026: {...}}, quarters {2026-06: {...}}) — one dict per period
    carrying P&L + BS + CF + ratio fields, ₹ Cr, nulls dropped. Newest first."""
    r = ((j.get("quoteSummary") or {}).get("result") or [{}])[0]
    stats = r.get("defaultKeyStatistics") or {}
    shares = (stats.get("sharesOutstanding") or {}).get("raw")
    pnl_a = _stmt_map("incomeStatementHistory", "incomeStatementHistory", j)
    bs_a = _stmt_map("balanceSheetHistory", "balanceSheetStatements", j)
    cf_a = _stmt_map("cashflowStatementHistory", "cashflowStatements", j)
    annuals = {}
    for end in sorted(pnl_a, reverse=True):
        d = {**_pnl(pnl_a[end], shares), "end": end}
        b = bs_a.get(end, {})
        d.update(_bs(b))
        d.update(_ratios(pnl_a[end], b))
        c = cf_a.get(end, {})
        d.update(_cf(c))
        d["depreciation"] = _cr(c.get("depreciation"))
        np_, div = pnl_a[end].get("netIncome"), c.get("dividendsPaid")
        if np_ and div is not None:
            d["div_payout"] = round(abs(div) / np_ * 100, 1)
        annuals[fy_label(end)] = {k: v for k, v in d.items() if v is not None}
    quarters = {}
    for end in sorted(_stmt_map("incomeStatementHistoryQuarterly", "incomeStatementHistory", j),
                      reverse=True):
        s = _stmt_map("incomeStatementHistoryQuarterly", "incomeStatementHistory", j)[end]
        d = {**_pnl(s, shares), "end": end}
        quarters[end[:7]] = {k: v for k, v in d.items() if v is not None}
    if stats.get("bookValue") is not None and annuals:
        newest = next(iter(annuals))
        annuals[newest]["book_value"] = (stats["bookValue"] or {}).get("raw") \
            if isinstance(stats.get("bookValue"), dict) else stats.get("bookValue")
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


def pros_cons(annuals):
    """Screener-style rule bullets. Deliberately few and blunt — every rule is
    a plain threshold a reader can verify from the tables below it."""
    pros, cons = [], []
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


def compute_summary(annuals, quarters, monthly_closes):
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
    pros, cons = pros_cons(annuals)
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


def shape_docs(reports, announcements, ratings=None, cap=20):
    """{annual_reports: [{fy,url}], announcements: [{date,subject,url}],
    concalls: [...], credit_ratings: [...]}. Concall-ish announcements
    (transcripts, PPTs, analyst meets) move to their own list, Screener-style."""
    ars = [{"fy": r.get("toYr"), "url": r.get("fileName")}
           for r in (reports or {}).get("data") or [] if r.get("fileName")]
    anns, calls = [], []
    for a in announcements or []:
        subject = a.get("desc") or a.get("attchmntText")
        if not subject:
            continue
        row = {"date": a.get("an_dt"), "subject": subject, "url": a.get("attchmntFile")}
        (calls if CONCALL_RE.search(subject) else anns).append(row)
    out = {"annual_reports": ars, "announcements": anns[:cap], "concalls": calls[:12]}
    if ratings:
        out["credit_ratings"] = ratings
    return out


def _first(r, *keys):
    for k in keys:
        if r.get(k):
            return r[k]
    return None


def shape_ratings(j, cap=8):
    """corporate-credit-rating rows -> [{agency, rating, date, url}]. Key names
    are best guesses normalized through variants — verify from a runner."""
    out = []
    for r in (j.get("data") if isinstance(j, dict) else j) or []:
        agency = _first(r, "creditRatingAgencyName", "cra", "agency", "creditRatingAgency")
        rating = _first(r, "rating", "crRating", "creditRating")
        if not agency and not rating:
            continue
        out.append({"agency": agency, "rating": rating,
                    "date": _first(r, "date", "crDate", "an_dt"),
                    "url": _first(r, "attchmntFile", "xbrl", "fileName")})
    return out[:cap]


# SEBI SHP taxonomy localname patterns -> our shareholding keys. Step A best
# guesses (2026-08-29); the unmapped-names diagnostic in enrich_shareholding
# prints one real filing's element names to the CI log for step B correction.
SHP_PATTERNS = (
    ("fiis", re.compile(r"ForeignPortfolioInvestor|ForeignInstitutionalInvestor", re.I)),
    ("diis", re.compile(r"MutualFund|InsuranceCompan|ProvidentFund|PensionFund"
                        r"|FinancialInstitution|AlternateInvestmentFund", re.I)),
    ("govt", re.compile(r"CentralGovernment|StateGovernment|PresidentOfIndia", re.I)),
    ("n_holders", re.compile(r"TotalNumberOfShareholders|NumberOfShareholders$", re.I)),
)


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


def map_shp_facts(facts):
    """(mapped {fiis, diis, govt, n_holders}, unmapped localnames). Facts whose
    localname matches multiple patterns of one key are summed (DII buckets)."""
    sums, unmapped = {}, []
    for name, text in facts.items():
        try:
            v = float(str(text).replace(",", ""))
        except ValueError:
            continue
        for key, pat in SHP_PATTERNS:
            if pat.search(name):
                sums[key] = sums.get(key, 0) + v
                break
        else:
            unmapped.append(name)
    if "n_holders" in sums:
        sums["n_holders"] = int(sums["n_holders"])
    return {k: (round(v, 2) if isinstance(v, float) else v) for k, v in sums.items()}, unmapped


def enrich_shareholding(sh, master_rows, fetch):
    """Merge the FII/DII split from the newest filing's XBRL into the newest
    shareholding period. One doc fetch per symbol per pass (insider's cost
    model); any failure leaves the master's promoter/public split untouched."""
    if not sh or not master_rows:
        return sh
    newest = master_rows[0]  # API order is newest-first, like the master shape
    url = _first(newest, "xbrl", "xbrlFile", "submissionLink")
    if not url:
        print(f"FUND SHP no xbrl field; row keys: {sorted(newest)[:20]}")
        return sh
    try:
        mapped, unmapped = map_shp_facts(parse_ix_facts(fetch(url)))
    except Exception as e:
        print(f"FUND SHP xbrl fetch/parse: {e}")
        return sh
    if unmapped:
        print(f"FUND SHP unmapped elements (step B): {unmapped[:40]}")
    period = max(sh)
    if mapped:
        sh[period] = {**sh[period], **mapped}
    return sh


def fetch_nse_deep(sym, session):
    """(shareholding, docs) for one symbol; every piece fails independently and
    just leaves its section empty. Endpoint shapes per NseIndiaApi docs —
    verify from a runner on first deploy (NSE blocks this dev machine)."""
    def get(path, **params):
        r = session.get(NSE_API + path, params=params, timeout=25)
        r.raise_for_status()
        if "json" not in r.headers.get("content-type", ""):
            raise RuntimeError(f"non-JSON {r.status_code}")
        return r.json()

    sh, reports, anns, ratings = {}, None, None, None
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
    try:  # endpoint path unverified (undocumented) — silent absence if wrong
        ratings = shape_ratings(get("corporate-credit-rating", index="equities", symbol=sym))
    except Exception as e:
        print(f"FUND NSE ratings {sym}: {e}")
    docs = shape_docs(reports, anns, ratings)
    if not any(docs.get(k) for k in ("annual_reports", "announcements", "concalls",
                                     "credit_ratings")):
        docs = {}
    return sh, docs


# ---------- table rows ----------

def fundamentals_rows(sym, annuals, quarters, summary, now, src="yahoo",
                      shareholding=None, docs=None):
    ts = now.isoformat()
    rows = [{"symbol": sym, "kind": "annual", "period": p, "data": {**d, "src": src},
             "updated_at": ts} for p, d in annuals.items()]
    rows += [{"symbol": sym, "kind": "quarter", "period": p, "data": {**d, "src": src},
              "updated_at": ts} for p, d in quarters.items()]
    rows += [{"symbol": sym, "kind": "shareholding", "period": p, "data": d,
              "updated_at": ts} for p, d in (shareholding or {}).items()]
    if docs:
        rows.append({"symbol": sym, "kind": "docs", "period": "latest",
                     "data": docs, "updated_at": ts})
    if summary:
        rows.append({"symbol": sym, "kind": "summary", "period": "latest",
                     "data": summary, "updated_at": ts})
    return rows


# ---------- fetchers (network; kept thin, everything above is pure) ----------

def fetch_statements(sym):
    session, crumb = yahoo_session()
    r = session.get(f"{QS_URL}{sym}.NS", params={"modules": STMT_MODULES, "crumb": crumb},
                    timeout=TIMEOUT)
    if r.status_code == 401:  # crumb expired mid-run: one refresh, retry once
        session, crumb = yahoo_session(force=True)
        r = session.get(f"{QS_URL}{sym}.NS", params={"modules": STMT_MODULES, "crumb": crumb},
                        timeout=TIMEOUT)
    r.raise_for_status()
    return parse_statements(r.json())


def fetch_monthly_closes(sym):
    r = requests.get(f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}.NS",
                     params={"range": "10y", "interval": "1mo"},
                     headers=BROWSER_UA, timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()["chart"]["result"][0]["indicators"]["quote"][0].get("close") or []


def _existing_fresh(sb, symbols, now):
    """Symbols whose summary row is younger than DEEP_MAX_AGE_D."""
    if not symbols:
        return set()
    cutoff = (now - timedelta(days=DEEP_MAX_AGE_D)).strftime("%Y-%m-%dT%H:%M:%SZ")
    rows = sb("GET", "fundamentals?select=symbol&kind=eq.summary"
                     f"&updated_at=gte.{cutoff}")
    return {r["symbol"] for r in rows} & set(symbols)


def deep_fetch(sb, symbols, now):
    n = 0
    nse = nse_session() if symbols else None
    for sym in symbols:
        try:
            annuals, quarters = fetch_statements(sym)
            if not annuals and not quarters:
                continue
            # merge with what the table already holds (kaggle/older yahoo rows)
            # for the CAGR math — the upsert itself never deletes old periods.
            prior = {r["period"]: r["data"] for r in
                     sb("GET", f"fundamentals?select=period,data&kind=eq.annual&symbol=eq.{sym}")}
            closes = []
            try:
                closes = fetch_monthly_closes(sym)
            except Exception as e:
                print(f"FUND closes {sym}: {e}")
            shareholding, docs = fetch_nse_deep(sym, nse)
            summary = compute_summary({**prior, **annuals}, quarters, closes)
            n += upsert(sb, fundamentals_rows(sym, annuals, quarters, summary, now,
                                              shareholding=shareholding, docs=docs),
                        table="fundamentals", key="symbol,kind,period")
        except Exception as e:
            print(f"FUND {sym}: {e}")
        time.sleep(0.5)
    return n


# ---------- screening engine: fundamentals -> screener_metrics, daily ----------

SCREENER_COLS = ("symbol", "name", "sector", "price", "mcap_cr", "pe", "pb",
                 "div_yield", "roe", "roce", "de", "opm",
                 "sales_cagr_3y", "profit_cagr_3y", "sales_cagr_5y",
                 "profit_cagr_5y", "promoter_pct", "updated_at")


def ttm_eps(quarters):
    """Sum of the newest 4 quarterly eps; None unless all 4 are present."""
    vals = [quarters[k].get("eps") for k in sorted(quarters, reverse=True)[:4]]
    vals = [v for v in vals if v is not None]
    return round(sum(vals), 2) if len(vals) == 4 else None


def screener_metrics_row(sym, name, sector, annuals, quarters, promoter_pct, price, now):
    """One screener_metrics row; every SCREENER_COLS key always present (None
    where uncomputable) so upsert() lands in one PGRST102 bucket."""
    eps_used = ttm_eps(quarters) or _latest(annuals, "eps")
    np_, eps_a = _latest(annuals, "net_profit"), _latest(annuals, "eps")
    # ponytail: shares inferred as np/eps (eps rounded to 2dp upstream) — mcap
    # off a few % for low-eps stocks; good enough to screen, not to display.
    shares = np_ / eps_a if np_ is not None and eps_a else None
    equity = (_latest(annuals, "reserves") or 0) + (_latest(annuals, "equity_cap") or 0) \
        if _latest(annuals, "reserves") is not None or _latest(annuals, "equity_cap") is not None \
        else None
    borrowings = _latest(annuals, "borrowings")
    bv = _latest(annuals, "book_value")
    if bv is None and equity is not None and equity > 0 and shares:
        bv = equity / shares  # Cr / Cr-shares = ₹/share
    payout = _latest(annuals, "div_payout")
    r = {"symbol": sym, "name": name, "sector": sector, "price": price,
         "mcap_cr": round(price * shares, 1) if price and shares and shares > 0 else None,
         "pe": round(price / eps_used, 2) if price and eps_used and eps_used > 0 else None,
         "pb": round(price / bv, 2) if price and bv and bv > 0 else None,
         "div_yield": round(payout * eps_a / 100 / price * 100, 2)
             if price and payout is not None and eps_a and eps_a > 0 else None,
         "roe": _latest(annuals, "roe"), "roce": _latest(annuals, "roce"),
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
    if not annuals:
        return 0
    names = {c["nse_symbol"]: (c.get("name"), c.get("sector")) for c in
             sb("GET", "companies?select=nse_symbol,name,sector") if c.get("nse_symbol")}
    prev = {r["symbol"]: r["price"] for r in
            sb("GET", "screener_metrics?select=symbol,price")}
    syms = sorted(annuals)
    data = fetch_spark([f"{s}.NS" for s in syms])
    rows = []
    for s in syms:
        p = parse_spark(data.get(f"{s}.NS", {}) or {})
        price = p.price if p else prev.get(s)
        name, sector = names.get(s, (None, None))
        rows.append(screener_metrics_row(s, name, sector, annuals[s],
                                         quarters.get(s, {}), sh.get(s), price, now))
    return upsert(sb, rows, table="screener_metrics", key="symbol")


def refresh_deep_new(sb, now):
    """Every 5 min: deep statements for symbols users opened (analysis_requests,
    same rows market.refresh_analysis_new reads — no extra request table)."""
    reqs = [r["symbol"] for r in sb("GET", "analysis_requests?select=symbol&order=requested_at")]
    todo = [s for s in reqs if s not in _existing_fresh(sb, reqs, now)][:DEEP_NEW_CAP]
    return deep_fetch(sb, todo, now) if todo else 0


def refresh_deep_warm(sb, now):
    """Daily 17:30 IST: Nifty50 + followed companies, staleness-gated."""
    syms = [c["nse_symbol"] for c in
            sb("GET", "companies?select=nse_symbol&is_nifty50=eq.true") if c.get("nse_symbol")]
    followed = [int(f["target_id"]) for f in
                sb("GET", "follows?select=target_id&target_type=eq.company")
                if str(f["target_id"]).isdigit()]
    for i in range(0, len(followed), 200):
        chunk = ",".join(str(c) for c in followed[i:i + 200])
        syms += [c["nse_symbol"] for c in
                 sb("GET", f"companies?select=nse_symbol&id=in.({chunk})") if c.get("nse_symbol")]
    syms = list(dict.fromkeys(syms))
    todo = [s for s in syms if s not in _existing_fresh(sb, syms, now)]
    return deep_fetch(sb, todo, now)
