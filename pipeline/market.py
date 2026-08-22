"""Market data layer (2026-08-22): indices, equities, FX, commodities, crypto
(and, from phase 3, MF NAVs, macro series and NSE smart-money lists) into the
`quotes` / `market_blobs` tables, so every phone reads one cached row instead
of hitting Yahoo itself.

Free and keyless: Yahoo's spark endpoint (20 symbols a call, verified from a
GitHub runner 2026-08-22), CoinGecko, mfapi.in, NSE's JSON. Called once per
pipeline loop from run.main(); each group gates its own cadence in memory —
the process is resident ~5.5 h, a restart just refetches once. No import of
run.py (it imports us): the PostgREST helper `sb` is passed in.

ponytail: Yahoo spark is the single equity source. Trigger to add Twelve Data
(800/day, keyed): runner 403/429 on >5% of spark calls for a day.
"""
import time
from collections import namedtuple
from datetime import datetime, timedelta, timezone

import requests

IST = timezone(timedelta(hours=5, minutes=30))
TIMEOUT = 20
# A browser UA, not run.py's "FinSwipe pipeline" one: Yahoo answers the former.
BROWSER_UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                            "(KHTML, like Gecko) Chrome/126.0 Safari/537.36",
              "Accept": "*/*", "Accept-Language": "en-US,en;q=0.9"}

SPARK_URL = "https://query1.finance.yahoo.com/v8/finance/spark"
SPARK_BATCH = 20            # Yahoo's hard cap per call
EQUITY_CAP = 200            # ~10 spark calls per refresh; raise after a week of clean logs
TROY_OZ_G = 31.1035

INDICES = {"^NSEI": "NIFTY 50", "^BSESN": "SENSEX", "^NSEBANK": "NIFTY Bank", "^CNXIT": "NIFTY IT"}
FX = {"USDINR=X": "USD/INR", "EURINR=X": "EUR/INR", "GBPINR=X": "GBP/INR", "JPYINR=X": "JPY/INR"}
COMMODITIES = {"GC=F": "Gold (USD/oz)", "SI=F": "Silver (USD/oz)", "CL=F": "Crude WTI (USD/bbl)"}
CRYPTO = {"bitcoin": "Bitcoin", "ethereum": "Ethereum", "solana": "Solana"}

KINDS = {"equity", "index", "fx", "crypto", "commodity", "mf", "macro"}  # mirrors 011 CHECK

Parsed = namedtuple("Parsed", "price prev change_pct as_of closes")


# ---------- cadence ----------

_last_run = {}  # group -> utc datetime of the last attempt (success or not)

MARKET_OPEN, MARKET_LAST_PASS = (9, 15), (15, 45)  # NSE 09:15-15:30 + one post-close pass
INTERVAL = {"fxcom": 15, "crypto": 15, "nse": 60, "macro": 24 * 60}


def market_hours(now):
    t = now.astimezone(IST)
    return t.weekday() < 5 and MARKET_OPEN <= (t.hour, t.minute) <= MARKET_LAST_PASS


def interval_minutes(group, now):
    if group in ("equity", "index"):
        return 15 if market_hours(now) else 60
    return INTERVAL[group]


def nav_slot(now):
    """mfapi posts the day's NAV ~22:00-23:00 IST; before 22:30 the slot is
    still yesterday's NAV day, so one fetch per slot is one fetch per NAV."""
    t = now.astimezone(IST)
    return t.date() if (t.hour, t.minute) >= (22, 30) else t.date() - timedelta(days=1)


def due(group, now):
    last = _last_run.get(group)
    if last is None:
        return True
    if group == "mf":
        return nav_slot(now) != nav_slot(last)
    return now - last >= timedelta(minutes=interval_minutes(group, now))


# ---------- Yahoo spark ----------

def fetch_spark(symbols, rng="5d"):
    """{SYMBOL: {timestamp[], close[], chartPreviousClose}} for up to any number
    of symbols, 20 per call. A failed batch is logged and skipped."""
    out = {}
    for i in range(0, len(symbols), SPARK_BATCH):
        batch = symbols[i:i + SPARK_BATCH]
        try:
            r = requests.get(SPARK_URL, params={"symbols": ",".join(batch), "range": rng,
                                                "interval": "1d"},
                             headers=BROWSER_UA, timeout=TIMEOUT)
            r.raise_for_status()
            out.update(r.json())
        except Exception as e:
            print(f"MARKET spark batch failed ({batch[0]}..{batch[-1]}): {e}")
        if i + SPARK_BATCH < len(symbols):
            time.sleep(0.5)
    return out


def parse_spark(entry):
    closes = [c for c in (entry.get("close") or []) if c is not None]
    if not closes:
        return None
    price = closes[-1]
    prev = closes[-2] if len(closes) > 1 else entry.get("chartPreviousClose")
    pct = round((price - prev) / prev * 100, 2) if prev else None
    ts = entry.get("timestamp") or []
    as_of = datetime.fromtimestamp(ts[-1], tz=timezone.utc).isoformat() if ts else None
    return Parsed(price, prev, pct, as_of, closes)


# ---------- rows ----------

def row(symbol, kind, name, parsed, now, currency="INR", closes=False, meta=None):
    return {"symbol": symbol, "kind": kind, "name": name, "price": parsed.price,
            "prev_close": parsed.prev, "change_pct": parsed.change_pct, "currency": currency,
            "closes": parsed.closes if closes else None, "as_of": parsed.as_of,
            "updated_at": now.isoformat(), "meta": meta}


def gold_inr_row(gc, usdinr, now):
    """International spot converted to ₹/10g. MCX/retail runs ~10% higher
    (import duty + GST) — say so on the row rather than ship a wrong number."""
    price = round(gc.price * usdinr.price / TROY_OZ_G * 10)
    p = Parsed(price, None, gc.change_pct, gc.as_of, None)
    return row("GOLD_INR_10G", "commodity", "Gold (₹/10g)", p, now,
               meta={"derived": True, "label": "intl spot × USD/INR, ex-duty"})


def upsert(sb, rows, table="quotes", key="symbol"):
    for i in range(0, len(rows), 100):
        sb("POST", f"{table}?on_conflict={key}", json=rows[i:i + 100],
           headers={"Prefer": "resolution=merge-duplicates,return=minimal"})
    return len(rows)


# ---------- groups ----------

def refresh_indices(sb, now):
    data = fetch_spark(list(INDICES), rng="1mo")  # ~22 closes for the sparkline
    rows = [row(s, "index", n, p, now, closes=True)
            for s, n in INDICES.items() if (p := parse_spark(data.get(s, {})))]
    return upsert(sb, rows)


def equity_universe(sb, now):
    """[(nse_symbol, name)] — followed companies first, then those tagged on a
    story in the last 48 h, capped. Only these get a quote row."""
    since = (now - timedelta(hours=48)).strftime("%Y-%m-%dT%H:%M:%SZ")
    followed = [int(f["target_id"]) for f in sb("GET", "follows?select=target_id&target_type=eq.company")
                if str(f["target_id"]).isdigit()]
    tagged = [r["company_id"] for r in
              sb("GET", "story_companies?select=company_id,stories!inner(id)"
                        f"&stories.published_at=gte.{since}")]
    ids, seen = [], set()
    for cid in followed + tagged:
        if cid not in seen:
            seen.add(cid)
            ids.append(cid)
    ids = ids[:EQUITY_CAP]
    by_id = {}
    for i in range(0, len(ids), 200):
        chunk = ",".join(str(c) for c in ids[i:i + 200])
        for c in sb("GET", f"companies?select=id,nse_symbol,name&id=in.({chunk})"):
            if c.get("nse_symbol"):
                by_id[c["id"]] = (c["nse_symbol"], c["name"])
    return [by_id[c] for c in ids if c in by_id]


def refresh_equities(sb, now):
    universe = equity_universe(sb, now)
    data = fetch_spark([f"{s}.NS" for s, _ in universe])
    rows = [row(s, "equity", n, p, now)
            for s, n in universe if (p := parse_spark(data.get(f"{s}.NS", {})))]
    n = upsert(sb, rows)
    # Rows nobody refreshes any more (untagged, unfollowed) age out after a week.
    if now.astimezone(IST).hour == 3 and now.minute < 15:
        sb("DELETE", f"quotes?kind=eq.equity&updated_at=lt.{(now - timedelta(days=7)).isoformat()}")
    return n


def refresh_fxcom(sb, now):
    data = fetch_spark(list(FX) + list(COMMODITIES), rng="1mo")
    parsed = {s: parse_spark(data.get(s, {})) for s in list(FX) + list(COMMODITIES)}
    rows = [row(s, "fx", n, parsed[s], now, closes=True) for s, n in FX.items() if parsed[s]]
    rows += [row(s, "commodity", n, parsed[s], now, currency="USD", closes=True)
             for s, n in COMMODITIES.items() if parsed[s]]
    if parsed.get("GC=F") and parsed.get("USDINR=X"):
        rows.append(gold_inr_row(parsed["GC=F"], parsed["USDINR=X"], now))
    return upsert(sb, rows)


def refresh_crypto(sb, now):
    r = requests.get("https://api.coingecko.com/api/v3/simple/price",
                     params={"ids": ",".join(CRYPTO), "vs_currencies": "inr,usd",
                             "include_24hr_change": "true"},
                     headers=BROWSER_UA, timeout=TIMEOUT)
    r.raise_for_status()
    rows = []
    for cid, name in CRYPTO.items():
        d = r.json().get(cid) or {}
        if "inr" not in d:
            continue
        pct = d.get("inr_24h_change")
        prev = round(d["inr"] / (1 + pct / 100), 2) if pct is not None else None
        p = Parsed(d["inr"], prev, round(pct, 2) if pct is not None else None, now.isoformat(), None)
        rows.append(row(cid, "crypto", name, p, now, meta={"usd": d.get("usd")}))
    return upsert(sb, rows)


GROUPS = (("index", refresh_indices), ("equity", refresh_equities),
          ("fxcom", refresh_fxcom), ("crypto", refresh_crypto))


def refresh(sb, now=None):
    """Run every due group; one failing group never blocks another, and a
    failure waits out its interval like a success (no 45-second hammering)."""
    now = now or datetime.now(timezone.utc)
    counts = {}
    for group, fn in GROUPS:
        if not due(group, now):
            continue
        _last_run[group] = now
        try:
            counts[group] = fn(sb, now)
        except Exception as e:
            print(f"MARKET FAIL {group}: {e}")
    return counts
