-- M8: a story can carry one matched broadcaster video (hotlinked YouTube URL).
alter table stories add column if not exists video_url text;
