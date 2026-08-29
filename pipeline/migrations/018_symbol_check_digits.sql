-- 018 (2026-08-29): NSE symbols can start with a digit (20MICRONS, 3MINDIA,
-- 360ONE, 5PAISA…). The CHECKs copied through 013 -> 016 -> 017 required a
-- leading letter, so those symbols could never be requested from the stock
-- page nor backfilled. Relax all three.
alter table analysis_requests drop constraint if exists analysis_requests_symbol_check;
alter table analysis_requests add constraint analysis_requests_symbol_check
  check (symbol ~ '^[A-Z0-9][A-Z0-9&-]{0,19}$');

alter table fundamentals drop constraint if exists fundamentals_symbol_check;
alter table fundamentals add constraint fundamentals_symbol_check
  check (symbol ~ '^[A-Z0-9][A-Z0-9&-]{0,19}$');

alter table screener_metrics drop constraint if exists screener_metrics_symbol_check;
alter table screener_metrics add constraint screener_metrics_symbol_check
  check (symbol ~ '^[A-Z0-9][A-Z0-9&-]{0,19}$');
