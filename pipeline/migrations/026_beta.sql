-- 026 (2026-09-20): 5-year beta from stockanalysis.com on screener_metrics.
-- Yahoo's quoteSummary beta read 0.17 for TCS against Moneycontrol's 0.78;
-- the site's `beta` (5Y, monthly) matches MC. pipeline/stockanalysis.py owns it.
alter table screener_metrics add column if not exists beta_5y numeric;
