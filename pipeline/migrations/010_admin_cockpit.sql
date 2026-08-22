-- 010: admin cockpit. Remote config (3 jsonb rows), per-run pipeline log,
-- edge-function call log, app version telemetry on profiles.
-- Additive; every consumer degrades to code defaults when these are absent,
-- so deploying code before this migration is safe (except the app build that
-- writes profiles.app_version — apply this first).

create table if not exists app_config (
  key        text primary key,           -- 'pipeline' | 'app' | 'edge'
  value      jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
alter table app_config enable row level security;
-- the app reads only its own row; pipeline/edge rows stay service_role-only
create policy "app reads app config" on app_config
  for select to authenticated using (key = 'app');

insert into app_config (key, value) values
  ('pipeline', '{"switches": {"pipeline": true, "auto_approve": true, "alerts": true,
                              "personal_alerts": true, "chief_editor": true, "video_match": true},
                 "knobs": {}, "ops_user_ids": []}'),
  ('app',      '{"min_version": "0.0.0",
                 "force_update_message": "Please update FinSwipe to keep reading.",
                 "update_url": "", "maintenance": "",
                 "flags": {"deep_read_enabled": true, "qa_enabled": true, "live_default": true,
                           "live_poll_seconds": 15, "ambient_poll_seconds": 90}}'),
  ('edge',     '{"qa_enabled": true, "deepread_enabled": true, "daily_cap": 50, "lanes": {}}')
on conflict (key) do nothing;

-- one row per pipeline main() iteration; pruned by retention_sweep
-- (ok rows after 48 h, everything after 14 d)
create table if not exists pipeline_runs (
  id          bigint generated always as identity primary key,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  ok          boolean,
  host        text,        -- GITHUB_RUN_ID or hostname
  counts      jsonb,       -- stage counters (fetched, new, processed, flagged, alerted, ...)
  ai_usage    jsonb,       -- lane -> calls served this run
  errors      jsonb,       -- log lines matching FAIL|Traceback|Exception (<= 50)
  log         text         -- captured stdout, last 20k chars
);
create index if not exists pipeline_runs_started_idx on pipeline_runs (started_at desc);
alter table pipeline_runs enable row level security;   -- no policies: service_role only

-- every AI lane attempt from the qa / deepread edge functions; pruned after 30 d
create table if not exists edge_log (
  id         bigint generated always as identity primary key,
  fn         text not null,     -- 'qa' | 'deepread'
  lane       text,              -- 'gemini/gemini-3.7-flash#0'
  ok         boolean not null,
  status     int,
  error      text,
  ms         int,
  created_at timestamptz not null default now()
);
create index if not exists edge_log_created_idx on edge_log (created_at desc);
alter table edge_log enable row level security;        -- service_role only

alter table profiles
  add column if not exists app_version text,
  add column if not exists last_seen_at timestamptz;
