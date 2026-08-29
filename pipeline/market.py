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
import os
import re
import time
from collections import namedtuple
from datetime import datetime, timedelta, timezone
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

INDICES = {"^NSEI": "NIFTY 50", "^BSESN": "SENSEX", "^NSEBANK": "NIFTY Bank", "^CNXIT": "NIFTY IT"}
FX = {"USDINR=X": "USD/INR", "EURINR=X": "EUR/INR", "GBPINR=X": "GBP/INR", "JPYINR=X": "JPY/INR"}
COMMODITIES = {"GC=F": "Gold (USD/oz)", "SI=F": "Silver (USD/oz)", "CL=F": "Crude WTI (USD/bbl)"}
CRYPTO = {"bitcoin": "Bitcoin", "ethereum": "Ethereum", "solana": "Solana"}

# Direct-Growth scheme codes verified against mfapi.in/mf/search on 2026-08-22.
# Names come from the API (shortened); these are the board everyone sees,
# followed schemes are added on top.
DEFAULT_MF = (120716, 119063, 143341, 122639, 118955, 118825, 120586, 125497,
              118778, 120828, 118968, 119788, 120503, 135781, 119835)

# FRED series (free key). India coverage on FRED is thin; 3-4 series is the
# honest set. Any id that 400s is skipped, not faked.
MACRO_SERIES = {"FEDFUNDS": ("US Fed funds rate", "%"),
                "DGS10": ("US 10Y Treasury yield", "%"),
                "INDCPIALLMINMEI": ("India CPI (OECD, 2015=100)", "index"),
                "DEXINUS": ("USD/INR (Fed H.10)", "INR")}

KINDS = {"equity", "index", "fx", "crypto", "commodity", "mf", "macro"}  # mirrors 011 CHECK

Parsed = namedtuple("Parsed", "price prev change_pct as_of closes")


# ---------- cadence ----------

_last_run = {}  # group -> utc datetime of the last attempt (success or not)

MARKET_OPEN, MARKET_LAST_PASS = (9, 15), (15, 45)  # NSE 09:15-15:30 + one post-close pass
INTERVAL = {"fxcom": 15, "crypto": 15, "nse": 60, "bonds": 60, "macro": 24 * 60,
            "mf_new": 5, "analysis_new": 5, "deep_new": 5, "screener_px": 60}


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
              "deep_warm": (17, 30), "screener": (18, 0)}


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


# ---------- phase 1 groups ----------

def refresh_indices(sb, now):
    data = fetch_spark(list(INDICES), rng="1mo")  # ~22 closes for the sparkline
    rows = [row(s, "index", n, p, now, closes=True)
            for s, n in INDICES.items() if (p := parse_spark(data.get(s, {})))]
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
    for sid, (name, units) in MACRO_SERIES.items():
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


# India G-Sec yields off Stooq's keyless daily-history CSV.
# ponytail: Stooq only; if it drops these symbols, FRED INDIRLTLT01STM exists
# but is monthly — decide then whether stale beats absent.
STOOQ_BONDS = (("10Y", "10yiny.b"), ("5Y", "5yiny.b"), ("2Y", "2yiny.b"))


def parse_stooq_csv(text):
    """Date,Open,High,Low,Close(,Volume) history -> (last, prev, date) closes."""
    closes = []
    for line in (text or "").strip().splitlines()[1:]:
        parts = line.split(",")
        if len(parts) >= 5:
            try:
                closes.append((parts[0], float(parts[4])))
            except ValueError:
                continue
    if not closes:
        return None
    (date, last), prev = closes[-1], (closes[-2][1] if len(closes) > 1 else None)
    return last, prev, date


def refresh_bonds(sb, now):
    yields = []
    for tenor, sym in STOOQ_BONDS:
        try:
            r = requests.get("https://stooq.com/q/d/l/", params={"s": sym, "i": "d"},
                             headers=BROWSER_UA, timeout=TIMEOUT)
            r.raise_for_status()
            parsed = parse_stooq_csv(r.text)
        except Exception as e:
            print(f"MARKET bonds {sym}: {e}")
            continue
        if not parsed:
            continue
        y, prev, date = parsed
        yields.append({"tenor": tenor, "yield": y, "prev": prev, "date": date,
                       "chg_bp": round((y - prev) * 100, 1) if prev is not None else None})
    if not yields:
        return 0  # old blob stays; never had one -> no BONDS section
    return upsert(sb, [{"key": "bonds", "payload": {"yields": yields},
                        "updated_at": now.isoformat()}], table="market_blobs", key="key")


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
    return upsert(sb, rows, table="market_blobs", key="key")


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
          ("mf", refresh_mf), ("mf_new", refresh_mf_new),
          ("analysis_new", refresh_analysis_new),
          ("fundamentals", refresh_fundamentals), ("technicals", refresh_technicals),
          ("macro", refresh_macro), ("nse", refresh_nse_blobs),
          ("bonds", refresh_bonds),
          ("deep_new", refresh_deep_new), ("deep_warm", refresh_deep_warm),
          ("screener", refresh_screener), ("screener_px", refresh_screener_px))


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
