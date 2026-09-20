"""Stock-page data-completeness audit (20 Sep 2026 review, Tanis: "data is
missing from multiple stocks — check it yourself"). Builds every section's
inputs the way the app does, for a stratified sample of symbols, and prints
the % of the sample where each field is missing. Read-only.

    py -3 audit_page.py            # 60-symbol sample across bands
    py -3 audit_page.py TCS,INFY   # just these
"""
import os
import random
import sys
from collections import Counter

import requests

for line in open(os.path.join(os.path.dirname(__file__), ".env"), encoding="utf-8"):
    if "=" in line and not line.startswith("#"):
        k, v = line.strip().split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())
from run import sb  # noqa: E402

UA = {"User-Agent": "Mozilla/5.0"}


def sample(n=60):
    rows = sb("GET", "screener_metrics?select=symbol,mcap_cr,industry,sector,sa&price=not.is.null&order=mcap_cr.desc.nullslast")
    random.seed(20)
    big, mid, small = rows[:150], rows[150:600], rows[600:]
    banks = [r for r in rows if (r.get("industry") or "").lower().startswith("bank")]
    nbfc = [r for r in rows if "credit" in (r.get("industry") or "").lower() or "financ" in (r.get("industry") or "").lower()]
    young = [r for r in rows if str((r.get("sa") or {}).get("founded") or "") >= "2015"]
    pick = []
    for pool, k in ((big, 14), (mid, 14), (small, 14), (banks, 6), (nbfc, 6), (young, 6)):
        pick += random.sample(pool, min(k, len(pool)))
    seen, out = set(), []
    for r in pick:
        if r["symbol"] not in seen:
            seen.add(r["symbol"])
            out.append(r["symbol"])
    return out[:n]


def audit(sym):
    miss = []
    q = sb("GET", f"quotes?select=meta&symbol=eq.{sym}")
    f = ((q[0].get("meta") if q else None) or {}).get("f") or {}
    t = ((q[0].get("meta") if q else None) or {}).get("t") or {}
    for k in ("pe", "pb", "mcap", "eps", "roe", "de", "div_yield", "beta", "sector", "industry"):
        if f.get(k) is None:
            miss.append(f"overview.{k}")
    for k in ("street", "profile"):
        if not f.get(k):
            miss.append(f"forecast/info.{k}")
    for k in ("sma50", "sma200", "rsi14", "trend"):
        if t.get(k) is None:
            miss.append(f"technicals.{k}")
    sm = sb("GET", f"screener_metrics?select=*&symbol=eq.{sym}")
    sm = sm[0] if sm else {}
    for k in ("ret_1w", "ret_1y", "f_score", "sector_pe", "altman_z", "tape", "avg_vol"):
        if sm.get(k) is None:
            miss.append(f"screener.{k}")
    sa = sm.get("sa") or {}
    for k in ("analystRatings", "priceTarget", "allTimeHigh", "isin"):
        if sa.get(k) in (None, ""):
            miss.append(f"sa.{k}")
    kinds = Counter(r["kind"] for r in sb("GET", f"fundamentals?select=kind&symbol=eq.{sym}"))
    for k in ("annual", "quarter", "shareholding", "summary", "docs"):
        if not kinds.get(k):
            miss.append(f"fund.{k}")
    ann = sb("GET", f"fundamentals?select=data&symbol=eq.{sym}&kind=eq.annual&order=period.desc&limit=1")
    a = ann[0]["data"] if ann else {}
    for k in ("sales", "net_profit", "total_assets", "equity_cap", "reserves", "roce", "cfo"):
        if a.get(k) is None:
            miss.append(f"annual.{k}")
    sh = sb("GET", f"fundamentals?select=data&symbol=eq.{sym}&kind=eq.shareholding&order=period.desc&limit=1")
    s = sh[0]["data"] if sh else {}
    for k in ("promoters", "fiis", "diis", "public"):
        if s.get(k) is None:
            miss.append(f"shareholding.{k}")
    try:
        r = requests.get(f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}.NS",
                         params={"range": "max", "interval": "1mo", "events": "div,splits"}, headers=UA, timeout=20).json()
        res = r["chart"]["result"][0]
        closes = [c for c in res["indicators"]["quote"][0]["close"] if c is not None]
        if len(closes) < 13:
            miss.append("seasonality.<13 months")
        if not (res.get("events") or {}).get("dividends"):
            miss.append("actions.dividends")
        if not res["meta"].get("fiftyTwoWeekHigh"):
            miss.append("overview.52w")
    except Exception:
        miss.append("yahoo.chart")
    return miss


if __name__ == "__main__":
    syms = sys.argv[1].split(",") if len(sys.argv) > 1 else sample()
    tally, per = Counter(), {}
    for s in syms:
        per[s] = audit(s)
        tally.update(per[s])
    print(f"audited {len(syms)} symbols\n")
    print("field                          missing   of sample")
    for k, n in sorted(tally.items(), key=lambda kv: -kv[1]):
        print(f"{k:30} {n:7}   {n / len(syms) * 100:5.0f}%")
    worst = sorted(per.items(), key=lambda kv: -len(kv[1]))[:8]
    print("\nworst symbols:", [(s, len(m)) for s, m in worst])
    for s, m in worst[:3]:
        print(" ", s, m)
