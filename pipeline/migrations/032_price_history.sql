-- 032 (2026-09-26): price_history — the daily close series the app never had
-- (technicals threw the 1y chart away after computing meta.t; tape keeps 22
-- sessions). Feeds the scanners, backtests, ATL/ATH flags and beta/correlation
-- metrics of the free-parity plan. One row per symbol, arrays not rows: 3.2k ×
-- (1,260 closes + 250 vols) × 4 B ≈ 19 MB against a 500 MB cap.
--
-- Alignment: closes are the trailing NSE trading days ending `asof`, NULL
-- where Yahoo had no print, so every equity row lines up position-for-position
-- with the calendar row (^NSEI carries `dates`). No per-row dates = half the
-- bytes. Merges run server-side (history_merge) so the pipeline never reads
-- the arrays back — egress is the tighter free-tier budget.

create table if not exists price_history (
  symbol     text primary key check (symbol ~ '^[A-Z0-9^][A-Z0-9&:.-]{0,19}$'),
  asof       date not null,          -- date of closes[last]
  closes     real[] not null,        -- trailing trading days, split-adjusted (Yahoo), ≤ 1260
  vols       real[],                 -- trailing ≤ 250
  dates      date[],                 -- calendar rows only (^NSEI): the days behind closes
  atl real, atl_date date,           -- all-time low/high from the one-off range=max pull
  ath real, ath_date date,
  updated_at timestamptz not null default now()
);
alter table price_history enable row level security;
drop policy if exists "read price_history" on price_history;
create policy "read price_history" on price_history for select to authenticated using (true);

-- rows: [{symbol, k, closes[], vols[], asof, chk, atl, atl_date, ath, ath_date}]
--   k     = trailing stored elements the new window overlaps (replace them)
--   chk   = the new window's first close; if the stored close at that position
--           differs by > 2 % the series was re-adjusted (split/bonus) and the
--           symbol is returned for a full refill instead of being merged.
-- Returns the symbols that need a refill (missing row, gap, or re-adjustment).
create or replace function history_merge(rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r jsonb; sym text; old real[]; oldv real[]; newc real[]; newv real[];
  n int; k int; chk real; refill text[] := '{}';
begin
  for r in select * from jsonb_array_elements(rows) loop
    sym := r->>'symbol';
    select closes, vols into old, oldv from price_history where symbol = sym;
    if old is null then refill := refill || sym; continue; end if;
    n := cardinality(old); k := (r->>'k')::int; chk := (r->>'chk')::real;
    if k > n or k < 1 then refill := refill || sym; continue; end if;
    if old[n - k + 1] is not null and chk is not null and abs(old[n - k + 1] - chk) > 0.02 * chk then
      refill := refill || sym; continue;
    end if;
    newc := array(select (x #>> '{}')::real from jsonb_array_elements(r->'closes') x);
    newv := array(select (x #>> '{}')::real from jsonb_array_elements(coalesce(r->'vols', '[]'::jsonb)) x);
    old := old[1:n - k] || newc;
    if cardinality(old) > 1260 then old := old[cardinality(old) - 1259:]; end if;
    if oldv is not null and cardinality(oldv) >= k then oldv := oldv[1:cardinality(oldv) - k] || newv; else oldv := newv; end if;
    if cardinality(oldv) > 250 then oldv := oldv[cardinality(oldv) - 249:]; end if;
    update price_history set closes = old, vols = oldv, asof = (r->>'asof')::date,
      atl = coalesce((r->>'atl')::real, atl), atl_date = coalesce((r->>'atl_date')::date, atl_date),
      ath = coalesce((r->>'ath')::real, ath), ath_date = coalesce((r->>'ath_date')::date, ath_date),
      updated_at = now()
    where symbol = sym;
  end loop;
  return to_jsonb(refill);
end $$;
revoke all on function history_merge(jsonb) from public, anon, authenticated;
