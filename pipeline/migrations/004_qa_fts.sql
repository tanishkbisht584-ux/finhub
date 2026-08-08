-- M5: Q&A Tier 1 search (spec §6 "Search"). Generated column so the pipeline
-- never has to remember to maintain it; websearch_to_tsquery at read time.
alter table stories add column fts tsvector
  generated always as (
    to_tsvector('english', coalesce(headline, '') || ' ' || coalesce(summary, ''))
  ) stored;

create index stories_fts_idx on stories using gin (fts);
