"""One-time snapshot fixup after the Kaggle backfill: bring per-share history
to the CURRENT share basis and fill what the dataset lacked. Run LOCALLY:

    py -3 fixup_snapshot.py --dry-run   # preview (prints DRREDDY-style plans)
    py -3 fixup_snapshot.py             # do it (~30-40 min: one Yahoo call/symbol)

Per backfilled symbol, one Yahoo chart call (10y monthly + div/split events):
1. split-adjust kaggle rows' per-share fields (eps, book_value) for periods
   ending before each split — kills the post-Dec-2023 split distortion in
   P/E, P/B, EPS history and the np/eps share-count inference everywhere;
2. dividend history -> div_payout on annual rows missing it, latest-FY dps
   into the summary row (Yahoo per-share dividends are already split-adjusted,
   so the ratio against adjusted eps is basis-consistent);
   ponytail: dps buckets by PAYMENT date, so a year's payout mixes last
   year's final + this year's interim dividend — fine for a ratio;
3. compute_summary for EVERY symbol (12y CAGRs, pros/cons, price CAGR) —
   cold stocks get their strips without waiting for a deep fetch.
Idempotent: symbols whose summary row carries a `fixup` stamp are skipped.
Then rerun refresh_screener (main() does it) so screens pick everything up.
"""
import sys
import time
from datetime import date, datetime, timedelta, timezone

import requests

from fundamentals import compute_summary, fy_label
from market import BROWSER_UA, TIMEOUT, upsert

PER_SHARE = ("eps", "book_value")


def cum_split_factor(splits, end):
    """How many current shares one share of `end`-date vintage became: the
    product of ratios for splits strictly after that period end."""
    f = 1.0
    for ts, s in (splits or {}).items():
        if datetime.fromtimestamp(int(ts), tz=timezone.utc).date() > end:
            f *= s["numerator"] / s["denominator"]
    return f


def period_end(kind, period):
    """FY2023 -> 31 Mar 2023 (convention); '2023-09' -> last day of month."""
    if kind == "annual":
        return date(int(period[2:]), 3, 31)
    y, m = int(period[:4]), int(period[5:7])
    nxt = date(y + (m == 12), m % 12 + 1, 1)
    return nxt - timedelta(days=1)


def fy_dps(dividends):
    """{FY2024: total per-share dividend} bucketed by payment date's Indian FY."""
    out = {}
    for ts, d in (dividends or {}).items():
        dt = datetime.fromtimestamp(int(ts), tz=timezone.utc).date()
        fy = fy_label(dt.isoformat())
        out[fy] = round(out.get(fy, 0) + (d.get("amount") or 0), 2)
    return out


def adjust_rows(rows, splits):
    """Kaggle rows whose period predates a split get per-share fields divided
    by the cumulative factor; returns only the rows that changed."""
    out = []
    for r in rows:
        d = r["data"]
        if d.get("src") != "kaggle" or "split_adj" in d:
            continue
        f = cum_split_factor(splits, period_end(r["kind"], r["period"]))
        if f == 1.0 or not any(d.get(k) is not None for k in PER_SHARE):
            continue
        nd = dict(d)
        for k in PER_SHARE:
            if nd.get(k) is not None:
                nd[k] = round(nd[k] / f, 2)
        nd["split_adj"] = round(f, 4)
        out.append({**r, "data": nd})
    return out


def add_div_payout(rows, dps_by_fy):
    """Annual rows missing div_payout get dps/eps (post-adjustment eps)."""
    out = []
    for r in rows:
        d = r["data"]
        dps = dps_by_fy.get(r["period"])
        if (r["kind"] != "annual" or "div_payout" in d or not dps
                or not d.get("eps") or d["eps"] <= 0):
            continue
        out.append({**r, "data": {**d, "div_payout": round(dps / d["eps"] * 100, 1)}})
    return out


def fetch_chart_events(sym):
    r = requests.get(f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}.NS",
                     params={"range": "10y", "interval": "1mo", "events": "div,splits"},
                     headers=BROWSER_UA, timeout=TIMEOUT)
    r.raise_for_status()
    res = r.json()["chart"]["result"][0]
    ev = res.get("events") or {}
    closes = (res.get("indicators", {}).get("quote") or [{}])[0].get("close") or []
    return ev.get("splits") or {}, ev.get("dividends") or {}, closes


def main():
    dry = "--dry-run" in sys.argv
    from run import load_env, sb
    load_env()
    now = datetime.now(timezone.utc)
    ts = now.isoformat()

    print("reading fundamentals…")
    all_rows = sb("GET", "fundamentals?select=symbol,kind,period,data"
                         "&kind=in.(annual,quarter,summary)&order=symbol,period")
    per_sym = {}
    for r in all_rows:
        per_sym.setdefault(r["symbol"], []).append(r)
    todo = [s for s, rows in sorted(per_sym.items())
            if any(r["kind"] == "annual" and r["data"].get("src") == "kaggle" for r in rows)
            and not any(r["kind"] == "summary" and r["data"].get("fixup") for r in rows)]
    only = [a.split("=", 1)[1] for a in sys.argv if a.startswith("--only=")]
    if only:  # explicit re-request overrides the fixup stamp
        wanted = set(only[0].split(","))
        todo = [s for s in sorted(per_sym) if s in wanted
                and any(r["kind"] == "annual" and r["data"].get("src") == "kaggle"
                        for r in per_sym[s])]
    print(f"{len(per_sym)} symbols, {len(todo)} to fix up")

    writes, done = [], 0
    for sym in todo:
        rows = per_sym[sym]
        try:
            splits, divs, closes = fetch_chart_events(sym)
        except Exception as e:
            print(f"SKIP {sym}: chart {e}")
            continue
        adjusted = adjust_rows(rows, splits)
        adj_by_key = {(r["kind"], r["period"]): r["data"] for r in adjusted}
        merged = [{**r, "data": adj_by_key.get((r["kind"], r["period"]), r["data"])}
                  for r in rows]
        payout = add_div_payout([r for r in merged if r["kind"] == "annual"],
                                fy_dps(divs))
        pay_by_key = {(r["kind"], r["period"]): r["data"] for r in payout}
        merged = [{**r, "data": pay_by_key.get((r["kind"], r["period"]), r["data"])}
                  for r in merged]
        annuals = {r["period"]: r["data"] for r in merged if r["kind"] == "annual"}
        quarters = {r["period"]: r["data"] for r in merged if r["kind"] == "quarter"}
        old_summary = next((r["data"] for r in rows if r["kind"] == "summary"), {})
        summary = compute_summary(annuals, quarters, closes)
        dps = fy_dps(divs)
        latest_fy = max(dps) if dps else None
        if latest_fy:
            summary["dps"] = dps[latest_fy]
        for keep in ("shares", "dps_ttm"):  # reported values from the warm
            if old_summary.get(keep) is not None:
                summary[keep] = old_summary[keep]
        summary["fixup"] = ts
        # payout rows already carry the split adjustment (computed on merged),
        # so on PK overlap they win — and one upsert batch must not hit the
        # same PK twice (PostgREST rejects a double update).
        by_key = {(r["kind"], r["period"]): r for r in adjusted + payout}
        batch = list(by_key.values()) + [
            {"symbol": sym, "kind": "summary", "period": "latest", "data": summary}]
        for b in batch:
            b.update(symbol=sym, updated_at=ts)
        if dry and done < 5:
            print(f"\n{sym}: splits={list(splits and [s['numerator'] for s in splits.values()])}"
                  f" adjust={len(adjusted)} rows, payout+={len(payout)},"
                  f" pros={len(summary['pros'])} cons={len(summary['cons'])}")
            for r in adjusted[:3]:
                print("  ", r["kind"], r["period"], {k: r['data'].get(k) for k in ('eps', 'book_value', 'split_adj')})
        writes += batch
        done += 1
        if done % 100 == 0:
            print(f"  {done}/{len(todo)} ({len(writes)} rows queued)")
            if not dry:  # flush as we go — a crash resumes via the fixup stamp
                upsert(sb, writes, table="fundamentals", key="symbol,kind,period")
                writes = []
        time.sleep(0.4)
    if dry:
        print(f"\ndry run: {done} symbols would write ~{len(writes)} rows")
        return 0
    if writes:
        upsert(sb, writes, table="fundamentals", key="symbol,kind,period")
    print(f"fixed up {done} symbols; rebuilding screener_metrics…")
    import fundamentals
    print("screener rows:", fundamentals.refresh_screener(sb, now))
    return 0


if __name__ == "__main__":
    sys.exit(main())
