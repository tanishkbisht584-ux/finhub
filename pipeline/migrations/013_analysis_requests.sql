-- 013: on-demand analysis backfill (2026-08-24).
-- A stock page opened outside the equity universe has a live price (the app
-- fetches the Yahoo chart itself) but no meta.f/meta.t. The app drops the
-- symbol here; market.refresh_analysis_new backfills within ~5 min, and
-- equity_universe keeps the quote fresh while the row lives (48 h, pruned by
-- the pipeline). Served rows are kept on purpose — deleting them would evict
-- the symbol from the universe.

create table if not exists analysis_requests (
  symbol       text primary key
                 check (symbol ~ '^[A-Z][A-Z0-9&-]{0,19}$'),  -- keeps pipeline URL filters safe
  requested_at timestamptz not null default now()
);

-- Same posture as events (003): insert-only for signed-in users, no select —
-- the app never reads back; the pipeline (service_role) bypasses RLS.
alter table analysis_requests enable row level security;
create policy "authenticated request analysis" on analysis_requests
  for insert to authenticated with check (true);
