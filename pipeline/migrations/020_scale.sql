-- 020 (2026-09-13): scale hardening for ~1000 daily users on the free tier.

-- Both edge functions count a user's qa_ask / deep_read rows since midnight on
-- every request; the qa function now also counts the day's total for a global
-- budget. Partial indexes over just those two types stay a sliver of the table
-- (views are ~95% of events) and turn each count into an index range scan.
create index if not exists events_user_type_created_idx
  on events (user_id, type, created_at desc) where type in ('qa_ask', 'deep_read');
create index if not exists events_type_created_idx
  on events (type, created_at desc) where type in ('qa_ask', 'deep_read');

-- qa_cache was never pruned; retention_sweep now deletes rows older than 7 d.
create index if not exists qa_cache_created_idx on qa_cache (created_at);

-- Personal-alert ledger: replaces profiles.alert_settings.pa. The engine kept
-- a day counter + id cursor per user inside a user-writable jsonb column and
-- PATCHed one profile per user per 45 s lap; this table takes one bulk upsert
-- per lap and users cannot reset their own 5/day cap. Service-role only.
create table if not exists personal_sends (
  user_id    uuid primary key references profiles(id) on delete cascade,
  day        text   not null,            -- IST yyyy-mm-dd, as the engine formats it
  n          int    not null default 0,  -- pushes sent that day
  cur        bigint not null default 0,  -- highest story id already considered
  updated_at timestamptz not null default now()
);
alter table personal_sends enable row level security;  -- no policies: service_role only

-- Carry every existing cursor over so nobody is re-buzzed on the switch.
insert into personal_sends (user_id, day, n, cur)
select id,
       coalesce(alert_settings->'pa'->>'d', ''),
       coalesce((alert_settings->'pa'->>'n')::int, 0),
       coalesce((alert_settings->'pa'->>'cur')::bigint, 0)
from profiles
where alert_settings ? 'pa'
on conflict (user_id) do nothing;
