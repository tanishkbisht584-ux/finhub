-- 037 (2026-09-26): backtests + concall summaries (free-parity P5).
-- backtests: one cached result per (owner, screen name) — the six presets
-- under the zero owner, users' saved screens under their uid; recomputed
-- weekly by pipeline/backtest.py from price_history. Readable by the owner
-- and everyone for the presets.
-- fundamentals.kind gains 'concall': one row per summarised transcript
-- (period = call date, data = {subject, url, summary, guidance, risks,
-- qa_highlights, sentiment, model}) written by pipeline/concalls.py.
create table if not exists backtests (
  user_id     uuid not null default '00000000-0000-0000-0000-000000000000',
  name        text not null,
  params      jsonb,
  result      jsonb,
  computed_at timestamptz not null default now(),
  primary key (user_id, name)
);
alter table backtests enable row level security;
drop policy if exists "read backtests" on backtests;
create policy "read backtests" on backtests for select to authenticated
  using (user_id = auth.uid() or user_id = '00000000-0000-0000-0000-000000000000');

alter table fundamentals drop constraint if exists fundamentals_kind_check;
alter table fundamentals add constraint fundamentals_kind_check
  check (kind in ('annual','quarter','shareholding','docs','summary','concall'));
