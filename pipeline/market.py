"""Market data layer (2026-08-22): indices, equities, FX, commodities, crypto,
MF NAVs, macro series and NSE smart-money lists into the `quotes` /
`market_blobs` tables, so every phone reads one cached row instead of
hitting Yahoo itself.

Free and keyless where it can be: Yahoo's spark endpoint (20 symbols a call,
verified from a GitHub runner 2026-08-22), CoinGecko, mfapi.in, NSE's JSON;
FRED needs a free key. Called once per pipeline loop from run.main(); each
group gates its own cadence in memory — the process is resident ~5.5 h, a
restart just refetches once. No import of run.py (it imports us): the
PostgREST helper `sb` is passed in.

ponytail: Yahoo spark is the single equity source. Trigger to add Twelve Data
(800/day, keyed): runner 403/429 on >5% of spark calls for a day.
"""
import csv
import hashlib
import io
import json
import os
import re
import statistics
import time
from collections import namedtuple
from datetime import date as _date, datetime, timedelta, timezone
from urllib.parse import quote

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

INDICES = {"^NSEI": "NIFTY 50", "^BSESN": "SENSEX", "^NSEBANK": "NIFTY Bank", "^CNXIT": "NIFTY IT",
           "^INDIAVIX": "India VIX"}  # verified on spark 2026-09-02; feeds fear/greed
FX = {"USDINR=X": "USD/INR", "EURINR=X": "EUR/INR", "GBPINR=X": "GBP/INR", "JPYINR=X": "JPY/INR"}
COMMODITIES = {"GC=F": "Gold (USD/oz)", "SI=F": "Silver (USD/oz)", "CL=F": "Crude WTI (USD/bbl)",
               "BZ=F": "Crude Brent (USD/bbl)", "HG=F": "Copper (USD/lb)"}
# Global layer (4 Sep, worldmonitor follow-up): world indices + India ADRs.
# kind stays "index" with meta.global=true — a new quotes.kind means a
# migration (011 CHECK), and kind="equity" would drag ADRs into signals
# movers and the 7-day equity age-out. ADR symbols are prefixed: bare "INFY"
# IS the NSE row (quotes PK), Yahoo's NYSE ADR would silently overwrite it.
GLOBAL_INDICES = {"^GSPC": "S&P 500", "^IXIC": "Nasdaq", "^DJI": "Dow Jones",
                  "^FTSE": "FTSE 100", "^GDAXI": "DAX", "^N225": "Nikkei 225",
                  "^HSI": "Hang Seng", "000001.SS": "Shanghai Composite",
                  "^VIX": "US VIX", "DX-Y.NYB": "Dollar Index"}
ADRS = {"INFY": "Infosys ADR (NYSE)", "HDB": "HDFC Bank ADR (NYSE)",
        "IBN": "ICICI Bank ADR (NYSE)", "WIT": "Wipro ADR (NYSE)"}
# Stablecoins ride the same call (P3, 4 Sep): USDT/INR vs USDINR is the
# on-ramp premium Indian crypto users actually watch; peg drift + mcap in meta.
CRYPTO = {"bitcoin": "Bitcoin", "ethereum": "Ethereum", "solana": "Solana",
          "tether": "Tether (USDT)", "usd-coin": "USD Coin (USDC)"}
STABLE = ("tether", "usd-coin")

# Direct-Growth scheme codes verified against mfapi.in/mf/search on 2026-08-22.
# Names come from the API (shortened); these are the board everyone sees,
# followed schemes are added on top.
DEFAULT_MF = (120716, 119063, 143341, 122639, 118955, 118825, 120586, 125497,
              118778, 120828, 118968, 119788, 120503, 135781, 119835)

# FRED series (free key). India coverage on FRED is thin; 3-4 series is the
# honest set. Any id that 400s is skipped, not faked.
MACRO_SERIES = {"FEDFUNDS": ("US Fed funds rate", "%"),
                "DGS10": ("US 10Y Treasury yield", "%"),
                "DGS2": ("US 2Y Treasury yield", "%"),  # 2s10s inversion read with DGS10
                "DEXINUS": ("USD/INR (Fed H.10)", "INR"),
                # P3 (4 Sep): every India series FRED keeps within ~3 months.
                # Monthly OECD rates; the daily curve comes from the RBI
                # homepage (refresh_bonds).
                "IRSTCI01INM156N": ("India call money rate", "%"),
                "INDIR3TIB01STM": ("India 3M T-bill yield", "%"),
                "INDIRLTLT01STM": ("India 10Y G-Sec yield (monthly)", "%"),
                "TRESEGINM052N": ("India forex reserves ex-gold", "USD mn"),
                "CCRETT01INM661N": ("India real effective exchange rate (2015=100)", "index"),
                "INDEPUINDXM": ("India policy uncertainty index", "index"),
                # Trade (G4): FRED serves raw USD (~4e10) — third tuple slot
                # scales to bn so the app's macro row reads like a headline.
                "XTEXVA01INM667S": ("India exports, goods", "USD bn", 1e-9),
                "XTIMVA01INM667S": ("India imports, goods", "USD bn", 1e-9)}

KINDS = {"equity", "index", "fx", "crypto", "commodity", "mf", "macro"}  # mirrors 011 CHECK

Parsed = namedtuple("Parsed", "price prev change_pct as_of closes")


# ---------- cadence ----------

_last_run = {}  # group -> utc datetime of the last attempt (success or not)
_status = {}    # group -> last attempt outcome; mirrored to app_config `market_status`

MARKET_OPEN, MARKET_LAST_PASS = (9, 15), (15, 45)  # NSE 09:15-15:30 + one post-close pass
INTERVAL = {"fxcom": 15, "crypto": 15, "global": 15, "polymarket": 60, "nse": 60, "bonds": 60, "macro": 24 * 60,
            "mf_new": 5, "analysis_new": 5, "deep_new": 5, "screener_px": 60,
            "sentiment": 60, "hazards": 60}


def market_hours(now):
    t = now.astimezone(IST)
    return t.weekday() < 5 and MARKET_OPEN <= (t.hour, t.minute) <= MARKET_LAST_PASS


def interval_minutes(group, now):
    if group in ("equity", "index"):
        return 15 if market_hours(now) else 60
    return INTERVAL[group]


def day_slot(now, hh, mm):
    """One run per IST day, opening at hh:mm — before that the slot is still
    yesterday's, so one fetch per slot is one fetch per publication."""
    t = now.astimezone(IST)
    return t.date() if (t.hour, t.minute) >= (hh, mm) else t.date() - timedelta(days=1)


def nav_slot(now):
    return day_slot(now, 22, 30)  # mfapi posts the day's NAV ~22:00-23:00 IST


DAILY_SLOT = {"mf": (22, 30), "fundamentals": (16, 30), "technicals": (16, 15),
              "deep_warm": (17, 30), "screener": (18, 0), "worldmacro": (6, 0),
              "wikidata": (3, 0), "cpi": (18, 0), "cb_rates": (7, 0), "calendar": (6, 30),
              "participant_oi": (19, 0), "shipping": (7, 30),
              "monsoon": (9, 0)}


def due(group, now):
    last = _last_run.get(group)
    if last is None:
        return True
    if group in DAILY_SLOT:
        hh, mm = DAILY_SLOT[group]
        return day_slot(now, hh, mm) != day_slot(last, hh, mm)
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

_OMIT = object()  # row(): "no meta" must mean "leave the column alone", not "null it"


def row(symbol, kind, name, parsed, now, currency="INR", closes=False, meta=_OMIT):
    r = {"symbol": symbol, "kind": kind, "name": name, "price": parsed.price,
         "prev_close": parsed.prev, "change_pct": parsed.change_pct, "currency": currency,
         "closes": parsed.closes if closes else None, "as_of": parsed.as_of,
         "updated_at": now.isoformat()}
    if meta is not _OMIT:
        r["meta"] = meta
    return r


def gold_inr_row(gc, usdinr, now):
    """International spot converted to ₹/10g. MCX/retail runs ~10% higher
    (import duty + GST) — say so on the row rather than ship a wrong number."""
    price = round(gc.price * usdinr.price / TROY_OZ_G * 10)
    p = Parsed(price, None, gc.change_pct, gc.as_of, None)
    return row("GOLD_INR_10G", "commodity", "Gold (₹/10g)", p, now,
               meta={"derived": True, "label": "intl spot × USD/INR, ex-duty"})


def upsert(sb, rows, table="quotes", key="symbol"):
    # PostgREST bulk insert demands identical keys on every row (PGRST102) —
    # a batch mixing rows with and without meta (gold_inr_row) must be split.
    buckets = {}
    for r in rows:
        buckets.setdefault(tuple(sorted(r)), []).append(r)
    for batch in buckets.values():
        for i in range(0, len(batch), 100):
            sb("POST", f"{table}?on_conflict={key}", json=batch[i:i + 100],
               headers={"Prefer": "resolution=merge-duplicates,return=minimal"})
    return len(rows)


_blob_sent = {}  # key -> sha256 of last payload this process wrote


def write_blobs(sb, rows):
    """market_blobs upsert that skips payloads identical to this process's last
    write. Keeps updated_at meaning "content changed", so the app's delta reads
    (updated_at=gt.since) refetch a blob only when it actually moved — an
    off-hours lap rewriting identical NSE lists must not bump every client.
    Hashes are stamped only after the upsert succeeds, so a transient write
    failure retries instead of being suppressed until the payload changes.
    ponytail: in-process memory only — the first lap after a restart rewrites
    everything once, which is fine."""
    fresh = [r for r in rows if _blob_sent.get(r["key"]) != _blob_hash(r["payload"])]
    if not fresh:
        return 0
    n = upsert(sb, fresh, table="market_blobs", key="key")
    for r in fresh:
        _blob_sent[r["key"]] = _blob_hash(r["payload"])
    return n


def _blob_hash(payload):
    return hashlib.sha256(json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()


# ---------- phase 1 groups ----------

def refresh_indices(sb, now):
    data = fetch_spark(list(INDICES), rng="1mo")  # ~22 closes for the sparkline
    rows = [row(s, "index", n, p, now, closes=True)
            for s, n in INDICES.items() if (p := parse_spark(data.get(s, {})))]
    return upsert(sb, rows)


def refresh_global(sb, now):
    data = fetch_spark(list(GLOBAL_INDICES) + list(ADRS), rng="1mo")
    rows = [row(s, "index", n, p, now, currency="", closes=True, meta={"global": True})
            for s, n in GLOBAL_INDICES.items() if (p := parse_spark(data.get(s, {})))]
    rows += [row(f"ADR:{s}", "index", n, p, now, currency="USD", closes=True,
                 meta={"global": True, "adr": True})
             for s, n in ADRS.items() if (p := parse_spark(data.get(s, {})))]
    return upsert(sb, rows)


def equity_universe(sb, now):
    """[(nse_symbol, name)] — followed companies first, then user-requested
    symbols (analysis_requests, <48 h), then those tagged on a story in the
    last 48 h, deduped, capped. Only these get a quote row."""
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
    by_id = {}
    for i in range(0, len(ids), 200):
        chunk = ",".join(str(c) for c in ids[i:i + 200])
        for c in sb("GET", f"companies?select=id,nse_symbol,name&id=in.({chunk})"):
            if c.get("nse_symbol"):
                by_id[c["id"]] = (c["nse_symbol"], c["name"])
    followed_n = len([c for c in followed if c in by_id])
    pairs = [by_id[c] for c in ids if c in by_id]
    requested = [r["symbol"] for r in
                 sb("GET", f"analysis_requests?select=symbol&requested_at=gte.{since}")]
    if requested:  # values quoted: M&M etc. would break a bare in.() filter
        vals = ",".join(f'"{quote(s, safe="")}"' for s in requested)
        req_pairs = [(c["nse_symbol"], c["name"]) for c in
                     sb("GET", f"companies?select=nse_symbol,name&nse_symbol=in.({vals})")]
        pairs = pairs[:followed_n] + req_pairs + pairs[followed_n:]
    out, have = [], set()
    for sym, name in pairs:
        if sym not in have:
            have.add(sym)
            out.append((sym, name))
    return out[:EQUITY_CAP]


def refresh_equities(sb, now):
    universe = equity_universe(sb, now)
    data = fetch_spark([f"{s}.NS" for s, _ in universe])
    rows = [row(s, "equity", n, p, now)
            for s, n in universe if (p := parse_spark(data.get(f"{s}.NS", {})))]
    n = upsert(sb, rows)
    # Rows nobody refreshes any more (untagged, unfollowed) age out after a week.
    if now.astimezone(IST).hour == 3 and now.minute < 15:  # Z, not +00:00: "+" is a space in a URL
        sb("DELETE", "quotes?kind=eq.equity&updated_at=lt."
           + (now - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"))
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
                             "include_24hr_change": "true", "include_market_cap": "true"},
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
        meta = {"usd": d.get("usd")}
        if cid in STABLE and d.get("usd") is not None:
            meta["peg_pct"] = round((d["usd"] - 1) * 100, 3)   # drift from $1
            meta["usd_mcap"] = d.get("usd_market_cap")
        rows.append(row(cid, "crypto", name, p, now, meta=meta))
    return upsert(sb, rows)


# ---------- phase 3: mutual funds (mfapi.in, keyless) ----------

def short_mf_name(name):
    """'Parag Parikh Flexi Cap Fund - Direct Plan - Growth' -> 'Parag Parikh Flexi Cap Fund'."""
    return re.sub(r"\s*-\s*Direct.*$", "", name or "", flags=re.I).strip()


def parse_mf(j):
    """mfapi /mf/{code}: data newest-first [{date:'21-08-2026', nav:'112.22'}].
    -> (Parsed with 30 NAV closes, meta with 1m/1y returns) or None."""
    navs = []
    for d in (j.get("data") or [])[:400]:
        try:
            navs.append((datetime.strptime(d["date"], "%d-%m-%Y").replace(tzinfo=IST), float(d["nav"])))
        except (KeyError, ValueError, TypeError):
            continue
    if not navs:
        return None
    navs.reverse()  # oldest first
    closes = [v for _, v in navs[-30:]]
    price = closes[-1]
    prev = closes[-2] if len(closes) > 1 else None
    pct = round((price - prev) / prev * 100, 2) if prev else None

    def ret(trading_days):
        if len(navs) > trading_days:
            return round((price / navs[-1 - trading_days][1] - 1) * 100, 1)
        return None

    m = j.get("meta") or {}
    meta = {"fund_house": m.get("fund_house"), "category": m.get("scheme_category"),
            "ret_1m": ret(21), "ret_1y": ret(250)}
    return Parsed(price, prev, pct, navs[-1][0].isoformat(), closes), meta


def followed_mf(sb):
    return [int(f["target_id"]) for f in sb("GET", "follows?select=target_id&target_type=eq.mf")
            if str(f["target_id"]).isdigit()]


def refresh_mf(sb, now):
    """Daily, per NAV slot: the default board plus every followed scheme."""
    codes = list(DEFAULT_MF)
    codes += [c for c in followed_mf(sb) if c not in codes]
    return fetch_mf_rows(sb, codes, now)


def refresh_mf_new(sb, now):
    """Every 5 min: followed schemes with no quote row yet (a follow made since
    the daily pass), so a fresh follow never stares at a blank until tomorrow."""
    have = {r["symbol"] for r in sb("GET", "quotes?select=symbol&kind=eq.mf")}
    codes = [c for c in followed_mf(sb) if f"MF:{c}" not in have]
    return fetch_mf_rows(sb, codes, now) if codes else 0


def fetch_mf_rows(sb, codes, now):
    rows = []
    for code in codes:
        try:
            r = requests.get(f"https://api.mfapi.in/mf/{code}", headers=BROWSER_UA, timeout=TIMEOUT)
            r.raise_for_status()
            j = r.json()
            parsed = parse_mf(j)
        except Exception as e:
            print(f"MARKET mf {code}: {e}")
            continue
        if not parsed:
            continue
        p, meta = parsed
        name = short_mf_name((j.get("meta") or {}).get("scheme_name")) or str(code)
        rows.append(row(f"MF:{code}", "mf", name, p, now, closes=True,
                        meta={**meta, "scheme_code": code}))
        time.sleep(0.2)
    return upsert(sb, rows)


# ---------- phase 3: macro (FRED, free key) ----------

def parse_fred(observations):
    """sort_order=desc observations; '.' is FRED's missing value. Rates move in
    points, not %, so change_pct is left empty and the delta goes in meta."""
    vals = []
    for o in observations or []:
        v = o.get("value")
        if v in (None, ".", ""):
            continue
        try:
            vals.append((o.get("date"), float(v)))
        except (TypeError, ValueError):
            continue
    if not vals:
        return None
    vals.reverse()
    closes = [v for _, v in vals]
    price = closes[-1]
    prev = closes[-2] if len(closes) > 1 else None
    p = Parsed(price, prev, None, f"{vals[-1][0]}T00:00:00+00:00", closes)
    return p, {"period": vals[-1][0], "delta": round(price - prev, 2) if prev is not None else None}


def refresh_macro(sb, now):
    key = os.environ.get("FRED_API_KEY", "").split(",")[0].strip()
    if not key:
        return 0  # optional: no key, no Economy section, nothing else changes
    rows = []
    for sid, spec in MACRO_SERIES.items():
        name, units, scale = (*spec, 1)[:3]
        try:
            r = requests.get("https://api.stlouisfed.org/fred/series/observations",
                             params={"series_id": sid, "api_key": key, "file_type": "json",
                                     "sort_order": "desc", "limit": 24},
                             headers=BROWSER_UA, timeout=TIMEOUT)
            r.raise_for_status()
            parsed = parse_fred(r.json().get("observations"))
        except Exception as e:
            print(f"MARKET macro {sid}: {e}")
            continue
        if not parsed:
            continue
        p, meta = parsed
        if scale != 1:
            p = p._replace(price=round(p.price * scale, 2),
                           prev=round(p.prev * scale, 2) if p.prev is not None else None,
                           closes=[round(c * scale, 2) for c in p.closes])
            if meta.get("delta") is not None:
                meta["delta"] = round(p.price - p.prev, 2) if p.prev is not None else None
        rows.append(row(f"MACRO:{sid}", "macro", name, p, now, currency="", closes=True,
                        meta={**meta, "units": units, "series": sid}))
    return upsert(sb, rows)


# ---------- v0.20.0: fundamentals (Yahoo quoteSummary, crumb dance) ----------
# Verified from a GitHub runner 2026-08-23: fc.yahoo cookie -> getcrumb ->
# quoteSummary 200 for .NS symbols. Ratios, growth, holders and 4 quarters of
# revenue/PAT land in quotes.meta.f; technicals computed from the 1y chart land
# in meta.t. The price refresh omits `meta` entirely, so these survive it.

QS_URL = "https://query1.finance.yahoo.com/v10/finance/quoteSummary/"
CRUMB_URL = "https://query1.finance.yahoo.com/v1/test/getcrumb"
QS_MODULES = ("summaryDetail,defaultKeyStatistics,financialData,"
              "incomeStatementHistoryQuarterly,majorHoldersBreakdown,assetProfile")
ANALYSIS_MAX_AGE_H = 20  # a process restart must not redo the whole universe
ANALYSIS_NEW_CAP = 10    # requested-symbol backfills per pass; bursts drain over a few 5-min passes

_yahoo = {"session": None, "crumb": None}


def yahoo_session(force=False):
    if _yahoo["crumb"] and not force:
        return _yahoo["session"], _yahoo["crumb"]
    s = requests.Session()
    s.headers.update(BROWSER_UA)
    try:  # sets the cookie the crumb is bound to; its own status is irrelevant
        s.get("https://fc.yahoo.com/", timeout=TIMEOUT)
    except requests.RequestException:
        pass
    r = s.get(CRUMB_URL, timeout=TIMEOUT)
    r.raise_for_status()
    crumb = r.text.strip()
    if not crumb or "<" in crumb:
        raise RuntimeError(f"no crumb: {crumb[:40]!r}")
    _yahoo.update(session=s, crumb=crumb)
    return s, crumb


def parse_fundamentals(j):
    result = (j.get("quoteSummary") or {}).get("result") or []
    if not result:
        return {}
    r = result[0]

    def raw(module, key):
        return ((r.get(module) or {}).get(key) or {}).get("raw")

    def pct(v):
        return round(v * 100, 1) if v is not None else None

    de = raw("financialData", "debtToEquity")
    f = {"pe": raw("summaryDetail", "trailingPE"), "fwd_pe": raw("summaryDetail", "forwardPE"),
         "mcap": raw("summaryDetail", "marketCap"), "div_yield": pct(raw("summaryDetail", "dividendYield")),
         "pb": raw("defaultKeyStatistics", "priceToBook"), "eps": raw("defaultKeyStatistics", "trailingEps"),
         "beta": raw("defaultKeyStatistics", "beta"), "roe": pct(raw("financialData", "returnOnEquity")),
         "de": round(de / 100, 2) if de is not None else None,  # Yahoo reports it in percent
         "margin": pct(raw("financialData", "profitMargins")),
         "rev_growth": pct(raw("financialData", "revenueGrowth")),
         "earn_growth": pct(raw("financialData", "earningsGrowth")),
         "target": raw("financialData", "targetMeanPrice"),
         "rec": (r.get("financialData") or {}).get("recommendationKey"),
         "promoter_pct": pct(raw("majorHoldersBreakdown", "insidersPercentHeld")),
         "inst_pct": pct(raw("majorHoldersBreakdown", "institutionsPercentHeld")),
         "sector": (r.get("assetProfile") or {}).get("sector"),
         "industry": (r.get("assetProfile") or {}).get("industry")}
    quarters = [{"end": (q.get("endDate") or {}).get("fmt"),
                 "revenue": (q.get("totalRevenue") or {}).get("raw"),
                 "net_income": (q.get("netIncome") or {}).get("raw")}
                for q in ((r.get("incomeStatementHistoryQuarterly") or {})
                          .get("incomeStatementHistory") or [])[:4]]
    if quarters:
        f["quarters"] = quarters
    f = {k: (round(v, 2) if isinstance(v, float) else v) for k, v in f.items() if v is not None}
    return f


def needs_refresh(symbols, existing_meta, stamp, now):
    """Symbols whose `stamp` in meta is older than ANALYSIS_MAX_AGE_H (or absent)."""
    cutoff = now - timedelta(hours=ANALYSIS_MAX_AGE_H)
    out = []
    for s in symbols:
        at = (existing_meta.get(s) or {}).get(stamp)
        done = False
        if at:
            try:
                done = datetime.fromisoformat(at) > cutoff
            except ValueError:
                pass
        if not done:
            out.append(s)
    return out


def merge_meta(sb, updates, key, now):
    """Merge {symbol: dict} into quotes.meta[key] (+ key_at stamp) for rows that
    exist; a symbol with no quote row yet waits for the next price pass."""
    existing = {r["symbol"]: r for r in
                sb("GET", "quotes?select=symbol,kind,name,price,meta&kind=eq.equity")}
    rows = []
    for sym, d in updates.items():
        base = existing.get(sym)
        if not base:
            continue
        meta = {**(base.get("meta") or {}), key: d, f"{key}_at": now.isoformat()}
        rows.append({**{k: base[k] for k in ("symbol", "kind", "name", "price")}, "meta": meta})
    return upsert(sb, rows)


def fetch_fundamentals_for(symbols):
    """{symbol: parsed f-dict} via quoteSummary; owns the crumb dance including
    the one 401 retry. Per-symbol failures are logged and skipped."""
    if not symbols:
        return {}
    session, crumb = yahoo_session()
    updates = {}
    for sym in symbols:
        try:
            r = session.get(f"{QS_URL}{sym}.NS", params={"modules": QS_MODULES, "crumb": crumb},
                            timeout=TIMEOUT)
            if r.status_code == 401:  # crumb expired mid-run: one refresh, retry once
                session, crumb = yahoo_session(force=True)
                r = session.get(f"{QS_URL}{sym}.NS", params={"modules": QS_MODULES, "crumb": crumb},
                                timeout=TIMEOUT)
            r.raise_for_status()
            f = parse_fundamentals(r.json())
            if f:
                updates[sym] = f
        except Exception as e:
            print(f"MARKET fundamentals {sym}: {e}")
        time.sleep(0.4)
    return updates


def refresh_fundamentals(sb, now):
    universe = equity_universe(sb, now)
    existing = {r["symbol"]: (r.get("meta") or {}) for r in
                sb("GET", "quotes?select=symbol,meta&kind=eq.equity")}
    updates = fetch_fundamentals_for(
        needs_refresh([s for s, _ in universe], existing, "f_at", now))
    return merge_meta(sb, updates, "f", now) if updates else 0


# ---------- v0.20.0: technicals, computed from the 1y daily chart ----------

def _ema(values, n):
    k = 2 / (n + 1)
    e = values[0]
    out = [e]
    for v in values[1:]:
        e = v * k + e * (1 - k)
        out.append(e)
    return out


def compute_technicals(closes, volumes):
    c = [x for x in (closes or []) if x is not None]
    if not c:
        return {}
    last = c[-1]
    t = {"close": round(last, 2)}

    def sma(n):
        return round(sum(c[-n:]) / n, 2) if len(c) >= n else None

    for n in (20, 50, 200):
        v = sma(n)
        if v is not None:
            t[f"sma{n}"] = v
    if len(c) >= 15:  # Wilder RSI over the whole series
        gains = losses = 0.0
        for a, b in zip(c[:15], c[1:15]):
            d = b - a
            gains += max(d, 0)
            losses += max(-d, 0)
        avg_g, avg_l = gains / 14, losses / 14
        for a, b in zip(c[14:], c[15:]):
            d = b - a
            avg_g = (avg_g * 13 + max(d, 0)) / 14
            avg_l = (avg_l * 13 + max(-d, 0)) / 14
        t["rsi14"] = round(100.0 if avg_l == 0 else 100 - 100 / (1 + avg_g / avg_l), 1)
    if len(c) >= 35:
        macd = [a - b for a, b in zip(_ema(c, 12), _ema(c, 26))]
        t["macd_hist"] = round(macd[-1] - _ema(macd, 9)[-1], 2)
    hi, lo = max(c), min(c)
    t["hi52"], t["lo52"] = round(hi, 2), round(lo, 2)
    t["pos52"] = round((last - lo) / (hi - lo), 2) if hi > lo else 0.5
    v = [x for x in (volumes or []) if x]
    if len(v) >= 20 and sum(v[-20:]):
        t["vol_ratio"] = round(v[-1] / (sum(v[-20:]) / 20), 2)
    if t.get("sma200") is not None:
        t["above200"] = last > t["sma200"]
        t["vs200"] = round((last / t["sma200"] - 1) * 100, 1)
    if t.get("sma50") is not None:
        t["vs50"] = round((last / t["sma50"] - 1) * 100, 1)
    if t.get("sma50") is not None and t.get("sma200") is not None:
        if t["sma50"] > t["sma200"] and last > t["sma50"]:
            t["trend"] = "up"
        elif t["sma50"] < t["sma200"] and last < t["sma50"]:
            t["trend"] = "down"
        else:
            t["trend"] = "mixed"
    else:
        t["trend"] = "mixed"
    return t


def fetch_technicals_for(symbols):
    """{symbol: computed t-dict} from the 1y daily chart, one call per symbol."""
    updates = {}
    for sym in symbols:
        try:
            r = requests.get(f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}.NS",
                             params={"range": "1y", "interval": "1d"},
                             headers=BROWSER_UA, timeout=TIMEOUT)
            r.raise_for_status()
            q = r.json()["chart"]["result"][0]["indicators"]["quote"][0]
            t = compute_technicals(q.get("close"), q.get("volume"))
            if t:
                updates[sym] = t
        except Exception as e:
            print(f"MARKET technicals {sym}: {e}")
        time.sleep(0.3)
    return updates


def refresh_technicals(sb, now):
    universe = equity_universe(sb, now)
    existing = {r["symbol"]: (r.get("meta") or {}) for r in
                sb("GET", "quotes?select=symbol,meta&kind=eq.equity")}
    updates = fetch_technicals_for(
        needs_refresh([s for s, _ in universe], existing, "t_at", now))
    return merge_meta(sb, updates, "t", now) if updates else 0


def refresh_analysis_new(sb, now):
    """Every 5 min: backfill f/t for symbols users requested from a stock page
    outside the universe (analysis_requests, app-inserted). Served rows are
    KEPT until the 48 h prune — their presence holds the symbol in
    equity_universe while it's hot; needs_refresh makes re-serving free."""
    sb("DELETE", "analysis_requests?requested_at=lt."  # Z, not +00:00: "+" is a space in a URL
       + (now - timedelta(hours=48)).strftime("%Y-%m-%dT%H:%M:%SZ"))
    reqs = sb("GET", "analysis_requests?select=symbol&order=requested_at")
    if not reqs:
        return 0
    names = {c["nse_symbol"]: c["name"] for c in
             sb("GET", "companies?select=nse_symbol,name") if c.get("nse_symbol")}
    for r in reqs:  # typos, delisted; one call each — M&M breaks an in.() filter
        if r["symbol"] not in names:
            sb("DELETE", f"analysis_requests?symbol=eq.{quote(r['symbol'], safe='')}")
    todo = [r["symbol"] for r in reqs if r["symbol"] in names][:ANALYSIS_NEW_CAP]
    if not todo:
        return 0
    existing = {r["symbol"]: (r.get("meta") or {}) for r in
                sb("GET", "quotes?select=symbol,meta&kind=eq.equity")}
    # merge_meta only touches rows that exist: give quote-less symbols a price
    # row first (row() omits meta, so this write can never clobber analysis).
    missing = [s for s in todo if s not in existing]
    if missing:
        data = fetch_spark([f"{s}.NS" for s in missing])
        rows = [row(s, "equity", names[s], p, now)
                for s in missing if (p := parse_spark(data.get(f"{s}.NS", {})))]
        if rows:
            upsert(sb, rows)
            existing.update({r["symbol"]: {} for r in rows})
    todo = [s for s in todo if s in existing]  # a spark miss retries next pass
    n = 0
    f_updates = fetch_fundamentals_for(needs_refresh(todo, existing, "f_at", now))
    if f_updates:
        n += merge_meta(sb, f_updates, "f", now)
    t_updates = fetch_technicals_for(needs_refresh(todo, existing, "t_at", now))
    if t_updates:
        n += merge_meta(sb, t_updates, "t", now)
    return n


# ---------- v0.20.0: flows (FII/DII, PCR, breadth) -> market_blobs.flows ----------

def parse_fiidii(rows):
    out = {}
    for r in rows or []:
        cat = "fii" if "FII" in (r.get("category") or "") else "dii"
        try:
            out[cat] = {"buy": float(r["buyValue"]), "sell": float(r["sellValue"]),
                        "net": float(r["netValue"])}
            out["date"] = r.get("date")
        except (KeyError, TypeError, ValueError):
            continue
    return out


def nearest_expiry(contract_info):
    dates = (contract_info or {}).get("expiryDates") or []
    return dates[0] if dates else None


def parse_option_chain(j, expiry):
    f = (j.get("filtered") or {})
    ce, pe = (f.get("CE") or {}).get("totOI"), (f.get("PE") or {}).get("totOI")
    if not ce or not pe:
        return {}
    out = {"pcr": round(pe / ce, 2), "ce_oi": ce, "pe_oi": pe, "expiry": expiry,
           "underlying": (j.get("records") or {}).get("underlyingValue")}
    best, best_oi = None, -1
    for row_ in (j.get("records") or {}).get("data") or []:
        oi = ((row_.get("CE") or {}).get("openInterest") or 0) +              ((row_.get("PE") or {}).get("openInterest") or 0)
        if oi > best_oi:
            best, best_oi = row_.get("strikePrice"), oi
    if best is not None:
        out["max_oi_strike"] = best
    return out


def breadth(indices):
    out = {}
    for r in indices or []:
        if r.get("index") in ("NIFTY 50", "NIFTY 500") and r.get("advances") is not None:
            try:
                out[r["index"]] = {"adv": int(r["advances"]), "dec": int(r["declines"])}
            except (TypeError, ValueError):
                continue
    return out


# ---------- phase 3: NSE smart-money lists -> market_blobs (keyless) ----------

NSE_API = "https://www.nseindia.com/api/"
RESULTS_RE = re.compile(r"result|financial", re.I)
# 21 Aug 2026: /api/corporates-pit went dark (200, data:[]) — the site now calls
# /api/corporates-pit-gg, which lists filings only; person/qty/side moved into
# each filing's inline-XBRL doc (BSE/NSE shared taxonomy, single-quoted attrs).
PIT_XBRL_KEYS = {"NameOfThePerson": "person", "CategoryOfPerson": "category",
                 "TypeOfInstrument": "security",
                 "SecuritiesAcquiredOrDisposedNumberOfSecurity": "qty",
                 "SecuritiesAcquiredOrDisposedValueOfSecurity": "value",
                 "SecuritiesAcquiredOrDisposedTransactionType": "side",
                 "ModeOfAcquisitionOrDisposal": "mode",
                 "DateOfAllotmentAdviceOrAcquisitionOfSharesOrSaleOfSharesSpecifyFromDate": "date",
                 "DateOfIntimationToCompany": "intimated"}


def nse_session():
    s = requests.Session()
    s.headers.update({**BROWSER_UA, "Referer": "https://www.nseindia.com/"})
    try:  # cookie warm-up; a 403 here is fine (verified from a runner 2026-08-22)
        s.get("https://www.nseindia.com/", timeout=8)
    except requests.RequestException:
        pass
    return s


def parse_nse_date(s):
    try:
        return datetime.strptime(s or "", "%d-%b-%Y").date()
    except ValueError:
        return None


def results_calendar(events, meetings, known, now, days=14):
    """Board meetings in the next `days` whose purpose is results, for symbols
    we know, from both NSE lists (they overlap but not fully), deduped."""
    today = now.astimezone(IST).date()
    end = today + timedelta(days=days)
    out = {}
    for e in events or []:
        sym, d = e.get("symbol"), parse_nse_date(e.get("date"))
        if sym in known and d and today <= d <= end and RESULTS_RE.search(e.get("purpose") or ""):
            out.setdefault((sym, d), {"symbol": sym, "company": e.get("company"),
                                      "date": d.isoformat(), "purpose": e.get("purpose"),
                                      "desc": e.get("bm_desc")})
    for m in meetings or []:
        sym, d = m.get("bm_symbol"), parse_nse_date(m.get("bm_date"))
        if sym in known and d and today <= d <= end and RESULTS_RE.search(m.get("bm_purpose") or ""):
            out.setdefault((sym, d), {"symbol": sym, "company": m.get("sm_name"),
                                      "date": d.isoformat(), "purpose": m.get("bm_purpose"),
                                      "desc": m.get("bm_desc")})
    return sorted(out.values(), key=lambda r: (r["date"], r["symbol"]))[:300]


def shape_deals(j, cap=100):
    deals = []
    for kind, key in (("bulk", "BULK_DEALS_DATA"), ("block", "BLOCK_DEALS_DATA")):
        for d in j.get(key) or []:
            try:
                qty, price = int(float(d.get("qty") or 0)), float(d.get("watp") or 0)
            except (TypeError, ValueError):
                continue
            deals.append({"type": kind, "symbol": d.get("symbol"), "name": d.get("name"),
                          "side": (d.get("buySell") or "").upper(), "qty": qty, "price": price,
                          "value": round(qty * price), "client": d.get("clientName"),
                          "date": d.get("date")})
    deals.sort(key=lambda x: -x["value"])
    return {"as_on": j.get("as_on_date"), "deals": deals[:cap]}


def parse_pit_xbrl(html):
    """{person, qty, side, ...} facts out of one insider iXBRL filing."""
    out = {}
    for name, val in re.findall(
            r"<ix:non(?:Numeric|Fraction)[^>]*name=['\"]([^'\"]+)['\"][^>]*>(.*?)"
            r"</ix:non(?:Numeric|Fraction)>", html, re.S):
        key = PIT_XBRL_KEYS.get(name.split(":")[-1])
        if key and key not in out:
            out[key] = re.sub(r"<[^>]+>", "", val).strip()
    return out


def shape_insider(j, known, prev=None, fetch=None, cap=200, fetch_cap=40):
    """pit-gg lists filings; the details cost one doc fetch each, so parse only
    filings not already in the previous blob (appId) and keep the newest `cap`."""
    seen = {r.get("appId") for r in prev or []}
    data = (j.get("data") if isinstance(j, dict) else j) or []
    fresh, fetched = [], 0
    for d in data:  # API order is newest-first; keep it
        if d.get("symbol") not in known or not d.get("ixbrl") or d.get("appId") in seen:
            continue
        if fetched >= fetch_cap:  # first run catches up over a few hourly passes
            break
        fetched += 1
        try:
            facts = parse_pit_xbrl(fetch(d["ixbrl"]))
        except Exception as e:
            print(f"MARKET insider {d.get('symbol')}: {e}")
            continue
        fresh.append({"appId": d.get("appId"), "symbol": d.get("symbol"),
                      "company": d.get("companyName"), **facts})
    return (fresh + list(prev or []))[:cap]


def shape_indices(j, keep=("BROAD MARKET INDICES", "SECTORAL INDICES",
                           "THEMATIC INDICES", "STRATEGY INDICES")):
    return [{"index": r.get("index"), "group": r.get("key"), "last": r.get("last"),
             "pct": r.get("percentChange"), "pe": r.get("pe"), "advances": r.get("advances"),
             "declines": r.get("declines"), "year_high": r.get("yearHigh"),
             "year_low": r.get("yearLow"), "pct_30d": r.get("perChange30d"),
             "pct_1y": r.get("perChange365d")}
            for r in j.get("data") or [] if r.get("key") in keep]


# ---------- trader coverage (2026-08-29): IPOs, F&O snapshot, G-Sec yields ----------
# NSE field names below are read leniently (every observed spelling) because
# these endpoints drift; verify actual shapes from a GitHub runner before
# trusting a quiet blob (local machines get Akamai 403s).

def _pick(d, *keys):
    for k in keys:
        v = d.get(k)
        if v not in (None, "", "-"):
            return v
    return None


def _num(v):
    try:
        return float(str(v).replace(",", "").replace("%", ""))
    except (TypeError, ValueError):
        return None


def _rows(j):
    """NSE wraps lists as {"data": [...]} — sometimes one level deeper."""
    if isinstance(j, list):
        return j
    if not isinstance(j, dict):
        return []
    if isinstance(j.get("data"), list):
        return j["data"]
    for sub in j.values():
        if isinstance(sub, dict) and isinstance(sub.get("data"), list):
            return sub["data"]
    return []


def shape_ipos(current, upcoming, cap=30):
    def rows(j, fallback_status):
        out = []
        for d in _rows(j):
            if not isinstance(d, dict):
                continue
            sym, name = _pick(d, "symbol", "sym"), _pick(d, "companyName", "company", "issuer")
            if not (sym or name):
                continue
            out.append({"symbol": sym, "company": name,
                        "open": _pick(d, "issueStartDate", "startDate", "openDt"),
                        "close": _pick(d, "issueEndDate", "endDate", "closeDt"),
                        "band": _pick(d, "priceBand", "issuePrice", "price"),
                        "size": _pick(d, "issueSize", "size"),
                        "series": _pick(d, "series", "issueType", "category"),
                        "status": _pick(d, "status", "statusOfIssue") or fallback_status})
        return out[:cap]
    return {"current": rows(current, "open"), "upcoming": rows(upcoming, "upcoming")}


def shape_oi_spurts(j, cap=8):
    rows = []
    for d in _rows(j):
        sym = _pick(d, "symbol", "underlying")
        oi_pct = _num(_pick(d, "avgInOI", "changeInOI", "oiChgPct", "pctChangeInOI"))
        if not sym or oi_pct is None:
            continue
        rows.append({"symbol": sym, "ltp": _num(_pick(d, "ltp", "lastPrice", "ltP")),
                     "pct": _num(_pick(d, "pChange", "perChange", "pctChange")),
                     "oi_pct": oi_pct})
    return {"oi_gainers": sorted((r for r in rows if r["oi_pct"] > 0),
                                 key=lambda r: -r["oi_pct"])[:cap],
            "oi_losers": sorted((r for r in rows if r["oi_pct"] < 0),
                                key=lambda r: r["oi_pct"])[:cap]}


def shape_variations(j, cap=8):
    out = []
    for d in _rows(j):
        sym = _pick(d, "symbol")
        pct = _num(_pick(d, "pChange", "perChange", "netPrice"))
        if not sym or pct is None:
            continue
        out.append({"symbol": sym, "ltp": _num(_pick(d, "ltp", "lastPrice", "ltP")), "pct": pct})
    return out[:cap]


# ---------- RBI homepage "Current Rates": benchmark G-Secs + policy rates ----------
# rbi.org.in's rates box is plain <th>name</th><td>: value</td> tables with an
# "as on <date>" footnote. One fetch feeds two blobs: `bonds` (benchmark
# G-Secs keyed by residual tenor - replaced Stooq's daily CSV on 4 Sep 2026,
# which had sat behind a JS proof-of-work page since August while the group
# stayed green) and `rbi_rates` (repo/SDF/MSF/bank/reverse repo/CRR/SLR and
# T-bill auction cut-offs). ponytail: regex over th/td pairs, no HTML parser
# dependency; a layout change raises and the group goes red.

RBI_URL = "https://www.rbi.org.in/"
_RBI_PAIR = re.compile(r"<th[^>]*>\s*(.*?)\s*</th>\s*<td[^>]*>\s*:?\s*(.*?)\s*</td>", re.S)
_RBI_GSEC = re.compile(r"^[\d.]+%\s*GS\s*(\d{4})$")
RBI_RATES = {"Policy Repo Rate": "repo", "Standing Deposit Facility Rate": "sdf",
             "Marginal Standing Facility Rate": "msf", "Bank Rate": "bank_rate",
             "Fixed Reverse Repo Rate": "reverse_repo", "CRR": "crr", "SLR": "slr",
             "91 day T-bills": "tbill_91d", "182 day T-bills": "tbill_182d",
             "364 day T-bills": "tbill_364d"}


def _rbi_text(s):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>|&nbsp;", " ", s)).strip()


def _rbi_pct(v):
    m = re.match(r"([\d.]+)\s*%", v)
    return float(m.group(1)) if m else None


def parse_rbi_home(html, year):
    """-> (gsec yields, rates dict, as-on ISO date) from the Current Rates box."""
    a = html.find("CURRENT RATES START")
    seg = html[a:a + 40000] if a >= 0 else html
    m = re.search(r"as on\s*(?:<!--.*?-->)?\s*([A-Z][a-z]+ \d{1,2}, \d{4})", seg, re.S)
    asof = datetime.strptime(m.group(1), "%B %d, %Y").date().isoformat() if m else None
    gsecs, rates = [], {}
    for k, v in _RBI_PAIR.findall(seg):
        k, v = _rbi_text(k), _rbi_text(v)
        g = _RBI_GSEC.match(k)
        if g:
            y = _rbi_pct(v)
            if y is not None:
                gsecs.append({"tenor": f"{int(g.group(1)) - year}Y", "name": k,
                              "yield": y, "date": asof})
        elif k in RBI_RATES:
            rates[RBI_RATES[k]] = _rbi_pct(v)
    return gsecs, rates, asof


def refresh_bonds(sb, now):
    r = requests.get(RBI_URL, headers=BROWSER_UA, timeout=TIMEOUT)
    r.raise_for_status()
    gsecs, rates, asof = parse_rbi_home(r.text, now.astimezone(IST).year)
    if not gsecs:
        raise RuntimeError("RBI current-rates box not found: layout changed or blocked page")
    # chg_bp is day-over-day against the last published blob, never intraday
    old = sb("GET", "market_blobs?select=payload&key=eq.bonds")
    prev = {y.get("name"): y for y in ((old[0]["payload"] if old else {}) or {}).get("yields") or []}
    for y in gsecs:
        p = prev.get(y["name"])
        if p and p.get("date") != asof and p.get("yield") is not None:
            y["prev"] = p["yield"]
            y["chg_bp"] = round((y["yield"] - p["yield"]) * 100, 1)
        else:  # first sight, or the same day re-read: keep the last comparison
            y["prev"], y["chg_bp"] = (p or {}).get("prev"), (p or {}).get("chg_bp")
    ts = now.isoformat()
    return write_blobs(sb, [{"key": "bonds", "payload": {"yields": gsecs}, "updated_at": ts},
                            {"key": "rbi_rates", "payload": {**rates, "asof": asof}, "updated_at": ts}])


# ---------- P4 context sources (4 Sep 2026, worldmonitor study) ----------
# World Bank WDI: the annual India macro frame (growth, inflation, CAD, fiscal)
# for one context card. Keyless JSON; `lastupdated` is the content date.

WB_INDICATORS = {"NY.GDP.MKTP.KD.ZG": ("GDP growth", "%"),
                 "FP.CPI.TOTL.ZG": ("CPI inflation", "%"),
                 "BN.CAB.XOKA.GD.ZS": ("Current account", "% of GDP")}
# (no fiscal balance: WDI's GC.NLD.TOTL.GD.ZS for India stops at 2022 with gaps)
WB_URL = "https://api.worldbank.org/v2/country/IND/indicator/" + ";".join(WB_INDICATORS)


def parse_worldbank(payload):
    """[meta, rows] (mrv=3, newest first per indicator) -> (series, lastupdated)."""
    if not isinstance(payload, list) or len(payload) < 2:
        return {}, None
    meta, rows = payload[0] or {}, payload[1] or []
    series = {}
    for r in rows:
        code = (r.get("indicator") or {}).get("id")
        if code not in WB_INDICATORS or r.get("value") is None:
            continue
        name, units = WB_INDICATORS[code]
        cur = series.get(code)
        if cur is None:
            series[code] = {"name": name, "units": units, "value": round(r["value"], 2),
                            "year": r.get("date"), "prev": None, "prev_year": None}
        elif cur["prev"] is None:
            cur["prev"], cur["prev_year"] = round(r["value"], 2), r.get("date")
    return series, meta.get("lastupdated")


def refresh_worldmacro(sb, now):
    r = requests.get(WB_URL, params={"source": 2, "format": "json", "mrv": 3},
                     headers=BROWSER_UA, timeout=TIMEOUT)
    r.raise_for_status()
    series, asof = parse_worldbank(r.json())
    if not series:
        raise RuntimeError("World Bank returned no India series")
    return write_blobs(sb, [{"key": "macro_context", "payload": {"series": series, "asof": asof},
                             "updated_at": now.isoformat()}])


# USGS quakes over the India region, M4.5+, last 7 days. GeoJSON, keyless.
# ponytail: quakes only - NASA EONET's "open" events carried 2025 wildfires
# as current when probed, and GDELT 429s every call from here.

USGS_URL = "https://earthquake.usgs.gov/fdsnws/event/1/query"
INDIA_BBOX = {"minlatitude": 5, "maxlatitude": 38, "minlongitude": 66, "maxlongitude": 98}
QUAKE_MIN_MAG = 4.5


def parse_usgs(payload):
    out = []
    for f in (payload or {}).get("features") or []:
        p, g = f.get("properties") or {}, (f.get("geometry") or {}).get("coordinates") or []
        if p.get("mag") is None or p.get("time") is None:
            continue
        out.append({"mag": p["mag"], "place": p.get("place") or "",
                    "time": datetime.fromtimestamp(p["time"] / 1000, tz=timezone.utc).isoformat(),
                    "url": p.get("url"),
                    "lat": g[1] if len(g) > 1 else None, "lon": g[0] if g else None})
    return out


def refresh_hazards(sb, now):
    r = requests.get(USGS_URL, params={"format": "geojson", "minmagnitude": QUAKE_MIN_MAG,
                                       "starttime": (now - timedelta(days=7)).strftime("%Y-%m-%d"),
                                       "orderby": "time", "limit": 20, **INDIA_BBOX},
                     headers=BROWSER_UA, timeout=TIMEOUT)
    r.raise_for_status()
    r.encoding = "utf-8"  # USGS omits charset; requests' Latin-1 fallback mojibakes place names
    quakes = parse_usgs(r.json())  # an empty week is a real, publishable answer
    return write_blobs(sb, [{"key": "hazards", "payload": {"quakes": quakes},
                             "updated_at": now.isoformat()}])


# ---------- Polymarket prediction odds (G3; CI-only, dev IP refused) ----------
# One Gamma call for the highest-volume open markets, filtered to themes that
# move Indian portfolios (Fed, oil, China, tariffs...). GDELT was probed from
# a runner the same day and 429s there too - buried, do not re-add.

POLY_URL = "https://gamma-api.polymarket.com/markets"
POLY_THEMES = ("fed", "rate", "recession", "india", "china", "oil", "opec",
               "tariff", "inflation", "bitcoin", "war", "sanction")
POLY_CAP = 10


def parse_polymarket(rows):
    out = []
    for m in rows or []:
        q = (m.get("question") or "").strip()
        if not q or not any(t in q.lower() for t in POLY_THEMES):
            continue
        try:
            outcomes = json.loads(m.get("outcomes") or "[]")
            prices = [float(x) for x in json.loads(m.get("outcomePrices") or "[]")]
        except (TypeError, ValueError):
            continue
        if not outcomes or len(prices) != len(outcomes):
            continue
        if outcomes[:2] == ["Yes", "No"]:
            label, pct = "Yes", round(prices[0] * 100)
        else:  # multi-outcome: report the current favourite
            label, pct = max(zip(outcomes, prices), key=lambda x: x[1])[0], \
                round(max(prices) * 100)
        out.append({"q": q, "slug": m.get("slug"), "label": label, "pct": pct,
                    "end": (m.get("endDate") or "")[:10]})
    return out[:POLY_CAP]


def refresh_polymarket(sb, now):
    r = requests.get(POLY_URL, params={"limit": 100, "active": "true", "closed": "false",
                                       "order": "volume24hr", "ascending": "false"},
                     headers=BROWSER_UA, timeout=TIMEOUT)
    r.raise_for_status()
    markets = parse_polymarket(r.json())
    if not markets:
        raise RuntimeError("Polymarket: no theme-matching markets in the top 100")
    return write_blobs(sb, [{"key": "predictions", "payload": {"markets": markets},
                             "updated_at": now.isoformat()}])


# ---------- MOSPI CPI (official, replaces FRED's frozen INDCPIALLMINMEI) ----------
# api.mospi.gov.in is keyless, 10 rows/page, newest month first; its query
# filters are IGNORED, so page and filter client-side — the All-India /
# General-Overall rows sit within the first ~8 pages. Gotcha: the server
# demands legacy TLS renegotiation, which modern OpenSSL refuses by default,
# hence the dedicated session.

MOSPI_CPI_URL = "https://api.mospi.gov.in/api/cpi/getCPIIndex"
MOSPI_PAGES = 12  # sector blocks run ~3 pages each (Rural/Urban/Combined); Combined seen on page 9
_MONTHS = {m: i + 1 for i, m in enumerate(
    ("January", "February", "March", "April", "May", "June", "July",
     "August", "September", "October", "November", "December"))}
_mospi = {"session": None}


def _legacy_tls_session():
    if _mospi["session"] is None:
        import ssl
        from requests.adapters import HTTPAdapter

        class _LegacyTLS(HTTPAdapter):
            def init_poolmanager(self, *a, **kw):
                ctx = ssl.create_default_context()
                ctx.options |= getattr(ssl, "OP_LEGACY_SERVER_CONNECT", 0x4)
                kw["ssl_context"] = ctx
                return super().init_poolmanager(*a, **kw)

        sess = requests.Session()
        sess.headers.update(BROWSER_UA)
        sess.mount("https://", _LegacyTLS())
        _mospi["session"] = sess
    return _mospi["session"]


def parse_mospi_cpi(pages):
    """Page payloads (newest first) -> the newest month's All-India General
    rows: {"period": "YYYY-MM", sector: {"index": f, "inflation": f}}."""
    target, out = None, {}
    for d in pages:
        for r in (d or {}).get("data") or []:
            if (r.get("state") != "All India" or r.get("group") != "General"
                    or r.get("subgroup") != "General-Overall"):
                continue
            mm = _MONTHS.get(r.get("month"))
            if not mm:
                continue
            period = f"{r['year']}-{mm:02d}"
            target = target or period
            if period != target:  # pages run newest-first; an older month = done
                continue
            try:
                out[r["sector"]] = {"index": float(r["index"]),
                                    "inflation": float(r["inflation"])}
            except (TypeError, ValueError):
                continue
    return ({"period": target, **out} if target and "Combined" in out else None)


def refresh_cpi(sb, now):
    sess = _legacy_tls_session()
    pages = []
    for page in range(1, MOSPI_PAGES + 1):
        r = sess.get(MOSPI_CPI_URL, params={"format": "json", "page": page}, timeout=TIMEOUT)
        r.raise_for_status()
        pages.append(r.json())
        parsed = parse_mospi_cpi(pages)
        if parsed and all(k in parsed for k in ("Combined", "Rural", "Urban")):
            break
    else:
        parsed = parse_mospi_cpi(pages)
    if not parsed:
        raise RuntimeError(f"MOSPI CPI: no All-India General row in {MOSPI_PAGES} pages")
    c = parsed["Combined"]
    # prev = the last stored month's inflation (bonds pattern: vs our own row)
    old = sb("GET", "quotes?select=price,meta&symbol=eq.MACRO:MOSPI_CPI")
    prev = None
    if old and ((old[0].get("meta") or {}).get("period")) != parsed["period"]:
        prev = old[0].get("price")
    elif old:
        prev = (old[0].get("meta") or {}).get("prev_inflation")
    meta = {"units": "%", "period": parsed["period"], "index": c["index"],
            "series": "MOSPI CPI (2012=100)", "prev_inflation": prev,
            "delta": round(c["inflation"] - prev, 2) if prev is not None else None,
            "rural": (parsed.get("Rural") or {}).get("inflation"),
            "urban": (parsed.get("Urban") or {}).get("inflation")}
    p = Parsed(c["inflation"], prev, None, f"{parsed['period']}-01T00:00:00+00:00", None)
    return upsert(sb, [row("MACRO:MOSPI_CPI", "macro", "India CPI inflation (MOSPI)",
                           p, now, currency="", meta=meta)])


# ---------- Wikidata entity aliases (worldmonitor leftover, 4 Sep 2026) ----------
# One SPARQL query pulls every company Wikidata knows to be NSE-listed
# (P414 exchange = Q638740 with a P249 ticker) plus its English altLabels —
# the alternate names ("Satluj Jal Vidyut Nigam" for SJVN) the AI card
# matcher misses today. New names merge into companies.aliases, which
# run.companies_index() already keys — zero matcher changes.

WIKIDATA_SPARQL = """SELECT ?ticker ?itemLabel (GROUP_CONCAT(DISTINCT ?alt; separator="|") AS ?alts)
WHERE { ?item p:P414 ?ex . ?ex ps:P414 wd:Q638740 . ?ex pq:P249 ?ticker .
  OPTIONAL { ?item skos:altLabel ?alt . FILTER(LANG(?alt)="en") }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". } }
GROUP BY ?ticker ?itemLabel"""
WIKIDATA_UA = {"User-Agent": "FinSwipe/1.0 (news pipeline; single daily query)"}


def parse_wikidata_aliases(payload):
    """SPARQL JSON bindings -> {TICKER: [name, alt, ...]} (raw, uncleaned)."""
    out = {}
    for b in ((payload or {}).get("results") or {}).get("bindings") or []:
        ticker = (b.get("ticker") or {}).get("value")
        if not ticker:
            continue
        names = [(b.get("itemLabel") or {}).get("value") or ""]
        names += ((b.get("alts") or {}).get("value") or "").split("|")
        out[ticker.upper()] = [n.strip() for n in names if n.strip()]
    return out


def refresh_wikidata(sb, now):
    r = requests.get("https://query.wikidata.org/sparql",
                     params={"query": WIKIDATA_SPARQL, "format": "json"},
                     headers=WIKIDATA_UA, timeout=60)
    r.raise_for_status()
    by_ticker = parse_wikidata_aliases(r.json())
    if not by_ticker:
        raise RuntimeError("Wikidata returned no NSE-listed companies — query or QID broke")
    patched = 0
    for c in sb("GET", "companies?select=id,name,nse_symbol,aliases&nse_symbol=not.is.null"):
        names = by_ticker.get(c["nse_symbol"].upper())
        if not names:
            continue
        have = {a.casefold() for a in c.get("aliases") or []}
        have |= {c["name"].casefold(), c["nse_symbol"].casefold()}
        new = [n.casefold() for n in dict.fromkeys(names)
               if n.casefold() not in have and 3 < len(n) < 80]
        if new:
            sb("PATCH", f"companies?id=eq.{c['id']}",
               json={"aliases": sorted(set(c.get("aliases") or []) | set(new))})
            patched += 1
    return patched


# ---------- Context layer (4 Sep 2026 night, worldmonitor residue) ----------
# BIS WS_CBPOL: one keyless CSV with the latest policy rate of every major
# central bank. TITLE cells contain commas, so it goes through csv, never split.

BIS_URL = ("https://stats.bis.org/api/v2/data/dataflow/BIS/WS_CBPOL/1.0/"
           "D.US+XM+JP+GB+CN+IN?lastNObservations=1&format=csv")
BIS_NAMES = {"US": "Fed funds", "XM": "ECB deposit", "JP": "BoJ policy",
             "GB": "BoE bank rate", "CN": "PBoC 1y LPR", "IN": "RBI repo"}


def parse_bis(text):
    """CSV -> {REF_AREA: {"name", "rate", "asof"}}; blank/odd values skipped."""
    out = {}
    for r in csv.DictReader(io.StringIO(text or "")):
        area = (r.get("REF_AREA") or "").strip()
        try:
            rate = float(r.get("OBS_VALUE") or "")
        except ValueError:
            continue
        if area in BIS_NAMES:
            out[area] = {"name": BIS_NAMES[area], "rate": rate, "asof": r.get("TIME_PERIOD")}
    return out


def refresh_cb_rates(sb, now):
    r = requests.get(BIS_URL, headers=BROWSER_UA, timeout=TIMEOUT)
    r.raise_for_status()
    rates = parse_bis(r.text)
    if not rates:
        raise RuntimeError("BIS CBPOL: no policy-rate rows")
    # asof = fetch date on purpose: the rates' own dates are months old (last
    # change), so a payload-date freshness budget would grade a healthy group
    # stale. Cost: one rewrite a day.
    return write_blobs(sb, [{"key": "cb_rates",
                             "payload": {"rates": rates, "asof": now.date().isoformat()},
                             "updated_at": now.isoformat()}])


# Macro release calendar: FRED's release/dates for the US prints (keyed, the
# same key refresh_macro uses); India from a rule (MOSPI: CPI+IIP on the 12th,
# GDP on the last working day of Feb/May/Aug/Nov - the MOSPI site is a JS SPA
# with no calendar endpoint) plus code-level RBI MPC dates. FOMC is a constant
# too: FRED release 101 answers every calendar day (no schedule; 4 Sep 2026).
# ponytail: refresh RBI_MPC each March and FOMC each December from the source.

FRED_RELEASE_URL = "https://api.stlouisfed.org/fred/release/dates"
FRED_RELEASES = {10: "US CPI", 46: "US PPI", 50: "US jobs report", 53: "US GDP", 54: "US PCE"}
FOMC = ("2026-09-16", "2026-10-28", "2026-12-09")                       # decision day
RBI_MPC = ("2026-04-08", "2026-06-05", "2026-08-05", "2026-10-07", "2026-12-04")  # FY27; Feb-2027 TBD
CAL_DAYS = 45


def _roll_fwd(d):
    while d.weekday() >= 5:
        d += timedelta(days=1)
    return d


def india_events(today):
    out = []
    for k in range(3):  # this month and the next two
        y, m0 = divmod(today.month - 1 + k, 12)
        y, m = today.year + y, m0 + 1
        out.append((_roll_fwd(_date(y, m, 12)), "India CPI + IIP (MOSPI)", "16:00 IST"))
        if m in (2, 5, 8, 11):
            last = _date(y + (m == 12), m % 12 + 1, 1) - timedelta(days=1)
            while last.weekday() >= 5:
                last -= timedelta(days=1)
            out.append((last, "India GDP, quarterly (MOSPI)", "16:00 IST"))
    out += [(_date.fromisoformat(d), "RBI MPC decision", "10:00 IST") for d in RBI_MPC]
    return [{"date": d.isoformat(), "name": n, "region": "IN", "time": t} for d, n, t in out]


def fred_release_dates(key, today):
    out = []
    for rid, name in FRED_RELEASES.items():
        try:
            r = requests.get(FRED_RELEASE_URL, headers=BROWSER_UA, timeout=TIMEOUT,
                             params={"release_id": rid, "api_key": key, "file_type": "json",
                                     "realtime_start": today.isoformat(),
                                     "realtime_end": (today + timedelta(days=60)).isoformat(),
                                     # "true": scheduled dates carry no data yet; with
                                     # "false" FRED only returns already-published ones
                                     "include_release_dates_with_no_data": "true",
                                     "sort_order": "asc"})
            r.raise_for_status()
            out += [{"date": x["date"], "name": name, "region": "US", "time": "08:30 ET"}
                    for x in r.json().get("release_dates") or []]
        except Exception as e:  # one dead release id never sinks the calendar
            print(f"MARKET calendar {rid}: {e}")
    return out


def refresh_calendar(sb, now):
    today = now.astimezone(IST).date()
    events = india_events(today)
    events += [{"date": d, "name": "FOMC decision", "region": "US", "time": "14:00 ET"} for d in FOMC]
    key = os.environ.get("FRED_API_KEY", "").split(",")[0].strip()
    if key:
        events += fred_release_dates(key, today)
    lo, hi = today.isoformat(), (today + timedelta(days=CAL_DAYS)).isoformat()
    events = sorted((e for e in events if lo <= e["date"] <= hi),
                    key=lambda e: (e["date"], e["region"], e["name"]))
    return write_blobs(sb, [{"key": "calendar",
                             "payload": {"events": events, "asof": today.isoformat()},
                             "updated_at": now.isoformat()}])


# NSE participant-wise F&O open interest (the Indian COT). A daily CSV on
# the archives host, which - unlike www.nseindia.com/api - answers from any IP,
# so this is its own local-runnable group, not an nse job. Published after
# close; no file on a holiday, so step back a few days.

POI_URL = "https://nsearchives.nseindia.com/content/nsccl/fao_participant_oi_{}.csv"
POI_COLS = {"Future Index Long": "fut_idx_long", "Future Index Short": "fut_idx_short",
            "Option Index Call Long": "opt_idx_call_long", "Option Index Put Long": "opt_idx_put_long",
            "Option Index Call Short": "opt_idx_call_short", "Option Index Put Short": "opt_idx_put_short",
            "Total Long Contracts": "total_long", "Total Short Contracts": "total_short"}
POI_BACK_DAYS = 5  # Fri file on a Mon + one holiday; Diwali week may raise once


def parse_participant_oi(text):
    """CSV (quoted title line, padded headers, TOTAL row) -> {Client|DII|FII|Pro: {...}}."""
    lines = (text or "").splitlines()
    out = {}
    for r in csv.DictReader(io.StringIO("\n".join(lines[1:]))):
        r = {(k or "").strip(): (v or "").strip() for k, v in r.items()}
        who = r.get("Client Type")
        if not who or who.upper() == "TOTAL":
            continue
        try:
            row = {v: int(r[k]) for k, v in POI_COLS.items()}
        except (KeyError, ValueError):
            continue
        row["net_fut_idx"] = row["fut_idx_long"] - row["fut_idx_short"]
        out[who] = row
    return out


def refresh_participant_oi(sb, now):
    day = now.astimezone(IST).date()
    for back in range(POI_BACK_DAYS):
        d = day - timedelta(days=back)
        r = requests.get(POI_URL.format(d.strftime("%d%m%Y")), headers=BROWSER_UA, timeout=TIMEOUT)
        rows = parse_participant_oi(r.text) if r.status_code == 200 else {}
        if rows:
            break
    else:
        raise RuntimeError(f"participant OI: no file in the last {POI_BACK_DAYS} days")
    date = d.isoformat()
    # day-over-day net index futures vs the last published blob (bonds pattern)
    old = sb("GET", "market_blobs?select=payload&key=eq.participant_oi")
    oldp = (old[0]["payload"] if old else {}) or {}
    for who, row in rows.items():
        p = (oldp.get("rows") or {}).get(who) or {}
        row["prev_net_fut_idx"] = (p.get("net_fut_idx") if oldp.get("date") != date
                                   else p.get("prev_net_fut_idx"))
    return write_blobs(sb, [{"key": "participant_oi", "payload": {"date": date, "rows": rows},
                             "updated_at": now.isoformat()}])


# IMF PortWatch (keyless ArcGIS): daily transits through the chokepoints that
# carry India's oil and exports, plus port calls at the big Indian ports. The
# source lags ~5 days, so the payload carries its own dates and ops budgets
# 10 days. Latest week vs the prior 30 days is the "is Hormuz quiet" number.

PORTWATCH = "https://services9.arcgis.com/weJ1QsnbMYJlCHdG/arcgis/rest/services/"
CHOKEPOINTS = {"chokepoint6": "Hormuz", "chokepoint1": "Suez", "chokepoint4": "Bab el-Mandeb",
               "chokepoint5": "Malacca", "chokepoint7": "Cape of Good Hope"}
PORTS = {"port776": "JNPT", "port777": "Mundra", "port540": "Kandla",
         "port1367": "Vizag", "port235": "Chennai"}


def _pw_query(layer, ids, fields, n):
    r = requests.get(PORTWATCH + layer + "/FeatureServer/0/query", headers=BROWSER_UA, timeout=TIMEOUT,
                     params={"where": "portid IN (" + ",".join(f"'{i}'" for i in ids) + ")",
                             "outFields": fields, "orderByFields": "date DESC",
                             "resultRecordCount": n, "f": "json"})
    r.raise_for_status()
    return [f.get("attributes") or {} for f in r.json().get("features") or []]


def _pw_date(v):
    """ArcGIS dates arrive as 'YYYY-MM-DD' strings or epoch ms; -> ISO date or None."""
    if isinstance(v, str):
        return v[:10] or None
    try:
        return datetime.fromtimestamp(v / 1000, tz=timezone.utc).date().isoformat()
    except (TypeError, ValueError):
        return None


def shape_shipping(chokes, ports):
    by = {}
    for a in chokes:
        if a.get("n_total") is not None:
            by.setdefault(a.get("portid"), []).append({**a, "date": _pw_date(a.get("date"))})
    out = []
    for pid, name in CHOKEPOINTS.items():
        rows = sorted(by.get(pid, []), key=lambda r: r["date"] or "", reverse=True)
        if not rows:
            continue
        recent, base = rows[:7], rows[7:37]
        avg7 = sum(r["n_total"] for r in recent) / len(recent)
        avg30 = sum(r["n_total"] for r in base) / len(base) if base else None
        out.append({"name": name, "date": rows[0]["date"], "n_total": rows[0]["n_total"],
                    "n_tanker": rows[0].get("n_tanker"), "avg7": round(avg7, 1),
                    "avg30": round(avg30, 1) if avg30 else None,
                    "pct": round((avg7 / avg30 - 1) * 100, 1) if avg30 else None})
    latest = {}
    for a in ports:
        pid, d = a.get("portid"), _pw_date(a.get("date")) or ""
        if pid in PORTS and d > (latest.get(pid) or {}).get("date", ""):
            latest[pid] = {"name": PORTS[pid], "date": d, "portcalls": a.get("portcalls"),
                           "import": a.get("import"), "export": a.get("export")}
    plist = sorted(latest.values(), key=lambda p: -(p["portcalls"] or 0))
    return out, plist


def refresh_shipping(sb, now):
    got = {}
    for label, args in (("chokepoints", ("Daily_Chokepoints_Data", CHOKEPOINTS, "date,portid,n_total,n_tanker", 200)),
                        ("ports", ("Daily_Ports_Data", PORTS, "date,portid,portcalls,import,export", 40))):
        try:
            got[label] = _pw_query(*args)
        except Exception as e:  # one dead layer: publish the other
            print(f"MARKET shipping {label}: {e}")
            got[label] = []
    chokes, plist = shape_shipping(got["chokepoints"], got["ports"])
    if not chokes and not plist:
        raise RuntimeError("PortWatch: no chokepoint or port rows")
    asof = max([c["date"] for c in chokes] + [p["date"] for p in plist])
    return write_blobs(sb, [{"key": "shipping",
                             "payload": {"chokepoints": chokes, "ports": plist, "asof": asof},
                             "updated_at": now.isoformat()}])


# IMD monsoon: the subdivision map page carries, in a JS array, the cumulative
# (since 1 June) rainfall departure for the country, 4 regions and 36
# subdivisions - the number FMCG/agri/rural desks quote. Keyless, plain TLS
# (probed 5 Sep 2026); IMD's JSON APIs need IP whitelisting, so the page it is.

IMD_URL = "https://mausam.imd.gov.in/responsive/rainfallinformation_msd.php"
# balloon is optional; [^{}] keeps the lazy match inside one map-area object
IMD_ROW = re.compile(r'"title":\s*"([^"]+)"[^{}]*?"info":\s*"([^"]*)"(?:[^{}]*?"balloonText":\s*"([^"]*)")?', re.S)
IMD_TOP = 5


def _imd_mm(balloon, label):
    m = re.search(label + r"\s*:\s*([\d.]+)\s*mm", balloon or "")
    return float(m.group(1)) if m else None


def parse_imd(html):
    """-> {"country", "regions", "worst", "best"} or None when no country row."""
    country, regions, subs = None, [], []
    for title, info, balloon in IMD_ROW.findall(html or ""):
        title = re.sub(r"\s+", " ", title).strip()
        m = re.search(r"(-?\d+)%", info or "")
        if not m:
            continue
        dep = int(m.group(1))
        if title.startswith("COUNTRY :"):
            country = {"dep_pct": dep, "actual_mm": _imd_mm(balloon, "Actual"),
                       "normal_mm": _imd_mm(balloon, "Normal")}
        elif title.startswith("REGION :"):
            regions.append({"name": title.split(":", 1)[1].strip().title(), "dep_pct": dep})
        else:
            subs.append({"name": title.title(), "dep_pct": dep})
    if not country:
        return None
    subs.sort(key=lambda s: s["dep_pct"])
    return {"country": country, "regions": regions,
            "worst": subs[:IMD_TOP], "best": subs[::-1][:IMD_TOP]}


def refresh_monsoon(sb, now):
    r = requests.get(IMD_URL, params={"msg": "C"}, headers=BROWSER_UA, timeout=TIMEOUT)
    r.raise_for_status()
    parsed = parse_imd(r.text)
    if not parsed:
        raise RuntimeError("IMD: no COUNTRY row on the subdivision page (layout changed?)")
    return write_blobs(sb, [{"key": "monsoon",
                             "payload": {**parsed, "asof": now.astimezone(IST).date().isoformat()},
                             "updated_at": now.isoformat()}])


# ---------- sentiment composites (P2, worldmonitor study) ----------
# Editorial scales, not empirical. methodology_version is bumped whenever a
# component, scale, or weighting changes so clients and history can tell
# versions apart. Equal weights over available components, renormalized when
# one is missing (an exchange holiday without VIX must not fake a score) —
# a score needs at least two real components or it is an anecdote.

FG_VERSION = 2  # v2 (2026-09-05): + pcr, fii_pos, nifty_gold
RISK_VERSION = 1


def _scale(x, lo, hi):
    """x -> 0..100 linearly, clamped; invert by passing lo > hi."""
    if x is None:
        return None
    t = (x - lo) / (hi - lo)
    return round(max(0.0, min(1.0, t)) * 100)


def _blend(comp, labels):
    comp = {k: v for k, v in comp.items() if v is not None}
    if len(comp) < 2:
        return None
    score = round(sum(comp.values()) / len(comp))
    label = next(l for cut, l in labels if score <= cut)
    return {"score": score, "label": label, "components": comp}


def _rel_return_pct(a, b):
    """1-window relative return of series a over series b, in %; None unless
    both carry >=10 real closes."""
    a = [c for c in a or [] if c]
    b = [c for c in b or [] if c]
    if len(a) < 10 or len(b) < 10 or not a[0] or not b[0]:
        return None
    return (a[-1] / a[0] - b[-1] / b[0]) * 100


def compute_fear_greed(q, flows, fno, poi=None):
    """q: symbol -> quotes row. 0 = extreme fear, 100 = extreme greed."""
    b = ((flows or {}).get("breadth") or {}).get("NIFTY 500") or {}
    adv, dec = b.get("adv"), b.get("dec")
    hi, lo = (fno or {}).get("hi52"), (fno or {}).get("lo52")
    n = q.get("^NSEI") or {}
    closes = [c for c in n.get("closes") or [] if c]
    mean = sum(closes) / len(closes) if len(closes) >= 10 else None
    # FII index-futures tilt, self-normalized to position size so contract-
    # count regime changes don't move the bounds.
    fii_row = ((poi or {}).get("rows") or {}).get("FII") or {}
    fl, fs = fii_row.get("fut_idx_long"), fii_row.get("fut_idx_short")
    fii_ratio = (fl - fs) / (fl + fs) if fl is not None and fs is not None and fl + fs else None
    comp = {
        "vix": _scale((q.get("^INDIAVIX") or {}).get("price"), 26, 10),  # calm=greed
        "breadth": round(adv / (adv + dec) * 100)
                   if adv is not None and dec is not None and adv + dec else None,
        "fii": _scale(((flows or {}).get("fii") or {}).get("net"), -3000, 3000),
        "hi_lo": round(hi / (hi + lo) * 100) if hi is not None and lo is not None and hi + lo else None,
        "momentum": _scale((n["price"] - mean) / mean * 100, -3, 3)
                    if mean and n.get("price") else None,
        # v2: heavy put writing = bullish conviction (Indian OI convention);
        # 0.7-1.5 is the observed NIFTY index-PCR band.
        "pcr": _scale((flows or {}).get("pcr"), 0.7, 1.5),
        "fii_pos": _scale(fii_ratio, -0.6, 0.6),
        # v2: risk appetite — equities outperforming gold over the window =
        # greed (the CNN stocks-vs-bonds analog with instruments we hold).
        "nifty_gold": _scale(_rel_return_pct(n.get("closes"),
                                             (q.get("GC=F") or {}).get("closes")),
                             -5, 5),
    }
    out = _blend(comp, ((24, "Extreme fear"), (44, "Fear"), (55, "Neutral"),
                        (75, "Greed"), (100, "Extreme greed")))
    return {**out, "methodology_version": FG_VERSION} if out else None


# Correlation matrix assets: symbol -> short display name. All six store
# ~22 daily closes (indices/fx/commodities); BTC is out until refresh_crypto
# attaches closes to the bitcoin row.
CORR_ASSETS = (("^NSEI", "NIFTY"), ("^GSPC", "S&P 500"), ("GC=F", "Gold"),
               ("USDINR=X", "USD/INR"), ("CL=F", "Crude"), ("DX-Y.NYB", "DXY"))


def compute_correlations(q):
    """Pairwise Pearson over daily pct-returns from quotes closes. Assets with
    <10 usable returns are dropped; needs >=2 assets or returns None.
    ponytail: closes arrays are date-less, so IN/US holiday offsets can skew a
    pair by <=1 day — upgrade path is storing dated closes."""
    series = {}
    for sym, name in CORR_ASSETS:
        closes = [c for c in (q.get(sym) or {}).get("closes") or [] if c]
        rets = [closes[i] / closes[i - 1] - 1 for i in range(1, len(closes))]
        if len(rets) >= 10:
            series[name] = rets
    if len(series) < 2:
        return None
    names = [name for _, name in CORR_ASSETS if name in series]
    matrix = []
    for a in names:
        row = []
        for b in names:
            if a == b:
                row.append(1.0)
                continue
            ra, rb = series[a], series[b]
            n = min(len(ra), len(rb))  # trim both to the common tail
            try:
                row.append(round(statistics.correlation(ra[-n:], rb[-n:]), 2))
            except statistics.StatisticsError:  # constant series
                row.append(None)
        matrix.append(row)
    return {"assets": names, "matrix": matrix,
            "window_d": min(len(v) for v in series.values())}


def compute_risk_index(q, flows, trending):
    """0 = calm, 100 = stressed: VIX, FII selling, INR weakening, breadth
    damage, high-confidence news spikes (signals.py trending blob)."""
    b = ((flows or {}).get("breadth") or {}).get("NIFTY 500") or {}
    adv, dec = b.get("adv"), b.get("dec")
    spikes = (trending or {}).get("spikes") or []
    comp = {
        "vix": _scale((q.get("^INDIAVIX") or {}).get("price"), 10, 26),
        "fii_outflow": _scale(((flows or {}).get("fii") or {}).get("net"), 3000, -3000),
        "inr": _scale((q.get("USDINR=X") or {}).get("change_pct"), -0.6, 0.6),
        "breadth": round(dec / (adv + dec) * 100)
                   if adv is not None and dec is not None and adv + dec else None,
        "news": _scale(sum(1 for s in spikes if s.get("confidence") == "high"), 0, 3),
    }
    out = _blend(comp, ((34, "Low"), (60, "Elevated"), (100, "High")))
    return {**out, "methodology_version": RISK_VERSION} if out else None


def market_summary_text(q, flows, fg, move_ctx):
    """One-line market summary, zero AI — a template over numbers already in
    the tables, so it survives a total model-lane outage."""
    bits = []
    for sym, name in (("^NSEI", "NIFTY"), ("^BSESN", "SENSEX")):
        r = q.get(sym) or {}
        if r.get("change_pct") is not None:
            bits.append(f"{name} {r['change_pct']:+.1f}%")
    parts = [", ".join(bits)] if bits else []
    fii = ((flows or {}).get("fii") or {}).get("net")
    dii = ((flows or {}).get("dii") or {}).get("net")
    if fii is not None and dii is not None:
        parts.append(f"FII {fii:+,.0f} cr / DII {dii:+,.0f} cr")
    ex = (move_ctx or {}).get("explained") or []
    if ex:
        m = max(ex, key=lambda e: abs(e.get("chg") or 0))
        parts.append(f"{m['symbol']} {m['chg']:+.1f}% on “{(m.get('title') or '')[:60]}”")
    if fg:
        parts.append(f"Mood: {fg['label'].lower()} ({fg['score']})")
    return " · ".join(parts)


def refresh_sentiment(sb, now):
    """Fear/greed, risk index, and the no-AI market summary — DB reads only,
    so it runs anywhere (never RUN_NOW-excluded). No computed_at in these
    payloads: they are DERIVED blobs whose inputs (flows, trending, quotes)
    already carry graded freshness, and a stable score must suppress its
    write (write_blobs) rather than heartbeat a new timestamp every hour."""
    q = {r["symbol"]: r for r in
         sb("GET", "quotes?select=symbol,price,change_pct,closes&kind=in.(index,fx,commodity)")}
    blobs = {r["key"]: r["payload"] for r in
             sb("GET", "market_blobs?select=key,payload&key=in.(flows,fno,trending,move_context,participant_oi)")}
    fg = compute_fear_greed(q, blobs.get("flows"), blobs.get("fno"),
                            blobs.get("participant_oi"))
    risk = compute_risk_index(q, blobs.get("flows"), blobs.get("trending"))
    text = market_summary_text(q, blobs.get("flows"), fg, blobs.get("move_context"))
    corr = compute_correlations(q)
    ts = now.isoformat()
    rows = ([{"key": "fear_greed", "payload": fg, "updated_at": ts}] if fg else []) + \
           ([{"key": "risk_index", "payload": risk, "updated_at": ts}] if risk else []) + \
           ([{"key": "market_summary", "payload": {"text": text}, "updated_at": ts}] if text else []) + \
           ([{"key": "correlation", "payload": corr, "updated_at": ts}] if corr else [])
    return write_blobs(sb, rows)


def refresh_nse_blobs(sb, now, session=None):
    known = {c["nse_symbol"] for c in sb("GET", "companies?select=nse_symbol") if c.get("nse_symbol")}
    s = session or nse_session()

    def get(path, **params):
        r = s.get(NSE_API + path, params=params, timeout=25)
        r.raise_for_status()
        if "json" not in r.headers.get("content-type", ""):
            raise RuntimeError(f"non-JSON {r.status_code}")
        return r.json()

    ist = now.astimezone(IST)

    def flows():
        out = {}
        try:
            out.update(parse_fiidii(get("fiidiiTradeReact")))
        except Exception as e:
            print(f"MARKET NSE fiidii: {e}")
        try:
            exp = nearest_expiry(get("option-chain-contract-info", symbol="NIFTY"))
            if exp:
                out.update(parse_option_chain(
                    get("option-chain-v3", type="Indices", symbol="NIFTY", expiry=exp), exp))
        except Exception as e:
            print(f"MARKET NSE pcr: {e}")
        try:  # raw rows: NIFTY 50 lives in the derivatives group, which
              # shape_indices filters out for the sector heatmap
            out["breadth"] = breadth((get("allIndices") or {}).get("data"))
        except Exception as e:
            print(f"MARKET NSE breadth: {e}")
        if not out:
            raise RuntimeError("all flow pieces failed")  # keep the old blob
        return out

    def ipos():
        cur = up = None
        try:
            cur = get("ipo-current-issue")
        except Exception as e:
            print(f"MARKET NSE ipo current: {e}")
        try:
            up = get("all-upcoming-issues", category="ipo")
        except Exception as e:
            print(f"MARKET NSE ipo upcoming: {e}")
        if cur is None and up is None:
            raise RuntimeError("both IPO endpoints failed")  # keep the old blob
        return shape_ipos(cur or {}, up or {})

    def fno():
        out = {}
        try:
            out.update(shape_oi_spurts(get("live-analysis-oi-spurts-underlyings")))
        except Exception as e:
            print(f"MARKET NSE fno oi: {e}")
        for side, idx in (("gainers", "gainers"), ("losers", "loosers")):  # NSE's spelling
            try:
                out[side] = shape_variations(get("live-analysis-variations", index=idx))
            except Exception as e:
                print(f"MARKET NSE fno {side}: {e}")
        for label, idx in (("hi52", "high"), ("lo52", "low")):
            try:
                out[label] = len(_rows(get("live-analysis-52Week", index=idx)))
            except Exception as e:
                print(f"MARKET NSE fno {label}: {e}")
        if not out:
            raise RuntimeError("all F&O pieces failed")  # keep the old blob
        return out

    jobs = {
        "results_calendar": lambda: results_calendar(
            get("event-calendar", index="equities"),
            get("corporate-board-meetings", index="equities"), known, now),
        "bulk_deals": lambda: shape_deals(get("snapshot-capital-market-largedeal")),
        "insider_trades": lambda: shape_insider(
            get("corporates-pit-gg", index="equities",
                from_date=(ist - timedelta(days=7)).strftime("%d-%m-%Y"),
                to_date=ist.strftime("%d-%m-%Y")), known,
            prev=next((r["payload"] for r in
                       sb("GET", "market_blobs?select=payload&key=eq.insider_trades")), None),
            fetch=lambda u: s.get(u, timeout=25).text),
        "nse_indices": lambda: shape_indices(get("allIndices")),
        "flows": flows,
        "ipos": ipos,
        "fno": fno,
    }
    rows = []
    for key, fn in jobs.items():
        try:
            rows.append({"key": key, "payload": fn(), "updated_at": now.isoformat()})
        except Exception as e:  # the old blob stays; the app shows its age
            print(f"MARKET NSE {key}: {e}")
    return write_blobs(sb, rows)


def refresh_deep_new(sb, now):
    import fundamentals  # local: fundamentals imports us, top-level would cycle
    return fundamentals.refresh_deep_new(sb, now)


def refresh_deep_warm(sb, now):
    import fundamentals
    return fundamentals.refresh_deep_warm(sb, now)


def refresh_screener(sb, now):
    import fundamentals
    return fundamentals.refresh_screener(sb, now)


def refresh_screener_px(sb, now):
    import fundamentals
    return fundamentals.refresh_screener_px(sb, now)


GROUPS = (("index", refresh_indices), ("equity", refresh_equities),
          ("fxcom", refresh_fxcom), ("crypto", refresh_crypto),
          ("global", refresh_global),
          ("mf", refresh_mf), ("mf_new", refresh_mf_new),
          ("analysis_new", refresh_analysis_new),
          ("worldmacro", refresh_worldmacro), ("hazards", refresh_hazards),
          ("wikidata", refresh_wikidata), ("cpi", refresh_cpi),
          ("polymarket", refresh_polymarket), ("cb_rates", refresh_cb_rates),
          ("calendar", refresh_calendar), ("participant_oi", refresh_participant_oi),
          ("shipping", refresh_shipping), ("monsoon", refresh_monsoon),
          ("fundamentals", refresh_fundamentals), ("technicals", refresh_technicals),
          ("macro", refresh_macro), ("nse", refresh_nse_blobs),
          ("bonds", refresh_bonds), ("sentiment", refresh_sentiment),
          ("deep_new", refresh_deep_new), ("deep_warm", refresh_deep_warm),
          ("screener", refresh_screener), ("screener_px", refresh_screener_px))


def refresh(sb, now=None):
    """Run every due group; one failing group never blocks another, and a
    failure waits out its interval like a success (no 45-second hammering).
    Every attempt lands in the app_config `market_status` row so the admin
    and the watchdog see per-group state instead of grepping stdout; a
    `groups_off` list on the pipeline config row disables single groups."""
    now = now or datetime.now(timezone.utc)
    if not _last_run:  # fresh process: rehydrate cadence from the status row,
        # or every DAILY_SLOT group re-fires on each ~5.5h CI boot (4-5x/day)
        try:
            rows = sb("GET", "app_config?select=value&key=eq.market_status")
            for g, st in (((rows[0]["value"] if rows else {}) or {}).get("groups") or {}).items():
                if st.get("ts"):
                    _last_run[g] = datetime.fromisoformat(st["ts"])
                    _status.setdefault(g, st)
        except Exception:
            pass  # first-ever run or unreadable row -> run everything, as before
    todo = [(g, fn) for g, fn in GROUPS if due(g, now)]
    if not todo:
        return {}
    off = set()
    try:
        rows = sb("GET", "app_config?select=value&key=eq.pipeline")
        off = set(((rows[0]["value"] if rows else {}) or {}).get("groups_off") or [])
    except Exception:
        pass  # config unreadable -> run everything, as before
    counts = {}
    for group, fn in todo:
        if group in off:  # _last_run untouched: re-enabling runs it promptly
            continue
        _last_run[group] = now
        prev = _status.get(group) or {}
        daily = group in DAILY_SLOT or group == "macro"
        try:
            counts[group] = fn(sb, now)
            _status[group] = {"ok": True, "ts": now.isoformat(), "ok_ts": now.isoformat(),
                              "err": None, "fails": 0, "daily": daily}
        except Exception as e:
            print(f"MARKET FAIL {group}: {e}")
            _status[group] = {"ok": False, "ts": now.isoformat(), "ok_ts": prev.get("ok_ts"),
                              "err": str(e)[:300], "fails": (prev.get("fails") or 0) + 1,
                              "daily": daily}
    try:
        import fundamentals  # local: it imports us
        upsert(sb, [{"key": "market_status",
                     "value": {"groups": _status, "fund": fundamentals.counters,
                               # deploy-drift: which commit this process runs (ops compares vs HEAD)
                               "sha": os.environ.get("GITHUB_SHA", "")[:12]},
                     "updated_at": now.isoformat()}], table="app_config", key="key")
    except Exception as e:
        print(f"MARKET status write: {e}")
    return counts
