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


show("SHP master + XBRL", shp)
show("financial results + XBRL", results)
show("credit ratings raw", ratings)
show("annual reports / announcements", reports_announcements)
print("\nprobe done")
