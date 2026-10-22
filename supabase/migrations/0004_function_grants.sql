-- ---------------------------------------------------------------------------
-- 0004_function_grants.sql — lock down who may execute what.
--
-- PostgreSQL grants EXECUTE on a new function to PUBLIC by default, and a GRANT
-- to a specific role does not displace that. So the grants in 0003 were additive
-- and every function here was callable by `anon` — i.e. by anyone holding the
-- public anon key, which ships in the APK.
--
-- For the two read RPCs that was harmless: they are SECURITY INVOKER, so row
-- level security still applied and an anon caller got an empty result.
--
-- `purge_expired_coordinates()` is the one that mattered. It is SECURITY DEFINER,
-- so it runs with the owner's rights and ignores RLS entirely. An anon caller
-- could have used it to null out cached coordinates and clear the region ledger.
-- Today that is a no-op because every seeded row is OSM-sourced and leaves
-- `coords_fetched_at` null — but it stops being a no-op the moment a provider
-- with a retention limit is wired in, which is the whole reason the function
-- exists.
--
-- Trigger functions are revoked too. They are only ever invoked by their
-- triggers, so nothing should be calling them directly.
-- ---------------------------------------------------------------------------

-- ------------------------------------------- SECURITY DEFINER: nobody but the
-- ------------------------------------------- owner and service_role.

revoke all on function public.purge_expired_coordinates()  from public, anon, authenticated;
revoke all on function public.handle_new_user()            from public, anon, authenticated;
revoke all on function public.enforce_request_transition() from public, anon, authenticated;
revoke all on function public.touch_updated_at()           from public, anon, authenticated;

-- The scheduled purge runs as the table owner via pg_cron, and Edge Functions use
-- the service_role key, so neither needs a grant to anon or authenticated.
grant execute on function public.purge_expired_coordinates() to service_role;

-- ---------------------------------------------- Read RPCs: signed-in users only.

revoke all on function public.nearby_mechanics(
  double precision, double precision, double precision,
  mechanic_category, text, text, int) from public, anon;
revoke all on function public.my_requests() from public, anon;

grant execute on function public.nearby_mechanics(
  double precision, double precision, double precision,
  mechanic_category, text, text, int) to authenticated, service_role;
grant execute on function public.my_requests() to authenticated, service_role;

-- --------------------------------------------- Tables: anon reads nothing here.
--
-- Every RLS policy in 0003 is written `to authenticated`, so anon was already
-- getting empty results. Removing the table-level grant as well means the
-- database refuses at the privilege layer rather than relying on a policy to
-- filter everything out — defence in depth, and it makes the intent explicit.

revoke all on public.mechanics, public.services, public.mechanic_services,
               public.mechanic_hours, public.reviews, public.search_tiles,
               public.profiles, public.service_requests, public.mechanics_with_stats
  from anon;
