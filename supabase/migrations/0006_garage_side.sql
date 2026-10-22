-- ---------------------------------------------------------------------------
-- 0006_garage_side.sql — let a garage owner run their side of a booking.
--
-- The schema already supported this: `mechanics.owner_id`, the status
-- transition trigger, and policies that let an owner see and update requests
-- for their garage. Three things were missing.
--
-- 1. Claiming was impossible. `mechanics_update_own` is USING (owner_id =
--    auth.uid()), so a row whose owner_id is NULL matches nobody and no one
--    could ever take ownership of an imported listing. Loosening that policy
--    would let anyone reassign any unclaimed garage, so claiming gets a
--    SECURITY DEFINER function with its own rules instead.
--
-- 2. There was no read model for the garage side. `my_requests()` is written
--    from the customer's point of view and omits who the customer is, which is
--    exactly what the garage needs in order to do the job.
--
-- 3. `profiles_update_own` let a client write any column, including `role`.
--    Nothing authorises off `role` today, so it was inert — but a client being
--    able to set its own role to 'admin' is not something to leave lying around.
-- ---------------------------------------------------------------------------

-- ------------------------------------------------------------ role guardrail

create or replace function public.guard_profile_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- service_role and server-side callers have no auth.uid() and are not bound
  -- by this; it exists to stop a client promoting itself.
  if auth.uid() is null then
    return new;
  end if;

  if new.role is distinct from old.role and new.role not in ('customer', 'mechanic') then
    raise exception 'You can only switch between the customer and mechanic roles';
  end if;

  return new;
end $$;

drop trigger if exists profiles_guard_role on public.profiles;
create trigger profiles_guard_role
  before update on public.profiles
  for each row execute function public.guard_profile_role();

-- ------------------------------------------------------------------ claiming

/**
 * Take ownership of a garage listing.
 *
 * SECURITY DEFINER because no sane RLS policy can express "you may write this
 * row only while it has no owner" without also allowing an owner's row to be
 * taken from them. The checks live here instead, and the function is granted
 * only to authenticated users.
 */
create or replace function public.claim_mechanic(p_mechanic_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_owner uuid;
begin
  if v_user is null then
    raise exception 'You need to be signed in to claim a garage';
  end if;

  select owner_id into v_owner
    from public.mechanics
   where id = p_mechanic_id
   for update;

  if not found then
    raise exception 'That garage no longer exists';
  end if;

  if v_owner = v_user then
    return p_mechanic_id;                       -- already yours; nothing to do
  end if;

  if v_owner is not null then
    raise exception 'This garage has already been claimed by someone else';
  end if;

  update public.mechanics
     set owner_id = v_user
   where id = p_mechanic_id;

  -- Claiming a garage is what makes someone a mechanic, so the role follows
  -- rather than being a separate step the user has to find.
  update public.profiles
     set role = 'mechanic'
   where id = v_user and role = 'customer';

  return p_mechanic_id;
end $$;

create or replace function public.release_mechanic(p_mechanic_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'You need to be signed in';
  end if;

  update public.mechanics
     set owner_id = null
   where id = p_mechanic_id and owner_id = auth.uid();

  if not found then
    raise exception 'That garage is not yours to release';
  end if;
end $$;

-- ------------------------------------------------- the garage's own listings

create or replace function public.my_garages()
returns setof public.mechanics_with_stats
language sql
stable
as $$
  select v.*
    from public.mechanics_with_stats v
   where v.owner_id = auth.uid()
   order by v.name;
$$;

-- --------------------------------------------------- the garage's work queue

/**
 * Bookings made against any garage this user owns.
 *
 * Unlike `my_requests()` this carries the customer's name and number, because
 * the garage cannot do the work without being able to reach them. Row level
 * security already restricts `service_requests` to the two parties involved, so
 * this is SECURITY INVOKER and leans on that rather than re-implementing it.
 */
create or replace function public.my_garage_requests()
returns table (
  id                  uuid,
  mechanic_id         uuid,
  mechanic_name       text,
  service_name        text,
  customer_name       text,
  phone_number        text,
  vehicle_number      text,
  problem_description text,
  status              request_status,
  eta_minutes         int,
  mechanic_note       text,
  created_at          timestamptz,
  customer_rating     int,
  customer_comment    text
)
language sql
stable
as $$
  select
    r.id, r.mechanic_id, r.mechanic_name, r.service_name,
    r.customer_name, r.phone_number, r.vehicle_number, r.problem_description,
    r.status, r.eta_minutes, r.mechanic_note, r.created_at,
    rv.rating, rv.comment
  from public.service_requests r
  join public.mechanics m on m.id = r.mechanic_id
  left join public.reviews rv on rv.request_id = r.id
  where m.owner_id = auth.uid()
  order by
    -- Work that needs a decision first, finished work last.
    case r.status
      when 'pending' then 0
      when 'accepted' then 1
      when 'in_progress' then 2
      else 3
    end,
    r.created_at desc;
$$;

-- ------------------------------------------------------------------- grants
--
-- Same reasoning as 0004: PostgreSQL grants EXECUTE to PUBLIC by default, so
-- each of these is revoked and then granted only where it belongs.

revoke all on function public.guard_profile_role() from public, anon, authenticated;

revoke all on function public.claim_mechanic(uuid)   from public, anon;
revoke all on function public.release_mechanic(uuid) from public, anon;
revoke all on function public.my_garages()           from public, anon;
revoke all on function public.my_garage_requests()   from public, anon;

grant execute on function public.claim_mechanic(uuid)   to authenticated;
grant execute on function public.release_mechanic(uuid) to authenticated;
grant execute on function public.my_garages()           to authenticated;
grant execute on function public.my_garage_requests()   to authenticated;
