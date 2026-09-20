"""NSE end-of-day archives (Phase 4, 20 Sep 2026). www.nseindia.com/api/quote-*
refuses datacenter IPs (403 from a runner even with the quote-page cookies,
probe run 35464089563) and quote-derivative / corporate-actions are 404 —
but nsearchives.nseindia.com answers from anywhere. Two files per session:

  products/content/sec_bhavdata_full_DDMMYYYY.csv   every listed security:
      OHLC, AVG_PRICE (= VWAP), volume, turnover, trades, DELIV_QTY, DELIV_PER
  content/fo/BhavCopy_NSE_FO_0_0_0_YYYYMMDD_F_0000.csv.zip   every F&O contract:
      futures per expiry and options per strike with OI, ΔOI, volume, close

Both land on screener_metrics (migration 025): `tape` keeps the last TAPE_DAYS
sessions per symbol (MC's delivery block: today / yesterday / 1-week / 1-month
averages), `fno` the futures ladder and the nearest-expiry option chain around
the underlying. One pull a day at 19:30 IST; a 404 (holiday, not yet published)
is a no-op and the slot simply passes.
"""
import csv
import io
import zipfile
from datetime import date, timedelta

import requests

ARCH = "https://nsearchives.nseindia.com/"
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) FinSwipe/1.0"}
TAPE_DAYS = 22      # ~one trading month, the longest MC average
FNO_STRIKES = 6     # strikes each side of the underlying kept in the chain
FUT_TYPES = ("STF",)
OPT_TYPES = ("STO",)


def _f(v):
    try:
        return float(str(v).replace(",", "").strip())
    except (TypeError, ValueError):
        return None


def _i(v):
    f = _f(v)
    return int(f) if f is not None else None


def _clean(rows):
    return [{(k or "").strip(): (v or "").strip() for k, v in r.items()} for r in rows]


def fetch_full(day, session=requests):
    """sec_bhavdata_full rows for `day` (a date); None when not published."""
    r = session.get(ARCH + f"products/content/sec_bhavdata_full_{day:%d%m%Y}.csv", headers=UA, timeout=90)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return _clean(csv.DictReader(io.StringIO(r.text)))


def fetch_fo(day, session=requests):
    r = session.get(ARCH + f"content/fo/BhavCopy_NSE_FO_0_0_0_{day:%Y%m%d}_F_0000.csv.zip",
                    headers=UA, timeout=120)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    z = zipfile.ZipFile(io.BytesIO(r.content))
    with z.open(z.namelist()[0]) as fh:
        return _clean(csv.DictReader(io.TextIOWrapper(fh, encoding="utf-8")))


def tape_entry(row):
    """One session of one security from the full bhavcopy (EQ rows only)."""
    try:
        d = date(*[int(x) for x in _nse_date(row["DATE1"])])
    except (KeyError, ValueError, TypeError):
        return None
    turnover = _f(row.get("TURNOVER_LACS"))
    return {"date": d.isoformat(), "prev": _f(row.get("PREV_CLOSE")), "open": _f(row.get("OPEN_PRICE")),
            "high": _f(row.get("HIGH_PRICE")), "low": _f(row.get("LOW_PRICE")), "close": _f(row.get("CLOSE_PRICE")),
            "vwap": _f(row.get("AVG_PRICE")), "vol": _i(row.get("TTL_TRD_QNTY")),
            "turnover_cr": round(turnover / 100, 2) if turnover is not None else None,
            "trades": _i(row.get("NO_OF_TRADES")), "deliv_qty": _i(row.get("DELIV_QTY")),
            "deliv_pct": _f(row.get("DELIV_PER"))}


_MONTHS = {m: i for i, m in enumerate(("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"), 1)}


def _nse_date(s):
    """'18-Sep-2026' -> (2026, 9, 18)."""
    d, m, y = s.strip().split("-")
    return int(y), _MONTHS[m[:3].title()], int(d)


def merge_tape(prev, entry):
    """Newest first, one entry per date, capped at TAPE_DAYS."""
    old = [e for e in ((prev or {}).get("d") or []) if e.get("date") != entry["date"]]
    d = sorted([entry, *old], key=lambda e: e["date"], reverse=True)[:TAPE_DAYS]
    return {"asof": d[0]["date"], "d": d}


def fno_of(rows, day):
    """One underlying's F&O rows (already filtered) -> the stored fno dict, or
    None when it has no futures. Nearest expiry on/after `day` for options."""
    futs = sorted((r for r in rows if r.get("FinInstrmTp") in FUT_TYPES), key=lambda r: r.get("XpryDt", ""))
    if not futs:
        return None
    underlying = _f(futs[0].get("UndrlygPric"))
    futures = []
    for r in futs:
        # LastPric is what MC prints (2,095 for TCS Sep on 18 Sep); ClsPric is
        # the exchange's settlement-ish close (2,098.20). Last when it traded.
        close, prev = _f(r.get("LastPric")) or _f(r.get("ClsPric")), _f(r.get("PrvsClsgPric"))
        futures.append({"expiry": r.get("XpryDt"), "close": close, "prev": prev,
                        "chg_pct": round((close / prev - 1) * 100, 2) if close and prev else None,
                        "oi": _i(r.get("OpnIntrst")), "oi_chg": _i(r.get("ChngInOpnIntrst")),
                        "vol": _i(r.get("TtlTradgVol")), "lot": _i(r.get("NewBrdLotQty"))})
    out = {"asof": day.isoformat(), "underlying": underlying, "futures": futures}
    opts = [r for r in rows if r.get("FinInstrmTp") in OPT_TYPES and (r.get("XpryDt") or "") >= day.isoformat()]
    if not opts:
        return out
    expiry = min(r["XpryDt"] for r in opts)
    strikes = {}
    for r in opts:
        if r["XpryDt"] != expiry:
            continue
        k = _f(r.get("StrkPric"))
        side = (r.get("OptnTp") or "").lower()
        if k is None or side not in ("ce", "pe"):
            continue
        s = strikes.setdefault(k, {"strike": k})
        s[f"{side}_oi"] = _i(r.get("OpnIntrst"))
        s[f"{side}_oi_chg"] = _i(r.get("ChngInOpnIntrst"))
        s[f"{side}_ltp"] = _f(r.get("ClsPric"))
        s[f"{side}_vol"] = _i(r.get("TtlTradgVol"))
    if not strikes:
        return out
    ce_oi = sum(s.get("ce_oi") or 0 for s in strikes.values())
    pe_oi = sum(s.get("pe_oi") or 0 for s in strikes.values())
    ordered = sorted(strikes.values(), key=lambda s: s["strike"])
    at = next((i for i, s in enumerate(ordered) if underlying is not None and s["strike"] >= underlying), len(ordered))
    lo, hi = max(0, at - FNO_STRIKES), min(len(ordered), at + FNO_STRIKES)
    out.update({
        "expiry": expiry, "ce_oi": ce_oi, "pe_oi": pe_oi,
        "pcr": round(pe_oi / ce_oi, 2) if ce_oi else None,
        "max_ce": max(strikes.values(), key=lambda s: s.get("ce_oi") or 0)["strike"],
        "max_pe": max(strikes.values(), key=lambda s: s.get("pe_oi") or 0)["strike"],
        "chain": ordered[lo:hi],
    })
    return out


def tape_rows(full, existing):
    """screener_metrics rows {symbol, tape} for EQ rows of symbols we know."""
    out = []
    for r in full or []:
        if r.get("SERIES") != "EQ" or r.get("SYMBOL") not in existing:
            continue
        e = tape_entry(r)
        if e:
            out.append({"symbol": r["SYMBOL"], "tape": merge_tape(existing[r["SYMBOL"]], e)})
    return out


def fno_rows(fo, day, known):
    by = {}
    for r in fo or []:
        if r.get("FinInstrmTp") in FUT_TYPES + OPT_TYPES and r.get("TckrSymb") in known:
            by.setdefault(r["TckrSymb"], []).append(r)
    out = []
    for sym, rows in by.items():
        f = fno_of(rows, day)
        if f:
            out.append({"symbol": sym, "fno": f})
    return out


def refresh_bhav(sb, now, day=None, session=requests):
    """Daily group: the session `day` (default: today IST). Weekend or not
    published yet -> 0 and the slot passes."""
    from market import IST, upsert
    day = day or now.astimezone(IST).date()
    if day.weekday() >= 5:
        return 0
    full = fetch_full(day, session)
    if full is None:
        print(f"BHAV {day}: not published")
        return 0
    existing = {r["symbol"]: r.get("tape") for r in sb("GET", "screener_metrics?select=symbol,tape")}
    n = upsert(sb, tape_rows(full, existing), table="screener_metrics", key="symbol")
    fo = fetch_fo(day, session)
    if fo is not None:
        n += upsert(sb, fno_rows(fo, day, set(existing)), table="screener_metrics", key="symbol")
    return n


def backfill(sb, now, days=TAPE_DAYS + 8):
    """Oldest-first walk over the last `days` calendar days so merge_tape ends
    newest-first with a full window. Local one-off; F&O only for the last day."""
    from market import IST
    today = now.astimezone(IST).date()
    from market import upsert
    total, last = 0, None
    for back in range(days, -1, -1):
        d = today - timedelta(days=back)
        if d.weekday() >= 5:
            continue
        full = fetch_full(d)
        if full is None:
            continue
        existing = {r["symbol"]: r.get("tape") for r in sb("GET", "screener_metrics?select=symbol,tape")}
        rows = tape_rows(full, existing)
        total += upsert(sb, rows, table="screener_metrics", key="symbol")
        print(f"BHAV backfill {d}: {len(rows)} symbols")
        last = (d, set(existing))
    if last:  # F&O only for the last session: the chain is a snapshot, not a history
        fo = fetch_fo(last[0])
        if fo is not None:
            total += upsert(sb, fno_rows(fo, last[0], last[1]), table="screener_metrics", key="symbol")
    return total


if __name__ == "__main__":  # local bootstrap: python bhav.py
    import os
    from datetime import datetime, timezone
    for line in open(".env", encoding="utf-8"):
        if "=" in line and not line.startswith("#"):
            k, v = line.strip().split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())
    from run import sb
    print("rows", backfill(sb, datetime.now(timezone.utc)))
