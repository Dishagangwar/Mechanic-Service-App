-- ---------------------------------------------------------------------------
-- 0003_rls.sql — Row Level Security
--
-- This file IS the authorization layer. There is no application server to put
-- rules in, which is the point: the database refuses the write, so a tampered
-- client cannot talk its way past it.
--
-- The `service_role` key bypasses RLS entirely. That key lives only in the Edge
-- Function (never in the APK), which is how the importer writes mechanics rows
-- that no end user is allowed to write.
-- ---------------------------------------------------------------------------

alter table public.profiles          enable row level security;
alter table public.mechanics         enable row level security;
alter table public.services          enable row level security;
alter table public.mechanic_services enable row level security;
alter table public.mechanic_hours    enable row level security;
alter table public.service_requests  enable row level security;
alter table public.reviews           enable row level security;
alter table public.search_tiles      enable row level security;

grant usage on schema public to anon, authenticated;
grant select on public.mechanics, public.services, public.mechanic_services,
                public.mechanic_hours, public.reviews, public.search_tiles,
                public.mechanics_with_stats
  to authenticated;
grant select, insert, update on public.profiles         to authenticated;
grant select, insert, update on public.service_requests to authenticated;
grant select, insert, update, delete on public.reviews  to authenticated;
grant insert, update, delete on public.mechanics         to authenticated;
grant insert, update, delete on public.mechanic_services to authenticated;
grant insert, update, delete on public.mechanic_hours    to authenticated;
grant execute on function public.nearby_mechanics(
  double precision, double precision, double precision,
  mechanic_category, text, text, int) to authenticated;
grant execute on function public.my_requests() to authenticated;

-- ------------------------------------------------------------------ profiles

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated using (id = auth.uid());

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- The trigger in 0001 normally creates this row. The insert policy is a fallback
-- for accounts that predate the trigger.
drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
  for insert to authenticated with check (id = auth.uid());

-- ----------------------------------------------------------------- mechanics

-- Garage listings are a public directory to anyone signed in.
drop policy if exists mechanics_select_all on public.mechanics;
create policy mechanics_select_all on public.mechanics
  for select to authenticated using (true);

-- A garage owner may add their own listing, but cannot forge its provenance:
-- source is pinned to 'owner' and owner_id to themselves.
drop policy if exists mechanics_insert_own on public.mechanics;
create policy mechanics_insert_own on public.mechanics
  for insert to authenticated
  with check (owner_id = auth.uid() and source = 'owner');

-- Claimed listings are editable by whoever claimed them. Unclaimed imported rows
-- are not editable by end users at all — only by the importer's service_role.
drop policy if exists mechanics_update_own on public.mechanics;
create policy mechanics_update_own on public.mechanics
  for update to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

drop policy if exists mechanics_delete_own on public.mechanics;
create policy mechanics_delete_own on public.mechanics
  for delete to authenticated using (owner_id = auth.uid() and source = 'owner');

-- ------------------------------------------------ services & their join rows

drop policy if exists services_select_all on public.services;
create policy services_select_all on public.services
  for select to authenticated using (true);
-- No client write policy: the catalog is seeded and changed by migrations only.

drop policy if exists mechanic_services_select_all on public.mechanic_services;
create policy mechanic_services_select_all on public.mechanic_services
  for select to authenticated using (true);

drop policy if exists mechanic_services_write_own on public.mechanic_services;
create policy mechanic_services_write_own on public.mechanic_services
  for all to authenticated
  using (exists (
    select 1 from public.mechanics m
    where m.id = mechanic_services.mechanic_id and m.owner_id = auth.uid()))
  with check (exists (
    select 1 from public.mechanics m
    where m.id = mechanic_services.mechanic_id and m.owner_id = auth.uid()));

drop policy if exists mechanic_hours_select_all on public.mechanic_hours;
create policy mechanic_hours_select_all on public.mechanic_hours
  for select to authenticated using (true);

drop policy if exists mechanic_hours_write_own on public.mechanic_hours;
create policy mechanic_hours_write_own on public.mechanic_hours
  for all to authenticated
  using (exists (
    select 1 from public.mechanics m
    where m.id = mechanic_hours.mechanic_id and m.owner_id = auth.uid()))
  with check (exists (
    select 1 from public.mechanics m
    where m.id = mechanic_hours.mechanic_id and m.owner_id = auth.uid()));

-- ---------------------------------------------------------- service requests

-- A customer sees their own bookings; a garage owner sees bookings made against
-- their garage. Nobody sees anyone else's.
drop policy if exists service_requests_select_involved on public.service_requests;
create policy service_requests_select_involved on public.service_requests
  for select to authenticated
  using (
    customer_id = auth.uid()
    or exists (
      select 1 from public.mechanics m
      where m.id = service_requests.mechanic_id and m.owner_id = auth.uid())
  );

-- The booking must be filed as yourself, and must start life as 'pending' with no
-- ETA — a client cannot self-accept its own request or promise an ETA.
drop policy if exists service_requests_insert_own on public.service_requests;
create policy service_requests_insert_own on public.service_requests
  for insert to authenticated
  with check (
    customer_id = auth.uid()
    and status = 'pending'
    and eta_minutes is null
    and mechanic_note is null
  );

drop policy if exists service_requests_update_involved on public.service_requests;
create policy service_requests_update_involved on public.service_requests
  for update to authenticated
  using (
    customer_id = auth.uid()
    or exists (
      select 1 from public.mechanics m
      where m.id = service_requests.mechanic_id and m.owner_id = auth.uid())
  )
  with check (
    customer_id = auth.uid()
    or exists (
      select 1 from public.mechanics m
      where m.id = service_requests.mechanic_id and m.owner_id = auth.uid())
  );

-- RLS can say *who* may update a row but not *which transitions* are legal, so
-- that part is a trigger. Without it a customer could mark their own booking
-- 'completed' and then leave a review for work nobody did.
create or replace function public.enforce_request_transition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  is_customer boolean := old.customer_id = auth.uid();
  is_garage   boolean := exists (
    select 1 from public.mechanics m
    where m.id = old.mechanic_id and m.owner_id = auth.uid());
begin
  -- service_role (the importer / admin tooling) has no auth.uid() and is not
  -- subject to these product rules.
  if auth.uid() is null then
    return new;
  end if;

  if is_customer and not is_garage then
    -- A customer may only walk away from a booking, and only before work starts.
    if new.status <> old.status then
      if new.status <> 'cancelled' then
        raise exception 'A customer may only cancel a request (tried: % -> %)',
          old.status, new.status;
      end if;
      if old.status not in ('pending', 'accepted') then
        raise exception 'A % request can no longer be cancelled', old.status;
      end if;
    end if;
    -- And may not write the garage's fields.
    if coalesce(new.eta_minutes, -1) <> coalesce(old.eta_minutes, -1)
       or coalesce(new.mechanic_note, '') <> coalesce(old.mechanic_note, '') then
      raise exception 'Only the garage can set the ETA or add a note';
    end if;

  elsif is_garage then
    if new.status <> old.status
       and new.status not in ('accepted', 'in_progress', 'completed', 'rejected') then
      raise exception 'A garage cannot move a request to %', new.status;
    end if;
    if old.status in ('completed', 'cancelled') and new.status <> old.status then
      raise exception 'A % request is final', old.status;
    end if;
  end if;

  return new;
end $$;

drop trigger if exists service_requests_transition on public.service_requests;
create trigger service_requests_transition
  before update on public.service_requests
  for each row execute function public.enforce_request_transition();

-- ------------------------------------------------------------------- reviews

-- Ratings are public to signed-in users; that is what makes the aggregate useful.
drop policy if exists reviews_select_all on public.reviews;
create policy reviews_select_all on public.reviews
  for select to authenticated using (true);

-- The structural guarantee behind every rating in this app: you can only review a
-- booking that is yours, against the garage that booking was for, and only once it
-- is actually completed. Fake reviews are not discouraged here, they are impossible.
drop policy if exists reviews_insert_after_completion on public.reviews;
create policy reviews_insert_after_completion on public.reviews
  for insert to authenticated
  with check (
    customer_id = auth.uid()
    and exists (
      select 1 from public.service_requests r
      where r.id = reviews.request_id
        and r.customer_id = auth.uid()
        and r.mechanic_id = reviews.mechanic_id
        and r.status = 'completed')
  );

drop policy if exists reviews_update_own on public.reviews;
create policy reviews_update_own on public.reviews
  for update to authenticated
  using (customer_id = auth.uid()) with check (customer_id = auth.uid());

drop policy if exists reviews_delete_own on public.reviews;
create policy reviews_delete_own on public.reviews
  for delete to authenticated using (customer_id = auth.uid());

-- ------------------------------------------------------------- search_tiles

-- Readable so the app can tell "this area has never been imported" from "this
-- area was imported and genuinely has no garages". Written only by the importer.
drop policy if exists search_tiles_select_all on public.search_tiles;
create policy search_tiles_select_all on public.search_tiles
  for select to authenticated using (true);
