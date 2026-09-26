"""price_history (migration 032): the daily close series, filled for free from
the 1y chart the technicals pass already downloads per symbol per day.

One row per symbol, closes as a real[] aligned to the NSE trading calendar
(NULL where Yahoo had no print), ≤ MAX_CLOSES trailing days. Merges happen
inside the database (history_merge RPC) so the pipeline never reads the
arrays back — egress is the free tier's tightest budget. A symbol with no
row, a gap, or a re-adjusted series (split/bonus) gets one range=max pull.

Run the checks: cd pipeline && py -3 -m pytest test_history.py
"""
import time
from datetime import datetime, timedelta
from urllib.parse import quote

import requests

MAX_CLOSES = 1260      # ~5 trading years; ponytail: knob-free, trim in the RPC too
MAX_VOLS = 250
CALENDAR = ("^NSEI",)  # rows that also carry `dates` (the calendar behind every closes[])
CHART = "https://query1.finance.yahoo.com/v8/finance/chart/{}"
_missing_table = False  # 032 not applied yet: say so once, then stay quiet


def yahoo_symbol(sym):
    return sym if sym.startswith("^") else f"{sym}.NS"


def series_of(chart_json, tz):
    """Yahoo chart payload -> (dates, closes, vols); closes keep None so the
    positions stay aligned with the calendar."""
    res = chart_json["chart"]["result"][0]
    q = res["indicators"]["quote"][0]
    dates = [datetime.fromtimestamp(t, tz).date() for t in res.get("timestamp") or []]
    closes = list(q.get("close") or [])
    vols = list(q.get("volume") or [])
    n = min(len(dates), len(closes))
    return dates[:n], closes[:n], (vols + [None] * n)[:n]


def extremes(dates, closes):
    """(atl, atl_date, ath, ath_date) over the non-null closes; Nones when empty."""
    pts = [(c, d) for d, c in zip(dates, closes) if c is not None]
    if not pts:
        return None, None, None, None
    lo, hi = min(pts), max(pts)
    return lo[0], lo[1], hi[0], hi[1]


def full_row(sym, dates, closes, vols):
    """A complete price_history row from a range=max series (trailing window)."""
    atl, atl_d, ath, ath_d = extremes(dates, closes)
    row = {"symbol": sym, "asof": dates[-1].isoformat(),
           "closes": closes[-MAX_CLOSES:], "vols": vols[-MAX_VOLS:],
           "atl": atl, "atl_date": atl_d.isoformat() if atl_d else None,
           "ath": ath, "ath_date": ath_d.isoformat() if ath_d else None}
    if sym in CALENDAR:
        row["dates"] = [d.isoformat() for d in dates[-MAX_CLOSES:]]
    return row


def plan_merge(have, dates, closes, vols):
    """Existing row summary {asof, atl, ath} + a fresh 1y window -> ("refill", None)
    or ("merge", payload for history_merge). The payload replaces the stored
    tail that the window overlaps (k days) and appends the rest; atl/ath only
    when the window crosses them (the RPC keeps the old value on None)."""
    asof = datetime.strptime(have["asof"], "%Y-%m-%d").date()
    if not dates or dates[0] > asof:
        return "refill", None          # gap between the stored tail and the window
    k = sum(1 for d in dates if d <= asof)
    lo, lo_d, hi, hi_d = extremes(dates, closes)
    payload = {"symbol": have["symbol"], "k": k, "closes": closes, "vols": vols,
               "asof": dates[-1].isoformat(), "chk": closes[0],
               "atl": lo if lo is not None and (have.get("atl") is None or lo < have["atl"]) else None,
               "atl_date": lo_d.isoformat() if lo_d and (have.get("atl") is None or lo < have["atl"]) else None,
               "ath": hi if hi is not None and (have.get("ath") is None or hi > have["ath"]) else None,
               "ath_date": hi_d.isoformat() if hi_d and (have.get("ath") is None or hi > have["ath"]) else None}
    return "merge", payload


def fetch_max(sym, tz, headers, timeout):
    r = requests.get(CHART.format(yahoo_symbol(sym)), params={"range": "max", "interval": "1d"},
                     headers=headers, timeout=timeout)
    r.raise_for_status()
    return series_of(r.json(), tz)


def update(sb, series, tz, headers, timeout=20):
    """series = {symbol: (dates, closes, vols)} from this lap's 1y charts.
    Rows that exist are merged in the database; the rest (and any the RPC
    bounces) get a range=max pull. Returns rows written."""
    global _missing_table
    if not series or _missing_table:
        return 0
    syms = list(series)
    try:
        have = {r["symbol"]: r for r in sb(
            "GET", "price_history?select=symbol,asof,atl,ath&symbol=in.("
                   + ",".join(quote(s, safe="") for s in syms) + ")")}
    except requests.HTTPError as e:
        if "price_history" not in str(e):
            raise
        _missing_table = True   # same guard as user_symbols / price_alerts
        print("MARKET history: migration 032 not applied; skipping until restart")
        return 0
    refill, merges = [], []
    for s in syms:
        if s not in have:
            refill.append(s)
            continue
        verdict, payload = plan_merge(have[s], *series[s])
        (merges.append(payload) if verdict == "merge" else refill.append(s))
    if merges:
        bounced = sb("POST", "rpc/history_merge", json={"rows": merges}) or []
        refill.extend(x for x in bounced if x not in refill)
    rows = []
    for s in refill:
        try:
            dates, closes, vols = fetch_max(s, tz, headers, timeout)
            if dates:
                rows.append(full_row(s, dates, closes, vols))
        except Exception as e:  # noqa: BLE001 — one dead symbol never stalls the lap
            print(f"MARKET history {s}: {e}")
        time.sleep(0.3)
    if rows:
        from market import upsert
        upsert(sb, rows, table="price_history")
    if refill or merges:
        print(f"MARKET history: merged {len(merges)}, refilled {len(rows)}/{len(refill)}")
    return len(merges) + len(rows)


# ---------- 033: screener columns one 1y close series answers ----------
_nifty = {"at": 0.0, "closes": {}}


def nifty_closes(tz, headers, timeout=20):
    """{date: close} for ^NSEI over 1y, refetched every 6 h (one call per lap at most)."""
    if time.monotonic() - _nifty["at"] > 6 * 3600:
        try:
            r = requests.get(CHART.format("^NSEI"), params={"range": "1y", "interval": "1d"},
                             headers=headers, timeout=timeout)
            r.raise_for_status()
            d, c, _ = series_of(r.json(), tz)
            _nifty.update(at=time.monotonic(), closes={x: y for x, y in zip(d, c) if y is not None})
        except Exception as e:  # noqa: BLE001
            print(f"MARKET history nifty: {e}")
            _nifty["at"] = time.monotonic() - 5 * 3600  # retry in an hour, not every lap
    return _nifty["closes"]


def metrics_row(sym, dates, closes, nifty, macd_hist=None):
    """Volatility, drawdown, up-days, Nifty correlation, days since the 52w
    extremes. Every key always present (one PGRST102 bucket)."""
    import math
    import statistics

    pts = [(d, c) for d, c in zip(dates, closes) if c is not None]
    out = {"symbol": sym, "vol_30d": None, "vol_1y": None, "max_dd_1y": None, "up_days_pct_1y": None,
           "corr_nifty_1y": None, "days_since_hi52": None, "days_since_lo52": None, "macd_hist": macd_hist}
    if len(pts) < 20:
        return out
    rets = [(b[1] / a[1] - 1) for a, b in zip(pts, pts[1:]) if a[1]]
    ann = lambda xs: round(statistics.pstdev(xs) * math.sqrt(252) * 100, 1) if len(xs) > 2 else None  # noqa: E731
    out["vol_30d"], out["vol_1y"] = ann(rets[-30:]), ann(rets)
    peak, dd = pts[0][1], 0.0
    for _, c in pts:
        peak = max(peak, c)
        dd = min(dd, c / peak - 1)
    out["max_dd_1y"] = round(dd * 100, 1)
    out["up_days_pct_1y"] = round(sum(1 for x in rets if x > 0) / len(rets) * 100, 1) if rets else None
    hi = max(pts, key=lambda p: p[1])
    lo = min(pts, key=lambda p: p[1])
    out["days_since_hi52"], out["days_since_lo52"] = (pts[-1][0] - hi[0]).days, (pts[-1][0] - lo[0]).days
    if nifty:
        common = [(c, nifty[d]) for d, c in pts if d in nifty]
        if len(common) > 30:
            a = [b[0] / x[0] - 1 for x, b in zip(common, common[1:]) if x[0]]
            b = [b[1] / x[1] - 1 for x, b in zip(common, common[1:]) if x[0]]
            try:
                out["corr_nifty_1y"] = round(statistics.correlation(a, b), 2)
            except statistics.StatisticsError:
                pass
    return out


def metrics_rows(series, tech, tz, headers, signals=None):
    nifty = nifty_closes(tz, headers)
    return [{**metrics_row(s, d, c, nifty, (tech.get(s) or {}).get("macd_hist")),
             "signals": (signals or {}).get(s, [])}
            for s, (d, c, _) in series.items()]


def refresh_calendar(sb, tz, headers):
    """The ^NSEI row with `dates`: the trading calendar every equity row aligns
    to (and the backtests' benchmark). Called from the daily technicals pass."""
    if _missing_table:
        return 0
    from market import upsert
    rows = []
    for sym in CALENDAR:
        try:
            dates, closes, vols = fetch_max(sym, tz, headers, 20)
            if dates:
                rows.append(full_row(sym, dates, closes, vols))
        except Exception as e:  # noqa: BLE001
            print(f"MARKET history calendar {sym}: {e}")
    return upsert(sb, rows, table="price_history") if rows else 0
