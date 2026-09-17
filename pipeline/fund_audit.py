"""fund_audit (2026-09-15): the owner of the fundamentals panel. Pure — given
one symbol's rows exactly as deep_fetch already holds them, it says which
page sections are complete, which gaps are fixable and by whom, and which
numbers fail an identity check. deep_fetch writes the verdict into the
summary row (data.audit) on every pass, so it costs no extra read and can
never disagree with the data; refresh_deep_warm turns the stored verdicts
into a per-symbol deficit (the time-dependent parts — staleness — are
recomputed at read time) that orders the warm, plus a rollup in the
app_config `fund_audit` row for Health and the admin Coverage tab.

Thresholds were measured on the live table on 15 Sep 2026: the balance-sheet
identity at 2% fails ~1% of rows (sharp); the P&L identity must accept the
lender form (interest booked as a cost); quarters-vs-annual at 15% flags a
standalone/consolidated mix.
"""
from datetime import datetime, timedelta

# what the page renders (app/lib/screens/stock_sections.dart row lists)
ANNUAL_BS = ("total_assets", "equity_cap", "reserves", "borrowings")
ANNUAL_CF = ("cfo", "fcf")
QUARTER_FIELDS = ("sales", "net_profit", "eps")
SHP_SPLIT = ("fiis", "diis")

NEWEST_FY = 4      # the FYs a stock must carry in full
MIN_FY = 4         # fewer annual periods than this = short history
NEWEST_Q = 4       # quarters that must be complete (op_profit included)
MIN_Q = 8          # fewer quarters = short history
NEWEST_SHP = 4     # shareholding periods that must carry the FII/DII split
Q_MAX_AGE_D = 135  # SEBI's 45-day filing window + slack
Q_LAG_D = 100      # newest quarter this far behind SA's lastReportDate = a filing we lack
SHP_MAX_AGE_D = 120
DOCS_MAX_AGE_D = 30
BS_TOL, PNL_TOL, QA_TOL = 0.02, 0.02, 0.15
INF = 10 ** 6      # never audited: sorts first

# gap code -> who can fill it: yahoo (any machine), nse (CI only)
FIXER = {"annual.short": "yahoo", "bs.missing": "yahoo", "cf.missing": "yahoo",
         "ratios.missing": "yahoo", "q.short": "nse", "q.op_profit": "nse", "q.stale": "yahoo",
         "shp.missing": "nse", "shp.split": "nse", "shp.stale": "nse",
         "docs.missing": "nse", "docs.stale": "nse"}


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _close(a, b, tol, base=None):
    base = abs(base if base is not None else b)
    return abs(a - b) <= tol * base if base else abs(a - b) <= tol


def pnl_identity_ok(d):
    """sales ≈ expenses + op_profit, or the lender form with interest as a
    cost. For yahoo_ts/nse rows expenses is derived so this is a tautology;
    it bites on kaggle rows. None when the row lacks the parts."""
    s, e, op = _num(d.get("sales")), _num(d.get("expenses")), _num(d.get("op_profit"))
    if s is None or e is None or op is None:
        return None
    if _close(e + op, s, PNL_TOL):
        return True
    i = _num(d.get("interest"))
    return i is not None and _close(e + op + i, s, PNL_TOL)


def is_lender_row(d):
    """A period shaped like Screener's bank layout: the identity holds only
    with interest as a cost."""
    s, e, op, i = (_num(d.get("sales")), _num(d.get("expenses")), _num(d.get("op_profit")),
                   _num(d.get("interest")))
    if None in (s, e, op, i) or not i:
        return False
    return not _close(e + op, s, PNL_TOL) and _close(e + op + i, s, PNL_TOL)


def bs_identity_ok(d):
    total = _num(d.get("total_assets"))
    if not total:
        return None
    parts = [_num(d.get(k)) for k in ("equity_cap", "reserves", "borrowings", "other_liab")]
    if all(p is None for p in parts):
        return None
    return _close(sum(p or 0 for p in parts), total, BS_TOL)


def _no_net_worth(d):
    """The sheet is present and equity + reserves is not positive."""
    eq, res = _num(d.get("equity_cap")), _num(d.get("reserves"))
    return (eq is not None or res is not None) and (eq or 0) + (res or 0) <= 0


def fy_of_quarter(period):
    """'2026-06' -> 'FY2027' (Indian FY ends March)."""
    y, m = int(period[:4]), int(period[5:7])
    return f"FY{y if m <= 3 else y + 1}"


def period_end(period):
    """'2026-06' -> last day of that month; 'FY2026' -> 31 Mar 2026."""
    if period.startswith("FY"):
        return datetime(int(period[2:]), 3, 31)
    y, m = int(period[:4]), int(period[5:7])
    return datetime(y + (m == 12), (m % 12) + 1, 1) - timedelta(days=1)


def audit_symbol(annuals, quarters, shareholding, docs_at, basis_drop, now, complete_q=None):
    """One stock's verdict. `annuals`/`quarters`/`shareholding` are the
    merged {period: data} dicts deep_fetch feeds compute_summary; `docs_at`
    the docs row's updated_at (None = an NSE pass never ran); `basis_drop`
    whether this pass rejected Yahoo's statements; `complete_q` the periods
    fundamentals._complete_quarters accepts (the NSE filler's own predicate,
    so auditor and filler agree). Time-dependent checks live in deficit()."""
    complete_q = set(complete_q or ())
    missing, unfixable, issues = [], [], []
    fys = sorted(annuals, reverse=True)
    newest = fys[:NEWEST_FY]
    yahoo_fys = [p for p in fys if (annuals[p].get("src") or "").startswith("yahoo_ts")]
    nse_only = basis_drop and not yahoo_fys
    # a listing younger than 4 FYs, fully served by Yahoo: no source holds
    # more annual or quarterly history than this
    young = bool(yahoo_fys) and len(fys) < MIN_FY and len(yahoo_fys) == len(fys)

    def gap(code, periods=None, fixable=True):
        missing.append(code)
        if not fixable:
            unfixable.append(code)

    if len(fys) < MIN_FY:
        gap("annual.short", fixable=not young)
    if newest and any(annuals[p].get("total_assets") is None for p in newest):
        gap("bs.missing", fixable=not nse_only)
    if newest and any(annuals[p].get("cfo") is None for p in newest):
        gap("cf.missing", fixable=not nse_only)
    if newest:
        lender = any(is_lender_row(annuals[p]) for p in newest)
        need = ("roe",) if lender else ("roe", "roce")
        # a period whose sheet shows no positive net worth has no ROE/ROCE
        # anywhere (Screener shows a blank too), so it is not a gap
        if any(annuals[p].get(k) is None for p in newest for k in need
               if not _no_net_worth(annuals[p])):
            gap("ratios.missing", fixable=not nse_only)
    qs = sorted(quarters, reverse=True)
    if len(qs) < MIN_Q:
        gap("q.short", fixable=not young)
    for p in qs[:NEWEST_Q]:
        d = quarters[p]
        if p not in complete_q or any(d.get(k) is None for k in QUARTER_FIELDS):
            gap("q.op_profit")
            break
    shp = sorted(shareholding, reverse=True)
    if not shp:
        gap("shp.missing")
    elif any(shareholding[p].get(k) is None for p in shp[:NEWEST_SHP] for k in SHP_SPLIT):
        gap("shp.split")
    if not docs_at:
        gap("docs.missing")

    for p in newest:
        ok = bs_identity_ok(annuals[p])
        if ok is False:
            issues.append({"code": "bs_identity", "period": p})
    for p in list(newest) + qs[:NEWEST_Q]:
        d = annuals.get(p) or quarters.get(p) or {}
        if pnl_identity_ok(d) is False:
            issues.append({"code": "pnl_identity", "period": p})
        if (_num(d.get("sales")) or 0) < 0:
            issues.append({"code": "neg_sales", "period": p})
    by_fy = {}
    for p in qs:
        s = _num(quarters[p].get("sales"))
        if s is not None:
            by_fy.setdefault(fy_of_quarter(p), []).append(s)
    for fy, vals in by_fy.items():
        a = _num((annuals.get(fy) or {}).get("sales"))
        if len(vals) == 4 and a and not _close(sum(vals), a, QA_TOL):
            issues.append({"code": "q_vs_annual", "period": fy})
    for p in shp[:NEWEST_SHP]:
        d = shareholding[p]
        tot = sum(_num(d.get(k)) or 0 for k in
                  ("promoters", "fiis", "diis", "govt", "public", "employee_trusts"))
        if d.get("fiis") is not None and not 97 <= tot <= 103:
            issues.append({"code": "shp_sum", "period": p})

    return {"missing": missing, "unfixable": unfixable, "issues": issues,
            "newest_fy": fys[0] if fys else None, "newest_q": qs[0] if qs else None,
            "shp_newest": shp[0] if shp else None,
            "docs_at": docs_at, "at": now.isoformat()}


def stale_codes(audit, now, lrd=None):
    """Time-dependent gaps, recomputed whenever the audit is read: a newest
    quarter older than SA's lastReportDate - Q_LAG_D means a filing exists
    that we lack (precise), else the flat Q_MAX_AGE_D rule."""
    out = []
    now = now.replace(tzinfo=None) if now.tzinfo else now
    lrd_d = None
    if lrd:
        try:
            lrd_d = datetime.fromisoformat(str(lrd)[:10])
        except ValueError:
            lrd_d = None
    if lrd_d and lrd_d > now:
        lrd_d = None
    q = audit.get("newest_q")
    if q:
        end = period_end(q)
        if lrd_d:
            if end < lrd_d - timedelta(days=Q_LAG_D):
                out.append("q.stale")
        elif end < now - timedelta(days=Q_MAX_AGE_D):
            out.append("q.stale")
    s = audit.get("shp_newest")
    if s:  # shareholding lands with (before) the quarter's results: same rule
        end = period_end(s)
        if lrd_d:
            if end < lrd_d - timedelta(days=Q_LAG_D):
                out.append("shp.stale")
        elif end < now - timedelta(days=SHP_MAX_AGE_D):
            out.append("shp.stale")
    d = audit.get("docs_at")
    if d:
        try:
            at = datetime.fromisoformat(str(d).replace("Z", "+00:00")).replace(tzinfo=None)
            if at < now - timedelta(days=DOCS_MAX_AGE_D):
                out.append("docs.stale")
        except ValueError:
            pass
    return out


def deficit(audit, now, lrd=None):
    """(fixable gap count, gap codes) — INF for a never-audited symbol so it
    sorts first in the warm."""
    if not audit:
        return INF, ["never_audited"]
    stale = stale_codes(audit, now, lrd)
    fixable = [c for c in audit.get("missing", []) if c not in set(audit.get("unfixable", []))]
    return len(fixable) + len(stale), fixable + stale


def rollup(items, now, prev_pct=None, worst_n=30):
    """items: iterable of (symbol, audit-or-None, lrd). The Health/admin
    summary: share of symbols with zero fixable deficit, counts per gap code,
    unfixable and issue counts, the worst symbols."""
    n = audited = complete = 0
    by_code, unfix, issues, scored = {}, {}, {}, []
    for sym, audit, lrd in items:
        n += 1
        d, codes = deficit(audit, now, lrd)
        if audit:
            audited += 1
            for c in audit.get("unfixable", []):
                unfix[c] = unfix.get(c, 0) + 1
            for i in audit.get("issues", []):
                issues[i["code"]] = issues.get(i["code"], 0) + 1
        for c in codes:
            by_code[c] = by_code.get(c, 0) + 1
        if d == 0:
            complete += 1
        scored.append((d, sym, codes))
    scored.sort(key=lambda t: (-t[0], t[1]))
    pct = round(complete * 100 / n, 1) if n else 0.0
    return {"n": n, "audited": audited, "complete": complete, "pct_complete": pct,
            "prev_pct": prev_pct, "by_code": dict(sorted(by_code.items())),
            "unfixable": dict(sorted(unfix.items())), "issues": dict(sorted(issues.items())),
            "worst": [{"symbol": s, "deficit": d, "codes": c} for d, s, c in scored[:worst_n]
                      if d > 0],
            "at": now.isoformat()}


def explain(symbol, audit, now, lrd=None):
    """Lines for `warm_local.py audit SYMBOL`: every section, its state, and
    who fixes it."""
    if not audit:
        return [f"{symbol}: never audited — run a deep pass (warm_local.py {symbol})"]
    d, codes = deficit(audit, now, lrd)
    lines = [f"{symbol}: deficit {d} · newest FY {audit.get('newest_fy')} · newest quarter "
             f"{audit.get('newest_q')} · shareholding {audit.get('shp_newest')} · docs "
             f"{(audit.get('docs_at') or 'never')[:10]} · audited {audit.get('at', '')[:16]}"]
    if not codes and not audit.get("issues"):
        lines.append("  complete: every section the page renders has its data")
    unfix = set(audit.get("unfixable", []))
    for c in codes:
        who = "unfixable" if c in unfix else {"yahoo": "Yahoo (this machine or CI)",
                                              "nse": "NSE filings (CI only)"}.get(FIXER.get(c), "?")
        lines.append(f"  gap   {c:16s} -> {who}")
    for c in unfix:
        if c not in codes:
            lines.append(f"  gap   {c:16s} -> unfixable (no source carries it)")
    for i in audit.get("issues", []):
        lines.append(f"  issue {i['code']:16s} {i.get('period', '')}")
    return lines
