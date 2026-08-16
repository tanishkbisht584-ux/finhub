-- Deep read (spec 2026-08-16): AI-written full story, generated on first
-- open by the deepread edge function, cached here forever after.
alter table stories add column if not exists deep_read jsonb;

-- deepread's per-user generation cap logs events of type 'deep_read'
-- (003_users.sql's inline check didn't know about it yet).
alter table events drop constraint if exists events_type_check;
alter table events add constraint events_type_check
  check (type in ('view','swipe_past','save','share','qa_ask','alert_open','deep_read'));
