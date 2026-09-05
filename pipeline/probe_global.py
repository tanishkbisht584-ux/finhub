"""One-shot upstream probe (run from a GitHub runner via the probe workflow —
several hosts treat datacenter and Indian residential IPs differently, so new
groups are built against real runner responses, or buried with evidence).
No writes. Current round (Sep 2026): zero-cost sweep #3 — IBJA gold, JODI oil,
IMF IRFCL, FAO FPI, SCFI/CCFI, BDI, SEBI/RBI RSS liveness. All answered the
dev IP on 5 Sep; this run confirms the runner's IP.
"""
import re

import requests

UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) FinSwipe-probe/1.0"}


def show(tag, url, params=None):
    try:
        r = requests.get(url, params=params, headers=UA, timeout=25)
        body = r.text[:600].replace("\n", " ")
        print(f"\n[{tag}] {r.status_code} {r.headers.get('content-type', '?')[:40]}")
        print(f"  {body}")
        return r
    except Exception as e:  # noqa: BLE001
        print(f"\n[{tag}] EXC {e}")
        return None


r = show("ibja", "https://ibjarates.com/")
if r is not None and r.ok:
    m = re.search(r'"purity999":\[([\d,.]+)\]', r.text)
    d = re.search(r'"dates":\[([^\]]+)\]', r.text)
    print("  purity999 tail:", m.group(1)[-80:] if m else "MISSING")
    print("  dates tail:", d.group(1)[-80:] if d else "MISSING")

r = show("jodi oil", "https://www.jodidata.org/_resources/files/downloads/"
         "oil-data/annual-csv/primary/primaryyear2026.csv")
if r is not None and r.ok:
    rows = [ln for ln in r.text.splitlines() if ln.startswith("IN,")]
    print(f"  IN rows: {len(rows)}")
    for ln in rows[-3:]:
        print("  last:", ln)
    print("  products:", sorted({ln.split(",")[2] for ln in rows}))
    print("  flows:", sorted({ln.split(",")[3] for ln in rows}))

show("imf irfcl gold", "https://api.imf.org/external/sdmx/2.1/data/"
     "IMF.STA,IRFCL/IND.IRFCLDT1_IRFCL56V_FTO..M", {"lastNObservations": 3})

r = show("fao fpi", "https://www.fao.org/media/docs/worldfoodsituationlibraries/"
         "default-document-library/food_price_indices_data.csv")
if r is not None and r.ok:
    print("  tail:", r.text.strip().splitlines()[-1])

show("scfi", "https://en.sse.net.cn/currentIndex", {"indexName": "scfi"})
show("ccfi", "https://en.sse.net.cn/currentIndex", {"indexName": "ccfi"})

r = show("bdi handybulk", "https://www.handybulk.com/baltic-dry-index/")
if r is not None and r.ok:  # need a LEVEL + date, not just the daily change
    for x in re.findall(r"[^>]{0,60}BDI[^<]{0,80}", r.text)[:6]:
        print("  ", x)

# item 3 repair-side: are the regulator feeds alive at these URLs?
show("sebi rss", "https://www.sebi.gov.in/sebirss.xml")
show("rbi press rss", "https://www.rbi.org.in/pressreleases_rss.xml")
print("\nprobe done")
