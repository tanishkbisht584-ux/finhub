-- Follow a STORY (2026-08-28): the card's follow button subscribes to the
-- cluster, so the reader is pinged only when that story actually develops —
-- a watchlist for narratives. target_id is already text, a uuid fits.
-- 003 declared the CHECK inline so Postgres auto-named it (007's pattern).
alter table follows drop constraint if exists follows_target_type_check;
alter table follows add constraint follows_target_type_check
  check (target_type in ('company','sector','category','cluster'));
