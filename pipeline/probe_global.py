"""One-shot GDELT + Polymarket probe (run from a GitHub runner via the probe
workflow — both refuse/429 the dev machine's Indian IP, same story as NSE).
Prints status + shape samples so the global-layer groups are built against
real responses, or buried with evidence. No writes.
"""
import json
import time

import requests

UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) FinSwipe-probe/1.0"}


def show(tag, url, params=None):
    try:
        r = requests.get(url, params=params, headers=UA, timeout=20)
        body = r.text[:600].replace("\n", " ")
        print(f"\n[{tag}] {r.status_code} {r.headers.get('content-type', '?')[:40]}")
        print(f"  {body}")
        return r
    except Exception as e:  # noqa: BLE001
        print(f"\n[{tag}] EXC {e}")
        return None


# GDELT DOC 2.0 — numbers only (timeline volume + tone), never articles
show("gdelt timelinevol", "https://api.gdeltproject.org/api/v2/doc/doc",
     {"query": '"Reserve Bank of India"', "mode": "timelinevol",
      "timespan": "7d", "format": "json"})
time.sleep(6)  # their own stated rate limit: one call per 5 s
show("gdelt timelinetone", "https://api.gdeltproject.org/api/v2/doc/doc",
     {"query": "india economy", "mode": "timelinetone",
      "timespan": "7d", "format": "json"})

# Polymarket Gamma — market list + a search, for the curated-slug design
r = show("polymarket markets", "https://gamma-api.polymarket.com/markets",
         {"limit": 3, "active": "true", "closed": "false",
          "order": "volume24hr", "ascending": "false"})
if r is not None and r.ok:
    for m in r.json()[:3]:
        print("  slug:", m.get("slug"), "| q:", (m.get("question") or "")[:60],
              "| outcomes:", m.get("outcomes"), "| prices:", m.get("outcomePrices"))
show("polymarket search", "https://gamma-api.polymarket.com/public-search",
     {"q": "india", "limit_per_type": 5})
show("polymarket fed search", "https://gamma-api.polymarket.com/public-search",
     {"q": "fed rate", "limit_per_type": 5})
print("\nprobe done")
