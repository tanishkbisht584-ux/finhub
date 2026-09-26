"""stockanalysis.com screener table: one keyless GET returns any of ~320 data
points for every NSE stock (3.2k rows, ~1.5 s). Undocumented frontend endpoint
found 12 Sep 2026; answers browser-ish UAs from the dev IP AND GitHub runners
(probe run 34678287615). Column ids: column-meta?type=quote.

Ownership rule (council, 12 Sep): this module writes ONLY the columns listed
here (migration 019, plus sector + industry on every row since 022 - the
companies table never had a sector, so peers had nothing to group by) - never
pe/pb/de/opm/roe/roce/div_yield/price/mcap_cr, which stay ours; the site
disagreed with us on 34 of the top-100 P/Es, so the two sets never mix and the
app's "Stock Analysis" footnote is true per column.
ToS: "not allowed to republish content in full" - attributed, additive fields.
"""
import re
from datetime import date, timedelta
from itertools import product

import requests

URL = "https://stockanalysis.com/_api/endpoints/screener/table"
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) FinFlick/1.0"}

# site id -> screener_metrics column (all real numeric columns: filter/sort-able)
NUM = {"ch1w": "ret_1w", "ch1m": "ret_1m", "ch3m": "ret_3m", "ch6m": "ret_6m", "chYTD": "ret_ytd",
       "ch1y": "ret_1y", "ch3y": "ret_3y", "ch5y": "ret_5y", "allTimeHighChange": "ath_pct",
       "averageVolume": "avg_vol", "relativeVolume": "rel_vol", "sharpeRatio": "sharpe",
       "sortinoRatio": "sortino", "atr": "atr", "grahamUpside": "graham_upside", "fScore": "f_score",
       "psRatio": "ps", "earningsYield": "earnings_yield", "fcfYield": "fcf_yield", "roic": "roic",
       "interestCoverage": "int_cov", "evEbitda": "ev_ebitda", "sectorPe": "sector_pe",
       "industryPe": "industry_pe", "sharesYoY": "shares_yoy",
       # 024 (19 Sep): universe technicals for the Markets TRENDS section + stock page
       # (zScore left 26 Sep: fundamentals.py computes altman_z from our own sheets now)
       "ma50": "ma50", "ma200": "ma200", "rsi": "rsi",
       "high52": "hi52", "low52": "lo52",
       # 026 (20 Sep review): Yahoo's beta read 0.17 for TCS vs MC's 0.78; the site's 5Y beta matches MC
       "beta": "beta_5y",
       # 033 (26 Sep, free-parity P1): the rest of the catalogue that is not
       # ours to compute — ids confirmed against column-meta?type=quote the same day
       "ch10y": "ret_10y",
       "tr1y": "tr_1y",
       "low52ch": "dist_lo52",
       "high52ch": "dist_hi52",
       "allTimeLowChange": "from_atl_pct",
       "priceTargetChange": "target_upside",
       "analystCount": "analyst_count",
       "employees": "employees",
       "revPerEmployee": "rev_per_employee_l",
       "peForward": "fwd_pe",
       "peRatio3Y": "pe_avg_3y",
       "peRatio5Y": "pe_avg_5y",
       "pegRatio": "peg",
       "evSales": "ev_sales",
       "evEbit": "ev_ebit",
       "evFcf": "ev_fcf",
       "enterpriseValue": "ev_cr",
       "pFcfRatio": "p_fcf",
       "pOcfRatio": "p_ocf",
       "priceEbitda": "p_ebitda",
       "grossMargin": "gross_margin",
       "ebitdaMargin": "ebitda_margin",
       "pretaxMargin": "pretax_margin",
       "profitMargin": "npm",
       "fcfMargin": "fcf_margin",
       "buybackYield": "buyback_yield",
       "totalReturn": "shareholder_yield",
       "divCAGR5": "div_growth_5y",
       "dividendYears": "div_years",
       "netCash": "net_cash_cr",
       "cash": "cash_cr",
       "netCashByMarketCap": "net_cash_mcap_pct",
       "debtEbitda": "debt_ebitda",
       "netDebtEbitda": "nd_ebitda",
       "debtFcf": "debt_fcf",
       "sharesInstitutions": "inst_pct",
       "ma20": "ma20",
       "ma150": "ma150",
       "ma20ch": "dist_ma20",
       "ma50ch": "dist_ma50",
       "ma200ch": "dist_ma200",
       "rsiWeekly": "rsi_w",
       "rsiMonthly": "rsi_m",
       "beta1y": "beta_1y",
       "sharpeRatio3y": "sharpe_3y",
       "sortinoRatio3y": "sortino_3y",
       "daysGap": "gap_pct",
       "positionInRange": "range_pos",
       "changeFromOpen": "from_open_pct",
       "sharesQoQ": "shares_qoq",
       "floatPercent": "float_pct",
       "lynchUpside": "lynch_upside",
       "wacc": "wacc",
       "profitableYears": "profitable_years",
       "revenueGrowthYears": "rev_growth_years",
       "dividendGrowthYears": "div_growth_years",
       "epsGrowth": "eps_growth",
       "epsGrowthQ": "eps_growth_q",
       "fcfPerShare": "fcf_ps",
       "ptbvRatio": "p_tbv"}
# raw INR -> Cr / lakh for the money columns (dollarVolume is handled apart)
SA_SCALE = {'enterpriseValue': 10000000.0, 'cash': 10000000.0, 'netCash': 10000000.0, 'revPerEmployee': 100000.0}
# display-only extras -> `sa` jsonb (dates, analyst, company facts)
SA_KEYS = ("allTimeHigh", "allTimeHighDate", "allTimeLow", "allTimeLowDate", "high52Date", "low52Date", "grahamNumber",
           "nextEarningsDate", "lastReportDate", "exDivDate", "paymentDate", "employees",
           "founded", "website", "isin", "float", "buybackYield", "analystRatings",
           "analystCount", "priceTarget", "priceTargetChange")
# price/change are read for the trend state and the blob only — never stored (fundamentals.py owns price)
COLUMNS = ",".join(("n", "sector", "industry", "priceDate", "dollarVolume", "price", "change", *NUM, *SA_KEYS))
TURN_DAYS = 7      # "turning" = the trend flipped within the last week of closes
TREND_CAP = 40     # rows per bucket in the trends blob
SYMBOL_RE = re.compile(r"^[A-Z0-9][A-Z0-9&-]{0,19}$")  # = migration 018 CHECK; one bad row fails a 100-row batch


def fetch(columns=COLUMNS, filters="exchangeCode-is-NSE,subtype-is-stock", count=5000,
          sort="marketCap", session=requests):
    """Rows keyed by NSE symbol ('NSE-RELIANCE' -> 'RELIANCE'), mcap-desc.
    Filters use the site's DSL: exchangeCode-is-NSE, country_short-is-IN,
    marketCap-over-1e11, sector-is-Energy. BSE rows come back as BOM-<scrip>."""
    r = session.get(URL, params={"type": "s", "m": sort, "s": "desc", "c": "s," + columns,
                                 "cn": count, "f": filters, "i": "symbols"},
                    headers=UA, timeout=60)
    r.raise_for_status()
    rows = (r.json().get("data") or {}).get("data") or []
    return {row["s"].split("-", 1)[1]: row for row in rows if "-" in row.get("s", "")}


def _num(v, scale=1):
    return round(v / scale, 2) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def probe_price_date(session=requests):
    """~200 bytes: the site's last close date, e.g. '2026-09-11'."""
    row = next(iter(fetch(columns="priceDate", count=1, session=session).values()), {})
    return row.get("priceDate")


def resolve_symbol(sym, known):
    """The site flattens NSE's '&' and '-' to '_' (M_M, BAJAJ_AUTO, J_KBANK) and
    once to '.' (NAM.INDIA). Try both at every such position against the
    symbols we know; None when nothing matches (13 of 3,207 on 12 Sep)."""
    if SYMBOL_RE.match(sym):
        return sym
    parts = re.split(r"[_.]", sym)
    for fill in product("&-", repeat=len(parts) - 1):
        cand = "".join(p + f for p, f in zip(parts, fill + ("",)))
        if cand in known and SYMBOL_RE.match(cand):
            return cand
    return None


def trend_of(r):
    """Moneycontrol-style technical trend from the site's row: price above a
    rising MA stack = bullish, below a falling one = bearish, anything else
    mixed; None when the MAs are missing (young listings)."""
    p, m50, m200 = (_num(r.get(k)) for k in ("price", "ma50", "ma200"))
    if None in (p, m50, m200):
        return None
    return "bullish" if p > m50 > m200 else "bearish" if p < m50 < m200 else "mixed"


def trend_cols(r, prev):
    """The four trend columns: carried from the last pull while the trend
    holds, reset (prev/since/price) the pull it flips. First sighting has no
    prev, so it never reads as "turning"."""
    t, prev = trend_of(r), prev or {}
    carry = {k: prev.get(k) for k in ("trend_prev", "trend_since", "trend_price")}
    if t is None or t == prev.get("trend"):
        return {"trend": t if t is not None else prev.get("trend"), **carry}
    return {"trend": t, "trend_prev": prev.get("trend"), "trend_since": r.get("priceDate"),
            "trend_price": _num(r.get("price"))}


def sa_rows(raw, existing, now, known=None):
    """Site row -> screener_metrics row, SA-owned columns only, sector and
    industry included (the peer keys). Every row carries the same keys (one
    PGRST102 bucket); symbols not yet in the table also get a name (a second
    bucket) so they aren't blank. `existing` is a set of symbols, or (024) a
    {symbol: {trend, trend_prev, trend_since, trend_price}} dict so the trend
    state survives across pulls."""
    out, known = [], known or set(existing)
    prev_of = existing.get if isinstance(existing, dict) else (lambda s: None)
    for sym, r in raw.items():
        sym = resolve_symbol(sym, known)
        if not sym:
            continue
        row = {"symbol": sym, **{col: _num(r.get(k), SA_SCALE.get(k, 1)) for k, col in NUM.items()},
               "turnover_cr": _num(r.get("dollarVolume"), 1e7),
               "sector": r.get("sector") or None, "industry": r.get("industry") or None,
               "sa": {k: r[k] for k in SA_KEYS if r.get(k) not in (None, "")},
               "sa_price_date": r.get("priceDate"), "sa_at": now.isoformat(),
               **trend_cols(r, prev_of(sym))}
        if sym not in existing:
            row["name"] = r.get("n")
        out.append(row)
    return out


def trends_blob(raw, rows, now):
    """Markets TRENDS blob: bullish / bearish (top TREND_CAP by mcap — `raw`
    arrives mcap-desc) and turning_bullish / turning_bearish (flipped within
    TURN_DAYS, newest flip first). perf = move since the flip."""
    by_sym = {r["symbol"]: r for r in rows}
    asof = next((r.get("priceDate") for r in raw.values()), None)
    cutoff = (date.fromisoformat(asof) - timedelta(days=TURN_DAYS)).isoformat() if asof else ""
    buckets = {"bullish": [], "bearish": [], "turning_bullish": [], "turning_bearish": []}
    for site_sym, r in raw.items():
        row = by_sym.get(resolve_symbol(site_sym, by_sym) or "")
        if not row or row["trend"] not in ("bullish", "bearish"):
            continue
        price, since_px = _num(r.get("price")), row["trend_price"]
        e = {"symbol": row["symbol"], "name": r.get("n"), "price": price, "chg": _num(r.get("change")),
             "trend": row["trend"], "prev": row["trend_prev"], "since": row["trend_since"],
             "since_price": since_px,
             "perf": round((price / since_px - 1) * 100, 2) if price and since_px else None}
        if len(buckets[row["trend"]]) < TREND_CAP:
            buckets[row["trend"]].append(e)
        if row["trend_prev"] and (row["trend_since"] or "") >= cutoff:
            buckets["turning_" + row["trend"]].append(e)
    for k in ("turning_bullish", "turning_bearish"):
        buckets[k] = sorted(buckets[k], key=lambda e: e["since"] or "", reverse=True)[:TREND_CAP]
    return {"key": "trends", "payload": {"asof": asof, **buckets}, "updated_at": now.isoformat()}


def sa_blobs(raw, now, ist_today):
    """Two Markets-tab blobs from the same pull. `raw` arrives mcap-desc, so
    the at-ATH list is already 'by market cap'."""
    lo, hi = ist_today.isoformat(), (ist_today + timedelta(days=14)).isoformat()
    cal = sorted(({"symbol": s, "name": r.get("n"), "date": r["nextEarningsDate"]}
                  for s, r in raw.items() if lo <= (r.get("nextEarningsDate") or "") <= hi),
                 key=lambda e: (e["date"], e["symbol"]))[:300]
    ath = [(s, _num(r.get("allTimeHighChange"))) for s, r in raw.items()]
    n = max(len(raw), 1)
    records = {"ath": [s for s, p in ath if p is not None and p >= -0.5][:30],
               "near_ath_pct": round(sum(p is not None and p >= -5 for _, p in ath) / n * 100, 1),
               "up_1y_pct": round(sum((_num(r.get("ch1y")) or 0) > 0 for r in raw.values()) / n * 100, 1),
               "asof": next((r.get("priceDate") for r in raw.values()), None)}
    ts = now.isoformat()
    return [{"key": "earnings_calendar", "payload": cal, "updated_at": ts},
            {"key": "records", "payload": records, "updated_at": ts}]


def refresh_stockanalysis(sb, now, session=requests):
    """Hourly group. Probe the site's priceDate; equal to our watermark ->
    nothing (a weekend = 24 probes, ~5 KB). Moved -> one full pull, upsert
    3.2k rows (SA columns only), rewrite the two blobs. Becomes hourly-intraday
    by itself the day the site does."""
    from market import IST, upsert, write_blobs  # local: market wraps us
    pd = probe_price_date(session)
    mark = sb("GET", "screener_metrics?select=sa_price_date&order=sa_price_date.desc.nullslast&limit=1")
    if not pd or (mark and mark[0].get("sa_price_date") == pd):
        return 0
    raw = fetch(session=session)
    existing = {r["symbol"]: r for r in
                sb("GET", "screener_metrics?select=symbol,trend,trend_prev,trend_since,trend_price")}
    known = set(existing) | {c["nse_symbol"] for c in sb("GET", "companies?select=nse_symbol") if c.get("nse_symbol")}
    rows = sa_rows(raw, existing, now, known)
    n = upsert(sb, rows, table="screener_metrics", key="symbol")
    write_blobs(sb, sa_blobs(raw, now, now.astimezone(IST).date()) + [trends_blob(raw, rows, now)])
    return n


if __name__ == "__main__":  # self-check: shape, a known symbol, the mapping
    from datetime import datetime, timezone
    raw = fetch(count=50)
    rows = {r["symbol"]: r for r in sa_rows(raw, set(), datetime.now(timezone.utc), {"M&M", "BAJAJ-AUTO"})}
    assert len(rows) == 50 and "RELIANCE" in rows and "M&M" in rows, sorted(rows)[:5]
    ril = rows["RELIANCE"]
    assert ril["ret_1y"] is not None and ril["turnover_cr"] > 0 and ril["sa"].get("allTimeHigh"), ril
    print("ok", len(rows), {k: ril[k] for k in ("ret_1y", "ath_pct", "f_score", "turnover_cr")},
          ril["sa"].get("nextEarningsDate"), "probe:", probe_price_date())
