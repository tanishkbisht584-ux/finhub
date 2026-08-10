"""Seed companies from the NSE equity master (spec §6: "seeded from NSE/BSE
listings"). The pipeline has tagged companies per card since M1 — insert_story
matches card["companies"] against this table — but the table was never seeded,
so no story has ever been tagged. Idempotent: upserts on nse_symbol.

Run:  cd pipeline && python seed/companies_seed.py
"""
import io
import csv
import re
import sys
import pathlib

import requests

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from run import load_env, sb

CSV_URL = "https://nsearchives.nseindia.com/content/equities/EQUITY_L.csv"
# The archives host serves plain requests; the UA only guards against the
# no-header bot filter. ponytail: if NSE ever blocks this, the CSV is mirrored
# widely — swap the URL, the format is stable.
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}

LEGAL_TAIL = re.compile(r"\s+(limited|ltd\.?)$", re.I)


def display_name(legal):
    """'MAHINDRA & MAHINDRA LIMITED' -> 'Mahindra & Mahindra' — chips and the
    stock page header want the name people say, not the registrar's."""
    return LEGAL_TAIL.sub("", legal.strip()).title()


def main():
    load_env()
    r = requests.get(CSV_URL, headers=UA, timeout=60)
    r.raise_for_status()
    reader = csv.DictReader(io.StringIO(r.text))
    reader.fieldnames = [f.strip() for f in reader.fieldnames]  # NSE's CSV pads
    # header names with a leading space (" SERIES"), so an unnormalized
    # rec.get("SERIES", "EQ") silently misses every row and the filter below
    # becomes a no-op.
    rows = []
    for rec in reader:
        symbol = rec["SYMBOL"].strip()
        legal = rec["NAME OF COMPANY"].strip()
        if rec.get("SERIES", "EQ").strip() not in ("EQ", "BE"):
            continue  # only regular equity; no ETFs/partly-paid/warrants
        name = display_name(legal)
        aliases = sorted({legal.casefold(), name.casefold()} - {name.casefold()})
        rows.append({"name": name, "nse_symbol": symbol, "aliases": aliases})
    print(f"{len(rows)} equities parsed")
    if len(rows) < 1500:  # the master lists ~2000; a short file is a bad fetch
        raise SystemExit(f"only {len(rows)} rows — refusing to seed from a truncated CSV")
    for i in range(0, len(rows), 500):
        sb("POST", "companies?on_conflict=nse_symbol", json=rows[i:i + 500],
           headers={"Prefer": "resolution=merge-duplicates"})
    total = sb("GET", "companies?select=id")
    print(f"companies table now holds {len(total)} rows")


if __name__ == "__main__":
    main()
