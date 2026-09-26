-- 030 (2026-09-26): saved screens on the account — Phase C of the four-gap
-- plan. The phone keeps its SharedPreferences copy as the offline cache and
-- merges this on open (cloud wins on the same name), so a reinstall or a
-- second device sees the same screens.

create table if not exists user_screens (
  user_id    uuid not null references profiles(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 40),
  query      text,                     -- the typed formula, when there was one
  filters    jsonb not null default '[]'::jsonb,
  sort_col   text not null default 'mcap_cr',
  asc        boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (user_id, name)
);
alter table user_screens enable row level security;
create policy "own user_screens" on user_screens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
