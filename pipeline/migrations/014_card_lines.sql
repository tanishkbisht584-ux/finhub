-- Card one-liners (2026-08-28): four AI fields the scoring call now also
-- returns, rendered as glance lines on the story card. NULL on every story
-- scored before this shipped — the app renders nothing for NULL, so no
-- backfill. fts (004) stays headline||summary only, on purpose.
alter table stories add column if not exists why_it_matters text;
alter table stories add column if not exists winners_losers text;
alter table stories add column if not exists whats_next text;
alter table stories add column if not exists claim_status text
  check (claim_status in ('confirmed','reported','rumour'));  -- NULL passes
