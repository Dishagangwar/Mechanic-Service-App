-- ---------------------------------------------------------------------------
-- 0007_backfill_profiles.sql — give every existing account a profile row.
--
-- 0001 added an AFTER INSERT trigger on auth.users to create the matching
-- `profiles` row. Triggers only fire on new rows, so every account that already
-- existed when that migration ran has none — and nothing noticed, because the
-- only hard dependency is a foreign key that nothing exercised until the garage
-- side shipped:
--
--     insert or update on table "mechanics" violates foreign key constraint
--     "mechanics_owner_id_fkey"
--
-- Claiming a garage sets owner_id = auth.uid(), which must exist in profiles.
-- For a pre-trigger account it does not, so every claim failed.
--
-- The same gap silently broke two other things, neither of which reported an
-- error:
--   * rememberLocation() UPDATEs profiles, so it matched zero rows and the
--     user's last search location was never actually saved.
--   * myProfile() found nothing, so the booking form could not pre-fill the
--     name and phone it was supposed to.
-- ---------------------------------------------------------------------------

insert into public.profiles (id, full_name, phone_number)
select
  u.id,
  coalesce(u.raw_user_meta_data ->> 'full_name', ''),
  coalesce(u.raw_user_meta_data ->> 'phone_number', '')
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id)
on conflict (id) do nothing;

-- ------------------------------------------------- make claiming self-healing
--
-- The backfill fixes today's accounts. This makes the operation robust for any
-- account that somehow still lacks a row — a trigger that failed, a user
-- restored from backup, a future auth change. Claiming should not be the thing
-- that discovers a missing profile.

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

  -- Guarantee the row the foreign key needs, built from the same auth metadata
  -- the sign-up trigger would have used.
  insert into public.profiles (id, full_name, phone_number)
  select
    u.id,
    coalesce(u.raw_user_meta_data ->> 'full_name', ''),
    coalesce(u.raw_user_meta_data ->> 'phone_number', '')
  from auth.users u
  where u.id = v_user
  on conflict (id) do nothing;

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

revoke all on function public.claim_mechanic(uuid) from public, anon;
grant execute on function public.claim_mechanic(uuid) to authenticated;
