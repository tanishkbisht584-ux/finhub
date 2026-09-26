-- 028 (2026-09-26): portfolio trades — Phase A of the four-gap plan.
-- One table of dated buy/sell lots per user; holdings, P&L and XIRR are
-- derived on the phone (a holdings table would only cache that fold).
-- Symbol CHECK = the 018 regex, so the pipeline can put symbols straight into
-- PostgREST URL filters.

create table if not exists portfolio_trades (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references profiles(id) on delete cascade,
  symbol     text not null check (symbol ~ '^[A-Z0-9][A-Z0-9&-]{0,19}$'),
  side       text not null check (side in ('buy','sell')),
  qty        numeric not null check (qty > 0),
  price      numeric not null check (price >= 0),
  traded_on  date not null,
  note       text check (char_length(note) <= 200),
  source     text not null default 'manual'
               check (source in ('manual','zerodha','groww','upstox')),
  created_at timestamptz not null default now()
);
create index if not exists portfolio_trades_user_idx on portfolio_trades (user_id, symbol);

alter table portfolio_trades enable row level security;
create policy "own portfolio_trades" on portfolio_trades for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Distinct symbols for market.equity_universe (service_role only): one row
-- per symbol per lap, never one per trade. 029 unions price_alerts into it.
create or replace view user_symbols as select distinct symbol from portfolio_trades;
revoke all on user_symbols from anon, authenticated;
