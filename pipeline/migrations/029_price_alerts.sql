-- 029 (2026-09-26): user-set price alerts — Phase B of the four-gap plan.
-- Evaluated by pipeline/price_alerts.py on every equity quote lap (15 min in
-- NSE hours), pushed through profiles.fcm_token. above/below fire once and
-- deactivate (re-arm from the app); move / hi52 / lo52 fire at most once per
-- IST day and stay active.

create table if not exists price_alerts (
  id            bigint generated always as identity primary key,
  user_id       uuid not null references profiles(id) on delete cascade,
  symbol        text not null check (symbol ~ '^[A-Z0-9][A-Z0-9&-]{0,19}$'),
  kind          text not null check (kind in ('above','below','move','hi52','lo52')),
  threshold     numeric check (threshold > 0),   -- ₹ for above/below, % for move, null for 52w
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  last_fired_at timestamptz,
  fire_count    int not null default 0,
  check ((kind in ('hi52','lo52')) = (threshold is null))
);
create index if not exists price_alerts_active_idx on price_alerts (symbol) where active;
alter table price_alerts enable row level security;
create policy "own price_alerts" on price_alerts for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- History outlives a deleted alert (no FK on alert_id). Pipeline
-- (service_role) is the only writer; users read their own rows.
create table if not exists price_alert_fires (
  id        bigint generated always as identity primary key,
  alert_id  bigint not null,
  user_id   uuid not null references profiles(id) on delete cascade,
  symbol    text not null,
  kind      text not null,
  threshold numeric,
  price     numeric not null,
  fired_at  timestamptz not null default now()
);
create index if not exists price_alert_fires_user_idx on price_alert_fires (user_id, fired_at desc);
alter table price_alert_fires enable row level security;
create policy "read own price_alert_fires" on price_alert_fires for select to authenticated
  using (user_id = auth.uid());

-- Alert symbols join the portfolio's in the quote universe (028 view).
create or replace view user_symbols as
  select symbol from portfolio_trades
  union
  select symbol from price_alerts where active;
revoke all on user_symbols from anon, authenticated;
