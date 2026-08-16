-- Security audit 2026-08-16 (check 7: open DB permissions).
-- 005 granted search_stories to anon. SECURITY INVOKER + deny-all RLS means
-- anon gets zero rows today, but the grant is dead surface — one future
-- SECURITY DEFINER refactor away from an unauthenticated story dump.
-- Only `authenticated` (app) and `service_role` (edge fn) ever call it.
revoke execute on function search_stories(text, int) from anon;
