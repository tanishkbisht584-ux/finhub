-- Let the app read the other outlets that carried a story.
--
-- 002_security.sql granted read on `approved` only, which was right when a
-- card had exactly one source. Cards now credit every outlet that ran the
-- story — the outlet that published first in the byline, the rest behind
-- "+N more" — and those other outlets are stored as `duplicate` rows in the
-- same cluster. Under the old policy the app asked who else reported it and
-- the database answered "nobody", so the list never appeared. Not an error,
-- just silence: exactly the kind of failure tests with fake data cannot catch.
--
-- `rejected` and `flagged` stay hidden. Those are the pipeline's own judgement
-- calls (not India-relevant, low value, or an AI failure) and nothing outside
-- the admin panel should read them.
--
-- What this exposes that was hidden before: for a story already on the feed,
-- the headline and summary the AI wrote for another outlet's telling of it.
-- Judged acceptable — they are rewrites of public articles the card already
-- links to. The feed itself is unchanged: it still asks for `approved` only,
-- so no duplicate can ever become a card.

drop policy if exists "authenticated read approved stories" on stories;

create policy "authenticated read published stories" on stories
  for select to authenticated
  using (status in ('approved', 'duplicate'));
