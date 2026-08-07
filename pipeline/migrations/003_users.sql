-- M4: user-facing tables (spec §6). RLS on from creation — each user touches
-- only their own rows; profiles reference Supabase Auth (auth.users).

create table profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  display_name   text,
  fcm_token      text,
  alert_settings jsonb not null default '{"personalized": true, "voice_l1": true}',
  created_at     timestamptz not null default now()
);

create table follows (
  user_id     uuid not null references profiles(id) on delete cascade,
  target_type text not null check (target_type in ('company','sector','category')),
  target_id   text not null,     -- company id / sector name / category name
  created_at  timestamptz not null default now(),
  primary key (user_id, target_type, target_id)
);

create table saves (
  user_id  uuid   not null references profiles(id) on delete cascade,
  story_id bigint not null references stories(id) on delete cascade,
  saved_at timestamptz not null default now(),
  primary key (user_id, story_id)
);

create table events (
  id         bigint generated always as identity primary key,
  user_id    uuid references profiles(id) on delete set null,
  story_id   bigint references stories(id) on delete cascade,
  type       text not null check (type in ('view','swipe_past','save','share','qa_ask','alert_open')),
  created_at timestamptz not null default now()
);
create index events_created_idx on events (created_at);  -- 90-day prune

create table qa_cache (
  question_hash text primary key,
  answer_json   jsonb not null,
  created_at    timestamptz not null default now()
);

alter table profiles enable row level security;
alter table follows  enable row level security;
alter table saves    enable row level security;
alter table events   enable row level security;
alter table qa_cache enable row level security;  -- Edge Function (service role) only

create policy "own profile"  on profiles for all to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy "own follows"  on follows  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own saves"    on saves    for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "write own events" on events for insert to authenticated
  with check (user_id = auth.uid());
