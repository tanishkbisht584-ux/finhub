"""Backtests (free-parity P5, 26 Sep 2026): every saved screen (and the six
presets) replayed as an equal-weight, monthly-rebalanced basket of its top-20
matches over the last 36 months of price_history, against Nifty. Honest
about what it is: today's constituents, today's metrics — survivorship and
lookahead by construction, said so in the result and on screen.
ponytail: point-in-time selection needs dated fundamentals per rebalance
date (quarter rows exist for pe/sales/profit/opm/roe); not built until asked.

Run the checks: cd pipeline && py -3 -m pytest test_backtest.py
"""
from datetime import date, datetime, timedelta
from urllib.parse import quote

N = 20              # names per basket
MONTHS = 36
COST = 0.001        # 0.1 % a month for the rebalance churn
ZERO = "00000000-0000-0000-0000-000000000000"
PRESETS = {  # mirrors app/lib/screens/screens.dart screenPresets
    "VALUE": ([("pe", False, 15), ("roe", True, 15), ("de", False, 0.5), ("mcap_cr", True, 500)], "pe", True),
    "COMPOUNDERS": ([("roe", True, 20), ("roce", True, 20), ("profit_cagr_5y", True, 15), ("de", False, 0.3)],
                    "profit_cagr_5y", False),
    "DIVIDEND": ([("div_yield", True, 3), ("roe", True, 12), ("de", False, 1)], "div_yield", False),
    "GROWTH": ([("sales_cagr_3y", True, 15), ("profit_cagr_3y", True, 20), ("pe", False, 30)], "profit_cagr_3y", False),
    "DEBT-FREE SMALLCAP": ([("de", False, 0.1), ("mcap_cr", True, 300), ("mcap_cr", False, 5000), ("roe", True, 15)],
                           "roe", False),
    "PROMOTER HEAVY": ([("promoter_pct", True, 60), ("roe", True, 15), ("pe", False, 25)], "mcap_cr", False),
}


def month_starts(dates, months):
    """The first trading date of each of the last `months` months (+ the last date)."""
    if not dates:
        return []
    firsts, seen = [], set()
    for d in dates:
        key = (d.year, d.month)
        if key not in seen:
            seen.add(key)
            firsts.append(d)
    out = firsts[-months - 1:]
    if dates[-1] not in out:
        out.append(dates[-1])
    return out


def simulate(closes_by_sym, nifty, months=MONTHS, cost=COST):
    """closes_by_sym {sym: {date: close}}, nifty {date: close} -> the result
    dict. Monthly steps: the basket is reset to equal weight at each month's
    first trading day, so a month's return is the mean of the members' returns
    (members without both prints sit out that month)."""
    dates = sorted(nifty)
    steps = month_starts(dates, months)
    if len(steps) < 3:
        return None
    curve, ncurve, wins = [100.0], [100.0], 0
    for a, b in zip(steps, steps[1:]):
        rets = [c[b] / c[a] - 1 for c in closes_by_sym.values() if c.get(a) and c.get(b)]
        r = (sum(rets) / len(rets) - cost) if rets else 0.0
        nr = nifty[b] / nifty[a] - 1
        curve.append(round(curve[-1] * (1 + r), 2))
        ncurve.append(round(ncurve[-1] * (1 + nr), 2))
        wins += r > nr
    years = (steps[-1] - steps[0]).days / 365
    peak, mdd = curve[0], 0.0
    for v in curve:
        peak = max(peak, v)
        mdd = min(mdd, v / peak - 1)
    npeak, nmdd = ncurve[0], 0.0
    for v in ncurve:
        npeak = max(npeak, v)
        nmdd = min(nmdd, v / npeak - 1)
    return {"curve": curve, "nifty": ncurve,
            "cagr": round(((curve[-1] / 100) ** (1 / years) - 1) * 100, 1) if years > 0 else None,
            "nifty_cagr": round(((ncurve[-1] / 100) ** (1 / years) - 1) * 100, 1) if years > 0 else None,
            "mdd": round(mdd * 100, 1), "nifty_mdd": round(nmdd * 100, 1),
            "hit_rate": round(wins / (len(steps) - 1) * 100), "n": len(closes_by_sym),
            "from": steps[0].isoformat(), "to": steps[-1].isoformat(),
            "dates": [d.isoformat() for d in steps], "lookahead": True}


def _series(row, calendar):
    """price_history row -> {date: close} aligned to the calendar's tail."""
    closes = row.get("closes") or []
    asof = date.fromisoformat(row["asof"])
    tail = [d for d in calendar if d <= asof][-len(closes):]
    return {d: c for d, c in zip(tail, closes[-len(tail):]) if c is not None}


def matches(sb, filters, sort_col, asc):
    q = "&".join(f"{m}={'gte' if gte else 'lte'}.{v}" for m, gte, v in filters)
    rows = sb("GET", f"screener_metrics?select=symbol&board=eq.MAIN&{sort_col}=not.is.null&{q}"
                     f"&order={sort_col}.{'asc' if asc else 'desc'}&limit={N}")
    return [r["symbol"] for r in rows]


def refresh(sb, now):
    """Sunday 23:00 IST: presets + every saved equity screen."""
    from market import IST, upsert
    if now.astimezone(IST).weekday() != 6:
        return 0
    cal = next(iter(sb("GET", "price_history?select=asof,closes,dates&symbol=eq.%5ENSEI")), None)
    if not cal or not cal.get("dates"):
        print("BACKTEST: no ^NSEI calendar row yet")
        return 0
    calendar = [date.fromisoformat(d) for d in cal["dates"]]
    nifty = {d: c for d, c in zip(calendar, cal["closes"]) if c is not None}
    screens = [(ZERO, name, f, s, a) for name, (f, s, a) in PRESETS.items()]
    for r in sb("GET", "user_screens?select=user_id,name,filters,sort_col,sort_asc"):
        if str(r["name"]).startswith("MF:"):
            continue
        f = [(x["metric"], bool(x["gte"]), x["value"]) for x in (r.get("filters") or [])]
        if f:
            screens.append((r["user_id"], r["name"], f, r.get("sort_col") or "mcap_cr", bool(r.get("sort_asc"))))
    out = []
    for uid, name, f, sort_col, asc in screens:
        try:
            syms = matches(sb, f, sort_col, asc)
            res = None
            if syms:
                vals = ",".join(quote(s, safe="") for s in syms)
                rows = sb("GET", f"price_history?select=symbol,asof,closes&symbol=in.({vals})")
                res = simulate({r["symbol"]: _series(r, calendar) for r in rows}, nifty)
                if res:
                    res["symbols"] = syms
            out.append({"user_id": uid, "name": name, "params": {"filters": [list(x) for x in f], "sort_col": sort_col,
                                                                 "asc": asc, "n": N, "months": MONTHS},
                        "result": res, "computed_at": now.isoformat()})
        except Exception as e:  # noqa: BLE001 — one bad screen never blocks the rest
            print(f"BACKTEST {name}: {e}")
    if out:
        for i in range(0, len(out), 50):
            sb("POST", "backtests?on_conflict=user_id,name", json=out[i:i + 50],
               headers={"Prefer": "resolution=merge-duplicates,return=minimal"})
    print(f"BACKTEST: {len(out)} screens")
    return len(out)
