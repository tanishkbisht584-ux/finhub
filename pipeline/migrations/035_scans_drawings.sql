-- 035 (2026-09-26): technical scans + chart drawings (free-parity P3).
-- screener_metrics.signals: the scan names that fired on a symbol's latest
-- daily bar (written with its technicals pass; the nightly `scans` group
-- rolls them into the Markets SCANS blob and one grouped push per holder).
-- user_drawings: trendlines / levels / fib / boxes / notes a user draws on a
-- stock chart, anchored in (time, price) so they survive range changes; one
-- row per (user, symbol), mirrored in SharedPreferences for offline.
alter table screener_metrics add column if not exists signals text[];

create table if not exists user_drawings (
  user_id    uuid not null references profiles(id) on delete cascade,
  symbol     text not null check (symbol ~ '^[A-Z0-9][A-Z0-9&:-]{0,19}$'),
  items      jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, symbol)
);
alter table user_drawings enable row level security;
drop policy if exists "own user_drawings" on user_drawings;
create policy "own user_drawings" on user_drawings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
