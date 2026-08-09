-- M5: relevance-ranked Q&A retrieval.
--
-- The Edge Function first used websearch_to_tsquery, which ANDs every term:
-- "What did the RBI decide about repo rates recently?" demanded decide AND
-- recently in the story text and matched nothing. Switching to OR fixed the
-- empty result but produced the opposite failure — any single common word
-- matched, PostgREST could not order by ts_rank, and the model was handed five
-- unrelated stories and (correctly) refused to answer from them.
--
-- Ranking is the missing half: OR to retrieve, ts_rank to choose. A doc
-- matching three query terms outranks one matching a stray word.
create or replace function search_stories(tsq text, max_rows int default 5)
returns table (
  headline    text,
  summary     text,
  source_name text,
  source_url  text,
  rank        real
)
language sql
stable
as $$
  select s.headline, s.summary, s.source_name, s.source_url,
         ts_rank(s.fts, q.query) as rank
  from stories s, to_tsquery('english', tsq) as q(query)
  where s.status = 'approved'
    and s.published_at >= now() - interval '7 days'
    and s.fts @@ q.query
  order by ts_rank(s.fts, q.query) desc, s.published_at desc
  limit max_rows;
$$;

grant execute on function search_stories(text, int) to authenticated, service_role, anon;
