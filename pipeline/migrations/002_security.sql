-- Security hardening: tables created via SQL have RLS DISABLED by default,
-- meaning anyone holding the project's anon key could read/write everything.
-- Enabling RLS with no anon policies = deny-all for the public key.
-- The pipeline and admin panel use the service_role key, which bypasses RLS.

alter table sources         enable row level security;
alter table companies       enable row level security;
alter table stories         enable row level security;
alter table story_companies enable row level security;

-- App users (M4, Google sign-in) may read only approved stories + reference data.
create policy "authenticated read approved stories" on stories
  for select to authenticated using (status = 'approved');
create policy "authenticated read companies" on companies
  for select to authenticated using (true);
create policy "authenticated read story links" on story_companies
  for select to authenticated using (true);
-- sources: no policy — internal table, service_role only.
