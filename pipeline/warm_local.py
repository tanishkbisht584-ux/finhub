"""Local Yahoo-only deep warm: consolidated statements (FY2023+ annuals with
balance sheet + cash flow, quarters to the latest filing, real shares/book
value) + chart (closes, TTM dps) + fresh summaries for every screener_metrics
symbol, then a screener rebuild. NSE pieces are skipped (this machine is
blocked) and drain via CI's deep passes instead.

    py -3 warm_local.py            # the whole universe (~2 h for 3.2k)
    py -3 warm_local.py SYM1,SYM2  # just these
"""
import sys
from datetime import datetime, timezone

from run import load_env, sb

load_env()
import fundamentals  # noqa: E402  (needs env for nothing, but keep order tidy)


def main():
    now = datetime.now(timezone.utc)
    syms = sorted({r["symbol"] for r in
                   sb("GET", "screener_metrics?select=symbol&order=symbol")})
    if len(sys.argv) > 1:
        only = set(sys.argv[1].split(","))
        syms = [s for s in syms if s in only]
    else:  # resume: a timeseries-sourced annual row marks a symbol done
        done = {r["symbol"] for r in
                sb("GET", "fundamentals?select=symbol&kind=eq.annual"
                          "&data->>src=eq.yahoo_ts&order=symbol")}
        syms = [s for s in syms if s not in done]
    print(f"warming {len(syms)} symbols (Yahoo only)…")
    done = 0
    for i in range(0, len(syms), 50):
        chunk = syms[i:i + 50]
        fundamentals.deep_fetch(sb, chunk, now, nse=False)
        done += len(chunk)
        print(f"  {done}/{len(syms)}", flush=True)
    print("rebuilding screener_metrics…")
    print("rows:", fundamentals.refresh_screener(sb, now))
    return 0


if __name__ == "__main__":
    sys.exit(main())
