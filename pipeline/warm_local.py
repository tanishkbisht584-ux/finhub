"""Local deep warm + the fundamentals-panel audit command.

    py -3 warm_local.py                  # Yahoo-only deep warm of the whole universe (~2 h / 3.2k)
    py -3 warm_local.py SYM1,SYM2        # just these
    py -3 warm_local.py audit            # rollup: % complete, gaps by code, the 30 worst (read-only)
    py -3 warm_local.py audit SYMBOL     # one stock, section by section, who fixes each gap
    py -3 warm_local.py audit --bootstrap  # one-off: verdicts for every symbol from the stored
                                           # rows (~12 MB read) without another Yahoo pass
    py -3 warm_local.py fix              # deep_fetch(nse=False) on Yahoo-fixable symbols, worst first

Warms are Yahoo-only: NSE blocks this machine, so shareholding/results/docs
gaps drain via CI's deep_warm (17:30 IST) and deep_new (5-min). Every pass
writes the symbol's fund_audit verdict into its summary row.
"""
import sys
from datetime import datetime, timezone

from run import load_env, sb

load_env()
import fund_audit  # noqa: E402
import fundamentals  # noqa: E402

CHUNK = 50


def warm(syms, now):
    print(f"warming {len(syms)} symbols (Yahoo only)…")
    done = 0
    for i in range(0, len(syms), CHUNK):
        chunk = syms[i:i + CHUNK]
        fundamentals.deep_fetch(sb, chunk, now, nse=False)
        done += len(chunk)
        print(f"  {done}/{len(syms)}", flush=True)
    print("rebuilding screener_metrics…")
    print("rows:", fundamentals.refresh_screener(sb, now))


def universe():
    return sorted({r["symbol"] for r in sb("GET", "screener_metrics?select=symbol&order=symbol")})


def audit_report(now):
    audits, ages, lrd = fundamentals.load_audits(sb)
    roll = fund_audit.rollup(((s, a, lrd.get(s)) for s, a in audits.items()), now)
    print(f"fundamentals panel: {roll['pct_complete']}% complete "
          f"({roll['complete']} of {roll['n']}; audited {roll['audited']})")
    print("gaps by code (fixable + stale):")
    for k, v in roll["by_code"].items():
        print(f"  {k:16s} {v:5d}  -> {fund_audit.FIXER.get(k, 'run a deep pass')}")
    if roll["unfixable"]:
        print("unfixable (no source carries it):", roll["unfixable"])
    if roll["issues"]:
        print("identity issues:", roll["issues"])
    print("worst:")
    for w in roll["worst"]:
        print(f"  {w['symbol']:12s} {w['deficit']:>7}  {', '.join(w['codes'])}")
    return audits, lrd


def audit_one(sym, now):
    rows = sb("GET", f"fundamentals?select=data,updated_at&kind=eq.summary&symbol=eq.{sym}")
    lrd = sb("GET", f"screener_metrics?select=lrd:sa->>lastReportDate&symbol=eq.{sym}")
    audit = (rows[0]["data"] or {}).get("audit") if rows else None
    for line in fund_audit.explain(sym, audit, now, (lrd[0].get("lrd") if lrd else None)):
        print(line)


def bootstrap(now):
    """Verdicts for every symbol from the rows already stored — one projected
    read of the table instead of a 2-hour Yahoo pass. basis_drop is unknown
    here (False); the next deep pass sets it."""
    fields = ("src", "sales", "net_profit", "eps", "expenses", "op_profit", "interest",
              "total_assets", "equity_cap", "reserves", "borrowings", "other_liab", "cfo", "fcf",
              "roe", "roce", "debtor_days")
    sel = ",".join(f"{f}:data->{f}" for f in fields)
    blank = {"annual": {}, "quarter": {}, "shp": {}, "docs_at": None, "summary": None}
    by = {}
    for kind in ("annual", "quarter"):
        for r in sb("GET", f"fundamentals?select=symbol,period,{sel}&kind=eq.{kind}&order=symbol,period"):
            d = {k: v for k, v in r.items() if k not in ("symbol", "period") and v is not None}
            by.setdefault(r["symbol"], {**blank, "annual": {}, "quarter": {}, "shp": {}})[kind][r["period"]] = d
    shp_sel = ",".join(f"{f}:data->{f}" for f in
                       ("promoters", "fiis", "diis", "govt", "public", "employee_trusts"))
    for r in sb("GET", f"fundamentals?select=symbol,period,{shp_sel}&kind=eq.shareholding&order=symbol,period"):
        d = {k: v for k, v in r.items() if k not in ("symbol", "period") and v is not None}
        by.setdefault(r["symbol"], {**blank, "annual": {}, "quarter": {}, "shp": {}})["shp"][r["period"]] = d
    for r in sb("GET", "fundamentals?select=symbol,updated_at&kind=eq.docs&order=symbol"):
        if r["symbol"] in by:
            by[r["symbol"]]["docs_at"] = r["updated_at"]
    for r in sb("GET", "fundamentals?select=symbol,data&kind=eq.summary&order=symbol"):
        if r["symbol"] in by:
            by[r["symbol"]]["summary"] = r["data"] or {}
    rows = []
    for sym, s in by.items():
        if s["summary"] is None:
            continue  # no summary row = never deep-fetched; the warm creates it
        audit = fund_audit.audit_symbol(s["annual"], s["quarter"], s["shp"], s["docs_at"], False, now,
                                        complete_q=fundamentals._complete_quarters(s["quarter"]))
        rows.append({"symbol": sym, "kind": "summary", "period": "latest",
                     "data": {**s["summary"], "audit": audit}, "updated_at": now.isoformat()})
    print(f"audited {len(rows)} symbols from stored rows; writing…")
    fundamentals.upsert(sb, rows, table="fundamentals", key="symbol,kind,period")
    audits, ages, lrd = fundamentals.load_audits(sb)
    print("rollup:", fundamentals.write_rollup(sb, audits, lrd, now)["pct_complete"], "% complete")


def fix(now):
    audits, lrd = audit_report(now)
    todo = []
    for sym, a in audits.items():
        d, codes = fund_audit.deficit(a, now, lrd.get(sym))
        if not a or any(fund_audit.FIXER.get(c) == "yahoo" for c in codes):
            todo.append((d, sym))
    todo = [s for _, s in sorted(todo, reverse=True)]
    print(f"\n{len(todo)} symbols have Yahoo-fixable gaps; NSE-only gaps wait for CI.")
    if todo:
        warm(todo, now)


def main():
    now = datetime.now(timezone.utc)
    args = sys.argv[1:]
    if args and args[0] == "audit":
        if len(args) > 1 and args[1] == "--bootstrap":
            bootstrap(now)
        elif len(args) > 1:
            audit_one(args[1].upper(), now)
        else:
            audit_report(now)
        return 0
    if args and args[0] == "fix":
        fix(now)
        return 0
    syms = universe()
    if args:
        only = set(args[0].split(","))
        syms = [s for s in syms if s in only]
    else:  # resume: a timeseries-sourced annual row marks a symbol done
        done = {r["symbol"] for r in
                sb("GET", "fundamentals?select=symbol&kind=eq.annual"
                          "&data->>src=eq.yahoo_ts&order=symbol")}
        syms = [s for s in syms if s not in done]
    warm(syms, now)
    return 0


if __name__ == "__main__":
    sys.exit(main())
