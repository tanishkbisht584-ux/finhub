-- stories.updated_at (2026-08-23): lets the pipeline fetch only rows created
-- OR edited since its last lap (run.recent_stories) instead of re-downloading
-- the whole 48 h window every 45 s — that re-read was ~55 GB/month against
-- Supabase's 5 GB free egress. Until this is applied the pipeline falls back
-- to a created_at delta (admin edits reach its dedupe window hourly).
alter table stories add column if not exists updated_at timestamptz not null default now();

create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists stories_updated_at on stories;
create trigger stories_updated_at before update on stories
  for each row execute function set_updated_at();

create index if not exists stories_updated_at_idx on stories (updated_at);
