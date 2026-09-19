-- 024 (2026-09-19): universe technicals + trend state on screener_metrics.
-- Moneycontrol's Markets page opens on "Technical Trends" (bullish / turning
-- bullish / bearish / turning bearish) for the whole market; we only had
-- meta.t for the ~200 quoted equities. stockanalysis.com serves ma50 / ma200 /
-- rsi / Altman Z / 52-week levels for all 3.2k NSE rows in the same keyless
-- GET, so pipeline/stockanalysis.py now stores them and derives the trend
-- (price > ma50 > ma200 = bullish, mirror = bearish, else mixed). The
-- trend_* state is carried across pulls and reset on a flip, which is what
-- "turning" means (flipped within the last 7 days of closes).
alter table screener_metrics
  add column if not exists altman_z    numeric,
  add column if not exists ma50        numeric,
  add column if not exists ma200       numeric,
  add column if not exists rsi         numeric,
  add column if not exists hi52        numeric,
  add column if not exists lo52        numeric,
  add column if not exists trend       text,
  add column if not exists trend_prev  text,
  add column if not exists trend_since date,
  add column if not exists trend_price numeric;
create index if not exists screener_metrics_trend_idx on screener_metrics (trend, trend_since desc);
