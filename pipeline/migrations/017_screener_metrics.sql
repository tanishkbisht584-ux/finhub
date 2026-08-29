-- 017 (2026-08-29): screening engine. One row per company with real numeric
-- columns so PostgREST .gte/.lte/.order compare numerically server-side —
-- the app sends filters and gets <=50 rows back, never the universe.
-- Rebuilt daily by pipeline/fundamentals.py refresh_screener from the
-- fundamentals table + Yahoo spark prices. No indexes: ~2k rows.
create table if not exists screener_metrics (
  symbol         text primary key check (symbol ~ '^[A-Z][A-Z0-9&-]{0,19}$'),
  name           text,
  sector         text,
  price          double precision,
  mcap_cr        double precision,
  pe             double precision,
  pb             double precision,
  div_yield      double precision,
  roe            double precision,
  roce           double precision,
  de             double precision,
  opm            double precision,
  sales_cagr_3y  double precision,
  profit_cagr_3y double precision,
  sales_cagr_5y  double precision,
  profit_cagr_5y double precision,
  promoter_pct   double precision,
  updated_at     timestamptz not null default now()
);

alter table screener_metrics enable row level security;
drop policy if exists "authenticated read screener_metrics" on screener_metrics;
create policy "authenticated read screener_metrics" on screener_metrics
  for select to authenticated using (true);
