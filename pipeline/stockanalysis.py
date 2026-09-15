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
from datetime import timedelta
from itertools import product

import requests

URL = "https://stockanalysis.com/_api/endpoints/screener/table"
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) FinSwipe/1.0"}

# site id -> screener_metrics column (all real numeric columns: filter/sort-able)
NUM = {"ch1w": "ret_1w", "ch1m": "ret_1m", "ch3m": "ret_3m", "ch6m": "ret_6m", "chYTD": "ret_ytd",
       "ch1y": "ret_1y", "ch3y": "ret_3y", "ch5y": "ret_5y", "allTimeHighChange": "ath_pct",
       "averageVolume": "avg_vol", "relativeVolume": "rel_vol", "sharpeRatio": "sharpe",
       "sortinoRatio": "sortino", "atr": "atr", "grahamUpside": "graham_upside", "fScore": "f_score",
       "psRatio": "ps", "earningsYield": "earnings_yield", "fcfYield": "fcf_yield", "roic": "roic",
       "interestCoverage": "int_cov", "evEbitda": "ev_ebitda", "sectorPe": "sector_pe",
       "industryPe": "industry_pe", "sharesYoY": "shares_yoy"}
# display-only extras -> `sa` jsonb (dates, analyst, company facts)
SA_KEYS = ("allTimeHigh", "allTimeHighDate", "high52Date", "low52Date", "grahamNumber",
           "nextEarningsDate", "lastReportDate", "exDivDate", "paymentDate", "employees",
           "founded", "website", "isin", "float", "buybackYield", "analystRatings",
           "analystCount", "priceTarget", "priceTargetChange")
COLUMNS = ",".join(("n", "sector", "industry", "priceDate", "dollarVolume", *NUM, *SA_KEYS))
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


def sa_rows(raw, existing, now, known=None):
    """Site row -> screener_metrics row, SA-owned columns only, sector and
    industry included (the peer keys). Every row carries the same keys (one
    PGRST102 bucket); symbols not yet in the table also get a name (a second
    bucket) so they aren't blank."""
    out, known = [], known or existing
    for sym, r in raw.items():
        sym = resolve_symbol(sym, known)
        if not sym:
            continue
        row = {"symbol": sym, **{col: _num(r.get(k)) for k, col in NUM.items()},
               "turnover_cr": _num(r.get("dollarVolume"), 1e7),
               "sector": r.get("sector") or None, "industry": r.get("industry") or None,
               "sa": {k: r[k] for k in SA_KEYS if r.get(k) not in (None, "")},
               "sa_price_date": r.get("priceDate"), "sa_at": now.isoformat()}
        if sym not in existing:
            row["name"] = r.get("n")
        out.append(row)
    return out


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
    existing = {r["symbol"] for r in sb("GET", "screener_metrics?select=symbol")}
    known = existing | {c["nse_symbol"] for c in sb("GET", "companies?select=nse_symbol") if c.get("nse_symbol")}
    n = upsert(sb, sa_rows(raw, existing, now, known), table="screener_metrics", key="symbol")
    write_blobs(sb, sa_blobs(raw, now, now.astimezone(IST).date()))
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
