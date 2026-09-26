-- 031 (2026-09-26): storage_stats() — database + per-table sizes readable over
-- PostgREST with the service_role key, so the hourly watchdog (CI has no
-- Management API token) and the admin Storage page can watch the 500 MB free
-- cap without pg_* privileges. security definer: pg_stat needs the owner.

create or replace function storage_stats() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'db_mb', round(pg_database_size(current_database()) / 1048576.0, 1),
    'tables', (
      select jsonb_agg(jsonb_build_object(
               'name', c.relname,
               'total_mb', round(pg_total_relation_size(c.oid) / 1048576.0, 1),
               'heap_mb', round(pg_relation_size(c.oid) / 1048576.0, 1),
               'index_mb', round(pg_indexes_size(c.oid) / 1048576.0, 1),
               'rows', s.n_live_tup,
               'dead', s.n_dead_tup,
               'last_vacuum', greatest(s.last_vacuum, s.last_autovacuum))
             order by pg_total_relation_size(c.oid) desc)
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      left join pg_stat_user_tables s on s.relid = c.oid
      where n.nspname = 'public' and c.relkind = 'r'),
    'stories', (
      select jsonb_build_object(
               'approved', count(*) filter (where status = 'approved'),
               'duplicate', count(*) filter (where status = 'duplicate'),
               'rejected', count(*) filter (where status = 'rejected'),
               'other', count(*) filter (where status not in ('approved','duplicate','rejected')),
               'oldest', min(created_at))
      from stories),
    'at', now());
$$;
revoke all on function storage_stats() from public, anon, authenticated;  -- service_role only
