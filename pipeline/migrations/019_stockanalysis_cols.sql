-- 019 (2026-09-12): stockanalysis.com columns on screener_metrics. Written ONLY
-- by pipeline/stockanalysis.py refresh_stockanalysis (hourly 200-byte probe of
-- the site's priceDate, one full 3.2k-row pull when it moves). refresh_screener
-- and refresh_screener_px send only their own columns and the upsert merges by
-- key-set, so pe/pb/de/opm/roe/roce/div_yield/price/mcap_cr/*cagr* stay ours
-- (the 12 Sep diff showed the site disagrees with us on 34 of the top-100 P/Es,
-- so the two sets never mix and the "Stock Analysis" footnote is true per
-- column). Display-only extras (dates, analyst, company facts) sit in `sa`
-- jsonb: select it for one symbol on the stock page, never in list projections.
-- RLS policy from 017 covers the new columns. No indexes: ~3.2k rows.
alter table screener_metrics
  add column if not exists ret_1w         double precision,
  add column if not exists ret_1m         double precision,
  add column if not exists ret_3m         double precision,
  add column if not exists ret_6m         double precision,
  add column if not exists ret_ytd        double precision,
  add column if not exists ret_1y         double precision,
  add column if not exists ret_3y         double precision,
  add column if not exists ret_5y         double precision,
  add column if not exists ath_pct        double precision,
  add column if not exists avg_vol        double precision,
  add column if not exists rel_vol        double precision,
  add column if not exists turnover_cr    double precision,
  add column if not exists sharpe         double precision,
  add column if not exists sortino        double precision,
  add column if not exists atr            double precision,
  add column if not exists graham_upside  double precision,
  add column if not exists f_score        double precision,
  add column if not exists ps             double precision,
  add column if not exists earnings_yield double precision,
  add column if not exists fcf_yield      double precision,
  add column if not exists roic           double precision,
  add column if not exists int_cov        double precision,
  add column if not exists ev_ebitda      double precision,
  add column if not exists sector_pe      double precision,
  add column if not exists industry_pe    double precision,
  add column if not exists shares_yoy     double precision,
  add column if not exists sa             jsonb,
  add column if not exists sa_price_date  date,
  add column if not exists sa_at          timestamptz;
