-- 034 (2026-09-26): full F&O chain + corporate actions (free-parity P2).
-- fno_chain: one row per underlying from the daily NSE F&O bhavcopy — every
-- expiry (NIFTY has 18 weekly/monthly), every strike, the index contracts too
-- (IDF/IDO, confirmed by probe 36246785128); bhav.py kept ±6 strikes of the
-- nearest expiry until now. Compact arrays per strike keep it ~3 MB; the row
-- is overwritten daily (ponytail: no OI history — add a 5-day ring if asked).
-- screener_metrics.actions: NSE ex-dates / bonus / splits / rights / board
-- meetings per symbol (the ACTIONS section knew only Yahoo dividends+splits).
create table if not exists fno_chain (
  symbol     text primary key check (symbol ~ '^[A-Z0-9][A-Z0-9&-]{0,19}$'),
  asof       date not null,
  data       jsonb not null,   -- {u, lot, pcr, max_ce, max_pe, max_pain, exp:[{e, fut:[close,prev,oi,oi_chg,vol]|null, pcr, s:[[k, ce_ltp, ce_oi, ce_chg, ce_vol, pe_ltp, pe_oi, pe_chg, pe_vol],…]}]}
  updated_at timestamptz not null default now()
);
alter table fno_chain enable row level security;
drop policy if exists "read fno_chain" on fno_chain;
create policy "read fno_chain" on fno_chain for select to authenticated using (true);
alter table screener_metrics add column if not exists actions jsonb;
