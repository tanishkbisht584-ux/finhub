"""stockanalysis.com screener table: one keyless GET returns any of ~320 data
points for every NSE stock (3.2k rows, ~1.5 s). Undocumented frontend endpoint
found 12 Sep 2026; answers browser-ish UAs from the dev IP AND GitHub runners
(probe run 34678287615). Column ids: column-meta?type=quote (or COLUMNS below).
ToS: "not allowed to republish content in full" - use as a gap-filler, cite it.
"""
import requests

URL = "https://stockanalysis.com/_api/endpoints/screener/table"
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) FinSwipe/1.0"}
# the ids the screener page + Markets panel would want; full list in column-meta
COLUMNS = ("n,marketCap,price,change,volume,sector,industry,peRatio,peForward,pbRatio,"
           "psRatio,evEbitda,pegRatio,dividendYield,dps,roe,roce,roa,roic,debtEquity,"
           "currentRatio,interestCoverage,grossMargin,operatingMargin,profitMargin,"
           "revenue,revenueGrowth,revenueGrowthQ,netIncome,netIncomeGrowth,eps,epsGrowth,"
           "fcf,fcfYield,cash,debt,netCash,equity,bvPerShare,sharesOut,float,"
           "sharesInsiders,sharesInstitutions,ch1w,ch1m,ch3m,ch6m,chYTD,ch1y,ch3y,ch5y,"
           "high52,low52,high52ch,low52ch,allTimeHigh,rsi,rsiWeekly,ma20,ma50,ma200,"
           "ma50vs200,beta,atr,averageVolume,relativeVolume,analystRatings,analystCount,"
           "priceTarget,priceTargetChange,nextEarningsDate,lastReportDate,fScore,zScore,"
           "grahamNumber,lynchFairValue,isin,priceDate")


def fetch(columns=COLUMNS, filters="exchangeCode-is-NSE,subtype-is-stock", count=5000,
          sort="marketCap", session=requests):
    """Rows keyed by NSE symbol ('NSE-RELIANCE' -> 'RELIANCE'). Filters use the
    site's DSL: exchangeCode-is-NSE, country_short-is-IN, marketCap-over-1e11,
    sector-is-Energy. BSE rows come back as BOM-<scrip code>."""
    r = session.get(URL, params={"type": "s", "m": sort, "s": "desc", "c": "s," + columns,
                                 "cn": count, "f": filters, "i": "symbols"},
                    headers=UA, timeout=60)
    r.raise_for_status()
    rows = (r.json().get("data") or {}).get("data") or []
    return {row["s"].split("-", 1)[1]: row for row in rows if "-" in row.get("s", "")}


if __name__ == "__main__":  # self-check: shape + a known symbol
    rows = fetch(columns="n,marketCap,price,peRatio,rsi,ma200", count=50)
    assert len(rows) == 50 and "RELIANCE" in rows, sorted(rows)[:5]
    ril = rows["RELIANCE"]
    assert ril["marketCap"] > 1e12 and ril["price"] > 0 and ril["rsi"], ril
    print("ok", len(rows), {k: ril[k] for k in ("price", "peRatio", "rsi", "ma200")})
