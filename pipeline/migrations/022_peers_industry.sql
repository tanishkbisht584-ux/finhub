-- 022 (2026-09-15): industry on screener_metrics. companies.sector is NULL for
-- every row and refresh_screener copied it, so 2,424 of 3,208 screener rows
-- had no sector and the stock page's Peers section vanished for RELIANCE,
-- TCS, HDFCBANK… stockanalysis.com serves both sector ("Energy") and
-- industry ("Oil & Gas Refining & Marketing") for the whole universe; from
-- this migration pipeline/stockanalysis.py owns both columns on every row and
-- the app groups peers by industry (Screener's key), sector as the fallback.
alter table screener_metrics add column if not exists industry text;
create index if not exists screener_metrics_industry_idx on screener_metrics (industry);
