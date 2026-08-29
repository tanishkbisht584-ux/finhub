-- 016 (2026-08-29): Screener-style statement history. One row per
-- (symbol, kind, period); pipeline/fundamentals.py upserts, history
-- accumulates forever (Yahoo only serves ~4y; a one-time Kaggle backfill
-- adds the deep years with data.src='kaggle').
create table if not exists fundamentals (
  symbol     text not null check (symbol ~ '^[A-Z][A-Z0-9&-]{0,19}$'),
  kind       text not null check (kind in ('annual','quarter','shareholding','docs','summary')),
  period     text not null,   -- 'FY2024' | '2026-06' | 'latest' (docs/summary)
  data       jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (symbol, kind, period)
);

-- Same posture as quotes (011): RLS on, signed-in read, service_role bypasses.
alter table fundamentals enable row level security;
drop policy if exists "authenticated read fundamentals" on fundamentals;
create policy "authenticated read fundamentals" on fundamentals
  for select to authenticated using (true);
