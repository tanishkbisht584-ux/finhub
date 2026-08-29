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
    if url:
        facts = parse_ix_facts(s.get(url, timeout=25).text)
        print(f"{len(facts)} ix facts; element names:")
        for name, val in list(facts.items())[:120]:
            print(f"  {name} = {str(val)[:60]}")


def shp():
    rows = rows_of(get("corporate-share-holdings-master", index="equities", symbol=SYM))
    print("rows:", len(rows), "| first row keys:", sorted(rows[0]) if rows else None)
    if rows:
        print("first row:", json.dumps(rows[0])[:600])
        xbrl_elements(rows[0])


def results():
    for path in ("corporates-financial-results", "corporate-financial-results"):
        try:
            rows = rows_of(get(path, index="equities", symbol=SYM, period="Quarterly"))
        except Exception as e:
            print(f"{path}: {e}")
            continue
        print("rows:", len(rows), "| first row keys:", sorted(rows[0]) if rows else None)
        if rows:
            print("first row:", json.dumps(rows[0])[:600])
            xbrl_elements(rows[0])
        return


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
