-- M8: a story can carry one matched broadcaster video (hotlinked YouTube URL).
alter table stories add column if not exists video_url text;

-- M8: video channels use sources.type='youtube', which 001_initial.sql's
-- inline check didn't allow (auto-named sources_type_check by Postgres since
-- the constraint was declared inline, not with `constraint <name>`) — every
-- seeded youtube row would have been rejected by the insert.
alter table sources drop constraint if exists sources_type_check;
alter table sources add constraint sources_type_check
  check (type in ('rss','google_news_query','nse','bse','sebi','rbi','youtube'));
