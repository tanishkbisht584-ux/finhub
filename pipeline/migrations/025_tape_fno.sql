-- 025 (2026-09-20): per-symbol tape + F&O from the NSE archives (pipeline/bhav.py).
-- NSE's quote APIs 403 datacenter IPs and quote-derivative is gone, but the
-- nsearchives host serves the daily full bhavcopy (VWAP, delivery %) and the
-- F&O bhavcopy (OI per contract) to any IP. tape = last 22 sessions
-- {asof, d:[{date, prev, open, high, low, close, vwap, vol, turnover_cr, trades,
-- deliv_qty, deliv_pct}]}; fno = {asof, underlying, futures:[…], expiry, ce_oi,
-- pe_oi, pcr, max_ce, max_pe, chain:[…]} for the ~230 F&O underlyings.
alter table screener_metrics
  add column if not exists tape jsonb,
  add column if not exists fno  jsonb;
