-- 027 (2026-09-20): BSE side of the tape (Tanis: "what about BSE"). Same shape
-- as `tape` (22 sessions: OHLC, vwap, vol, turnover_cr, trades, deliv_qty,
-- deliv_pct) from BSE's daily bhavcopy + gross-delivery file, joined to our
-- NSE symbols by ISIN. The app's DELIVERY block shows COMBINED / NSE / BSE.
alter table screener_metrics add column if not exists tape_bse jsonb;
