"""Mutual-fund screener data (free-parity P4, 26 Sep 2026): every Direct-Growth
scheme mfapi.in lists, reduced to one `mf_metrics` row (returns, CAGR,
volatility, Sharpe, drawdown, age) from its full NAV history. Two groups:
`mf_universe` weekly (the scheme list, new codes only) and `mf_drain` every
5 min off NSE hours (the stalest MF_DRAIN_CAP codes). Expense ratio and AUM
have no keyless per-scheme source (AMFI publishes TER per AMC as xls) —
ponytail: columns absent, footnoted in the app.

Run the checks: cd pipeline && py -3 -m pytest test_mf.py
"""
import math
import re
import statistics
import time
from datetime import date, datetime, timedelta

import requests

MF_LIST = "https://api.mfapi.in/mf"
MF_ONE = "https://api.mfapi.in/mf/{}"
MF_DRAIN_CAP = 150     # codes per 5-min lap; knob
MF_RF = 6.5            # risk-free % for Sharpe; knob
STALE_D = 7            # a row older than this is due
KEEP = re.compile(r"direct", re.I)
GROWTH = re.compile(r"growth", re.I)
DROP = re.compile(r"idcw|dividend|bonus|payout|reinvest", re.I)


def wanted(name):
    return bool(KEEP.search(name or "") and GROWTH.search(name or "") and not DROP.search(name or ""))


def split_category(cat):
    """'Equity Scheme - Large Cap Fund' -> ('Equity', 'Large Cap'); odd shapes
    keep the whole string as the category."""
    parts = [p.strip() for p in (cat or "").split(" - ", 1)]
    head = re.sub(r"\s*scheme$", "", parts[0], flags=re.I).strip() if parts else None
    sub = re.sub(r"\s*fund$", "", parts[1], flags=re.I).strip() if len(parts) > 1 else None
    return head or None, sub or None


def parse_navs(j):
    """mfapi data newest-first -> [(date, nav)] oldest-first, bad rows dropped."""
    out = []
    for d in j.get("data") or []:
        try:
            out.append((datetime.strptime(d["date"], "%d-%m-%Y").date(), float(d["nav"])))
        except (KeyError, ValueError, TypeError):
            continue
    out.sort()
    return [(d, v) for d, v in out if v > 0]


def _nav_at(navs, when):
    """The last NAV on or before `when` (None before the series starts)."""
    lo, hi = 0, len(navs)
    while lo < hi:
        mid = (lo + hi) // 2
        if navs[mid][0] <= when:
            lo = mid + 1
        else:
            hi = mid
    return navs[lo - 1][1] if lo else None


def mf_stats(navs, today, rf=MF_RF):
    """The mf_metrics numbers from an oldest-first [(date, nav)] series."""
    if len(navs) < 2:
        return {}
    last_d, last = navs[-1]

    def ret(days):
        base = _nav_at(navs, today - timedelta(days=days))
        return round((last / base - 1) * 100, 2) if base and navs[0][0] <= today - timedelta(days=days) else None

    def cagr(years):
        base = _nav_at(navs, today - timedelta(days=365 * years))
        if not base or navs[0][0] > today - timedelta(days=365 * years):
            return None
        return round(((last / base) ** (1 / years) - 1) * 100, 2)

    yr = [v for d, v in navs if d >= today - timedelta(days=365)]
    vol = sharpe = None
    if len(yr) > 30:
        rets = [math.log(b / a) for a, b in zip(yr, yr[1:]) if a > 0 and b > 0]
        if len(rets) > 2:
            vol = round(statistics.pstdev(rets) * math.sqrt(250) * 100, 2)
            r1 = ret(365)
            if vol and r1 is not None:
                sharpe = round((r1 - rf) / vol, 2)
    three = [v for d, v in navs if d >= today - timedelta(days=3 * 365)]
    mdd = None
    if len(three) > 30:
        peak, dd = three[0], 0.0
        for v in three:
            peak = max(peak, v)
            dd = min(dd, v / peak - 1)
        mdd = round(dd * 100, 2)
    return {"nav": round(last, 4), "nav_date": last_d.isoformat(),
            "ret_1m": ret(30), "ret_3m": ret(91), "ret_6m": ret(182), "ret_1y": ret(365),
            "ret_3y": ret(3 * 365), "ret_5y": ret(5 * 365),
            "cagr_3y": cagr(3), "cagr_5y": cagr(5), "vol_1y": vol, "sharpe_1y": sharpe, "mdd_3y": mdd,
            "age_y": round((last_d - navs[0][0]).days / 365, 1)}


def refresh_universe(sb, now):
    """Weekly: every listed scheme, Direct + Growth only; new codes get a
    name-only row the drain fills."""
    from market import upsert
    r = requests.get(MF_LIST, timeout=60)
    r.raise_for_status()
    have = {int(x["code"]) for x in sb("GET", "mf_metrics?select=code")}
    rows = [{"code": int(s["schemeCode"]), "name": s.get("schemeName")}
            for s in r.json() if wanted(s.get("schemeName")) and str(s.get("schemeCode", "")).isdigit()
            and int(s["schemeCode"]) not in have]
    return upsert(sb, rows, table="mf_metrics", key="code") if rows else 0


def refresh_drain(sb, now, cap=None):
    """Every 5 min off NSE hours: the stalest `cap` codes get their full NAV
    history reduced to one row."""
    from market import IST, market_hours, upsert
    if market_hours(now):
        return 0
    cap = cap or MF_DRAIN_CAP
    due = (now - timedelta(days=STALE_D)).isoformat()
    codes = [r["code"] for r in sb("GET", f"mf_metrics?select=code&or=(updated_at.is.null,updated_at.lt.{due})"
                                        f"&order=updated_at.asc.nullsfirst&limit={cap}")]
    today = now.astimezone(IST).date()
    rows = []
    for code in codes:
        try:
            r = requests.get(MF_ONE.format(code), timeout=30)
            if r.status_code == 429:
                print("MARKET mf drain: 429, backing off this lap")
                break
            r.raise_for_status()
            j = r.json()
            m = j.get("meta") or {}
            cat, sub = split_category(m.get("scheme_category"))
            stats = mf_stats(parse_navs(j), today)
            rows.append({"code": code, "name": m.get("scheme_name"), "house": m.get("fund_house"),
                         "category": cat, "sub_category": sub, **stats,
                         "updated_at": now.isoformat()})
        except Exception as e:  # noqa: BLE001 — one scheme never blocks the lap
            print(f"MARKET mf {code}: {e}")
            rows.append({"code": code, "updated_at": now.isoformat()})  # try again next week
        time.sleep(0.2)
    return upsert(sb, rows, table="mf_metrics", key="code") if rows else 0
