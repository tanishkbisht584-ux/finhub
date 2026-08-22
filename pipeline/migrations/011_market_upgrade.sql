-- Markets upgrade (2026-08-22): a server-side market-data layer so card chips,
-- the watchlist, the stock page, the Markets tab and Q&A all read one cached
-- row instead of every phone hitting Yahoo. Written by pipeline/market.py
-- (service_role), read by signed-in users. Free tiers only.

-- One row per instrument. symbol examples: 'TCS' (equity), '^NSEI' (index),
-- 'USDINR=X' (fx), 'bitcoin' (crypto, CoinGecko id), 'GC=F' (commodity),
-- 'MF:120503' (mutual fund scheme code), 'MACRO:FEDFUNDS' (FRED series).
create table if not exists quotes (
  symbol      text primary key,
  kind        text not null check (kind in
                ('equity','index','fx','crypto','commodity','mf','macro')),
  name        text not null,
  price       numeric not null,
  prev_close  numeric,
  change_pct  numeric,
  currency    text not null default 'INR',
  closes      jsonb,            -- recent closes for a sparkline; null on equities
  as_of       timestamptz,      -- market time of the price
  updated_at  timestamptz not null default now(),
  meta        jsonb             -- kind-specific extras (label, returns, units)
);
create index if not exists quotes_kind_idx on quotes (kind);

-- List-shaped market data keyed by name: results_calendar, bulk_deals,
-- insider_trades, nse_indices. A row is replaced whole on each refresh.
create table if not exists market_blobs (
  key         text primary key,
  payload     jsonb not null,
  updated_at  timestamptz not null default now()
);

-- Same posture as 002_security.sql: RLS on, signed-in read, anon nothing,
-- service_role (pipeline) bypasses.
alter table quotes       enable row level security;
alter table market_blobs enable row level security;
create policy "authenticated read quotes" on quotes
  for select to authenticated using (true);
create policy "authenticated read market blobs" on market_blobs
  for select to authenticated using (true);

-- Users can follow a mutual-fund scheme (target_id = mfapi scheme code).
alter table follows drop constraint if exists follows_target_type_check;
alter table follows add constraint follows_target_type_check
  check (target_type in ('company','sector','category','mf'));

-- Keyed news APIs as source types (see run.py FETCHERS + admin TYPES).
alter table sources drop constraint if exists sources_type_check;
alter table sources add constraint sources_type_check
  check (type in ('rss','google_news_query','nse','bse','sebi','rbi','youtube',
                  'gnews_api','newsdata','marketaux'));

-- The stock page and watchlist look up stories by company; only the
-- (story_id, company_id) PK existed, so that reverse lookup was a scan.
create index if not exists story_companies_company_idx on story_companies (company_id);
