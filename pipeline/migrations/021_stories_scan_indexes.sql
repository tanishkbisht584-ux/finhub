-- 021 (2026-09-13): stop two per-lap sequential scans of stories (135k rows,
-- 367 MB). From 12 Sep 18:00 UTC every lap crash-looped on "canceling
-- statement due to statement timeout" (8 s): the alert engine's daily counter
-- (alerted_at >= midnight) and the chief editor's featured-pin reset
-- (is_featured = true) both scanned the whole table, ~10 s each on the
-- free-tier disk once the table outgrew the page cache. Both filters match a
-- handful of rows, so the partial indexes are a few KB each.
create index if not exists stories_alerted_at_idx on stories (alerted_at) where alerted_at is not null;
create index if not exists stories_featured_idx on stories (id) where is_featured;

-- Headroom for the pipeline's service-role statements (PostgREST applies the
-- impersonated role's settings; with none set, service_role inherited the
-- authenticator's 8 s). 30 s turns a slow lap into a slow lap, not an outage.
alter role service_role set statement_timeout = '30s';
notify pgrst, 'reload config';
