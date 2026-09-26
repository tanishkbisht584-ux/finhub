-- 036 (2026-09-26): MF screener table + wider universe (free-parity P4).
-- mf_metrics: one row per Direct-Growth scheme from mfapi.in NAV history
-- (pipeline/mf.py). No expense ratio / AUM column: no keyless per-scheme
-- source exists. ~4k rows x ~300 B.
-- Universe: SME (series SM/ST) rows carry board='SME' (033 added the column
-- on screener_metrics; companies gets it here) and BSE-only listings live
-- as 'BSE:<scripcode>' — every symbol CHECK copied from 018 widens to allow
-- the ':' (analysis_requests, fundamentals, screener_metrics, portfolio_trades,
-- price_alerts; 032/035 already allow it).
create table if not exists mf_metrics (
  code         integer primary key,
  name         text,
  house        text,
  category     text,
  sub_category text,
  nav          real, nav_date date,
  ret_1m real, ret_3m real, ret_6m real, ret_1y real, ret_3y real, ret_5y real,
  cagr_3y real, cagr_5y real,
  vol_1y real, sharpe_1y real, mdd_3y real, age_y real,
  updated_at   timestamptz
);
alter table mf_metrics enable row level security;
drop policy if exists "read mf_metrics" on mf_metrics;
create policy "read mf_metrics" on mf_metrics for select to authenticated using (true);
create index if not exists mf_metrics_cat on mf_metrics (category, sub_category);

alter table companies add column if not exists board text not null default 'MAIN';

alter table analysis_requests drop constraint if exists analysis_requests_symbol_check;
alter table analysis_requests add constraint analysis_requests_symbol_check
  check (symbol ~ '^[A-Z0-9][A-Z0-9&:-]{0,19}$');
alter table fundamentals drop constraint if exists fundamentals_symbol_check;
alter table fundamentals add constraint fundamentals_symbol_check
  check (symbol ~ '^[A-Z0-9][A-Z0-9&:-]{0,19}$');
alter table screener_metrics drop constraint if exists screener_metrics_symbol_check;
alter table screener_metrics add constraint screener_metrics_symbol_check
  check (symbol ~ '^[A-Z0-9][A-Z0-9&:-]{0,19}$');
alter table portfolio_trades drop constraint if exists portfolio_trades_symbol_check;
alter table portfolio_trades add constraint portfolio_trades_symbol_check
  check (symbol ~ '^[A-Z0-9][A-Z0-9&:-]{0,19}$');
alter table price_alerts drop constraint if exists price_alerts_symbol_check;
alter table price_alerts add constraint price_alerts_symbol_check
  check (symbol ~ '^[A-Z0-9][A-Z0-9&:-]{0,19}$');
alter table fno_chain drop constraint if exists fno_chain_symbol_check;
alter table fno_chain add constraint fno_chain_symbol_check
  check (symbol ~ '^[A-Z0-9][A-Z0-9&:-]{0,19}$');
