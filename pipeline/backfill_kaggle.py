"""One-time 10-year statement backfill from a public dataset CSV into the
`fundamentals` table (annual rows, src='kaggle'). Run LOCALLY, never in CI:

    py -3 backfill_kaggle.py --inspect data.csv   # see the columns first
    (edit COLUMN_MAP below to match)
    py -3 backfill_kaggle.py data.csv             # validate + write
    py -3 backfill_kaggle.py data.csv --force     # write despite divergences

Needs pipeline/.env (SUPABASE_URL + SUPABASE_SERVICE_KEY). Safe by design:
existing (symbol, period) rows are never overwritten (Yahoo wins), and the
write aborts if >20% of Yahoo-overlap years diverge >20% on sales/net profit.
Bad import later? `delete from fundamentals where data->>'src' = 'kaggle'`.
"""
import csv
import re
import sys
from datetime import datetime, timezone

# Our annual-row field -> CSV column header. Defaults guess the Screener-style
# headings the Kaggle "Detailed Financials" datasets use; --inspect and edit.
COLUMN_MAP = {
    "symbol": "Symbol", "year": "Year",
    "sales": "Sales", "expenses": "Expenses", "op_profit": "Operating Profit",
    "opm": "OPM %", "other_income": "Other Income", "interest": "Interest",
    "depreciation": "Depreciation", "pbt": "Profit before tax",
    "tax_pct": "Tax %", "net_profit": "Net Profit", "eps": "EPS in Rs",
    "div_payout": "Dividend Payout %",
    "equity_cap": "Equity Capital", "reserves": "Reserves",
    "borrowings": "Borrowings", "other_liab": "Other Liabilities",
    "fixed_assets": "Fixed Assets", "cwip": "CWIP",
    "investments": "Investments", "other_assets": "Other Assets",
    "cfo": "Cash from Operating Activity",
    "cfi": "Cash from Investing Activity",
    "cff": "Cash from Financing Activity", "net_cf": "Net Cash Flow",
    "debtor_days": "Debtor Days", "inventory_days": "Inventory Days",
    "payable_days": "Days Payable", "wc_days": "Working Capital Days",
    "roce": "ROCE %", "roe": "ROE %",
}

DIVERGE_PCT = 20   # a single overlap-year check fails past this
ABORT_FRACTION = 0.2  # and this share of failing checks aborts the run


def parse_num(v):
    if v is None:
        return None
    s = str(v).replace(",", "").replace("%", "").replace("₹", "").strip()
    if not s or s in ("-", "--", "NA", "nan"):
        return None
    try:
        f = float(s)
    except ValueError:
        return None
    return int(f) if f == int(f) else f


def fy_from(year):
    m = re.search(r"(\d{4})", str(year or ""))
    return f"FY{m.group(1)}" if m else None


def map_row(row, column_map=None):
    """CSV row -> (symbol, 'FY2016', data) or None when unkeyable."""
    cm = column_map or COLUMN_MAP
    sym = (row.get(cm["symbol"]) or "").strip().upper()
    period = fy_from(row.get(cm["year"]))
    if not sym or not period:
        return None
    data = {}
    for field, col in cm.items():
        if field in ("symbol", "year"):
            continue
        v = parse_num(row.get(col))
        if v is not None:
            data[field] = v
    return sym, period, data


def validate_overlap(kaggle, yahoo):
    """[(key, field, kaggle_v, yahoo_v)...] where overlap years diverge more
    than DIVERGE_PCT on sales/net_profit, plus how many checks ran."""
    bad, checked = [], 0
    for key, kd in kaggle.items():
        yd = yahoo.get(key)
        if not yd:
            continue
        checked += 1
        for field in ("sales", "net_profit"):
            kv, yv = kd.get(field), yd.get(field)
            if kv and yv and abs(kv - yv) / max(abs(yv), 1) * 100 > DIVERGE_PCT:
                bad.append((key, field, kv, yv))
                break
    return bad, checked


def rows_to_write(kaggle, existing_keys, ts):
    return [{"symbol": s, "kind": "annual", "period": p,
             "data": {**d, "src": "kaggle"}, "updated_at": ts}
            for (s, p), d in kaggle.items() if (s, p) not in existing_keys and d]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 1
    path = args[0]
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        if "--inspect" in sys.argv:
            print("columns:", reader.fieldnames)
            for i, row in enumerate(reader):
                print(row)
                if i >= 2:
                    break
            return 0
        raw = list(reader)

    from run import load_env, sb  # heavy import kept out of --inspect/tests
    load_env()
    known = {c["nse_symbol"] for c in sb("GET", "companies?select=nse_symbol")
             if c.get("nse_symbol")}
    kaggle, skipped = {}, 0
    for row in raw:
        m = map_row(row)
        if not m or m[0] not in known:
            skipped += 1
            continue
        sym, period, data = m
        kaggle.setdefault((sym, period), {}).update(data)
    print(f"parsed {len(kaggle)} symbol-years ({skipped} rows skipped/unknown)")

    existing = sb("GET", "fundamentals?select=symbol,period,data&kind=eq.annual")
    yahoo = {(r["symbol"], r["period"]): r["data"] for r in existing
             if (r.get("data") or {}).get("src") != "kaggle"}
    bad, checked = validate_overlap(kaggle, yahoo)
    print(f"validated against {checked} Yahoo overlap years; {len(bad)} diverge >{DIVERGE_PCT}%")
    for key, field, kv, yv in bad[:20]:
        print(f"  {key} {field}: kaggle {kv} vs yahoo {yv}")
    if checked and len(bad) / checked > ABORT_FRACTION and "--force" not in sys.argv:
        print("ABORT: too many divergences — check COLUMN_MAP/units, or --force")
        return 1

    from market import upsert
    rows = rows_to_write(kaggle, set(yahoo), datetime.now(timezone.utc).isoformat())
    print(f"writing {len(rows)} annual rows (existing periods untouched)…")
    upsert(sb, rows, table="fundamentals", key="symbol,kind,period")
    print("done — deep_warm recomputes summaries on its next daily pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
