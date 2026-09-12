"""One-shot NSE endpoint probe (run from a GitHub runner via the probe
workflow — NSE Akamai-blocks the dev machine). Prints the shapes step B
needs: shareholding-master row keys + SHP XBRL element names, the
financial-results list + results XBRL element names, the credit-rating
endpoint's raw answer, annual-reports/announcements samples. No writes.
"""
import json

from fundamentals import parse_ix_facts
from market import NSE_API, nse_session

SYM = "RELIANCE"

s = nse_session()


def get(path, **params):
    r = s.get(NSE_API + path, params=params, timeout=25)
    print(f"[{r.status_code}] {r.url[:160]}")
    if "json" in r.headers.get("content-type", ""):
        return r.json()
    raise RuntimeError(f"non-JSON ({r.text[:120]!r})")


def rows_of(j):
    return (j.get("data") if isinstance(j, dict) else j) or []


def show(label, fn):
    print(f"\n===== {label} =====")
    try:
        fn()
    except Exception as e:
        print(f"FAILED: {e}")


def xbrl_elements(row):
    url = next((v for k, v in row.items() if "xbrl" in k.lower() and v), None)
    print("xbrl url:", url)
    if not url:
        return
    xml = s.get(url, timeout=25).text
    facts = parse_ix_facts(xml)
    print(f"{len(facts)} ix facts (inline)")
    # plain-XBRL instance: dump element localnames with contextRef + first value
    import re
    seen = {}
    for m in re.finditer(r"<(?:[\w.-]+:)?(\w+)[^>]*contextRef=\"([^\"]+)\"[^>]*>([^<]*)<", xml):
        name, ctx, val = m.group(1), m.group(2), m.group(3).strip()
        if name not in seen and val:
            seen[name] = (ctx, val)
    print(f"{len(seen)} plain-XBRL elements; name = (context, value):")
    for name, (ctx, val) in list(seen.items())[:150]:
        print(f"  {name} = ({ctx[:40]}, {val[:50]})")
    print("raw head:", xml[:1200].replace(chr(10), " ")[:1200])


def shp():
    rows = rows_of(get("corporate-share-holdings-master", index="equities", symbol=SYM))
    print("rows:", len(rows), "| first row keys:", sorted(rows[0]) if rows else None)
    if not rows:
        return
    url = rows[0].get("xbrl")
    print("xbrl url:", url)
    xml = s.get(url, timeout=25).text
    # every (context, value) for the two elements the split needs — the SHP
    # taxonomy repeats one element per category context
    import re
    for el in ("ShareholdingAsAPercentageOfTotalNumberOfShares", "NumberOfShareholders"):
        print(f"\nall contexts of {el}:")
        for m in re.finditer(
                rf"<[\w.-]+:{el}[^>]*contextRef=\"([^\"]+)\"[^>]*>([^<]*)<", xml):
            print(f"  {m.group(1)} = {m.group(2).strip()}")


def results():
    rows = rows_of(get("corporates-financial-results", index="equities",
                       symbol=SYM, period="Quarterly"))
    print("rows:", len(rows))
    con = next((r for r in rows if "Consolidated" == r.get("consolidated")), rows[0] if rows else None)
    if not con:
        return
    print("consolidated row:", json.dumps(con)[:700])
    xbrl_elements(con)
    link = con.get("resultDetailedDataLink")
    if link:
        r = s.get(link, timeout=25)
        print(f"\nresultDetailedDataLink [{r.status_code}] {r.headers.get('content-type')}")
        print(r.text[:1500])


def ratings():
    for path in ("corporate-credit-rating", "corporates-credit-rating"):
        r = s.get(NSE_API + path, params={"index": "equities", "symbol": SYM}, timeout=25)
        print(f"[{r.status_code}] {path}: {r.text[:500]!r}")


def reports_announcements():
    rep = rows_of(get("annual-reports", index="equities", symbol=SYM))
    print("annual-reports first:", json.dumps(rep[0])[:300] if rep else None)
    ann = rows_of(get("corporate-announcements", index="equities", symbol=SYM))
    print("announcements rows:", len(ann))
    print("announcements first keys:", sorted(ann[0]) if ann else None)


def market_shapes():
    """12 Sep 2026: F&O + announcements shapes for the Markets-tab tables —
    the live fno blob had ltp/pct null on every OI row and hi52/lo52 = 0."""
    def head(label, j, n=2, keys=None):
        rows = market_rows(j)
        print(f"\n-- {label}: {len(rows)} rows; top-level keys: {sorted(j) if isinstance(j, dict) else type(j).__name__}")
        for r in rows[:n]:
            print("  ", json.dumps({k: r.get(k) for k in keys} if keys else r)[:900])
        if rows:
            print("   row keys:", sorted(rows[0]))
        return rows

    head("oi-spurts", get("live-analysis-oi-spurts-underlyings"))
    for idx in ("high", "low"):
        j = get("live-analysis-52Week", index=idx)
        print(f"\n-- 52Week {idx}: type={type(j).__name__} keys={sorted(j) if isinstance(j, dict) else None}")
        print("  ", json.dumps(j)[:700])
    head("variations gainers", get("live-analysis-variations", index="gainers"))
    head("F&O securities", get("equity-stockIndices", index="SECURITIES IN F&O"))
    ann = get("corporate-announcements", index="equities")
    rows = head("announcements (all)", ann, n=3,
                keys=["symbol", "desc", "an_dt", "sm_name", "attchmntFile", "sort_date", "bd_dt"])
    dts = sorted(str(r.get("an_dt") or "") for r in rows)
    print("   an_dt span:", dts[:1], dts[-1:])


def market_rows(j):
    from market import _rows
    return [r for r in _rows(j) if isinstance(r, dict)]


show("market shapes (F&O, 52wk, announcements)", market_shapes)
show("SHP master + XBRL", shp)
show("financial results + XBRL", results)
show("credit ratings raw", ratings)
show("annual reports / announcements", reports_announcements)
print("\nprobe done")
