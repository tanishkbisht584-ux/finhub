"""One-time deep-history backfill from the Kaggle "Detailed Financials Data Of
4456 NSE & BSE Company" folder dump (Screener-shaped, snapshot ~Dec 2023) into
the `fundamentals` table: ~12y annual rows, ~13 quarter rows, and quarterly
shareholding WITH the FII/DII split, per company. Run LOCALLY, never in CI:

    py -3 backfill_kaggle.py "C:\\...\\archive"            # validate + write
    py -3 backfill_kaggle.py "C:\\...\\archive" --dry-run  # parse + validate only
    py -3 backfill_kaggle.py "C:\\...\\archive" --force    # write despite divergences

Layout expected under the folder (recursively): one dir per company holding
<name>_Basic_Info.csv (the NSE column keys the symbol), Yearly_Profit_Loss.csv,
Yearly_Balance_Sheet.csv, Yearly_Cash_flow.csv, Ratios.csv,
Quarterly_Profit_Loss.csv, Quarterly_Shareholding_Pattern.csv,
Yearly_Shareholding_Pattern.csv — all transposed (rows = metrics, cols =
periods).

Safe by design: existing (symbol, kind, period) rows are never overwritten
(Yahoo/NSE win, and later pipeline passes overwrite kaggle rows for periods
they cover), and the write aborts if >20% of Yahoo-overlap years diverge >20%
on sales/net profit. Bad import later?
`delete from fundamentals where data->>'src' = 'kaggle'` (annual/quarter);
shareholding rows carry no src — delete by updated_at if ever needed.
"""
import csv
import io
import pathlib
import re
import sys
from collections import Counter
from datetime import datetime, timezone

# CSV row label -> our fundamentals field (pipeline/fundamentals.py shapes).
# Skipped on purpose: Total Liabilities (== Total Assets on these sheets),
# Cash Conversion Cycle (derivable), Employee Trusts (absent here).
ROW_LABELS = {
    "Sales": "sales", "Expenses": "expenses", "Operating Profit": "op_profit",
    "OPM %": "opm", "Other Income": "other_income", "Interest": "interest",
    "Depreciation": "depreciation", "Profit before tax": "pbt", "Tax %": "tax_pct",
    "Net Profit": "net_profit", "EPS in Rs": "eps", "Dividend Payout %": "div_payout",
    "Equity Capital": "equity_cap", "Reserves": "reserves", "Borrowings": "borrowings",
    "Other Liabilities": "other_liab", "Fixed Assets": "fixed_assets", "CWIP": "cwip",
    "Investments": "investments", "Other Assets": "other_assets",
    "Total Assets": "total_assets",
    "Cash from Operating Activity": "cfo", "Cash from Investing Activity": "cfi",
    "Cash from Financing Activity": "cff", "Net Cash Flow": "net_cf",
    "Debtor Days": "debtor_days", "Inventory Days": "inventory_days",
    "Days Payable": "payable_days", "Working Capital Days": "wc_days",
    "ROCE %": "roce",
    "Promoters": "promoters", "FIIs": "fiis", "DIIs": "diis",
    "Government": "govt", "Public": "public", "No. of Shareholders": "n_holders",
}

ANNUAL_FILES = ("Yearly_Profit_Loss.csv", "Yearly_Balance_Sheet.csv",
                "Yearly_Cash_flow.csv", "Ratios.csv")
DIVERGE_PCT = 20      # a single overlap-year check fails past this
ABORT_FRACTION = 0.2  # and this share of failing checks aborts the run

MONTHS = {m: i + 1 for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"])}


def parse_num(v):
    if v is None:
        return None
    s = str(v).replace(",", "").replace("%", "").replace("\u20b9", "").strip()
    if not s or s in ("-", "--", "NA", "nan"):
        return None
    try:
        f = float(s)
    except ValueError:
        return None
    return int(f) if f == int(f) else f


def _ym(col):
    """(year, month) from '2023-03-01' or 'Mar 2023'; None otherwise."""
    m = re.match(r"(\d{4})-(\d{2})", str(col or "").strip())
    if m:
        return int(m.group(1)), int(m.group(2))
    m = re.match(r"([A-Z][a-z]{2})\w* (\d{4})", str(col or "").strip())
    if m and m.group(1) in MONTHS:
        return int(m.group(2)), MONTHS[m.group(1)]
    return None


def fy_of(col):
    """Indian FY the period-end falls in: Mar 2023 -> FY2023, Dec 2023 -> FY2024."""
    ym = _ym(col)
    if not ym:
        return None
    y, m = ym
    return f"FY{y if m <= 3 else y + 1}"


def quarter_of(col):
    ym = _ym(col)
    return f"{ym[0]}-{ym[1]:02d}" if ym else None


def parse_transposed(text, annual):
    """Transposed CSV -> {period: {field: value}}. Annual files keep only
    columns in the dominant month (drops the stray half-year column) and
    label periods FY....; others label YYYY-MM. TTM/unparseable columns and
    unmapped row labels are skipped."""
    rows = list(csv.reader(io.StringIO(text)))
    if not rows:
        return {}
    cols = rows[0][1:]
    keep = [i for i, c in enumerate(cols) if _ym(c)]
    if annual and keep:
        dominant = Counter(_ym(cols[i])[1] for i in keep).most_common(1)[0][0]
        keep = [i for i in keep if _ym(cols[i])[1] == dominant]
    out = {}
    for row in rows[1:]:
        field = ROW_LABELS.get((row[0] or "").strip())
        if not field:
            continue
        for i in keep:
            period = fy_of(cols[i]) if annual else quarter_of(cols[i])
            if period and i + 1 < len(row):
                v = parse_num(row[i + 1])
                if v is not None:
                    out.setdefault(period, {})[field] = v
    return out


def load_company(dirpath):
    """(nse_symbol, {(kind, period): data}) for one company folder; symbol is
    None for BSE-only companies (skipped by the caller)."""
    d = pathlib.Path(dirpath)
    info = next(iter(d.glob("*_Basic_Info.csv")), None)
    if not info:
        return None, {}
    with open(info, newline="", encoding="utf-8-sig") as f:
        row = next(iter(csv.DictReader(f)), {})
    sym = (row.get("NSE") or "").strip().upper()
    if not sym:
        return None, {}
    items = {}
    for name in ANNUAL_FILES:
        p = d / name
        if p.exists():
            for period, data in parse_transposed(
                    p.read_text(encoding="utf-8-sig"), annual=True).items():
                items.setdefault(("annual", period), {}).update(data)
    p = d / "Quarterly_Profit_Loss.csv"
    if p.exists():
        for period, data in parse_transposed(
                p.read_text(encoding="utf-8-sig"), annual=False).items():
            items[("quarter", period)] = data
    # yearly SHP first (older years), quarterly wins on overlapping periods
    for name in ("Yearly_Shareholding_Pattern.csv", "Quarterly_Shareholding_Pattern.csv"):
        p = d / name
        if p.exists():
            for period, data in parse_transposed(
                    p.read_text(encoding="utf-8-sig"), annual=False).items():
                items.setdefault(("shareholding", period), {}).update(data)
    return sym, items


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


def rows_to_write(items, existing_keys, ts):
    """items {(sym, kind, period): data} -> upsert rows; existing keys and
    empty data skipped; annual/quarter rows tagged src=kaggle (shareholding
    matches the untagged pipeline shape)."""
    rows = []
    for (sym, kind, period), data in items.items():
        if not data or (sym, kind, period) in existing_keys:
            continue
        rows.append({"symbol": sym, "kind": kind, "period": period,
                     "data": {**data, "src": "kaggle"} if kind in ("annual", "quarter") else data,
                     "updated_at": ts})
    return rows


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 1
    root = pathlib.Path(args[0])

    from run import load_env, sb
    load_env()
    known = {c["nse_symbol"] for c in sb("GET", "companies?select=nse_symbol")
             if c.get("nse_symbol")}

    company_dirs = sorted({p.parent for p in root.rglob("*_Basic_Info.csv")})
    print(f"{len(company_dirs)} company folders found")
    items, no_nse, unknown = {}, 0, 0
    for i, d in enumerate(company_dirs):
        try:
            sym, ci = load_company(d)
        except Exception as e:
            print(f"SKIP {d.name}: {e}")
            continue
        if not sym:
            no_nse += 1
            continue
        if sym not in known:
            unknown += 1
            continue
        for (kind, period), data in ci.items():
            items[(sym, kind, period)] = data
        if (i + 1) % 500 == 0:
            print(f"  parsed {i + 1}/{len(company_dirs)}…")
    n_syms = len({s for s, _, _ in items})
    print(f"parsed {len(items)} rows across {n_syms} NSE symbols "
          f"({no_nse} BSE-only, {unknown} not in companies table)")

    existing = sb("GET", "fundamentals?select=symbol,kind,period,data"
                         "&kind=in.(annual,quarter,shareholding)&order=symbol,period")
    existing_keys = {(r["symbol"], r["kind"], r["period"]) for r in existing}
    yahoo = {(r["symbol"], r["kind"], r["period"]): r["data"] for r in existing
             if r["kind"] == "annual" and (r.get("data") or {}).get("src") != "kaggle"}
    bad, checked = validate_overlap(items, yahoo)
    print(f"validated against {checked} Yahoo overlap years; {len(bad)} diverge >{DIVERGE_PCT}%")
    for key, field, kv, yv in bad[:20]:
        print(f"  {key} {field}: kaggle {kv} vs yahoo {yv}")
    if checked and len(bad) / checked > ABORT_FRACTION and "--force" not in sys.argv:
        print("ABORT: too many divergences — check units/labels, or --force")
        return 1

    rows = rows_to_write(items, existing_keys,
                         datetime.now(timezone.utc).isoformat())
    kinds = Counter(r["kind"] for r in rows)
    print(f"to write: {len(rows)} rows {dict(kinds)} (existing periods untouched)")
    if "--dry-run" in sys.argv:
        print("dry run — nothing written")
        return 0
    from market import upsert
    for i in range(0, len(rows), 2000):  # progress ticks; upsert re-chunks at 100
        upsert(sb, rows[i:i + 2000], table="fundamentals", key="symbol,kind,period")
        print(f"  wrote {min(i + 2000, len(rows))}/{len(rows)}")
    print("done — deep passes refresh summaries/CAGRs; screener rebuild at 18:00 IST")
    return 0


if __name__ == "__main__":
    sys.exit(main())
