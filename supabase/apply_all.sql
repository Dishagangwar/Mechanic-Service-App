-- ===========================================================================
-- apply_all.sql — everything, in order, in one file.
--
-- Paste this into the Supabase dashboard SQL editor (SQL Editor > New query)
-- and run it once. It is idempotent: running it again is safe and will refresh
-- the seeded garages without touching any listing a garage owner has claimed.
--
-- Contents:
--   0001_schema.sql          tables, enums, the auth.users -> profiles trigger
--   0002_views_rpc.sql       mechanics_with_stats, nearby_mechanics(), my_requests()
--   0003_rls.sql             row level security + the request transition trigger
--   0004_function_grants.sql revokes PUBLIC's default EXECUTE (see that file)
--   seed/0001_services       the 20-entry service catalog
--   seed/0002_mechanics      206 real garages from OpenStreetMap (ODbL)
--
-- Verified against PostgreSQL 16.
-- ===========================================================================


-- ========================= migrations/0001_schema.sql =========================

-- ---------------------------------------------------------------------------
-- 0001_schema.sql — tables for Instant Mechanic
--
-- Design notes that matter:
--
--  * `mechanics.lat/lng` are NULLABLE and carry `coords_fetched_at`. Google's Maps
--    Platform terms allow caching Places lat/lng for at most 30 consecutive days,
--    so provider-sourced coordinates expire and get nulled by a scheduled job.
--    OSM data is ODbL and has no such limit, so `coords_fetched_at` stays null for it.
--
--  * `is_open` is NOT stored. A stored boolean is wrong the moment the clock moves;
--    it is computed from `mechanic_hours` in 0003 and is NULL when hours are unknown.
--
--  * `rating` / `review_count` are NOT stored. They are aggregates over `reviews`,
--    so a rating can only exist if somebody actually left one.
--
--  * `service_requests` snapshots `mechanic_name` and `service_name`. A booking must
--    stay readable years later even if the mechanic row is edited or its cached
--    coordinates are purged.
-- ---------------------------------------------------------------------------

create extension if not exists pgcrypto;

-- --------------------------------------------------------------------- enums

do $$ begin
  create type mechanic_source as enum ('osm', 'google', 'owner', 'manual');
exception when duplicate_object then null; end $$;

do $$ begin
  create type mechanic_category as enum ('car', 'motorcycle', 'tyres', 'parts');
exception when duplicate_object then null; end $$;

do $$ begin
  create type request_status as enum (
    'pending', 'accepted', 'in_progress', 'completed', 'cancelled', 'rejected'
  );
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------------ profiles

create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  full_name    text        not null default '',
  phone_number text        not null default '',
  role         text        not null default 'customer'
                 check (role in ('customer', 'mechanic', 'admin')),
  -- Last location the user searched from, so a returning user skips the picker.
  last_lat     double precision,
  last_lng     double precision,
  last_label   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table public.profiles is
  'One row per auth user. Populated by the on_auth_user_created trigger from the
   full_name / phone_number keys the Android sign-up writes into user metadata.';

-- Keeps the profile row in step with auth.users without the client having to insert it
-- (and without trusting the client to say who it is).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone_number)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce(new.raw_user_meta_data ->> 'phone_number', '')
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------- mechanics

create table if not exists public.mechanics (
  id          uuid primary key default gen_random_uuid(),

  source      mechanic_source   not null default 'manual',
  -- 'node/123456789' for OSM, a place_id for Google. Null for hand-entered rows.
  external_id text,

  -- Set once a garage owner claims this listing; their edits then win over imported data.
  owner_id    uuid references public.profiles (id) on delete set null,

  name        text              not null,
  -- Many Indian listings are tagged in Devanagari; name:en is kept for search and
  -- for users whose device isn't set to Marathi/Hindi.
  name_en     text,
  category    mechanic_category not null default 'car',

  phone       text,
  website     text,
  brand       text,
  operator    text,

  address_line text,
  locality     text,
  city         text,
  state        text,
  postcode     text,

  lat               double precision,
  lng               double precision,
  -- Non-null only for sources with a retention limit (see header). The purge job in
  -- 0003 nulls lat/lng once this passes 30 days.
  coords_fetched_at timestamptz,

  -- The provider's raw hours string, kept verbatim. Parsed rows live in mechanic_hours;
  -- this stays so an unparseable string is not silently lost.
  opening_hours_raw text,
  timezone          text not null default 'Asia/Kolkata',

  is_active  boolean     not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Makes re-importing a region idempotent.
  constraint mechanics_source_external_id_key unique (source, external_id)
);

-- The nearby RPC prefilters on a lat/lng bounding box before doing any trigonometry,
-- so plain btree indexes are what it needs. Deliberately no PostGIS/earthdistance
-- dependency: at this table's size the bbox + haversine plan is fast and portable.
create index if not exists mechanics_lat_idx    on public.mechanics (lat) where is_active;
create index if not exists mechanics_lng_idx    on public.mechanics (lng) where is_active;
create index if not exists mechanics_city_idx   on public.mechanics (lower(city));
create index if not exists mechanics_owner_idx  on public.mechanics (owner_id);

-- ------------------------------------------------------------------ services

create table if not exists public.services (
  id         uuid primary key default gen_random_uuid(),
  slug       text unique not null,
  name       text        not null,
  -- Null means the service is sensible for any kind of garage.
  category   mechanic_category,
  sort_order int         not null default 100
);

create table if not exists public.mechanic_services (
  mechanic_id uuid not null references public.mechanics (id) on delete cascade,
  service_id  uuid not null references public.services (id)  on delete cascade,
  -- true  = the garage (or its OSM service:vehicle:* tags) actually declared this
  -- false = inferred from the garage's category, so the UI can hedge the wording
  is_declared boolean not null default false,
  price_estimate_inr int,
  primary key (mechanic_id, service_id)
);

create index if not exists mechanic_services_service_idx
  on public.mechanic_services (service_id);

-- ------------------------------------------------------------- opening hours

create table if not exists public.mechanic_hours (
  id          uuid primary key default gen_random_uuid(),
  mechanic_id uuid not null references public.mechanics (id) on delete cascade,
  -- Postgres `extract(dow)` convention: 0 = Sunday.
  day_of_week int  not null check (day_of_week between 0 and 6),
  opens       time not null,
  closes      time not null,
  constraint mechanic_hours_order check (closes > opens)
);

create index if not exists mechanic_hours_mechanic_idx
  on public.mechanic_hours (mechanic_id, day_of_week);

-- ---------------------------------------------------------- service requests

create table if not exists public.service_requests (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references auth.users (id) on delete cascade,
  -- restrict, not cascade: deleting a garage must not quietly delete bookings.
  mechanic_id uuid not null references public.mechanics (id) on delete restrict,
  service_id  uuid references public.services (id) on delete set null,

  -- Snapshots taken at booking time (see header).
  mechanic_name text not null,
  service_name  text not null,

  customer_name       text not null,
  phone_number        text not null,
  vehicle_number      text not null,
  problem_description text not null,

  status         request_status not null default 'pending',
  -- Null until a garage accepts and commits to one. The app previously invented this.
  eta_minutes    int check (eta_minutes is null or eta_minutes between 0 and 10080),
  mechanic_note  text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists service_requests_customer_idx
  on public.service_requests (customer_id, created_at desc);
create index if not exists service_requests_mechanic_idx
  on public.service_requests (mechanic_id, status);

-- ------------------------------------------------------------------- reviews

create table if not exists public.reviews (
  id          uuid primary key default gen_random_uuid(),
  -- One review per booking, which is what makes ratings hard to forge.
  request_id  uuid not null unique references public.service_requests (id) on delete cascade,
  customer_id uuid not null references auth.users (id) on delete cascade,
  mechanic_id uuid not null references public.mechanics (id) on delete cascade,
  rating      int  not null check (rating between 1 and 5),
  comment     text,
  created_at  timestamptz not null default now()
);

create index if not exists reviews_mechanic_idx on public.reviews (mechanic_id);

-- ------------------------------------------------------- region cache ledger

-- Which map regions have already been pulled from a provider, so a second user
-- searching the same area costs nothing. Keyed by a coarse geohash (~5 km at
-- precision 5).
create table if not exists public.search_tiles (
  id             uuid primary key default gen_random_uuid(),
  geohash        text            not null,
  source         mechanic_source not null,
  radius_m       int             not null,
  mechanic_count int             not null default 0,
  fetched_at     timestamptz     not null default now(),
  constraint search_tiles_geohash_source_key unique (geohash, source)
);

-- ------------------------------------------------------ updated_at bookkeeping

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

drop trigger if exists mechanics_touch on public.mechanics;
create trigger mechanics_touch before update on public.mechanics
  for each row execute function public.touch_updated_at();

drop trigger if exists service_requests_touch on public.service_requests;
create trigger service_requests_touch before update on public.service_requests
  for each row execute function public.touch_updated_at();

-- ========================= migrations/0002_views_rpc.sql =========================

-- ---------------------------------------------------------------------------
-- 0002_views_rpc.sql — derived reads
--
-- Everything the list and detail screens show that is NOT a stored column lives
-- here: live open/closed, real rating aggregates, the service name array, and
-- distance from wherever the user said they are.
-- ---------------------------------------------------------------------------

-- ------------------------------------------------- mechanics_with_stats view

create or replace view public.mechanics_with_stats
with (security_invoker = true) as
select
  m.id,
  m.source,
  m.external_id,
  m.owner_id,
  m.name,
  m.name_en,
  m.category,
  m.phone,
  m.website,
  m.brand,
  m.operator,
  m.address_line,
  m.locality,
  m.city,
  m.state,
  m.postcode,
  m.lat,
  m.lng,
  m.opening_hours_raw,
  m.timezone,
  m.is_active,

  -- NULL, not false, when nobody knows the hours. The app renders that as
  -- "Hours not listed" rather than claiming the garage is shut.
  case
    when not exists (
      select 1 from public.mechanic_hours h where h.mechanic_id = m.id
    ) then null
    else exists (
      select 1
      from public.mechanic_hours h
      where h.mechanic_id = m.id
        and h.day_of_week = extract(dow from (now() at time zone m.timezone))::int
        and (now() at time zone m.timezone)::time between h.opens and h.closes
    )
  end as is_open,

  -- NULL until a real review exists. No invented 4.6s.
  (select round(avg(r.rating)::numeric, 1)
     from public.reviews r where r.mechanic_id = m.id) as rating,
  (select count(*)
     from public.reviews r where r.mechanic_id = m.id) as review_count,

  -- Declared services first so a garage's own list leads, then inferred ones.
  coalesce((
    select array_agg(s.name order by ms.is_declared desc, s.sort_order, s.name)
    from public.mechanic_services ms
    join public.services s on s.id = ms.service_id
    where ms.mechanic_id = m.id
  ), '{}'::text[]) as services,

  -- Lets the UI say "listed by the garage" vs "typical for this type".
  exists (
    select 1 from public.mechanic_services ms
    where ms.mechanic_id = m.id and ms.is_declared
  ) as has_declared_services

from public.mechanics m;

comment on view public.mechanics_with_stats is
  'Read model for the mechanic list and detail screens. is_open, rating and
   review_count are derived — none of them are stored columns.';

-- -------------------------------------------------------- nearby_mechanics()

-- Distance search around an arbitrary point. The user picks that point (GPS or a
-- typed place), so nothing here is tied to one city.
--
-- Plan: cheap lat/lng bounding-box filter on the btree indexes, then haversine on
-- the survivors. No PostGIS or earthdistance extension needed.
create or replace function public.nearby_mechanics(
  p_lat       double precision,
  p_lng       double precision,
  p_radius_km double precision default 10,
  p_category  mechanic_category default null,
  p_service   text default null,
  p_query     text default null,
  p_limit     int default 100
)
returns table (
  id            uuid,
  name          text,
  name_en       text,
  category      mechanic_category,
  phone         text,
  website       text,
  brand         text,
  address_line  text,
  locality      text,
  city          text,
  postcode      text,
  lat           double precision,
  lng           double precision,
  opening_hours_raw text,
  is_open       boolean,
  rating        numeric,
  review_count  bigint,
  services      text[],
  has_declared_services boolean,
  source        mechanic_source,
  distance_km   double precision
)
language sql
stable
as $$
  with bounds as (
    select
      -- 1 degree of latitude is ~111.045 km anywhere.
      p_radius_km / 111.045 as d_lat,
      -- Longitude degrees shrink towards the poles. The guard keeps this finite
      -- if anyone ever searches from very near a pole.
      p_radius_km / (111.045 * greatest(cos(radians(p_lat)), 0.01)) as d_lng
  )
  select
    v.id, v.name, v.name_en, v.category, v.phone, v.website, v.brand,
    v.address_line, v.locality, v.city, v.postcode, v.lat, v.lng,
    v.opening_hours_raw, v.is_open, v.rating, v.review_count,
    v.services, v.has_declared_services, v.source,
    round(
      (2 * 6371 * asin(sqrt(
         power(sin(radians(v.lat - p_lat) / 2), 2) +
         cos(radians(p_lat)) * cos(radians(v.lat)) *
         power(sin(radians(v.lng - p_lng) / 2), 2)
      )))::numeric, 2
    )::double precision as distance_km
  from public.mechanics_with_stats v, bounds b
  where v.is_active
    and v.lat is not null
    and v.lng is not null
    and v.lat between p_lat - b.d_lat and p_lat + b.d_lat
    and v.lng between p_lng - b.d_lng and p_lng + b.d_lng
    and (p_category is null or v.category = p_category)
    and (p_service  is null or p_service = any (v.services))
    and (
      p_query is null or p_query = '' or
      v.name    ilike '%' || p_query || '%' or
      v.name_en ilike '%' || p_query || '%' or
      coalesce(v.locality, '') ilike '%' || p_query || '%'
    )
    -- Exact circle, applied after the cheap box filter above.
    and (2 * 6371 * asin(sqrt(
          power(sin(radians(v.lat - p_lat) / 2), 2) +
          cos(radians(p_lat)) * cos(radians(v.lat)) *
          power(sin(radians(v.lng - p_lng) / 2), 2)
        ))) <= p_radius_km
  order by distance_km
  limit least(coalesce(p_limit, 100), 200);
$$;

comment on function public.nearby_mechanics is
  'Mechanics within p_radius_km of an arbitrary point, nearest first. The point
   comes from the user (GPS or a typed location), so this is region-agnostic.';

-- --------------------------------------------------- my_requests() read model

-- Bookings for the signed-in user, newest first, with the review they left (if any).
create or replace function public.my_requests()
returns table (
  id                  uuid,
  mechanic_id         uuid,
  mechanic_name       text,
  service_name        text,
  vehicle_number      text,
  problem_description text,
  status              request_status,
  eta_minutes         int,
  mechanic_note       text,
  created_at          timestamptz,
  my_rating           int,
  my_comment          text
)
language sql
stable
as $$
  select
    r.id, r.mechanic_id, r.mechanic_name, r.service_name, r.vehicle_number,
    r.problem_description, r.status, r.eta_minutes, r.mechanic_note, r.created_at,
    rv.rating, rv.comment
  from public.service_requests r
  left join public.reviews rv on rv.request_id = r.id
  where r.customer_id = auth.uid()
  order by r.created_at desc;
$$;

-- ------------------------------------------------- coordinate retention purge

-- Google's Maps Platform terms cap caching of Places lat/lng at 30 consecutive
-- days. Rows whose source has no such limit (OSM, owner-entered) leave
-- coords_fetched_at null and are never touched by this.
create or replace function public.purge_expired_coordinates()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  affected int;
begin
  update public.mechanics
     set lat = null,
         lng = null,
         coords_fetched_at = null
   where coords_fetched_at is not null
     and coords_fetched_at < now() - interval '30 days';
  get diagnostics affected = row_count;

  -- Force a refetch of any tile whose coordinates have just gone.
  delete from public.search_tiles
   where source = 'google'
     and fetched_at < now() - interval '30 days';

  return affected;
end $$;

-- Enable pg_cron in the Supabase dashboard (Database > Extensions), then run this
-- once to schedule the purge nightly at 03:15 UTC:
--
--   select cron.schedule(
--     'purge-expired-coordinates', '15 3 * * *',
--     $job$ select public.purge_expired_coordinates(); $job$
--   );

-- ========================= migrations/0003_rls.sql =========================

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

-- ========================= migrations/0004_function_grants.sql =========================

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

-- ========================= seed/0001_services.sql =========================

-- ---------------------------------------------------------------------------
-- 0001_services.sql — the canonical service catalog.
--
-- The old app stored services as a free-text array per garage, so "Oil Change"
-- and "Oil change" were different services and nothing could be filtered on.
-- This is the single list everything joins to.
-- ---------------------------------------------------------------------------

insert into public.services (slug, name, category, sort_order) values
  ('full-service',        'Full Service',         null,         10),
  ('engine-repair',       'Engine Repair',        'car',         20),
  ('oil-change',          'Oil Change',           null,         30),
  ('brake-service',       'Brake Service',        null,         40),
  ('clutch-repair',       'Clutch Repair',        'car',         50),
  ('battery-replacement', 'Battery Replacement',  null,         60),
  ('electrical-work',     'Electrical Work',      null,         70),
  ('ac-service',          'AC Service',           'car',        80),
  ('diagnostics',         'Diagnostics',          null,         90),
  ('inspection',          'Vehicle Inspection',   null,        100),
  ('wheel-alignment',     'Wheel Alignment',      null,        110),
  ('tyre-replacement',    'Tyre Replacement',     null,        120),
  ('puncture-repair',     'Puncture Repair',      null,        130),
  ('denting-painting',    'Denting & Painting',   'car',       140),
  ('body-repair',         'Body Repair',          'car',       150),
  ('two-wheeler-service', 'Two Wheeler Service',  'motorcycle',160),
  ('chain-sprocket',      'Chain & Sprocket',     'motorcycle',170),
  ('car-wash',            'Car Wash & Cleaning',  null,        180),
  ('spare-parts',         'Spare Parts',          'parts',     190),
  ('towing',              'Towing',               null,        200)
on conflict (slug) do update
  set name = excluded.name,
      category = excluded.category,
      sort_order = excluded.sort_order;

-- ========================= seed/0002_mechanics_osm.sql =========================

-- -------------------------------------------------------------------------
-- 0002_mechanics_osm.sql  —  GENERATED, do not hand-edit.
--
-- Real auto-repair businesses from OpenStreetMap (ODbL). Re-running is safe:
-- every statement upserts on (source, external_id).
--
-- 206 garages across 7 cities.
-- phone: 40 (19%)   parseable hours: 20 (9%)   declared services: 8
--
-- The gaps are real. Rows without a phone render no call button; rows without
-- hours report is_open = NULL. Nothing here is invented to fill a column.
--
-- Attribution required by ODbL: data (c) OpenStreetMap contributors.
-- -------------------------------------------------------------------------

insert into public.mechanics (
  id, source, external_id, name, name_en, category, phone, website, brand,
  operator, address_line, locality, city, state, postcode, lat, lng,
  opening_hours_raw, timezone
) values
  ('6be9e13b-7e37-5fc4-8ad1-ee4a147d6db4', 'osm', 'node/1305484841', 'Guru Kripa Tyres', null, 'tyres', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6166351, 77.2877305, null, 'Asia/Kolkata'),
  ('c47b1e09-eb36-5ffc-bb59-80f1e30bdccc', 'osm', 'node/4582253690', 'Benelli Motorcycle Delhi', 'Benelli Motorcycle Delhi', 'car', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6468148, 77.1977758, null, 'Asia/Kolkata'),
  ('a6d29523-3098-5d50-9082-1ca73686ead3', 'osm', 'node/5269340451', 'Auto Mark', null, 'parts', '+919899070777', null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6118955, 77.2887799, null, 'Asia/Kolkata'),
  ('41759a2f-d38a-59b7-9c47-0dea3efc5db1', 'osm', 'node/5273128898', 'Parwaj Auto Mobile', null, 'car', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6118504, 77.2888160, null, 'Asia/Kolkata'),
  ('f4d888f1-1b3a-565a-9f60-d7cddafc3437', 'osm', 'node/5273129412', 'Rohit Motors', null, 'car', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6118611, 77.2888129, null, 'Asia/Kolkata'),
  ('3f02a878-6448-5e07-a24b-c73cc0d9bc59', 'osm', 'node/5642285315', 'The Detailing Mafia', null, 'parts', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5375606, 77.2109314, null, 'Asia/Kolkata'),
  ('eae9aa7b-93d9-5f27-a0b3-fcabdbe69fb6', 'osm', 'node/5804017973', 'Khanna Automobiles', null, 'motorcycle', '+919868973306', null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5254016, 77.2056364, null, 'Asia/Kolkata'),
  ('33537a37-a3bb-5048-9f53-641d9f640d55', 'osm', 'node/6110288721', 'Detailing Devils', null, 'car', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6021514, 77.2371256, null, 'Asia/Kolkata'),
  ('dbfc43eb-2284-508b-a4d1-81f28c927b5a', 'osm', 'node/6225480442', 'True North', null, 'car', null, null, 'Tata', null, null, null, 'Delhi', 'Delhi', null, 28.6332528, 77.1271390, null, 'Asia/Kolkata'),
  ('e02b1966-a3e1-584a-be1f-e24cae9b3c86', 'osm', 'node/6284673525', 'Two Brothers Design', null, 'parts', '+919711510017', 'https://www.twobrothers.co.in', null, null, 'B-82', 'Lajpat Nagar I', 'Delhi', 'Delhi', '110024', 28.5743776, 77.2394121, 'Tu-Su 11:30-20:30', 'Asia/Kolkata'),
  ('6d426394-8a34-5bf7-bd78-f2c8ea35f6b7', 'osm', 'node/6961442926', 'The Detailing Mafia', null, 'parts', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5908759, 77.1961181, null, 'Asia/Kolkata'),
  ('8d7f85f2-0f3e-574c-8c54-4f52ac29c080', 'osm', 'node/7193086024', 'The Tyre Plaza', null, 'tyres', '+919810301135', null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5758000, 77.2390491, 'Mo-Su 11:00-20:00', 'Asia/Kolkata'),
  ('ac998672-03be-50c3-b2c9-c719c516792e', 'osm', 'node/7334256834', 'Taaj Automobiles', null, 'car', '+918527610064', null, null, null, '5 Maruti Apartment', null, 'Delhi', 'Delhi', '110092', 28.6228089, 77.2908624, null, 'Asia/Kolkata'),
  ('48c162bf-4208-5193-80f8-576d73f90788', 'osm', 'node/8984990859', 'Rinku car mechanic', null, 'car', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6874041, 77.1838507, null, 'Asia/Kolkata'),
  ('13493a05-bf1a-5d5e-b42b-c76f3e0cf415', 'osm', 'node/8985017272', 'Wheel Emporium', null, 'tyres', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6818094, 77.1846778, null, 'Asia/Kolkata'),
  ('77280025-a435-5128-9282-cc3f52d04828', 'osm', 'node/8985017273', 'MRF Tyres', null, 'tyres', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6840184, 77.1827017, null, 'Asia/Kolkata'),
  ('03cfdb7d-7903-5287-bc83-ce8fadd4fac4', 'osm', 'node/10886146418', 'Delhi Auto Spares', null, 'motorcycle', '+919999099456', null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6296543, 77.2773303, null, 'Asia/Kolkata'),
  ('f6e7fff2-5fa2-5a84-a12a-2b6a8f27c178', 'osm', 'node/10924124849', 'Krishna Motor Garage', null, 'car', null, null, null, null, 'M-46 Middle Circle', 'Connaught Place', 'Delhi', 'Delhi', '110001', 28.6333490, 77.2221350, null, 'Asia/Kolkata'),
  ('62538202-654d-5bf0-91a8-bc40919b064a', 'osm', 'node/10931188070', 'Surjeet Automobile & Service Station', null, 'car', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6220478, 77.2939277, null, 'Asia/Kolkata'),
  ('904ae6a1-8f22-5f8d-b978-5df7bb01eba8', 'osm', 'node/11412068433', 'Shri Balaji Auto Service Point', null, 'motorcycle', '+919582802367', null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6224496, 77.2948794, null, 'Asia/Kolkata'),
  ('9c2b1073-60d1-5639-a7f2-096cd36a1e2d', 'osm', 'node/11586192742', 'Al-Fisha Tyres Company', null, 'tyres', '+919540404703', null, null, null, '3', 'Hasanpur Depot', 'Delhi', 'Delhi', '110092', 28.6364014, 77.3053951, null, 'Asia/Kolkata'),
  ('2d3b7e4a-0714-545f-bd36-db557a0661d1', 'osm', 'node/11597482388', 'Gulati Automobiles', null, 'motorcycle', '+919811973597', null, 'TVS', null, '1 Lawrence Road', null, 'Delhi', 'Delhi', null, 28.6836795, 77.1476511, null, 'Asia/Kolkata'),
  ('8ecb1908-3c4a-5b5b-b5ec-5e726b0d1d18', 'osm', 'node/11659648791', 'Image Authorised Service Station', null, 'car', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5936085, 77.2969153, null, 'Asia/Kolkata'),
  ('80d68f02-b7c2-5513-9f39-b9bbc89a1a0c', 'osm', 'node/11901174291', 'Gulati Work Shop', null, 'motorcycle', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5963568, 77.1329885, null, 'Asia/Kolkata'),
  ('6c72a221-bf5c-52ac-b8b8-01cba2a6abde', 'osm', 'node/11955856409', 'Kalsi Motors', null, 'car', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5924139, 77.1206264, null, 'Asia/Kolkata'),
  ('af0920e4-10a7-5401-8e70-f833a4f914e0', 'osm', 'node/12020183774', 'Sadhu Tyre House', null, 'tyres', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6613049, 77.2870184, null, 'Asia/Kolkata'),
  ('2b14a5c7-e6f1-5bd0-a68e-b671daf6c3c8', 'osm', 'node/12114337951', 'Tata car spare parts', null, 'car', null, null, 'Tata', null, 'ram lal Chandhok Marg', 'Kashmere Gate', 'Delhi', 'Delhi', null, 28.6652908, 77.2296513, null, 'Asia/Kolkata'),
  ('9493694e-909d-5bb7-8c39-26ddc0482904', 'osm', 'node/12486497449', 'AutoSitz India', null, 'parts', null, 'https://www.AutoSitzIndia.com', 'AutoSitz India', 'Moonspark Enterprise', '1/778, Nicholson Road', 'Delhi', 'Delhi', 'Delhi', '110006', 28.6654854, 77.2271594, 'Mon-Sat 11:30-20:00', 'Asia/Kolkata'),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', 'osm', 'node/12640886201', 'Evps technology', null, 'motorcycle', null, null, null, null, '1264/4 1264/4 gali no 4 karolbagh New Delhi 110005', null, 'Delhi', 'Delhi', '110005', 28.6488355, 77.1978773, 'Tu-Su 12:00-18:00', 'Asia/Kolkata'),
  ('adc476a7-dff8-5ebb-a59c-5d71dd430042', 'osm', 'node/12718990600', 'Auto Spare Parts', null, 'car', '+918430725054', null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6234454, 77.2890719, null, 'Asia/Kolkata'),
  ('b31f6b6d-4b40-5e47-8afb-04028a026141', 'osm', 'node/12718993221', 'Pradeep Auto Mechanic', null, 'motorcycle', '+919953929469', null, null, null, 'Buddha Marg', 'Mandawali', 'Delhi', 'Delhi', '110092', 28.6232343, 77.2889624, null, 'Asia/Kolkata'),
  ('2e329f24-ee7d-5709-a32d-ba7f5f84b404', 'osm', 'node/12896531742', 'Shiv Auto', null, 'motorcycle', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6326067, 77.2063906, null, 'Asia/Kolkata'),
  ('f1f9da57-74cc-5dda-b879-fde9a018cce9', 'osm', 'node/12896534721', 'Shiv Auto', null, 'motorcycle', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6326508, 77.2065207, null, 'Asia/Kolkata'),
  ('83cab5f1-0702-5562-9491-29f3c5107e04', 'osm', 'node/12896534722', 'Gulati Auto Repair', null, 'motorcycle', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6326564, 77.2064474, null, 'Asia/Kolkata'),
  ('c67507f6-e9d5-5c05-ac5d-c9ec20b365b1', 'osm', 'node/13061658553', 'M.K. Autoworks', null, 'car', '+919891652551', null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6290284, 77.2777789, null, 'Asia/Kolkata'),
  ('5489620e-ef24-55ac-b1e0-ef01f8fe62cd', 'osm', 'node/13110027587', 'Trakto Diesel Spares', null, 'car', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6823702, 77.1999028, null, 'Asia/Kolkata'),
  ('164afc1e-3930-5a2f-8e21-b5eaa4af1ee6', 'osm', 'node/13110159251', 'Shivam Sales Corporation', 'Shivam Sales Corporation', 'parts', null, null, 'Honda', null, null, null, 'Delhi', 'Delhi', null, 28.6791272, 77.2010661, null, 'Asia/Kolkata'),
  ('15e7e250-32c2-5b3d-ae27-1a85253ef0e4', 'osm', 'node/13447665106', 'Satnam Motors', null, 'car', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6330357, 77.2169568, 'PH open', 'Asia/Kolkata'),
  ('84552a2e-b84f-55b2-9562-5edfa5fc8bd5', 'osm', 'node/13621275517', 'Mayur Tyre', null, 'tyres', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.6043201, 77.2931360, null, 'Asia/Kolkata'),
  ('91384a36-0bc6-583c-9677-468ded8a520c', 'osm', 'node/13820115507', 'Auto Marc', null, 'parts', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5660066, 77.2333742, null, 'Asia/Kolkata'),
  ('0d862dbd-3b13-545d-bd7e-58b8b716733b', 'osm', 'node/13820116601', 'Sachedeva Motors', null, 'parts', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5661196, 77.2332831, null, 'Asia/Kolkata'),
  ('c1fadcfd-2f6e-5b5e-8c8f-e511dffdb620', 'osm', 'node/13846287160', 'Goodyear Autocare', null, 'tyres', '+919810555139', null, 'Goodyear;MRF;Bridgestone', 'Maruti Traders', null, null, 'Delhi', 'Delhi', null, 28.6195932, 77.2858160, null, 'Asia/Kolkata'),
  ('003948b4-5b95-53eb-86b7-e05c44e2f342', 'osm', 'node/13982683994', 'Bhim Auto', null, 'parts', null, null, null, null, 'G-83', null, 'Delhi', 'Delhi', null, 28.5738127, 77.2167310, null, 'Asia/Kolkata'),
  ('111a0835-1fa3-5ab7-a8be-9869d63f6359', 'osm', 'node/13982741916', 'Car Accessories', null, 'parts', '+918447255206', null, null, null, 'G-91', null, 'Delhi', 'Delhi', null, 28.5739002, 77.2167430, null, 'Asia/Kolkata'),
  ('106fb93d-277b-59b5-8856-51588c79c157', 'osm', 'node/14041377397', 'Auto Service Hero', null, 'motorcycle', null, null, 'Hero', null, null, null, 'Delhi', 'Delhi', null, 28.5694074, 77.2432661, null, 'Asia/Kolkata'),
  ('f7b128f7-2224-5f20-b051-4c0fe934f81b', 'osm', 'node/14046155129', 'Prince Spares', null, 'parts', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5656179, 77.1812991, null, 'Asia/Kolkata'),
  ('56c48ca5-7cc0-59b0-8af1-692a167564d5', 'osm', 'node/14046155267', 'Balaji Motor Bike Centre', null, 'motorcycle', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5657330, 77.1814000, null, 'Asia/Kolkata'),
  ('0dffdffb-1ee4-5380-9a35-ffe31d5d3e62', 'osm', 'node/14046155319', 'Jai Maa Santoshi Motors', null, 'parts', null, null, null, null, null, null, 'Delhi', 'Delhi', null, 28.5657836, 77.1814207, null, 'Asia/Kolkata'),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', 'osm', 'node/2466610123', 'Fiat Service', null, 'car', null, null, 'Fiat', null, null, null, 'Hyderabad', 'Telangana', null, 17.4235286, 78.4110425, '09:00-18:00', 'Asia/Kolkata'),
  ('c1701d10-266c-598e-8771-b603c7f8d6ca', 'osm', 'node/2715287495', 'SK Motors', null, 'car', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.4098857, 78.4857379, null, 'Asia/Kolkata'),
  ('6d3f0b63-3374-54f7-b6ea-221b07b17447', 'osm', 'node/2784821589', 'SLN Car Decors', null, 'car', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.4101367, 78.4855504, null, 'Asia/Kolkata'),
  ('2e40824f-7623-5e82-b832-43ba74c012c4', 'osm', 'node/3259919571', 'maruti suzuki service center', null, 'car', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.4049199, 78.5000197, null, 'Asia/Kolkata'),
  ('c6cb3634-5dc6-5b2a-80ee-5289786fe144', 'osm', 'node/5163286623', 'Royal Diesel Service', null, 'car', null, null, null, null, 'Saraswathnagar colony', null, 'Hyderabad', 'Telangana', null, 17.3428802, 78.5585841, null, 'Asia/Kolkata'),
  ('9bb0d3e9-eb95-5e0c-b42a-5666729de8c2', 'osm', 'node/5928150385', 'Maximus Automobile engineer s', null, 'car', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3792138, 78.4291980, null, 'Asia/Kolkata'),
  ('a8dfea36-bc17-5e6d-a257-2347f13f233d', 'osm', 'node/6198707986', 'Car Repair', null, 'car', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3948870, 78.4639089, null, 'Asia/Kolkata'),
  ('a423a6ff-2042-5ffb-8c59-568f1164e9cd', 'osm', 'node/6216842790', 'Bike Parts', null, 'parts', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3915500, 78.4667608, null, 'Asia/Kolkata'),
  ('1b4a8f2b-07a8-5ccc-a42c-d55f30340649', 'osm', 'node/6571756955', 'Laxmi Ganapathi Motors', null, 'motorcycle', null, null, null, null, 'Road No 7', null, 'Hyderabad', 'Telangana', '500039', 17.4227756, 78.5662354, null, 'Asia/Kolkata'),
  ('3a125d66-4571-5ddb-9ce7-3ea7686c2f72', 'osm', 'node/6575375658', 'Javeed Bike Point', null, 'motorcycle', '+919705405027', null, null, 'Md Javeed', null, null, 'Hyderabad', 'Telangana', null, 17.4217834, 78.5654280, null, 'Asia/Kolkata'),
  ('d1c277d6-9103-560b-b932-2833d6850589', 'osm', 'node/6581371215', 'Laxmi Ganapathi Motors', null, 'car', '+919505742248', null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.4232320, 78.5668789, null, 'Asia/Kolkata'),
  ('2137d6fa-0800-546f-8898-8ae0b443e72b', 'osm', 'node/6593421939', 'Riders Bike Point', null, 'motorcycle', '+919391076478', null, null, 'Md Javeed', null, null, 'Hyderabad', 'Telangana', null, 17.4229759, 78.5683651, null, 'Asia/Kolkata'),
  ('46ef8925-1e2d-58f2-bd38-e12fabb8987b', 'osm', 'node/6593421959', 'Sairam Bike Point', null, 'motorcycle', '+919848041938', null, null, 'T Raju', null, null, 'Hyderabad', 'Telangana', null, 17.4206257, 78.5647159, null, 'Asia/Kolkata'),
  ('719a9d5b-9732-5414-bf9f-986859098123', 'osm', 'node/7243907164', 'arvindh bike point', null, 'motorcycle', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3967828, 78.5026708, null, 'Asia/Kolkata'),
  ('212ab116-1da4-5b4e-9c47-04fc4495157e', 'osm', 'node/7243950730', 'raghavendra bike point', null, 'car', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3972624, 78.5023188, null, 'Asia/Kolkata'),
  ('107f8325-8d89-5f10-b9c5-9fb413f031d4', 'osm', 'node/7244487820', 'Sahu motors', null, 'motorcycle', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3949365, 78.4351180, null, 'Asia/Kolkata'),
  ('639f23e4-b3dd-5b2b-aafb-15512ab18475', 'osm', 'node/7246803478', 'Ashoka wheels', null, 'tyres', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3952998, 78.4325466, null, 'Asia/Kolkata'),
  ('edfe89a0-23dc-554b-84ed-2c70b0e8ac74', 'osm', 'node/7698796785', 'Exide Bettery Store', null, 'parts', null, null, null, null, '5th Lane', null, 'Hyderabad', 'Telangana', '500038', 17.4413474, 78.4458889, null, 'Asia/Kolkata'),
  ('f6f64e61-f013-50a2-aff1-109b8b056259', 'osm', 'node/8041890297', 'Bajaj Service Centre', null, 'motorcycle', null, null, null, null, 'SuryaNagar Colony Road', null, 'Hyderabad', 'Telangana', '500039', 17.3973083, 78.5617122, null, 'Asia/Kolkata'),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', 'osm', 'node/8066266609', 'M S MOTORS', 'M S MOTORS', 'car', '+919959200600', null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3662432, 78.5568481, 'Mo-Sa 09:00-21:00', 'Asia/Kolkata'),
  ('6d266468-465f-5ed2-818e-bb725e2fb2e8', 'osm', 'node/8111317707', 'Toyota', null, 'car', null, null, 'Toyota', null, 'Uppal', null, 'Hyderabad', 'Telangana', '500039', 17.4027048, 78.5722994, null, 'Asia/Kolkata'),
  ('b1ba39fa-4644-542f-b861-119e54cf90c0', 'osm', 'node/8113812653', 'Surya motor works', null, 'motorcycle', null, null, null, null, 'Sanathnagar', null, 'Hyderabad', 'Telangana', '500018', 17.4510022, 78.4434478, null, 'Asia/Kolkata'),
  ('929452ad-5990-5e6a-b7b0-ed48a07d39dd', 'osm', 'node/8389354230', 'Saboo Hyundai Service', null, 'car', null, null, null, 'Hyundai', 'Nacharam road', null, 'Hyderabad', 'Telangana', '500076', 17.4384498, 78.5595125, null, 'Asia/Kolkata'),
  ('f43c4a61-5643-558f-b2dc-f845618b6048', 'osm', 'node/10279266072', 'Mercedes-Benz', null, 'car', null, null, 'Mercedes-Benz', null, 'Beside Dmart Sanath Nagar Main Road', null, 'Hyderabad', 'Telangana', null, 17.4564036, 78.4457701, null, 'Asia/Kolkata'),
  ('08b58440-fff6-5117-bc3f-e998263f1383', 'osm', 'node/10279266088', 'Gem Suzuki Service Center', null, 'motorcycle', null, null, null, null, 'matha nagar', null, 'Hyderabad', 'Telangana', null, 17.4242071, 78.4553754, null, 'Asia/Kolkata'),
  ('dd65d9b0-543d-51e9-8853-659d3eb92dfd', 'osm', 'node/10279728131', 'Hyundai Service Center', null, 'car', null, null, 'Hyundai', null, 'Yousufguda Main Road', null, 'Hyderabad', 'Telangana', null, 17.4354249, 78.4316774, null, 'Asia/Kolkata'),
  ('80f68483-7350-5438-99cf-e9bd7553701e', 'osm', 'node/10279842288', 'Maruthi Suzuki Service Center', null, 'car', null, null, 'Suzuki', null, 'Begumpet Road', null, 'Hyderabad', 'Telangana', null, 17.4414361, 78.4586539, null, 'Asia/Kolkata'),
  ('5aaf4dea-83a0-530a-aace-e0a274f00acb', 'osm', 'node/11016292853', 'MG', null, 'car', null, null, 'MG', null, 'Vinayakanagar Colony', 'Bala Nagar', 'Hyderabad', 'Telangana', null, 17.4600833, 78.4588100, null, 'Asia/Kolkata'),
  ('3ad3d3d4-3479-5863-a3c0-b7dff15b1440', 'osm', 'node/11118266155', 'Sri Sai Automobiles & Electricals', null, 'parts', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.4191186, 78.5651524, null, 'Asia/Kolkata'),
  ('e1dd73b9-68b7-5086-a084-6d3b78be380d', 'osm', 'node/11690784190', 'michelin tyres and services', null, 'motorcycle', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3593576, 78.5442878, null, 'Asia/Kolkata'),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', 'osm', 'node/12112238201', 'Electric vehicles services centre', null, 'motorcycle', null, null, null, null, 'HMDA layout', null, 'Hyderabad', 'Telangana', '500039', 17.3904648, 78.5480125, 'Mo-Sa 09:00-18:00', 'Asia/Kolkata'),
  ('fcf678aa-71a3-576c-88c2-892229db3989', 'osm', 'node/12112241501', 'Jas Ev', null, 'motorcycle', null, null, null, null, 'Ramkote Rd', null, 'Hyderabad', 'Telangana', null, 17.3922347, 78.4888209, null, 'Asia/Kolkata'),
  ('8065ebed-1abe-57f8-b532-f46e559e13ad', 'osm', 'node/12854642106', 'Baqar Bike Mechanic', null, 'motorcycle', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.4198099, 78.4631353, null, 'Asia/Kolkata'),
  ('cef45b4b-dc5d-5a34-a298-91a2437a7cb0', 'osm', 'node/13536912466', 'Meter Works', null, 'motorcycle', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.4268545, 78.4871970, null, 'Asia/Kolkata'),
  ('00d0f195-fd45-538e-aab9-6f5e60f8c6a6', 'osm', 'node/13536912468', 'Helmet World', null, 'parts', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.4282500, 78.4879947, null, 'Asia/Kolkata'),
  ('77998f10-85f1-5fd5-b79f-459c4cbcf734', 'osm', 'node/13673586499', 'Repair shop', null, 'motorcycle', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3733528, 78.4670480, null, 'Asia/Kolkata'),
  ('16241a15-a43e-5807-9140-544a0bc53440', 'osm', 'way/252413988', 'Image Car Clinic', null, 'car', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3711559, 78.5684496, null, 'Asia/Kolkata'),
  ('d909c95f-7d9d-5e7b-8449-ae9ac3d62677', 'osm', 'way/253191871', 'Maruthi Service Station', null, 'car', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3751938, 78.5558985, null, 'Asia/Kolkata'),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', 'osm', 'way/356500581', '3M Care Care', null, 'car', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.4231872, 78.4620350, '09:30-20:00', 'Asia/Kolkata'),
  ('d98a82bd-049a-56d2-b412-341ae6fe5085', 'osm', 'way/357455772', 'new age car service', null, 'car', null, null, null, null, null, null, 'Hyderabad', 'Telangana', null, 17.3600559, 78.5448046, null, 'Asia/Kolkata'),
  ('b609fda6-38de-5469-bccc-b656f6124646', 'osm', 'node/7066241333', 'Goodyear dealer', null, 'tyres', null, null, null, null, null, null, 'Jaipur', 'Rajasthan', null, 26.9069649, 75.7526626, null, 'Asia/Kolkata'),
  ('8457abf6-8ac4-502b-9d86-537755e4f6a5', 'osm', 'node/7085549983', 'Dhaliwal & Company', null, 'tyres', null, null, null, null, null, null, 'Jaipur', 'Rajasthan', null, 26.9220000, 75.7497310, null, 'Asia/Kolkata'),
  ('b60123f4-8fcd-5988-94d8-fa80dc3349bf', 'osm', 'node/8115463755', 'Mama wheel repairing center', null, 'tyres', null, null, null, null, '3, Near Govt Hostel Sardar Patel Road', null, 'Jaipur', 'Rajasthan', null, 26.9171591, 75.8009252, null, 'Asia/Kolkata'),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', 'osm', 'node/10228123080', 'Ekna Car Care', null, 'car', '+916376125688', null, null, 'Ekna Car Care', '4', null, 'Jaipur', 'Rajasthan', '302020', 26.8582286, 75.7362060, 'Mo-Su 09:00-21:00', 'Asia/Kolkata'),
  ('d8a18579-3dcf-5547-aa52-010610f088ab', 'osm', 'node/10960889885', 'Apollo Tyres', null, 'tyres', null, null, 'Apollo Tyres', null, null, null, 'Jaipur', 'Rajasthan', null, 26.9705486, 75.7618729, null, 'Asia/Kolkata'),
  ('cec73578-3c8a-51ab-8015-e8fa570e77cb', 'osm', 'node/10960893912', 'R.D. Honda', null, 'motorcycle', null, null, null, null, null, null, 'Jaipur', 'Rajasthan', null, 26.9723972, 75.7668705, null, 'Asia/Kolkata'),
  ('204d7560-1133-5351-aad1-3d5807b2f321', 'osm', 'node/11696983719', 'Hero', null, 'motorcycle', null, null, 'Hero', null, null, null, 'Jaipur', 'Rajasthan', null, 26.9510967, 75.7051064, null, 'Asia/Kolkata'),
  ('6ccebe5b-bc36-5c33-ab95-bc77b4c8ab9c', 'osm', 'node/12669206427', 'Service Center- Crossland Hyundai Cars', null, 'car', null, null, null, null, null, null, 'Jaipur', 'Rajasthan', null, 26.9518103, 75.7477135, null, 'Asia/Kolkata'),
  ('c7873475-fa54-538a-89f5-43cdd1c2dd69', 'osm', 'node/12669229313', 'Volkswagen Service Centre', null, 'car', null, null, null, null, null, null, 'Jaipur', 'Rajasthan', null, 26.9474089, 75.7633540, null, 'Asia/Kolkata'),
  ('ed48e85a-b7c0-5564-8faf-5bb56c66f3f6', 'osm', 'node/12669229315', 'Tata Motors Cars Service Centre - Akar Fourwheel', null, 'car', null, null, null, null, null, null, 'Jaipur', 'Rajasthan', null, 26.9516904, 75.7523964, null, 'Asia/Kolkata'),
  ('85a8a406-b267-5b13-a5c7-d377487d6610', 'osm', 'node/12669229320', 'Maruti Suzuki Service (KTL Automobile)', null, 'car', null, null, null, null, null, null, 'Jaipur', 'Rajasthan', null, 26.9477657, 75.7623239, null, 'Asia/Kolkata'),
  ('0fcee794-d458-57c8-a03b-ffabd736950f', 'osm', 'node/13564675401', 'Jai Shri Shyam Auto Parts', null, 'parts', null, null, null, null, null, null, 'Jaipur', 'Rajasthan', null, 26.9804986, 75.7386227, null, 'Asia/Kolkata'),
  ('758441fa-8dc2-5404-8ba2-2ab247cff6bc', 'osm', 'node/14058850449', 'The Wheels', null, 'tyres', null, null, null, null, null, null, 'Jaipur', 'Rajasthan', null, 26.9179572, 75.8101968, null, 'Asia/Kolkata'),
  ('18364173-783a-5b10-abaf-c1d5798bb9c7', 'osm', 'node/14096231202', 'Shree Shyam car workshop and auto parts', null, 'car', '+918386087833', null, null, null, null, null, 'Jaipur', 'Rajasthan', '302012', 26.9821663, 75.7389655, null, 'Asia/Kolkata'),
  ('e76a7a45-4c01-5c56-ad79-0e9d675a4ddf', 'osm', 'way/868219555', 'Car World', null, 'car', null, null, null, null, null, null, 'Jaipur', 'Rajasthan', null, 26.8817475, 75.7692021, null, 'Asia/Kolkata'),
  ('411ddfdd-85f9-534c-8fd7-84a708576aba', 'osm', 'way/154883989', 'Central', null, 'car', null, null, null, null, null, null, 'Kolhapur', 'Maharashtra', null, 16.7033276, 74.2324386, null, 'Asia/Kolkata'),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', 'osm', 'node/1417731459', 'BMW Motorrad Service', null, 'car', null, null, 'BMW', 'Nanvit Motors', null, null, 'Mumbai', 'Maharashtra', null, 19.1300182, 72.8698690, 'Mo-Sa 08:00-21:00', 'Asia/Kolkata'),
  ('ed0a16be-723b-579d-b32b-446d8b4fa9c1', 'osm', 'node/1575140342', 'Hilti', null, 'car', null, null, null, null, 'Sarathi Hanuman Road', null, 'Mumbai', 'Maharashtra', '400057', 19.1030831, 72.8454520, null, 'Asia/Kolkata'),
  ('a7bbf5ac-7568-55c8-896c-318351a07ef0', 'osm', 'node/1579345006', 'Deepak Auto', null, 'car', null, null, null, null, 'Hanuman Road', null, 'Mumbai', 'Maharashtra', '400057', 19.1035621, 72.8537319, null, 'Asia/Kolkata'),
  ('b96bc697-1e70-53d8-ac3d-4c686d89b921', 'osm', 'node/1754955609', 'Shakti Sai Tyres Pvt. Ltd.', null, 'car', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.1321108, 72.8696918, null, 'Asia/Kolkata'),
  ('181b7fbb-76e1-5000-b452-3721dae37ea9', 'osm', 'node/2125278037', 'Vitesse Maruti Suzuki Service', null, 'car', null, 'https://www.vitesseltd.com/', null, null, 'Plot II Shah Industrial Estate New Link Road, Andheri West', null, 'Mumbai', 'Maharashtra', '400058', 19.1342440, 72.8320998, null, 'Asia/Kolkata'),
  ('ce4498a2-5787-56ef-b514-08f981d3ae92', 'osm', 'node/4014542565', 'Paul Auto Garage', null, 'car', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0601989, 72.8294403, null, 'Asia/Kolkata'),
  ('13b8118d-3303-5f4a-b8a5-0f148788ba66', 'osm', 'node/4375255407', 'Dhiraj Motor Stores', null, 'parts', null, null, null, null, '30th Road', 'Bandra, Mumbai', 'Mumbai', 'Maharashtra', '400050', 19.0614696, 72.8368820, null, 'Asia/Kolkata'),
  ('5af94e98-a192-55c7-a240-50f4058ae0c5', 'osm', 'node/5273194234', 'Exide Jeffson Battery Service', null, 'parts', null, null, null, 'Exide', 'Manuel Gonsalves Road', null, 'Mumbai', 'Maharashtra', '400050', 19.0590359, 72.8294755, null, 'Asia/Kolkata'),
  ('77ef8cc5-07ce-5a5c-b61e-09e0afa37935', 'osm', 'node/5506319436', 'Hyundai Authorised Service Centre', null, 'car', null, null, 'Hyundai', null, null, null, 'Mumbai', 'Maharashtra', null, 19.0646036, 72.8607356, null, 'Asia/Kolkata'),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', 'osm', 'node/5506321121', 'Bike Wash & Repair', null, 'motorcycle', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0645801, 72.8606982, 'Mo-Su 09:30-19:30', 'Asia/Kolkata'),
  ('d9505667-5775-5022-b986-608eb3aaa86f', 'osm', 'node/6796939957', '3M Car Care', null, 'car', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.1163909, 72.9094060, null, 'Asia/Kolkata'),
  ('66c5e75d-2019-506f-8a8c-5ff198fe4b1c', 'osm', 'node/6801919212', 'Azhar Auto garage;Ratna country Bar', null, 'motorcycle', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.1275932, 72.9192428, null, 'Asia/Kolkata'),
  ('66c38d5f-60d8-5f45-973d-20d6294a379a', 'osm', 'node/7048489111', 'Amarjeet Auto Store', null, 'parts', null, null, null, null, null, 'Mumbai', 'Mumbai', 'Maharashtra', '400025', 19.0377843, 72.8423795, null, 'Asia/Kolkata'),
  ('b5622957-d285-509a-9b99-6a4430f1689c', 'osm', 'node/9132742309', 'Ashish Motors', null, 'car', '+919029084690', null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.1438498, 72.8315291, null, 'Asia/Kolkata'),
  ('ab5b9935-c12b-56e8-9b52-147fdf968326', 'osm', 'node/11245100723', 'Bridgestone tyres', null, 'tyres', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0538910, 72.8922930, null, 'Asia/Kolkata'),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', 'osm', 'node/11339596974', 'Liyakat Bike Workshop', 'Liyakat Bike Workshop', 'motorcycle', '+919324543882', null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0526519, 72.8341129, 'Mo-Th 10:00-22:00; Sa-Su 10:00-22:00', 'Asia/Kolkata'),
  ('3b1f85da-f619-55ae-a9c6-e5465b4bb2f8', 'osm', 'node/11364283732', 'Speedway', 'Speedway', 'car', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0675196, 72.8371117, null, 'Asia/Kolkata'),
  ('7f38d712-9437-5a74-9c5d-31a5d2a02484', 'osm', 'node/11445795321', '3M Car Care', null, 'car', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.1066806, 72.8848281, null, 'Asia/Kolkata'),
  ('2d6b009a-7e20-5772-a9ea-47528a7f8838', 'osm', 'node/11449426485', 'Milan Tyres', null, 'tyres', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0844062, 72.8891481, null, 'Asia/Kolkata'),
  ('509bc816-c709-573f-b29f-7c2d88c0f222', 'osm', 'node/11452014311', 'Moosa Automobiles', null, 'car', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0709645, 72.8752796, null, 'Asia/Kolkata'),
  ('3475b516-42cd-512d-aa34-22519cd8100f', 'osm', 'node/11452014312', 'Sayana Traders', null, 'car', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0712498, 72.8753389, null, 'Asia/Kolkata'),
  ('9a33a2b0-730c-5c9c-b198-5b0296062f08', 'osm', 'node/11452014930', 'D.K Auto Traders', null, 'car', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0710892, 72.8753012, null, 'Asia/Kolkata'),
  ('edbbf22f-6ab7-5bf5-b528-0aba17954a9a', 'osm', 'node/12290000839', 'cycle repair', null, 'motorcycle', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.1455442, 72.8454613, null, 'Asia/Kolkata'),
  ('b2a4522b-64f2-5e4a-bc48-373c6e451fb9', 'osm', 'node/12770345572', 'Matunga General Lime Depot', null, 'motorcycle', '+919029685297', null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0271075, 72.8561304, null, 'Asia/Kolkata'),
  ('84b06730-7d0e-5bdd-acb8-ca13ff3ceabd', 'osm', 'node/13063238688', 'Ahura Auto', 'Ahura Auto', 'car', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0600558, 72.8388539, null, 'Asia/Kolkata'),
  ('5dcdd688-baa2-53d0-b925-afc60f05a57e', 'osm', 'node/13063238701', 'Jawa Yezdi Service', 'Jawa Yezdi Service', 'motorcycle', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0602059, 72.8388405, null, 'Asia/Kolkata'),
  ('df013ac4-a81d-563d-a8bc-598c7bea79f5', 'osm', 'node/13233017715', 'Chandrika automobile', 'Chandrika automobile', 'parts', '+919892252226', null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0205702, 72.8367425, 'Mo-Su 09:30-19:00', 'Asia/Kolkata'),
  ('5bc5a230-985f-57c1-b97c-fd933e1956dc', 'osm', 'node/13240679447', 'Shamim Motors', null, 'car', null, null, null, null, 'Plot No. 833, Mudran Kamgar Compound Jai Prakash Road', 'Mumbai', 'Mumbai', 'Maharashtra', '400053', 19.1300513, 72.8231526, null, 'Asia/Kolkata'),
  ('aedaec1a-f936-5fb5-9721-0f9f97d1d710', 'osm', 'node/13304968968', 'R.B. Tyres', null, 'tyres', '+919920288288', null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0082898, 72.8309948, 'Mo-Sa 09:00-20:00, Sa 09:00-17:00', 'Asia/Kolkata'),
  ('17573d2e-ec16-507b-98b9-17097804b284', 'osm', 'node/13310511290', 'R.B. Tyres', null, 'tyres', '+919920288288', null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0151362, 72.8275694, null, 'Asia/Kolkata'),
  ('1f7ff5fa-8081-5d55-8202-85fb5527d9e0', 'osm', 'node/13418030914', 'Detailing Dudes', null, 'car', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.1143283, 72.8798383, null, 'Asia/Kolkata'),
  ('52bb81d6-feb9-57c7-bb02-252272efcd03', 'osm', 'way/202061689', 'Citroën Service Garnet Motors', 'Citroën Service Garnet Motors', 'car', null, null, 'Citroën', 'Garnet Motors', null, null, 'Mumbai', 'Maharashtra', null, 19.1469277, 72.8477458, null, 'Asia/Kolkata'),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', 'osm', 'way/1227680057', 'Radhakrishna TVS', 'Radhakrishna TVS', 'motorcycle', null, null, null, null, null, null, 'Mumbai', 'Maharashtra', null, 19.0053652, 72.8365841, 'Mo-Su 09:30-18:00', 'Asia/Kolkata'),
  ('a824ade5-02ce-5aa6-8633-8116a23fca8c', 'osm', 'way/1364439087', 'Bhavna Ford', null, 'car', null, null, 'Ford', null, null, null, 'Mumbai', 'Maharashtra', null, 19.0855546, 72.8847494, null, 'Asia/Kolkata'),
  ('75c8edd6-f282-54f2-a4cb-ab3773553847', 'osm', 'node/1671917243', 'Maruti Service Centre', null, 'car', null, null, null, null, null, null, 'Nashik', 'Maharashtra', null, 19.9968370, 73.8008680, null, 'Asia/Kolkata'),
  ('e56a17fb-97ec-5eb0-b12a-c2d79f8cb79d', 'osm', 'node/13540932226', 'Datar Auto Battery', 'Datar Auto Battery', 'parts', '+919890088832', null, null, null, null, null, 'Nashik', 'Maharashtra', null, 19.9640203, 73.7337671, null, 'Asia/Kolkata'),
  ('565f6c71-855e-5ac9-ac81-2d5f2c0fc3ba', 'osm', 'node/1888063771', 'Sehgal Autoriders Maruti Service', null, 'car', null, null, null, null, 'Survey No. 51, Bavdhan Khurd NH4 Bypass', null, 'Pune', 'Maharashtra', '411021', 18.5228452, 73.7692736, null, 'Asia/Kolkata'),
  ('e91a9f05-ec7e-52f4-bb93-2314c5042cd7', 'osm', 'node/1888334981', 'Chowgule Industries Maruti Service', null, 'car', null, 'https://www.chowguleindustries.com/', null, null, 'Survey No. 53 Poona-Satara Highway, Katraj', null, 'Pune', 'Maharashtra', '411046', 18.4427184, 73.8603123, null, 'Asia/Kolkata'),
  ('172b35c2-4221-5187-8d0b-70578ed1a3c6', 'osm', 'node/2784751751', 'Bike Gurus', null, 'car', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5062639, 73.8174548, null, 'Asia/Kolkata'),
  ('dc638d2c-c1c2-5723-8a72-b178482e4232', 'osm', 'node/2973259365', 'Maruti Care Point', 'Maruti Care Point', 'car', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5530717, 73.8030453, null, 'Asia/Kolkata'),
  ('60ee3b69-87ae-5c3d-95db-e592d0056cd2', 'osm', 'node/5695618775', 'Nanded Tyres', null, 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.4565352, 73.8003492, null, 'Asia/Kolkata'),
  ('42084bbd-7221-5f97-b03f-a7fb63e0642e', 'osm', 'node/5795521361', 'Manny''s Automobiles', null, 'car', null, null, null, null, '38/2/5', 'Shree Swami Chhaya Apartments', 'Pune', 'Maharashtra', '411052', 18.4939774, 73.8256994, null, 'Asia/Kolkata'),
  ('f66ab8d7-3dc2-5463-b54a-c28701a4141b', 'osm', 'node/5815976617', 'Durga Car Decor', null, 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5200168, 73.8307251, null, 'Asia/Kolkata'),
  ('7d2d673a-fa20-5046-99ea-3f61531e199e', 'osm', 'node/5832548492', 'Tilak Automobiles', null, 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5082269, 73.8499528, null, 'Asia/Kolkata'),
  ('5a12694a-9660-5c4b-a0a2-71a9f18e9f26', 'osm', 'node/5839779141', '3M Car Care', null, 'car', null, null, null, '3M', null, null, 'Pune', 'Maharashtra', null, 18.4912458, 73.8218724, null, 'Asia/Kolkata'),
  ('943cf12f-f994-5ca4-a071-cc88e6ff66d4', 'osm', 'node/6111132433', 'Chaturshrungi Tyres', 'Chaturshrungi Tyres', 'tyres', null, null, null, null, 'Sanghvi Kesari Road', 'Pune', 'Pune', 'Maharashtra', '411007', 18.5604219, 73.8100690, null, 'Asia/Kolkata'),
  ('fd38de85-78e9-5086-9263-50f82669cace', 'osm', 'node/6113508079', 'Darshan Tyres', null, 'tyres', '+919552562621', null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5648188, 73.7856442, null, 'Asia/Kolkata'),
  ('2be8bc86-d0fa-5c2b-b7d0-be2ccc3ef343', 'osm', 'node/6145441628', 'Vijay Car Accessories', null, 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5050820, 73.8225068, null, 'Asia/Kolkata'),
  ('5a96ee8f-7b2c-56f1-96ff-50dde21cf12f', 'osm', 'node/9265940855', 'A J Motors', null, 'car', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5436323, 73.7765327, null, 'Asia/Kolkata'),
  ('aa9cd654-43fb-52aa-9d12-74cb5ab6d5e3', 'osm', 'node/9579659644', 'Siddharth auto', null, 'motorcycle', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5221731, 73.7648405, null, 'Asia/Kolkata'),
  ('30465a0d-51f3-5353-b877-a4f6048a95b2', 'osm', 'node/9801311340', 'Maruti Suzuki Arena Service Centre', null, 'car', null, null, 'Maruti', null, null, null, 'Pune', 'Maharashtra', null, 18.5410353, 73.7841609, null, 'Asia/Kolkata'),
  ('78d18d38-7a95-57ff-8f26-15831f03b99d', 'osm', 'node/10108645152', 'Arihaan Suzuki workshop', null, 'motorcycle', null, null, null, 'Suzuki', 'Hingane Internal Road', null, 'Pune', 'Maharashtra', '411051', 18.4787079, 73.8297146, null, 'Asia/Kolkata'),
  ('4ed52f7b-6d2d-5eb2-a21d-f88be4034033', 'osm', 'node/10115879743', 'VAIBHAV AUTO PARTS', null, 'parts', null, null, null, null, 'DSK Vishwa Road', null, 'Pune', 'Maharashtra', '411041', 18.4472455, 73.8088473, null, 'Asia/Kolkata'),
  ('79446389-617c-53ac-9a75-6419a6a4df1b', 'osm', 'node/10115879750', 'New Balaji Car Accessories', null, 'parts', '+917350886932', null, null, null, 'Baner Road', null, 'Pune', 'Maharashtra', '411045', 18.5551572, 73.7980425, null, 'Asia/Kolkata'),
  ('6685bb83-90d1-5d76-b6cb-a63b5d9b4e20', 'osm', 'node/10235274247', 'Chetak Service Center', null, 'motorcycle', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5892137, 73.8314678, null, 'Asia/Kolkata'),
  ('7feb06e1-9638-5aba-b492-f6981d87a1fc', 'osm', 'node/10250069959', 'Rahul Auto', null, 'car', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5536316, 73.8064427, null, 'Asia/Kolkata'),
  ('5b37b787-1b76-5ad9-9bc8-f4569617da3e', 'osm', 'node/10560840609', 'Nirankari Wheels', null, 'tyres', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5546938, 73.9373558, null, 'Asia/Kolkata'),
  ('a88d1a86-eccc-5818-933e-cbdf60d67d7d', 'osm', 'node/10567044012', 'Nathulal Automobiles', null, 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5610535, 73.9387289, null, 'Asia/Kolkata'),
  ('b34e44e5-8167-57bb-b845-48d6350b0352', 'osm', 'node/10567044013', 'Ganesh Automobiles & Lubricants', null, 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5614122, 73.9387626, null, 'Asia/Kolkata'),
  ('48a46ed3-32b6-5f19-9143-80370d02ed0f', 'osm', 'node/10567046712', 'Santosham', null, 'tyres', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5599904, 73.9386172, null, 'Asia/Kolkata'),
  ('6bb0b361-1a69-5b51-bb21-3fca3d278ab3', 'osm', 'node/10567046812', 'Shree Auto Service', null, 'motorcycle', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5600481, 73.9386210, null, 'Asia/Kolkata'),
  ('e8c6e7ef-c014-5d10-b1ae-0d64a9a43743', 'osm', 'node/10567046814', 'City Bike Garage', null, 'motorcycle', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5606587, 73.9386927, null, 'Asia/Kolkata'),
  ('32f7ccf7-5ef9-59d9-9560-1fddb9153be5', 'osm', 'node/10567054910', 'Nishant Tyres', null, 'tyres', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5615344, 73.9382576, null, 'Asia/Kolkata'),
  ('03757d5f-45df-5f35-80f0-f4aa8de0bb55', 'osm', 'node/10567055109', 'Shrinivas Automobile', null, 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5616074, 73.9382634, null, 'Asia/Kolkata'),
  ('38df482a-84c4-5ebe-b5b8-685619ff2508', 'osm', 'node/10567060809', 'New Yash Tyres', null, 'tyres', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5611716, 73.9381777, null, 'Asia/Kolkata'),
  ('0fbaf6fb-441d-5dd3-8c06-97da9d7f139e', 'osm', 'node/10567064409', 'Natuhal Automobiles & Spare', null, 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5606654, 73.9381275, null, 'Asia/Kolkata'),
  ('2c75a59f-7c47-5f67-b46d-cb69d695cbaa', 'osm', 'node/10567068409', 'National Lubricants', null, 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5604810, 73.9381186, null, 'Asia/Kolkata'),
  ('3fe1df63-b04f-5264-a423-bc13b4f9f6b4', 'osm', 'node/11061383057', 'Sai service bajaj', 'Sai service bajaj', 'motorcycle', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5669339, 73.8076567, null, 'Asia/Kolkata'),
  ('68578a90-09b3-5c48-b381-17a54a22f94f', 'osm', 'node/11276070943', 'Michelin Goodyear Sai Enterprises', null, 'tyres', '+919920250044', null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5607948, 73.7877625, null, 'Asia/Kolkata'),
  ('1b4e7fab-46d1-5e48-b02b-3d92efc2e391', 'osm', 'node/11292638600', 'Tyre Master', null, 'tyres', null, null, null, null, 'Sinhagad Road', 'Pune', 'Pune', 'Maharashtra', '411041', 18.4582232, 73.8077738, null, 'Asia/Kolkata'),
  ('7e8005eb-bd3d-565b-aeeb-a11a5065733f', 'osm', 'node/11330878769', 'Tyre Point', null, 'tyres', null, null, null, null, 'Goel Ganga road', 'Pune', 'Pune', 'Maharashtra', '411041', 18.4702506, 73.8214967, null, 'Asia/Kolkata'),
  ('92679091-7654-5db3-93c5-24f1d3aaa0c1', 'osm', 'node/11375788719', 'motorcycle repair shop', null, 'motorcycle', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5508954, 73.8245341, null, 'Asia/Kolkata'),
  ('fa74b232-8e05-5cec-b8d0-513227343ba9', 'osm', 'node/11394068369', 'Dream Wheels', null, 'car', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5536143, 73.7838682, null, 'Asia/Kolkata'),
  ('42a5fb0b-d5a0-5090-b630-080a2727447d', 'osm', 'node/11546228236', 'Vishal Auto Service', 'Vishal Auto Service', 'car', '+919850065377', null, null, null, 'New DP Road', 'Pune', 'Pune', 'Maharashtra', '411007', 18.5629468, 73.8025969, null, 'Asia/Kolkata'),
  ('ddd5345f-09af-59ce-8cbc-b3560c599250', 'osm', 'node/11690067259', 'Gurudatta Repair Shop', null, 'motorcycle', null, null, null, null, null, null, 'Pune', 'Maharashtra', '411041', 18.4491581, 73.8106193, null, 'Asia/Kolkata'),
  ('c4267dff-692f-59ae-a013-cd8214211b60', 'osm', 'node/12222103736', 'Raj Car Care', null, 'car', '+918605554634', null, null, null, 'DSK Vishwa Road', null, 'Pune', 'Maharashtra', '411041', 18.4471356, 73.8055683, null, 'Asia/Kolkata'),
  ('9999637a-daad-51ce-b786-7c6075fe51a2', 'osm', 'node/12222103798', 'Nexa Service (Maruti Suzuki Authorized Service Centre)', null, 'car', null, null, null, null, 'Sinhagad Road', null, 'Pune', 'Maharashtra', '411041', 18.4573213, 73.8051922, null, 'Asia/Kolkata'),
  ('bf5a5545-dff7-5e6e-b3f5-9e421e2bec67', 'osm', 'node/12345146728', 'Yeah Atu Garaj', null, 'motorcycle', '+919028805769', null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.4566446, 73.9129951, null, 'Asia/Kolkata'),
  ('2491f426-0c4a-5915-bedf-c707927e4520', 'osm', 'node/12770261291', 'Electro Power System', 'Electro Power System', 'parts', '+919823464255', null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5661129, 73.7826309, null, 'Asia/Kolkata'),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', 'osm', 'node/13352586801', 'Don’s Garage', null, 'car', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5087909, 73.9117505, 'Mo-Sa 09:00-18:00', 'Asia/Kolkata'),
  ('dc665694-ab79-56d3-997d-9fae550a02da', 'osm', 'node/13380912462', 'SK Pune Auto Garage', null, 'motorcycle', null, null, null, null, null, 'Pune', 'Pune', 'Maharashtra', '411031', 18.5886666, 73.8624565, null, 'Asia/Kolkata'),
  ('f38ba497-c36a-5b5b-8c86-267a344f8a5c', 'osm', 'node/13383423737', 'Shri Nath Automobiles', 'Shri Nath Automobiles', 'motorcycle', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.4804949, 73.8049318, null, 'Asia/Kolkata'),
  ('8a1633d9-5872-5336-b6b2-15efc76e67b2', 'osm', 'node/13624352699', 'Carbon And Crome', null, 'car', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5570535, 73.9079971, null, 'Asia/Kolkata'),
  ('88819774-5f3e-5117-921d-2dfd4be13da2', 'osm', 'node/13648780641', 'Motul Service Centre', null, 'motorcycle', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5939196, 73.8930652, null, 'Asia/Kolkata'),
  ('7098ea6c-f0bb-5f22-ac3f-fd1eb787f281', 'osm', 'node/13666883041', 'Ganesh Tyres', null, 'tyres', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.4577752, 73.8120215, null, 'Asia/Kolkata'),
  ('7777e087-1250-5078-8aab-43362c480091', 'osm', 'node/13762832085', 'Pune Automobiles', 'Pune Automobiles', 'parts', '+919819661363', null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5598388, 73.7887570, null, 'Asia/Kolkata'),
  ('13bc52bb-5233-589d-a770-8dba399c0144', 'osm', 'node/13762876238', 'Shri Auto Spare', 'Shri Auto Spare', 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5610554, 73.7873593, null, 'Asia/Kolkata'),
  ('02a4330e-1742-5336-adb6-ef74783c7300', 'osm', 'node/13767096727', 'New Balaji Car Accessories', 'New Balaji Car Accessories', 'parts', '+917015509883', null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5617603, 73.7842744, null, 'Asia/Kolkata'),
  ('776ee3ec-85cb-5d23-a01f-1ef7c73b14a5', 'osm', 'node/13920500412', 'SF Batteries', 'SF Batteries', 'parts', '+919860821137', null, null, 'Krishna Enterprises', null, null, 'Pune', 'Maharashtra', null, 18.5683905, 73.7798554, null, 'Asia/Kolkata'),
  ('33161b2f-8f4a-54f4-82df-ae5417b83023', 'osm', 'node/13920500422', 'BS Gaikwad Auto Service Center', 'BS Gaikwad Auto Service Center', 'motorcycle', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5683961, 73.7797144, null, 'Asia/Kolkata'),
  ('6ebec59a-1b01-5e93-ab75-55ae97918648', 'osm', 'node/13955573549', 'P.Chowdhary & CO.', null, 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5144841, 73.8798477, null, 'Asia/Kolkata'),
  ('a43a47bf-62f2-59ce-b61c-52cde76a676d', 'osm', 'node/14100462170', 'Prakash Tyres', null, 'tyres', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.4472348, 73.8079154, null, 'Asia/Kolkata'),
  ('53020bd6-40bf-5952-a1dc-081003b29821', 'osm', 'node/14182997083', 'Bridgestone', null, 'tyres', '+918071326769', 'https://tyreshop.bridgestone.co.in/bridgestone/stores-in-pune/stores-in-bavdhan/bridgestone-select-deepraj-tyres-in-bavdhan-pune--dcd97546-df51-46e1-85a6-62f3c603c800/home', 'Bridgestone', 'Deepraj Tyres', 'Shop No 1, Blue Hill Society, NDA Pashan Rd, opposite SBI Bank, Shri Krishna Nagar, Sagar Co-Operative Housing Society, Bavdhan', 'Pune', 'Pune', 'Maharashtra', '411021', 18.5171511, 73.7813410, 'Mo-Su, 9:30 am–8:30 pm', 'Asia/Kolkata'),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', 'osm', 'node/14212153690', 'Silverline Auto', null, 'motorcycle', null, null, null, null, 'Shop No.1, Padamshree Apartment, NDA Pashan Rd, Bavdhan,', 'Pune', 'Pune', 'Maharashtra', '411021', 18.5145336, 73.7821481, 'Mo-Sa 10 am–6:30 pm', 'Asia/Kolkata'),
  ('75947c24-0dfd-5ed0-bd04-fd1ed22eb24a', 'osm', 'node/14293314925', 'Shree Ramdev Auto Parts', null, 'parts', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5510683, 73.9392785, null, 'Asia/Kolkata'),
  ('6b840f4c-1847-58dd-9be7-e7d8475e8a83', 'osm', 'way/308721891', 'Crystal Honda Service Station', null, 'car', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5204395, 73.7660854, null, 'Asia/Kolkata'),
  ('17f857d1-a183-55b6-9b25-f9d199209633', 'osm', 'way/359947150', 'Kia', null, 'car', null, 'https://www.crystalkiaautopune.com/bavdhan', 'Kia', 'Crystal Kia', '19/1, Patil Nagar, Bavdhan,', 'Pune', 'Pune', 'Maharashtra', '411021', 18.5196695, 73.7714497, null, 'Asia/Kolkata'),
  ('38f571b2-fa52-5d09-936e-e073b4359673', 'osm', 'way/359982593', 'Mobil car Care', null, 'car', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5114531, 73.7670496, null, 'Asia/Kolkata'),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', 'osm', 'way/365081031', 'Kundan Hyundai Service Center', null, 'car', null, 'https://www.kundanhyundaipune.com/bavdhan', 'Hyundai', null, 'Sy No. 20, near Suryadatta College of Management, Patil Nagar, Bavdhan,', 'Pune', 'Pune', 'Maharashtra', '411021', 18.5189054, 73.7711281, 'Fr-We 9:30 am–6:30 pm', 'Asia/Kolkata'),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', 'osm', 'way/1250191655', 'Atharva Car Services', 'Atharva Car Services', 'car', '+919960690758', null, 'Maruti Suzuki', 'Maruti Suzuki', 'Lane 1', 'Pune', 'Pune', 'Maharashtra', '411038', 18.5090298, 73.7931711, 'Mo-Su 09:30-18:30', 'Asia/Kolkata'),
  ('269d804b-13ee-570a-826d-b9e412a0e1c5', 'osm', 'way/1527723387', 'Kothari Hyundai Service Center', null, 'car', null, null, null, null, null, null, 'Pune', 'Maharashtra', null, 18.5141859, 73.9113258, null, 'Asia/Kolkata'),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', 'osm', 'way/1561939994', 'Hero', null, 'motorcycle', null, 'https://kundanautomobile.com/', 'Hero', 'Kundan Automobile Service - HeroMotoCorp', 'Sr No. 20, near Suryadatta College, Patil Nagar, Bavdhan,', 'Pune', 'Pune', 'Maharashtra', '411021', 18.5193785, 73.7709694, 'Fr-We 9 am–6 pm', 'Asia/Kolkata')
on conflict (source, external_id) do update set
  name = excluded.name, name_en = excluded.name_en, category = excluded.category,
  phone = excluded.phone, website = excluded.website, brand = excluded.brand,
  operator = excluded.operator, address_line = excluded.address_line,
  locality = excluded.locality, city = excluded.city, state = excluded.state,
  postcode = excluded.postcode, lat = excluded.lat, lng = excluded.lng,
  opening_hours_raw = excluded.opening_hours_raw
-- A claimed listing is the owner's; imports must not overwrite their edits.
where public.mechanics.owner_id is null;

-- Parsed opening hours. Only garages whose OSM string parsed unambiguously.
delete from public.mechanic_hours where mechanic_id in (
  select id from public.mechanics where source = 'osm' and owner_id is null);
insert into public.mechanic_hours (mechanic_id, day_of_week, opens, closes) values
  ('e02b1966-a3e1-584a-be1f-e24cae9b3c86', 0, '11:30', '20:30'),
  ('e02b1966-a3e1-584a-be1f-e24cae9b3c86', 2, '11:30', '20:30'),
  ('e02b1966-a3e1-584a-be1f-e24cae9b3c86', 3, '11:30', '20:30'),
  ('e02b1966-a3e1-584a-be1f-e24cae9b3c86', 4, '11:30', '20:30'),
  ('e02b1966-a3e1-584a-be1f-e24cae9b3c86', 5, '11:30', '20:30'),
  ('e02b1966-a3e1-584a-be1f-e24cae9b3c86', 6, '11:30', '20:30'),
  ('8d7f85f2-0f3e-574c-8c54-4f52ac29c080', 0, '11:00', '20:00'),
  ('8d7f85f2-0f3e-574c-8c54-4f52ac29c080', 1, '11:00', '20:00'),
  ('8d7f85f2-0f3e-574c-8c54-4f52ac29c080', 2, '11:00', '20:00'),
  ('8d7f85f2-0f3e-574c-8c54-4f52ac29c080', 3, '11:00', '20:00'),
  ('8d7f85f2-0f3e-574c-8c54-4f52ac29c080', 4, '11:00', '20:00'),
  ('8d7f85f2-0f3e-574c-8c54-4f52ac29c080', 5, '11:00', '20:00'),
  ('8d7f85f2-0f3e-574c-8c54-4f52ac29c080', 6, '11:00', '20:00'),
  ('9493694e-909d-5bb7-8c39-26ddc0482904', 1, '11:30', '20:00'),
  ('9493694e-909d-5bb7-8c39-26ddc0482904', 2, '11:30', '20:00'),
  ('9493694e-909d-5bb7-8c39-26ddc0482904', 3, '11:30', '20:00'),
  ('9493694e-909d-5bb7-8c39-26ddc0482904', 4, '11:30', '20:00'),
  ('9493694e-909d-5bb7-8c39-26ddc0482904', 5, '11:30', '20:00'),
  ('9493694e-909d-5bb7-8c39-26ddc0482904', 6, '11:30', '20:00'),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', 0, '12:00', '18:00'),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', 2, '12:00', '18:00'),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', 3, '12:00', '18:00'),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', 4, '12:00', '18:00'),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', 5, '12:00', '18:00'),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', 6, '12:00', '18:00'),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', 0, '09:00', '18:00'),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', 1, '09:00', '18:00'),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', 2, '09:00', '18:00'),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', 3, '09:00', '18:00'),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', 4, '09:00', '18:00'),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', 5, '09:00', '18:00'),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', 6, '09:00', '18:00'),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', 1, '09:00', '21:00'),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', 2, '09:00', '21:00'),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', 3, '09:00', '21:00'),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', 4, '09:00', '21:00'),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', 5, '09:00', '21:00'),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', 6, '09:00', '21:00'),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', 1, '09:00', '18:00'),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', 2, '09:00', '18:00'),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', 3, '09:00', '18:00'),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', 4, '09:00', '18:00'),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', 5, '09:00', '18:00'),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', 6, '09:00', '18:00'),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', 0, '09:30', '20:00'),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', 1, '09:30', '20:00'),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', 2, '09:30', '20:00'),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', 3, '09:30', '20:00'),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', 4, '09:30', '20:00'),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', 5, '09:30', '20:00'),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', 6, '09:30', '20:00'),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', 0, '09:00', '21:00'),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', 1, '09:00', '21:00'),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', 2, '09:00', '21:00'),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', 3, '09:00', '21:00'),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', 4, '09:00', '21:00'),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', 5, '09:00', '21:00'),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', 6, '09:00', '21:00'),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', 1, '08:00', '21:00'),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', 2, '08:00', '21:00'),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', 3, '08:00', '21:00'),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', 4, '08:00', '21:00'),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', 5, '08:00', '21:00'),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', 6, '08:00', '21:00'),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', 0, '09:30', '19:30'),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', 1, '09:30', '19:30'),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', 2, '09:30', '19:30'),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', 3, '09:30', '19:30'),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', 4, '09:30', '19:30'),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', 5, '09:30', '19:30'),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', 6, '09:30', '19:30'),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', 1, '10:00', '22:00'),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', 2, '10:00', '22:00'),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', 3, '10:00', '22:00'),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', 4, '10:00', '22:00'),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', 0, '10:00', '22:00'),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', 6, '10:00', '22:00'),
  ('df013ac4-a81d-563d-a8bc-598c7bea79f5', 0, '09:30', '19:00'),
  ('df013ac4-a81d-563d-a8bc-598c7bea79f5', 1, '09:30', '19:00'),
  ('df013ac4-a81d-563d-a8bc-598c7bea79f5', 2, '09:30', '19:00'),
  ('df013ac4-a81d-563d-a8bc-598c7bea79f5', 3, '09:30', '19:00'),
  ('df013ac4-a81d-563d-a8bc-598c7bea79f5', 4, '09:30', '19:00'),
  ('df013ac4-a81d-563d-a8bc-598c7bea79f5', 5, '09:30', '19:00'),
  ('df013ac4-a81d-563d-a8bc-598c7bea79f5', 6, '09:30', '19:00'),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', 0, '09:30', '18:00'),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', 1, '09:30', '18:00'),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', 2, '09:30', '18:00'),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', 3, '09:30', '18:00'),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', 4, '09:30', '18:00'),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', 5, '09:30', '18:00'),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', 6, '09:30', '18:00'),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', 1, '09:00', '18:00'),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', 2, '09:00', '18:00'),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', 3, '09:00', '18:00'),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', 4, '09:00', '18:00'),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', 5, '09:00', '18:00'),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', 6, '09:00', '18:00'),
  ('53020bd6-40bf-5952-a1dc-081003b29821', 0, '09:30', '20:30'),
  ('53020bd6-40bf-5952-a1dc-081003b29821', 1, '09:30', '20:30'),
  ('53020bd6-40bf-5952-a1dc-081003b29821', 2, '09:30', '20:30'),
  ('53020bd6-40bf-5952-a1dc-081003b29821', 3, '09:30', '20:30'),
  ('53020bd6-40bf-5952-a1dc-081003b29821', 4, '09:30', '20:30'),
  ('53020bd6-40bf-5952-a1dc-081003b29821', 5, '09:30', '20:30'),
  ('53020bd6-40bf-5952-a1dc-081003b29821', 6, '09:30', '20:30'),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', 1, '10:00', '18:30'),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', 2, '10:00', '18:30'),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', 3, '10:00', '18:30'),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', 4, '10:00', '18:30'),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', 5, '10:00', '18:30'),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', 6, '10:00', '18:30'),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', 0, '09:30', '18:30'),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', 1, '09:30', '18:30'),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', 2, '09:30', '18:30'),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', 3, '09:30', '18:30'),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', 5, '09:30', '18:30'),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', 6, '09:30', '18:30'),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', 0, '09:30', '18:30'),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', 1, '09:30', '18:30'),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', 2, '09:30', '18:30'),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', 3, '09:30', '18:30'),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', 4, '09:30', '18:30'),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', 5, '09:30', '18:30'),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', 6, '09:30', '18:30'),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', 0, '09:00', '18:00'),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', 1, '09:00', '18:00'),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', 2, '09:00', '18:00'),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', 3, '09:00', '18:00'),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', 5, '09:00', '18:00'),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', 6, '09:00', '18:00');

-- Services. is_declared = true came from the garage's own OSM
-- service:vehicle:* tags; false is inferred from its category.
delete from public.mechanic_services where mechanic_id in (
  select id from public.mechanics where source = 'osm' and owner_id is null);
insert into public.mechanic_services (mechanic_id, service_id, is_declared) values
  ('6be9e13b-7e37-5fc4-8ad1-ee4a147d6db4', (select id from public.services where slug = 'tyre-replacement'), false),
  ('6be9e13b-7e37-5fc4-8ad1-ee4a147d6db4', (select id from public.services where slug = 'wheel-alignment'), false),
  ('6be9e13b-7e37-5fc4-8ad1-ee4a147d6db4', (select id from public.services where slug = 'puncture-repair'), false),
  ('c47b1e09-eb36-5ffc-bb59-80f1e30bdccc', (select id from public.services where slug = 'engine-repair'), false),
  ('c47b1e09-eb36-5ffc-bb59-80f1e30bdccc', (select id from public.services where slug = 'oil-change'), false),
  ('c47b1e09-eb36-5ffc-bb59-80f1e30bdccc', (select id from public.services where slug = 'brake-service'), false),
  ('c47b1e09-eb36-5ffc-bb59-80f1e30bdccc', (select id from public.services where slug = 'battery-replacement'), false),
  ('c47b1e09-eb36-5ffc-bb59-80f1e30bdccc', (select id from public.services where slug = 'full-service'), false),
  ('c47b1e09-eb36-5ffc-bb59-80f1e30bdccc', (select id from public.services where slug = 'diagnostics'), false),
  ('a6d29523-3098-5d50-9082-1ca73686ead3', (select id from public.services where slug = 'spare-parts'), false),
  ('a6d29523-3098-5d50-9082-1ca73686ead3', (select id from public.services where slug = 'battery-replacement'), false),
  ('41759a2f-d38a-59b7-9c47-0dea3efc5db1', (select id from public.services where slug = 'engine-repair'), false),
  ('41759a2f-d38a-59b7-9c47-0dea3efc5db1', (select id from public.services where slug = 'oil-change'), false),
  ('41759a2f-d38a-59b7-9c47-0dea3efc5db1', (select id from public.services where slug = 'brake-service'), false),
  ('41759a2f-d38a-59b7-9c47-0dea3efc5db1', (select id from public.services where slug = 'battery-replacement'), false),
  ('41759a2f-d38a-59b7-9c47-0dea3efc5db1', (select id from public.services where slug = 'full-service'), false),
  ('41759a2f-d38a-59b7-9c47-0dea3efc5db1', (select id from public.services where slug = 'diagnostics'), false),
  ('f4d888f1-1b3a-565a-9f60-d7cddafc3437', (select id from public.services where slug = 'engine-repair'), false),
  ('f4d888f1-1b3a-565a-9f60-d7cddafc3437', (select id from public.services where slug = 'oil-change'), false),
  ('f4d888f1-1b3a-565a-9f60-d7cddafc3437', (select id from public.services where slug = 'brake-service'), false),
  ('f4d888f1-1b3a-565a-9f60-d7cddafc3437', (select id from public.services where slug = 'battery-replacement'), false),
  ('f4d888f1-1b3a-565a-9f60-d7cddafc3437', (select id from public.services where slug = 'full-service'), false),
  ('f4d888f1-1b3a-565a-9f60-d7cddafc3437', (select id from public.services where slug = 'diagnostics'), false),
  ('3f02a878-6448-5e07-a24b-c73cc0d9bc59', (select id from public.services where slug = 'spare-parts'), false),
  ('3f02a878-6448-5e07-a24b-c73cc0d9bc59', (select id from public.services where slug = 'battery-replacement'), false),
  ('eae9aa7b-93d9-5f27-a0b3-fcabdbe69fb6', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('eae9aa7b-93d9-5f27-a0b3-fcabdbe69fb6', (select id from public.services where slug = 'oil-change'), false),
  ('eae9aa7b-93d9-5f27-a0b3-fcabdbe69fb6', (select id from public.services where slug = 'chain-sprocket'), false),
  ('eae9aa7b-93d9-5f27-a0b3-fcabdbe69fb6', (select id from public.services where slug = 'puncture-repair'), false),
  ('eae9aa7b-93d9-5f27-a0b3-fcabdbe69fb6', (select id from public.services where slug = 'battery-replacement'), false),
  ('33537a37-a3bb-5048-9f53-641d9f640d55', (select id from public.services where slug = 'engine-repair'), false),
  ('33537a37-a3bb-5048-9f53-641d9f640d55', (select id from public.services where slug = 'oil-change'), false),
  ('33537a37-a3bb-5048-9f53-641d9f640d55', (select id from public.services where slug = 'brake-service'), false),
  ('33537a37-a3bb-5048-9f53-641d9f640d55', (select id from public.services where slug = 'battery-replacement'), false),
  ('33537a37-a3bb-5048-9f53-641d9f640d55', (select id from public.services where slug = 'full-service'), false),
  ('33537a37-a3bb-5048-9f53-641d9f640d55', (select id from public.services where slug = 'diagnostics'), false),
  ('dbfc43eb-2284-508b-a4d1-81f28c927b5a', (select id from public.services where slug = 'engine-repair'), false),
  ('dbfc43eb-2284-508b-a4d1-81f28c927b5a', (select id from public.services where slug = 'oil-change'), false),
  ('dbfc43eb-2284-508b-a4d1-81f28c927b5a', (select id from public.services where slug = 'brake-service'), false),
  ('dbfc43eb-2284-508b-a4d1-81f28c927b5a', (select id from public.services where slug = 'battery-replacement'), false),
  ('dbfc43eb-2284-508b-a4d1-81f28c927b5a', (select id from public.services where slug = 'full-service'), false),
  ('dbfc43eb-2284-508b-a4d1-81f28c927b5a', (select id from public.services where slug = 'diagnostics'), false),
  ('e02b1966-a3e1-584a-be1f-e24cae9b3c86', (select id from public.services where slug = 'spare-parts'), false),
  ('e02b1966-a3e1-584a-be1f-e24cae9b3c86', (select id from public.services where slug = 'battery-replacement'), false),
  ('6d426394-8a34-5bf7-bd78-f2c8ea35f6b7', (select id from public.services where slug = 'spare-parts'), false),
  ('6d426394-8a34-5bf7-bd78-f2c8ea35f6b7', (select id from public.services where slug = 'battery-replacement'), false),
  ('8d7f85f2-0f3e-574c-8c54-4f52ac29c080', (select id from public.services where slug = 'tyre-replacement'), false),
  ('8d7f85f2-0f3e-574c-8c54-4f52ac29c080', (select id from public.services where slug = 'wheel-alignment'), false),
  ('8d7f85f2-0f3e-574c-8c54-4f52ac29c080', (select id from public.services where slug = 'puncture-repair'), false),
  ('ac998672-03be-50c3-b2c9-c719c516792e', (select id from public.services where slug = 'engine-repair'), false),
  ('ac998672-03be-50c3-b2c9-c719c516792e', (select id from public.services where slug = 'oil-change'), false),
  ('ac998672-03be-50c3-b2c9-c719c516792e', (select id from public.services where slug = 'brake-service'), false),
  ('ac998672-03be-50c3-b2c9-c719c516792e', (select id from public.services where slug = 'battery-replacement'), false),
  ('ac998672-03be-50c3-b2c9-c719c516792e', (select id from public.services where slug = 'full-service'), false),
  ('ac998672-03be-50c3-b2c9-c719c516792e', (select id from public.services where slug = 'diagnostics'), false),
  ('48c162bf-4208-5193-80f8-576d73f90788', (select id from public.services where slug = 'engine-repair'), false),
  ('48c162bf-4208-5193-80f8-576d73f90788', (select id from public.services where slug = 'oil-change'), false),
  ('48c162bf-4208-5193-80f8-576d73f90788', (select id from public.services where slug = 'brake-service'), false),
  ('48c162bf-4208-5193-80f8-576d73f90788', (select id from public.services where slug = 'battery-replacement'), false),
  ('48c162bf-4208-5193-80f8-576d73f90788', (select id from public.services where slug = 'full-service'), false),
  ('48c162bf-4208-5193-80f8-576d73f90788', (select id from public.services where slug = 'diagnostics'), false),
  ('13493a05-bf1a-5d5e-b42b-c76f3e0cf415', (select id from public.services where slug = 'tyre-replacement'), false),
  ('13493a05-bf1a-5d5e-b42b-c76f3e0cf415', (select id from public.services where slug = 'wheel-alignment'), false),
  ('13493a05-bf1a-5d5e-b42b-c76f3e0cf415', (select id from public.services where slug = 'puncture-repair'), false),
  ('77280025-a435-5128-9282-cc3f52d04828', (select id from public.services where slug = 'tyre-replacement'), false),
  ('77280025-a435-5128-9282-cc3f52d04828', (select id from public.services where slug = 'wheel-alignment'), false),
  ('77280025-a435-5128-9282-cc3f52d04828', (select id from public.services where slug = 'puncture-repair'), false),
  ('03cfdb7d-7903-5287-bc83-ce8fadd4fac4', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('03cfdb7d-7903-5287-bc83-ce8fadd4fac4', (select id from public.services where slug = 'oil-change'), false),
  ('03cfdb7d-7903-5287-bc83-ce8fadd4fac4', (select id from public.services where slug = 'chain-sprocket'), false),
  ('03cfdb7d-7903-5287-bc83-ce8fadd4fac4', (select id from public.services where slug = 'puncture-repair'), false),
  ('03cfdb7d-7903-5287-bc83-ce8fadd4fac4', (select id from public.services where slug = 'battery-replacement'), false),
  ('f6e7fff2-5fa2-5a84-a12a-2b6a8f27c178', (select id from public.services where slug = 'engine-repair'), false),
  ('f6e7fff2-5fa2-5a84-a12a-2b6a8f27c178', (select id from public.services where slug = 'oil-change'), false),
  ('f6e7fff2-5fa2-5a84-a12a-2b6a8f27c178', (select id from public.services where slug = 'brake-service'), false),
  ('f6e7fff2-5fa2-5a84-a12a-2b6a8f27c178', (select id from public.services where slug = 'battery-replacement'), false),
  ('f6e7fff2-5fa2-5a84-a12a-2b6a8f27c178', (select id from public.services where slug = 'full-service'), false),
  ('f6e7fff2-5fa2-5a84-a12a-2b6a8f27c178', (select id from public.services where slug = 'diagnostics'), false),
  ('62538202-654d-5bf0-91a8-bc40919b064a', (select id from public.services where slug = 'engine-repair'), false),
  ('62538202-654d-5bf0-91a8-bc40919b064a', (select id from public.services where slug = 'oil-change'), false),
  ('62538202-654d-5bf0-91a8-bc40919b064a', (select id from public.services where slug = 'brake-service'), false),
  ('62538202-654d-5bf0-91a8-bc40919b064a', (select id from public.services where slug = 'battery-replacement'), false),
  ('62538202-654d-5bf0-91a8-bc40919b064a', (select id from public.services where slug = 'full-service'), false),
  ('62538202-654d-5bf0-91a8-bc40919b064a', (select id from public.services where slug = 'diagnostics'), false),
  ('904ae6a1-8f22-5f8d-b978-5df7bb01eba8', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('904ae6a1-8f22-5f8d-b978-5df7bb01eba8', (select id from public.services where slug = 'oil-change'), false),
  ('904ae6a1-8f22-5f8d-b978-5df7bb01eba8', (select id from public.services where slug = 'chain-sprocket'), false),
  ('904ae6a1-8f22-5f8d-b978-5df7bb01eba8', (select id from public.services where slug = 'puncture-repair'), false),
  ('904ae6a1-8f22-5f8d-b978-5df7bb01eba8', (select id from public.services where slug = 'battery-replacement'), false),
  ('9c2b1073-60d1-5639-a7f2-096cd36a1e2d', (select id from public.services where slug = 'tyre-replacement'), false),
  ('9c2b1073-60d1-5639-a7f2-096cd36a1e2d', (select id from public.services where slug = 'wheel-alignment'), false),
  ('9c2b1073-60d1-5639-a7f2-096cd36a1e2d', (select id from public.services where slug = 'puncture-repair'), false),
  ('2d3b7e4a-0714-545f-bd36-db557a0661d1', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('2d3b7e4a-0714-545f-bd36-db557a0661d1', (select id from public.services where slug = 'oil-change'), false),
  ('2d3b7e4a-0714-545f-bd36-db557a0661d1', (select id from public.services where slug = 'chain-sprocket'), false),
  ('2d3b7e4a-0714-545f-bd36-db557a0661d1', (select id from public.services where slug = 'puncture-repair'), false),
  ('2d3b7e4a-0714-545f-bd36-db557a0661d1', (select id from public.services where slug = 'battery-replacement'), false),
  ('8ecb1908-3c4a-5b5b-b5ec-5e726b0d1d18', (select id from public.services where slug = 'engine-repair'), false),
  ('8ecb1908-3c4a-5b5b-b5ec-5e726b0d1d18', (select id from public.services where slug = 'oil-change'), false),
  ('8ecb1908-3c4a-5b5b-b5ec-5e726b0d1d18', (select id from public.services where slug = 'brake-service'), false),
  ('8ecb1908-3c4a-5b5b-b5ec-5e726b0d1d18', (select id from public.services where slug = 'battery-replacement'), false),
  ('8ecb1908-3c4a-5b5b-b5ec-5e726b0d1d18', (select id from public.services where slug = 'full-service'), false),
  ('8ecb1908-3c4a-5b5b-b5ec-5e726b0d1d18', (select id from public.services where slug = 'diagnostics'), false),
  ('80d68f02-b7c2-5513-9f39-b9bbc89a1a0c', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('80d68f02-b7c2-5513-9f39-b9bbc89a1a0c', (select id from public.services where slug = 'oil-change'), false),
  ('80d68f02-b7c2-5513-9f39-b9bbc89a1a0c', (select id from public.services where slug = 'chain-sprocket'), false),
  ('80d68f02-b7c2-5513-9f39-b9bbc89a1a0c', (select id from public.services where slug = 'puncture-repair'), false),
  ('80d68f02-b7c2-5513-9f39-b9bbc89a1a0c', (select id from public.services where slug = 'battery-replacement'), false),
  ('6c72a221-bf5c-52ac-b8b8-01cba2a6abde', (select id from public.services where slug = 'engine-repair'), false),
  ('6c72a221-bf5c-52ac-b8b8-01cba2a6abde', (select id from public.services where slug = 'oil-change'), false),
  ('6c72a221-bf5c-52ac-b8b8-01cba2a6abde', (select id from public.services where slug = 'brake-service'), false),
  ('6c72a221-bf5c-52ac-b8b8-01cba2a6abde', (select id from public.services where slug = 'battery-replacement'), false),
  ('6c72a221-bf5c-52ac-b8b8-01cba2a6abde', (select id from public.services where slug = 'full-service'), false),
  ('6c72a221-bf5c-52ac-b8b8-01cba2a6abde', (select id from public.services where slug = 'diagnostics'), false),
  ('af0920e4-10a7-5401-8e70-f833a4f914e0', (select id from public.services where slug = 'tyre-replacement'), false),
  ('af0920e4-10a7-5401-8e70-f833a4f914e0', (select id from public.services where slug = 'wheel-alignment'), false),
  ('af0920e4-10a7-5401-8e70-f833a4f914e0', (select id from public.services where slug = 'puncture-repair'), false),
  ('2b14a5c7-e6f1-5bd0-a68e-b671daf6c3c8', (select id from public.services where slug = 'engine-repair'), false),
  ('2b14a5c7-e6f1-5bd0-a68e-b671daf6c3c8', (select id from public.services where slug = 'oil-change'), false),
  ('2b14a5c7-e6f1-5bd0-a68e-b671daf6c3c8', (select id from public.services where slug = 'brake-service'), false),
  ('2b14a5c7-e6f1-5bd0-a68e-b671daf6c3c8', (select id from public.services where slug = 'battery-replacement'), false),
  ('2b14a5c7-e6f1-5bd0-a68e-b671daf6c3c8', (select id from public.services where slug = 'full-service'), false),
  ('2b14a5c7-e6f1-5bd0-a68e-b671daf6c3c8', (select id from public.services where slug = 'diagnostics'), false),
  ('9493694e-909d-5bb7-8c39-26ddc0482904', (select id from public.services where slug = 'spare-parts'), false),
  ('9493694e-909d-5bb7-8c39-26ddc0482904', (select id from public.services where slug = 'battery-replacement'), false),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', (select id from public.services where slug = 'oil-change'), false),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', (select id from public.services where slug = 'chain-sprocket'), false),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', (select id from public.services where slug = 'puncture-repair'), false),
  ('46af35c9-0644-50ad-8310-4f6a054d322d', (select id from public.services where slug = 'battery-replacement'), false),
  ('adc476a7-dff8-5ebb-a59c-5d71dd430042', (select id from public.services where slug = 'engine-repair'), false),
  ('adc476a7-dff8-5ebb-a59c-5d71dd430042', (select id from public.services where slug = 'oil-change'), false),
  ('adc476a7-dff8-5ebb-a59c-5d71dd430042', (select id from public.services where slug = 'brake-service'), false),
  ('adc476a7-dff8-5ebb-a59c-5d71dd430042', (select id from public.services where slug = 'battery-replacement'), false),
  ('adc476a7-dff8-5ebb-a59c-5d71dd430042', (select id from public.services where slug = 'full-service'), false),
  ('adc476a7-dff8-5ebb-a59c-5d71dd430042', (select id from public.services where slug = 'diagnostics'), false),
  ('b31f6b6d-4b40-5e47-8afb-04028a026141', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('b31f6b6d-4b40-5e47-8afb-04028a026141', (select id from public.services where slug = 'oil-change'), false),
  ('b31f6b6d-4b40-5e47-8afb-04028a026141', (select id from public.services where slug = 'chain-sprocket'), false),
  ('b31f6b6d-4b40-5e47-8afb-04028a026141', (select id from public.services where slug = 'puncture-repair'), false),
  ('b31f6b6d-4b40-5e47-8afb-04028a026141', (select id from public.services where slug = 'battery-replacement'), false),
  ('2e329f24-ee7d-5709-a32d-ba7f5f84b404', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('2e329f24-ee7d-5709-a32d-ba7f5f84b404', (select id from public.services where slug = 'oil-change'), false),
  ('2e329f24-ee7d-5709-a32d-ba7f5f84b404', (select id from public.services where slug = 'chain-sprocket'), false),
  ('2e329f24-ee7d-5709-a32d-ba7f5f84b404', (select id from public.services where slug = 'puncture-repair'), false),
  ('2e329f24-ee7d-5709-a32d-ba7f5f84b404', (select id from public.services where slug = 'battery-replacement'), false),
  ('f1f9da57-74cc-5dda-b879-fde9a018cce9', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('f1f9da57-74cc-5dda-b879-fde9a018cce9', (select id from public.services where slug = 'oil-change'), false),
  ('f1f9da57-74cc-5dda-b879-fde9a018cce9', (select id from public.services where slug = 'chain-sprocket'), false),
  ('f1f9da57-74cc-5dda-b879-fde9a018cce9', (select id from public.services where slug = 'puncture-repair'), false),
  ('f1f9da57-74cc-5dda-b879-fde9a018cce9', (select id from public.services where slug = 'battery-replacement'), false),
  ('83cab5f1-0702-5562-9491-29f3c5107e04', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('83cab5f1-0702-5562-9491-29f3c5107e04', (select id from public.services where slug = 'oil-change'), false),
  ('83cab5f1-0702-5562-9491-29f3c5107e04', (select id from public.services where slug = 'chain-sprocket'), false),
  ('83cab5f1-0702-5562-9491-29f3c5107e04', (select id from public.services where slug = 'puncture-repair'), false),
  ('83cab5f1-0702-5562-9491-29f3c5107e04', (select id from public.services where slug = 'battery-replacement'), false),
  ('c67507f6-e9d5-5c05-ac5d-c9ec20b365b1', (select id from public.services where slug = 'engine-repair'), false),
  ('c67507f6-e9d5-5c05-ac5d-c9ec20b365b1', (select id from public.services where slug = 'oil-change'), false),
  ('c67507f6-e9d5-5c05-ac5d-c9ec20b365b1', (select id from public.services where slug = 'brake-service'), false),
  ('c67507f6-e9d5-5c05-ac5d-c9ec20b365b1', (select id from public.services where slug = 'battery-replacement'), false),
  ('c67507f6-e9d5-5c05-ac5d-c9ec20b365b1', (select id from public.services where slug = 'full-service'), false),
  ('c67507f6-e9d5-5c05-ac5d-c9ec20b365b1', (select id from public.services where slug = 'diagnostics'), false),
  ('5489620e-ef24-55ac-b1e0-ef01f8fe62cd', (select id from public.services where slug = 'engine-repair'), false),
  ('5489620e-ef24-55ac-b1e0-ef01f8fe62cd', (select id from public.services where slug = 'oil-change'), false),
  ('5489620e-ef24-55ac-b1e0-ef01f8fe62cd', (select id from public.services where slug = 'brake-service'), false),
  ('5489620e-ef24-55ac-b1e0-ef01f8fe62cd', (select id from public.services where slug = 'battery-replacement'), false),
  ('5489620e-ef24-55ac-b1e0-ef01f8fe62cd', (select id from public.services where slug = 'full-service'), false),
  ('5489620e-ef24-55ac-b1e0-ef01f8fe62cd', (select id from public.services where slug = 'diagnostics'), false),
  ('164afc1e-3930-5a2f-8e21-b5eaa4af1ee6', (select id from public.services where slug = 'spare-parts'), false),
  ('164afc1e-3930-5a2f-8e21-b5eaa4af1ee6', (select id from public.services where slug = 'battery-replacement'), false),
  ('15e7e250-32c2-5b3d-ae27-1a85253ef0e4', (select id from public.services where slug = 'engine-repair'), false),
  ('15e7e250-32c2-5b3d-ae27-1a85253ef0e4', (select id from public.services where slug = 'oil-change'), false),
  ('15e7e250-32c2-5b3d-ae27-1a85253ef0e4', (select id from public.services where slug = 'brake-service'), false),
  ('15e7e250-32c2-5b3d-ae27-1a85253ef0e4', (select id from public.services where slug = 'battery-replacement'), false),
  ('15e7e250-32c2-5b3d-ae27-1a85253ef0e4', (select id from public.services where slug = 'full-service'), false),
  ('15e7e250-32c2-5b3d-ae27-1a85253ef0e4', (select id from public.services where slug = 'diagnostics'), false),
  ('84552a2e-b84f-55b2-9562-5edfa5fc8bd5', (select id from public.services where slug = 'tyre-replacement'), false),
  ('84552a2e-b84f-55b2-9562-5edfa5fc8bd5', (select id from public.services where slug = 'wheel-alignment'), false),
  ('84552a2e-b84f-55b2-9562-5edfa5fc8bd5', (select id from public.services where slug = 'puncture-repair'), false),
  ('91384a36-0bc6-583c-9677-468ded8a520c', (select id from public.services where slug = 'spare-parts'), false),
  ('91384a36-0bc6-583c-9677-468ded8a520c', (select id from public.services where slug = 'battery-replacement'), false),
  ('0d862dbd-3b13-545d-bd7e-58b8b716733b', (select id from public.services where slug = 'spare-parts'), false),
  ('0d862dbd-3b13-545d-bd7e-58b8b716733b', (select id from public.services where slug = 'battery-replacement'), false),
  ('c1fadcfd-2f6e-5b5e-8c8f-e511dffdb620', (select id from public.services where slug = 'tyre-replacement'), false),
  ('c1fadcfd-2f6e-5b5e-8c8f-e511dffdb620', (select id from public.services where slug = 'wheel-alignment'), false),
  ('c1fadcfd-2f6e-5b5e-8c8f-e511dffdb620', (select id from public.services where slug = 'puncture-repair'), false),
  ('003948b4-5b95-53eb-86b7-e05c44e2f342', (select id from public.services where slug = 'spare-parts'), false),
  ('003948b4-5b95-53eb-86b7-e05c44e2f342', (select id from public.services where slug = 'battery-replacement'), false),
  ('111a0835-1fa3-5ab7-a8be-9869d63f6359', (select id from public.services where slug = 'spare-parts'), false),
  ('111a0835-1fa3-5ab7-a8be-9869d63f6359', (select id from public.services where slug = 'battery-replacement'), false),
  ('106fb93d-277b-59b5-8856-51588c79c157', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('106fb93d-277b-59b5-8856-51588c79c157', (select id from public.services where slug = 'oil-change'), false),
  ('106fb93d-277b-59b5-8856-51588c79c157', (select id from public.services where slug = 'chain-sprocket'), false),
  ('106fb93d-277b-59b5-8856-51588c79c157', (select id from public.services where slug = 'puncture-repair'), false),
  ('106fb93d-277b-59b5-8856-51588c79c157', (select id from public.services where slug = 'battery-replacement'), false),
  ('f7b128f7-2224-5f20-b051-4c0fe934f81b', (select id from public.services where slug = 'spare-parts'), false),
  ('f7b128f7-2224-5f20-b051-4c0fe934f81b', (select id from public.services where slug = 'battery-replacement'), false),
  ('56c48ca5-7cc0-59b0-8af1-692a167564d5', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('56c48ca5-7cc0-59b0-8af1-692a167564d5', (select id from public.services where slug = 'oil-change'), false),
  ('56c48ca5-7cc0-59b0-8af1-692a167564d5', (select id from public.services where slug = 'chain-sprocket'), false),
  ('56c48ca5-7cc0-59b0-8af1-692a167564d5', (select id from public.services where slug = 'puncture-repair'), false),
  ('56c48ca5-7cc0-59b0-8af1-692a167564d5', (select id from public.services where slug = 'battery-replacement'), false),
  ('0dffdffb-1ee4-5380-9a35-ffe31d5d3e62', (select id from public.services where slug = 'spare-parts'), false),
  ('0dffdffb-1ee4-5380-9a35-ffe31d5d3e62', (select id from public.services where slug = 'battery-replacement'), false),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', (select id from public.services where slug = 'engine-repair'), false),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', (select id from public.services where slug = 'oil-change'), false),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', (select id from public.services where slug = 'brake-service'), false),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', (select id from public.services where slug = 'battery-replacement'), false),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', (select id from public.services where slug = 'full-service'), false),
  ('11b334cc-84b1-5660-a70a-7cf0837f9e94', (select id from public.services where slug = 'diagnostics'), false),
  ('c1701d10-266c-598e-8771-b603c7f8d6ca', (select id from public.services where slug = 'engine-repair'), false),
  ('c1701d10-266c-598e-8771-b603c7f8d6ca', (select id from public.services where slug = 'oil-change'), false),
  ('c1701d10-266c-598e-8771-b603c7f8d6ca', (select id from public.services where slug = 'brake-service'), false),
  ('c1701d10-266c-598e-8771-b603c7f8d6ca', (select id from public.services where slug = 'battery-replacement'), false),
  ('c1701d10-266c-598e-8771-b603c7f8d6ca', (select id from public.services where slug = 'full-service'), false),
  ('c1701d10-266c-598e-8771-b603c7f8d6ca', (select id from public.services where slug = 'diagnostics'), false),
  ('6d3f0b63-3374-54f7-b6ea-221b07b17447', (select id from public.services where slug = 'engine-repair'), false),
  ('6d3f0b63-3374-54f7-b6ea-221b07b17447', (select id from public.services where slug = 'oil-change'), false),
  ('6d3f0b63-3374-54f7-b6ea-221b07b17447', (select id from public.services where slug = 'brake-service'), false),
  ('6d3f0b63-3374-54f7-b6ea-221b07b17447', (select id from public.services where slug = 'battery-replacement'), false),
  ('6d3f0b63-3374-54f7-b6ea-221b07b17447', (select id from public.services where slug = 'full-service'), false),
  ('6d3f0b63-3374-54f7-b6ea-221b07b17447', (select id from public.services where slug = 'diagnostics'), false),
  ('2e40824f-7623-5e82-b832-43ba74c012c4', (select id from public.services where slug = 'engine-repair'), false),
  ('2e40824f-7623-5e82-b832-43ba74c012c4', (select id from public.services where slug = 'oil-change'), false),
  ('2e40824f-7623-5e82-b832-43ba74c012c4', (select id from public.services where slug = 'brake-service'), false),
  ('2e40824f-7623-5e82-b832-43ba74c012c4', (select id from public.services where slug = 'battery-replacement'), false),
  ('2e40824f-7623-5e82-b832-43ba74c012c4', (select id from public.services where slug = 'full-service'), false),
  ('2e40824f-7623-5e82-b832-43ba74c012c4', (select id from public.services where slug = 'diagnostics'), false),
  ('c6cb3634-5dc6-5b2a-80ee-5289786fe144', (select id from public.services where slug = 'engine-repair'), false),
  ('c6cb3634-5dc6-5b2a-80ee-5289786fe144', (select id from public.services where slug = 'oil-change'), false),
  ('c6cb3634-5dc6-5b2a-80ee-5289786fe144', (select id from public.services where slug = 'brake-service'), false),
  ('c6cb3634-5dc6-5b2a-80ee-5289786fe144', (select id from public.services where slug = 'battery-replacement'), false),
  ('c6cb3634-5dc6-5b2a-80ee-5289786fe144', (select id from public.services where slug = 'full-service'), false),
  ('c6cb3634-5dc6-5b2a-80ee-5289786fe144', (select id from public.services where slug = 'diagnostics'), false),
  ('9bb0d3e9-eb95-5e0c-b42a-5666729de8c2', (select id from public.services where slug = 'engine-repair'), false),
  ('9bb0d3e9-eb95-5e0c-b42a-5666729de8c2', (select id from public.services where slug = 'oil-change'), false),
  ('9bb0d3e9-eb95-5e0c-b42a-5666729de8c2', (select id from public.services where slug = 'brake-service'), false),
  ('9bb0d3e9-eb95-5e0c-b42a-5666729de8c2', (select id from public.services where slug = 'battery-replacement'), false),
  ('9bb0d3e9-eb95-5e0c-b42a-5666729de8c2', (select id from public.services where slug = 'full-service'), false),
  ('9bb0d3e9-eb95-5e0c-b42a-5666729de8c2', (select id from public.services where slug = 'diagnostics'), false),
  ('a8dfea36-bc17-5e6d-a257-2347f13f233d', (select id from public.services where slug = 'engine-repair'), false),
  ('a8dfea36-bc17-5e6d-a257-2347f13f233d', (select id from public.services where slug = 'oil-change'), false),
  ('a8dfea36-bc17-5e6d-a257-2347f13f233d', (select id from public.services where slug = 'brake-service'), false),
  ('a8dfea36-bc17-5e6d-a257-2347f13f233d', (select id from public.services where slug = 'battery-replacement'), false),
  ('a8dfea36-bc17-5e6d-a257-2347f13f233d', (select id from public.services where slug = 'full-service'), false),
  ('a8dfea36-bc17-5e6d-a257-2347f13f233d', (select id from public.services where slug = 'diagnostics'), false),
  ('a423a6ff-2042-5ffb-8c59-568f1164e9cd', (select id from public.services where slug = 'spare-parts'), false),
  ('a423a6ff-2042-5ffb-8c59-568f1164e9cd', (select id from public.services where slug = 'battery-replacement'), false),
  ('1b4a8f2b-07a8-5ccc-a42c-d55f30340649', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('1b4a8f2b-07a8-5ccc-a42c-d55f30340649', (select id from public.services where slug = 'oil-change'), false),
  ('1b4a8f2b-07a8-5ccc-a42c-d55f30340649', (select id from public.services where slug = 'chain-sprocket'), false),
  ('1b4a8f2b-07a8-5ccc-a42c-d55f30340649', (select id from public.services where slug = 'puncture-repair'), false),
  ('1b4a8f2b-07a8-5ccc-a42c-d55f30340649', (select id from public.services where slug = 'battery-replacement'), false),
  ('3a125d66-4571-5ddb-9ce7-3ea7686c2f72', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('3a125d66-4571-5ddb-9ce7-3ea7686c2f72', (select id from public.services where slug = 'oil-change'), false),
  ('3a125d66-4571-5ddb-9ce7-3ea7686c2f72', (select id from public.services where slug = 'chain-sprocket'), false),
  ('3a125d66-4571-5ddb-9ce7-3ea7686c2f72', (select id from public.services where slug = 'puncture-repair'), false),
  ('3a125d66-4571-5ddb-9ce7-3ea7686c2f72', (select id from public.services where slug = 'battery-replacement'), false),
  ('d1c277d6-9103-560b-b932-2833d6850589', (select id from public.services where slug = 'engine-repair'), false),
  ('d1c277d6-9103-560b-b932-2833d6850589', (select id from public.services where slug = 'oil-change'), false),
  ('d1c277d6-9103-560b-b932-2833d6850589', (select id from public.services where slug = 'brake-service'), false),
  ('d1c277d6-9103-560b-b932-2833d6850589', (select id from public.services where slug = 'battery-replacement'), false),
  ('d1c277d6-9103-560b-b932-2833d6850589', (select id from public.services where slug = 'full-service'), false),
  ('d1c277d6-9103-560b-b932-2833d6850589', (select id from public.services where slug = 'diagnostics'), false),
  ('2137d6fa-0800-546f-8898-8ae0b443e72b', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('2137d6fa-0800-546f-8898-8ae0b443e72b', (select id from public.services where slug = 'oil-change'), false),
  ('2137d6fa-0800-546f-8898-8ae0b443e72b', (select id from public.services where slug = 'chain-sprocket'), false),
  ('2137d6fa-0800-546f-8898-8ae0b443e72b', (select id from public.services where slug = 'puncture-repair'), false),
  ('2137d6fa-0800-546f-8898-8ae0b443e72b', (select id from public.services where slug = 'battery-replacement'), false),
  ('46ef8925-1e2d-58f2-bd38-e12fabb8987b', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('46ef8925-1e2d-58f2-bd38-e12fabb8987b', (select id from public.services where slug = 'oil-change'), false),
  ('46ef8925-1e2d-58f2-bd38-e12fabb8987b', (select id from public.services where slug = 'chain-sprocket'), false),
  ('46ef8925-1e2d-58f2-bd38-e12fabb8987b', (select id from public.services where slug = 'puncture-repair'), false),
  ('46ef8925-1e2d-58f2-bd38-e12fabb8987b', (select id from public.services where slug = 'battery-replacement'), false),
  ('719a9d5b-9732-5414-bf9f-986859098123', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('719a9d5b-9732-5414-bf9f-986859098123', (select id from public.services where slug = 'oil-change'), false),
  ('719a9d5b-9732-5414-bf9f-986859098123', (select id from public.services where slug = 'chain-sprocket'), false),
  ('719a9d5b-9732-5414-bf9f-986859098123', (select id from public.services where slug = 'puncture-repair'), false),
  ('719a9d5b-9732-5414-bf9f-986859098123', (select id from public.services where slug = 'battery-replacement'), false),
  ('212ab116-1da4-5b4e-9c47-04fc4495157e', (select id from public.services where slug = 'engine-repair'), false),
  ('212ab116-1da4-5b4e-9c47-04fc4495157e', (select id from public.services where slug = 'oil-change'), false),
  ('212ab116-1da4-5b4e-9c47-04fc4495157e', (select id from public.services where slug = 'brake-service'), false),
  ('212ab116-1da4-5b4e-9c47-04fc4495157e', (select id from public.services where slug = 'battery-replacement'), false),
  ('212ab116-1da4-5b4e-9c47-04fc4495157e', (select id from public.services where slug = 'full-service'), false),
  ('212ab116-1da4-5b4e-9c47-04fc4495157e', (select id from public.services where slug = 'diagnostics'), false),
  ('107f8325-8d89-5f10-b9c5-9fb413f031d4', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('107f8325-8d89-5f10-b9c5-9fb413f031d4', (select id from public.services where slug = 'oil-change'), false),
  ('107f8325-8d89-5f10-b9c5-9fb413f031d4', (select id from public.services where slug = 'chain-sprocket'), false),
  ('107f8325-8d89-5f10-b9c5-9fb413f031d4', (select id from public.services where slug = 'puncture-repair'), false),
  ('107f8325-8d89-5f10-b9c5-9fb413f031d4', (select id from public.services where slug = 'battery-replacement'), false),
  ('639f23e4-b3dd-5b2b-aafb-15512ab18475', (select id from public.services where slug = 'tyre-replacement'), false),
  ('639f23e4-b3dd-5b2b-aafb-15512ab18475', (select id from public.services where slug = 'wheel-alignment'), false),
  ('639f23e4-b3dd-5b2b-aafb-15512ab18475', (select id from public.services where slug = 'puncture-repair'), false),
  ('edfe89a0-23dc-554b-84ed-2c70b0e8ac74', (select id from public.services where slug = 'spare-parts'), false),
  ('edfe89a0-23dc-554b-84ed-2c70b0e8ac74', (select id from public.services where slug = 'battery-replacement'), false),
  ('f6f64e61-f013-50a2-aff1-109b8b056259', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('f6f64e61-f013-50a2-aff1-109b8b056259', (select id from public.services where slug = 'oil-change'), false),
  ('f6f64e61-f013-50a2-aff1-109b8b056259', (select id from public.services where slug = 'chain-sprocket'), false),
  ('f6f64e61-f013-50a2-aff1-109b8b056259', (select id from public.services where slug = 'puncture-repair'), false),
  ('f6f64e61-f013-50a2-aff1-109b8b056259', (select id from public.services where slug = 'battery-replacement'), false),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', (select id from public.services where slug = 'engine-repair'), false),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', (select id from public.services where slug = 'oil-change'), false),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', (select id from public.services where slug = 'brake-service'), false),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', (select id from public.services where slug = 'battery-replacement'), false),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', (select id from public.services where slug = 'full-service'), false),
  ('af4e9c84-f50f-5772-bf12-2b11aecc148e', (select id from public.services where slug = 'diagnostics'), false),
  ('6d266468-465f-5ed2-818e-bb725e2fb2e8', (select id from public.services where slug = 'engine-repair'), false),
  ('6d266468-465f-5ed2-818e-bb725e2fb2e8', (select id from public.services where slug = 'oil-change'), false),
  ('6d266468-465f-5ed2-818e-bb725e2fb2e8', (select id from public.services where slug = 'brake-service'), false),
  ('6d266468-465f-5ed2-818e-bb725e2fb2e8', (select id from public.services where slug = 'battery-replacement'), false),
  ('6d266468-465f-5ed2-818e-bb725e2fb2e8', (select id from public.services where slug = 'full-service'), false),
  ('6d266468-465f-5ed2-818e-bb725e2fb2e8', (select id from public.services where slug = 'diagnostics'), false),
  ('b1ba39fa-4644-542f-b861-119e54cf90c0', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('b1ba39fa-4644-542f-b861-119e54cf90c0', (select id from public.services where slug = 'oil-change'), false),
  ('b1ba39fa-4644-542f-b861-119e54cf90c0', (select id from public.services where slug = 'chain-sprocket'), false),
  ('b1ba39fa-4644-542f-b861-119e54cf90c0', (select id from public.services where slug = 'puncture-repair'), false),
  ('b1ba39fa-4644-542f-b861-119e54cf90c0', (select id from public.services where slug = 'battery-replacement'), false),
  ('929452ad-5990-5e6a-b7b0-ed48a07d39dd', (select id from public.services where slug = 'engine-repair'), false),
  ('929452ad-5990-5e6a-b7b0-ed48a07d39dd', (select id from public.services where slug = 'oil-change'), false),
  ('929452ad-5990-5e6a-b7b0-ed48a07d39dd', (select id from public.services where slug = 'brake-service'), false),
  ('929452ad-5990-5e6a-b7b0-ed48a07d39dd', (select id from public.services where slug = 'battery-replacement'), false),
  ('929452ad-5990-5e6a-b7b0-ed48a07d39dd', (select id from public.services where slug = 'full-service'), false),
  ('929452ad-5990-5e6a-b7b0-ed48a07d39dd', (select id from public.services where slug = 'diagnostics'), false),
  ('f43c4a61-5643-558f-b2dc-f845618b6048', (select id from public.services where slug = 'engine-repair'), false),
  ('f43c4a61-5643-558f-b2dc-f845618b6048', (select id from public.services where slug = 'oil-change'), false),
  ('f43c4a61-5643-558f-b2dc-f845618b6048', (select id from public.services where slug = 'brake-service'), false),
  ('f43c4a61-5643-558f-b2dc-f845618b6048', (select id from public.services where slug = 'battery-replacement'), false),
  ('f43c4a61-5643-558f-b2dc-f845618b6048', (select id from public.services where slug = 'full-service'), false),
  ('f43c4a61-5643-558f-b2dc-f845618b6048', (select id from public.services where slug = 'diagnostics'), false),
  ('08b58440-fff6-5117-bc3f-e998263f1383', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('08b58440-fff6-5117-bc3f-e998263f1383', (select id from public.services where slug = 'oil-change'), false),
  ('08b58440-fff6-5117-bc3f-e998263f1383', (select id from public.services where slug = 'chain-sprocket'), false),
  ('08b58440-fff6-5117-bc3f-e998263f1383', (select id from public.services where slug = 'puncture-repair'), false),
  ('08b58440-fff6-5117-bc3f-e998263f1383', (select id from public.services where slug = 'battery-replacement'), false),
  ('dd65d9b0-543d-51e9-8853-659d3eb92dfd', (select id from public.services where slug = 'engine-repair'), false),
  ('dd65d9b0-543d-51e9-8853-659d3eb92dfd', (select id from public.services where slug = 'oil-change'), false),
  ('dd65d9b0-543d-51e9-8853-659d3eb92dfd', (select id from public.services where slug = 'brake-service'), false),
  ('dd65d9b0-543d-51e9-8853-659d3eb92dfd', (select id from public.services where slug = 'battery-replacement'), false),
  ('dd65d9b0-543d-51e9-8853-659d3eb92dfd', (select id from public.services where slug = 'full-service'), false),
  ('dd65d9b0-543d-51e9-8853-659d3eb92dfd', (select id from public.services where slug = 'diagnostics'), false),
  ('80f68483-7350-5438-99cf-e9bd7553701e', (select id from public.services where slug = 'engine-repair'), false),
  ('80f68483-7350-5438-99cf-e9bd7553701e', (select id from public.services where slug = 'oil-change'), false),
  ('80f68483-7350-5438-99cf-e9bd7553701e', (select id from public.services where slug = 'brake-service'), false),
  ('80f68483-7350-5438-99cf-e9bd7553701e', (select id from public.services where slug = 'battery-replacement'), false),
  ('80f68483-7350-5438-99cf-e9bd7553701e', (select id from public.services where slug = 'full-service'), false),
  ('80f68483-7350-5438-99cf-e9bd7553701e', (select id from public.services where slug = 'diagnostics'), false),
  ('5aaf4dea-83a0-530a-aace-e0a274f00acb', (select id from public.services where slug = 'engine-repair'), false),
  ('5aaf4dea-83a0-530a-aace-e0a274f00acb', (select id from public.services where slug = 'oil-change'), false),
  ('5aaf4dea-83a0-530a-aace-e0a274f00acb', (select id from public.services where slug = 'brake-service'), false),
  ('5aaf4dea-83a0-530a-aace-e0a274f00acb', (select id from public.services where slug = 'battery-replacement'), false),
  ('5aaf4dea-83a0-530a-aace-e0a274f00acb', (select id from public.services where slug = 'full-service'), false),
  ('5aaf4dea-83a0-530a-aace-e0a274f00acb', (select id from public.services where slug = 'diagnostics'), false),
  ('3ad3d3d4-3479-5863-a3c0-b7dff15b1440', (select id from public.services where slug = 'spare-parts'), false),
  ('3ad3d3d4-3479-5863-a3c0-b7dff15b1440', (select id from public.services where slug = 'battery-replacement'), false),
  ('e1dd73b9-68b7-5086-a084-6d3b78be380d', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('e1dd73b9-68b7-5086-a084-6d3b78be380d', (select id from public.services where slug = 'oil-change'), false),
  ('e1dd73b9-68b7-5086-a084-6d3b78be380d', (select id from public.services where slug = 'chain-sprocket'), false),
  ('e1dd73b9-68b7-5086-a084-6d3b78be380d', (select id from public.services where slug = 'puncture-repair'), false),
  ('e1dd73b9-68b7-5086-a084-6d3b78be380d', (select id from public.services where slug = 'battery-replacement'), false),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', (select id from public.services where slug = 'oil-change'), false),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', (select id from public.services where slug = 'chain-sprocket'), false),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', (select id from public.services where slug = 'puncture-repair'), false),
  ('6cd7e623-39ce-5899-a023-7741b2d46ddc', (select id from public.services where slug = 'battery-replacement'), false),
  ('fcf678aa-71a3-576c-88c2-892229db3989', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('fcf678aa-71a3-576c-88c2-892229db3989', (select id from public.services where slug = 'oil-change'), false),
  ('fcf678aa-71a3-576c-88c2-892229db3989', (select id from public.services where slug = 'chain-sprocket'), false),
  ('fcf678aa-71a3-576c-88c2-892229db3989', (select id from public.services where slug = 'puncture-repair'), false),
  ('fcf678aa-71a3-576c-88c2-892229db3989', (select id from public.services where slug = 'battery-replacement'), false),
  ('8065ebed-1abe-57f8-b532-f46e559e13ad', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('8065ebed-1abe-57f8-b532-f46e559e13ad', (select id from public.services where slug = 'oil-change'), false),
  ('8065ebed-1abe-57f8-b532-f46e559e13ad', (select id from public.services where slug = 'chain-sprocket'), false),
  ('8065ebed-1abe-57f8-b532-f46e559e13ad', (select id from public.services where slug = 'puncture-repair'), false),
  ('8065ebed-1abe-57f8-b532-f46e559e13ad', (select id from public.services where slug = 'battery-replacement'), false),
  ('cef45b4b-dc5d-5a34-a298-91a2437a7cb0', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('cef45b4b-dc5d-5a34-a298-91a2437a7cb0', (select id from public.services where slug = 'oil-change'), false),
  ('cef45b4b-dc5d-5a34-a298-91a2437a7cb0', (select id from public.services where slug = 'chain-sprocket'), false),
  ('cef45b4b-dc5d-5a34-a298-91a2437a7cb0', (select id from public.services where slug = 'puncture-repair'), false),
  ('cef45b4b-dc5d-5a34-a298-91a2437a7cb0', (select id from public.services where slug = 'battery-replacement'), false),
  ('00d0f195-fd45-538e-aab9-6f5e60f8c6a6', (select id from public.services where slug = 'spare-parts'), false),
  ('00d0f195-fd45-538e-aab9-6f5e60f8c6a6', (select id from public.services where slug = 'battery-replacement'), false),
  ('77998f10-85f1-5fd5-b79f-459c4cbcf734', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('77998f10-85f1-5fd5-b79f-459c4cbcf734', (select id from public.services where slug = 'oil-change'), false),
  ('77998f10-85f1-5fd5-b79f-459c4cbcf734', (select id from public.services where slug = 'chain-sprocket'), false),
  ('77998f10-85f1-5fd5-b79f-459c4cbcf734', (select id from public.services where slug = 'puncture-repair'), false),
  ('77998f10-85f1-5fd5-b79f-459c4cbcf734', (select id from public.services where slug = 'battery-replacement'), false),
  ('16241a15-a43e-5807-9140-544a0bc53440', (select id from public.services where slug = 'engine-repair'), false),
  ('16241a15-a43e-5807-9140-544a0bc53440', (select id from public.services where slug = 'oil-change'), false),
  ('16241a15-a43e-5807-9140-544a0bc53440', (select id from public.services where slug = 'brake-service'), false),
  ('16241a15-a43e-5807-9140-544a0bc53440', (select id from public.services where slug = 'battery-replacement'), false),
  ('16241a15-a43e-5807-9140-544a0bc53440', (select id from public.services where slug = 'full-service'), false),
  ('16241a15-a43e-5807-9140-544a0bc53440', (select id from public.services where slug = 'diagnostics'), false),
  ('d909c95f-7d9d-5e7b-8449-ae9ac3d62677', (select id from public.services where slug = 'engine-repair'), false),
  ('d909c95f-7d9d-5e7b-8449-ae9ac3d62677', (select id from public.services where slug = 'oil-change'), false),
  ('d909c95f-7d9d-5e7b-8449-ae9ac3d62677', (select id from public.services where slug = 'brake-service'), false),
  ('d909c95f-7d9d-5e7b-8449-ae9ac3d62677', (select id from public.services where slug = 'battery-replacement'), false),
  ('d909c95f-7d9d-5e7b-8449-ae9ac3d62677', (select id from public.services where slug = 'full-service'), false),
  ('d909c95f-7d9d-5e7b-8449-ae9ac3d62677', (select id from public.services where slug = 'diagnostics'), false),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', (select id from public.services where slug = 'engine-repair'), false),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', (select id from public.services where slug = 'oil-change'), false),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', (select id from public.services where slug = 'brake-service'), false),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', (select id from public.services where slug = 'battery-replacement'), false),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', (select id from public.services where slug = 'full-service'), false),
  ('f99edaf4-8098-596f-a7cc-e4f1338f3dd3', (select id from public.services where slug = 'diagnostics'), false),
  ('d98a82bd-049a-56d2-b412-341ae6fe5085', (select id from public.services where slug = 'engine-repair'), false),
  ('d98a82bd-049a-56d2-b412-341ae6fe5085', (select id from public.services where slug = 'oil-change'), false),
  ('d98a82bd-049a-56d2-b412-341ae6fe5085', (select id from public.services where slug = 'brake-service'), false),
  ('d98a82bd-049a-56d2-b412-341ae6fe5085', (select id from public.services where slug = 'battery-replacement'), false),
  ('d98a82bd-049a-56d2-b412-341ae6fe5085', (select id from public.services where slug = 'full-service'), false),
  ('d98a82bd-049a-56d2-b412-341ae6fe5085', (select id from public.services where slug = 'diagnostics'), false),
  ('b609fda6-38de-5469-bccc-b656f6124646', (select id from public.services where slug = 'tyre-replacement'), false),
  ('b609fda6-38de-5469-bccc-b656f6124646', (select id from public.services where slug = 'wheel-alignment'), false),
  ('b609fda6-38de-5469-bccc-b656f6124646', (select id from public.services where slug = 'puncture-repair'), false),
  ('8457abf6-8ac4-502b-9d86-537755e4f6a5', (select id from public.services where slug = 'tyre-replacement'), false),
  ('8457abf6-8ac4-502b-9d86-537755e4f6a5', (select id from public.services where slug = 'wheel-alignment'), false),
  ('8457abf6-8ac4-502b-9d86-537755e4f6a5', (select id from public.services where slug = 'puncture-repair'), false),
  ('b60123f4-8fcd-5988-94d8-fa80dc3349bf', (select id from public.services where slug = 'tyre-replacement'), false),
  ('b60123f4-8fcd-5988-94d8-fa80dc3349bf', (select id from public.services where slug = 'wheel-alignment'), false),
  ('b60123f4-8fcd-5988-94d8-fa80dc3349bf', (select id from public.services where slug = 'puncture-repair'), false),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', (select id from public.services where slug = 'body-repair'), true),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', (select id from public.services where slug = 'full-service'), true),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', (select id from public.services where slug = 'car-wash'), true),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', (select id from public.services where slug = 'engine-repair'), false),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', (select id from public.services where slug = 'oil-change'), false),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', (select id from public.services where slug = 'brake-service'), false),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', (select id from public.services where slug = 'battery-replacement'), false),
  ('b2458e5e-bbec-587e-b38e-a632338d6828', (select id from public.services where slug = 'diagnostics'), false),
  ('d8a18579-3dcf-5547-aa52-010610f088ab', (select id from public.services where slug = 'tyre-replacement'), false),
  ('d8a18579-3dcf-5547-aa52-010610f088ab', (select id from public.services where slug = 'wheel-alignment'), false),
  ('d8a18579-3dcf-5547-aa52-010610f088ab', (select id from public.services where slug = 'puncture-repair'), false),
  ('cec73578-3c8a-51ab-8015-e8fa570e77cb', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('cec73578-3c8a-51ab-8015-e8fa570e77cb', (select id from public.services where slug = 'oil-change'), false),
  ('cec73578-3c8a-51ab-8015-e8fa570e77cb', (select id from public.services where slug = 'chain-sprocket'), false),
  ('cec73578-3c8a-51ab-8015-e8fa570e77cb', (select id from public.services where slug = 'puncture-repair'), false),
  ('cec73578-3c8a-51ab-8015-e8fa570e77cb', (select id from public.services where slug = 'battery-replacement'), false),
  ('204d7560-1133-5351-aad1-3d5807b2f321', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('204d7560-1133-5351-aad1-3d5807b2f321', (select id from public.services where slug = 'oil-change'), false),
  ('204d7560-1133-5351-aad1-3d5807b2f321', (select id from public.services where slug = 'chain-sprocket'), false),
  ('204d7560-1133-5351-aad1-3d5807b2f321', (select id from public.services where slug = 'puncture-repair'), false),
  ('204d7560-1133-5351-aad1-3d5807b2f321', (select id from public.services where slug = 'battery-replacement'), false),
  ('6ccebe5b-bc36-5c33-ab95-bc77b4c8ab9c', (select id from public.services where slug = 'engine-repair'), false),
  ('6ccebe5b-bc36-5c33-ab95-bc77b4c8ab9c', (select id from public.services where slug = 'oil-change'), false),
  ('6ccebe5b-bc36-5c33-ab95-bc77b4c8ab9c', (select id from public.services where slug = 'brake-service'), false),
  ('6ccebe5b-bc36-5c33-ab95-bc77b4c8ab9c', (select id from public.services where slug = 'battery-replacement'), false),
  ('6ccebe5b-bc36-5c33-ab95-bc77b4c8ab9c', (select id from public.services where slug = 'full-service'), false),
  ('6ccebe5b-bc36-5c33-ab95-bc77b4c8ab9c', (select id from public.services where slug = 'diagnostics'), false),
  ('c7873475-fa54-538a-89f5-43cdd1c2dd69', (select id from public.services where slug = 'engine-repair'), false),
  ('c7873475-fa54-538a-89f5-43cdd1c2dd69', (select id from public.services where slug = 'oil-change'), false),
  ('c7873475-fa54-538a-89f5-43cdd1c2dd69', (select id from public.services where slug = 'brake-service'), false),
  ('c7873475-fa54-538a-89f5-43cdd1c2dd69', (select id from public.services where slug = 'battery-replacement'), false),
  ('c7873475-fa54-538a-89f5-43cdd1c2dd69', (select id from public.services where slug = 'full-service'), false),
  ('c7873475-fa54-538a-89f5-43cdd1c2dd69', (select id from public.services where slug = 'diagnostics'), false),
  ('ed48e85a-b7c0-5564-8faf-5bb56c66f3f6', (select id from public.services where slug = 'engine-repair'), false),
  ('ed48e85a-b7c0-5564-8faf-5bb56c66f3f6', (select id from public.services where slug = 'oil-change'), false),
  ('ed48e85a-b7c0-5564-8faf-5bb56c66f3f6', (select id from public.services where slug = 'brake-service'), false),
  ('ed48e85a-b7c0-5564-8faf-5bb56c66f3f6', (select id from public.services where slug = 'battery-replacement'), false),
  ('ed48e85a-b7c0-5564-8faf-5bb56c66f3f6', (select id from public.services where slug = 'full-service'), false),
  ('ed48e85a-b7c0-5564-8faf-5bb56c66f3f6', (select id from public.services where slug = 'diagnostics'), false),
  ('85a8a406-b267-5b13-a5c7-d377487d6610', (select id from public.services where slug = 'engine-repair'), false),
  ('85a8a406-b267-5b13-a5c7-d377487d6610', (select id from public.services where slug = 'oil-change'), false),
  ('85a8a406-b267-5b13-a5c7-d377487d6610', (select id from public.services where slug = 'brake-service'), false),
  ('85a8a406-b267-5b13-a5c7-d377487d6610', (select id from public.services where slug = 'battery-replacement'), false),
  ('85a8a406-b267-5b13-a5c7-d377487d6610', (select id from public.services where slug = 'full-service'), false),
  ('85a8a406-b267-5b13-a5c7-d377487d6610', (select id from public.services where slug = 'diagnostics'), false),
  ('0fcee794-d458-57c8-a03b-ffabd736950f', (select id from public.services where slug = 'spare-parts'), false),
  ('0fcee794-d458-57c8-a03b-ffabd736950f', (select id from public.services where slug = 'battery-replacement'), false),
  ('758441fa-8dc2-5404-8ba2-2ab247cff6bc', (select id from public.services where slug = 'tyre-replacement'), false),
  ('758441fa-8dc2-5404-8ba2-2ab247cff6bc', (select id from public.services where slug = 'wheel-alignment'), false),
  ('758441fa-8dc2-5404-8ba2-2ab247cff6bc', (select id from public.services where slug = 'puncture-repair'), false),
  ('18364173-783a-5b10-abaf-c1d5798bb9c7', (select id from public.services where slug = 'engine-repair'), false),
  ('18364173-783a-5b10-abaf-c1d5798bb9c7', (select id from public.services where slug = 'oil-change'), false),
  ('18364173-783a-5b10-abaf-c1d5798bb9c7', (select id from public.services where slug = 'brake-service'), false),
  ('18364173-783a-5b10-abaf-c1d5798bb9c7', (select id from public.services where slug = 'battery-replacement'), false),
  ('18364173-783a-5b10-abaf-c1d5798bb9c7', (select id from public.services where slug = 'full-service'), false),
  ('18364173-783a-5b10-abaf-c1d5798bb9c7', (select id from public.services where slug = 'diagnostics'), false),
  ('e76a7a45-4c01-5c56-ad79-0e9d675a4ddf', (select id from public.services where slug = 'engine-repair'), false),
  ('e76a7a45-4c01-5c56-ad79-0e9d675a4ddf', (select id from public.services where slug = 'oil-change'), false),
  ('e76a7a45-4c01-5c56-ad79-0e9d675a4ddf', (select id from public.services where slug = 'brake-service'), false),
  ('e76a7a45-4c01-5c56-ad79-0e9d675a4ddf', (select id from public.services where slug = 'battery-replacement'), false),
  ('e76a7a45-4c01-5c56-ad79-0e9d675a4ddf', (select id from public.services where slug = 'full-service'), false),
  ('e76a7a45-4c01-5c56-ad79-0e9d675a4ddf', (select id from public.services where slug = 'diagnostics'), false),
  ('411ddfdd-85f9-534c-8fd7-84a708576aba', (select id from public.services where slug = 'engine-repair'), false),
  ('411ddfdd-85f9-534c-8fd7-84a708576aba', (select id from public.services where slug = 'oil-change'), false),
  ('411ddfdd-85f9-534c-8fd7-84a708576aba', (select id from public.services where slug = 'brake-service'), false),
  ('411ddfdd-85f9-534c-8fd7-84a708576aba', (select id from public.services where slug = 'battery-replacement'), false),
  ('411ddfdd-85f9-534c-8fd7-84a708576aba', (select id from public.services where slug = 'full-service'), false),
  ('411ddfdd-85f9-534c-8fd7-84a708576aba', (select id from public.services where slug = 'diagnostics'), false),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', (select id from public.services where slug = 'engine-repair'), false),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', (select id from public.services where slug = 'oil-change'), false),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', (select id from public.services where slug = 'brake-service'), false),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', (select id from public.services where slug = 'battery-replacement'), false),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', (select id from public.services where slug = 'full-service'), false),
  ('6ac236ef-ca7d-50cd-9f1f-5e554ee4a66f', (select id from public.services where slug = 'diagnostics'), false),
  ('ed0a16be-723b-579d-b32b-446d8b4fa9c1', (select id from public.services where slug = 'engine-repair'), false),
  ('ed0a16be-723b-579d-b32b-446d8b4fa9c1', (select id from public.services where slug = 'oil-change'), false),
  ('ed0a16be-723b-579d-b32b-446d8b4fa9c1', (select id from public.services where slug = 'brake-service'), false),
  ('ed0a16be-723b-579d-b32b-446d8b4fa9c1', (select id from public.services where slug = 'battery-replacement'), false),
  ('ed0a16be-723b-579d-b32b-446d8b4fa9c1', (select id from public.services where slug = 'full-service'), false),
  ('ed0a16be-723b-579d-b32b-446d8b4fa9c1', (select id from public.services where slug = 'diagnostics'), false),
  ('a7bbf5ac-7568-55c8-896c-318351a07ef0', (select id from public.services where slug = 'engine-repair'), false),
  ('a7bbf5ac-7568-55c8-896c-318351a07ef0', (select id from public.services where slug = 'oil-change'), false),
  ('a7bbf5ac-7568-55c8-896c-318351a07ef0', (select id from public.services where slug = 'brake-service'), false),
  ('a7bbf5ac-7568-55c8-896c-318351a07ef0', (select id from public.services where slug = 'battery-replacement'), false),
  ('a7bbf5ac-7568-55c8-896c-318351a07ef0', (select id from public.services where slug = 'full-service'), false),
  ('a7bbf5ac-7568-55c8-896c-318351a07ef0', (select id from public.services where slug = 'diagnostics'), false),
  ('b96bc697-1e70-53d8-ac3d-4c686d89b921', (select id from public.services where slug = 'engine-repair'), false),
  ('b96bc697-1e70-53d8-ac3d-4c686d89b921', (select id from public.services where slug = 'oil-change'), false),
  ('b96bc697-1e70-53d8-ac3d-4c686d89b921', (select id from public.services where slug = 'brake-service'), false),
  ('b96bc697-1e70-53d8-ac3d-4c686d89b921', (select id from public.services where slug = 'battery-replacement'), false),
  ('b96bc697-1e70-53d8-ac3d-4c686d89b921', (select id from public.services where slug = 'full-service'), false),
  ('b96bc697-1e70-53d8-ac3d-4c686d89b921', (select id from public.services where slug = 'diagnostics'), false),
  ('181b7fbb-76e1-5000-b452-3721dae37ea9', (select id from public.services where slug = 'engine-repair'), false),
  ('181b7fbb-76e1-5000-b452-3721dae37ea9', (select id from public.services where slug = 'oil-change'), false),
  ('181b7fbb-76e1-5000-b452-3721dae37ea9', (select id from public.services where slug = 'brake-service'), false),
  ('181b7fbb-76e1-5000-b452-3721dae37ea9', (select id from public.services where slug = 'battery-replacement'), false),
  ('181b7fbb-76e1-5000-b452-3721dae37ea9', (select id from public.services where slug = 'full-service'), false),
  ('181b7fbb-76e1-5000-b452-3721dae37ea9', (select id from public.services where slug = 'diagnostics'), false),
  ('ce4498a2-5787-56ef-b514-08f981d3ae92', (select id from public.services where slug = 'engine-repair'), false),
  ('ce4498a2-5787-56ef-b514-08f981d3ae92', (select id from public.services where slug = 'oil-change'), false),
  ('ce4498a2-5787-56ef-b514-08f981d3ae92', (select id from public.services where slug = 'brake-service'), false),
  ('ce4498a2-5787-56ef-b514-08f981d3ae92', (select id from public.services where slug = 'battery-replacement'), false),
  ('ce4498a2-5787-56ef-b514-08f981d3ae92', (select id from public.services where slug = 'full-service'), false),
  ('ce4498a2-5787-56ef-b514-08f981d3ae92', (select id from public.services where slug = 'diagnostics'), false),
  ('13b8118d-3303-5f4a-b8a5-0f148788ba66', (select id from public.services where slug = 'spare-parts'), false),
  ('13b8118d-3303-5f4a-b8a5-0f148788ba66', (select id from public.services where slug = 'battery-replacement'), false),
  ('5af94e98-a192-55c7-a240-50f4058ae0c5', (select id from public.services where slug = 'spare-parts'), false),
  ('5af94e98-a192-55c7-a240-50f4058ae0c5', (select id from public.services where slug = 'battery-replacement'), false),
  ('77ef8cc5-07ce-5a5c-b61e-09e0afa37935', (select id from public.services where slug = 'engine-repair'), false),
  ('77ef8cc5-07ce-5a5c-b61e-09e0afa37935', (select id from public.services where slug = 'oil-change'), false),
  ('77ef8cc5-07ce-5a5c-b61e-09e0afa37935', (select id from public.services where slug = 'brake-service'), false),
  ('77ef8cc5-07ce-5a5c-b61e-09e0afa37935', (select id from public.services where slug = 'battery-replacement'), false),
  ('77ef8cc5-07ce-5a5c-b61e-09e0afa37935', (select id from public.services where slug = 'full-service'), false),
  ('77ef8cc5-07ce-5a5c-b61e-09e0afa37935', (select id from public.services where slug = 'diagnostics'), false),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', (select id from public.services where slug = 'oil-change'), false),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', (select id from public.services where slug = 'chain-sprocket'), false),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', (select id from public.services where slug = 'puncture-repair'), false),
  ('137787ea-53ba-50db-8d7d-05709738dc9b', (select id from public.services where slug = 'battery-replacement'), false),
  ('d9505667-5775-5022-b986-608eb3aaa86f', (select id from public.services where slug = 'engine-repair'), false),
  ('d9505667-5775-5022-b986-608eb3aaa86f', (select id from public.services where slug = 'oil-change'), false),
  ('d9505667-5775-5022-b986-608eb3aaa86f', (select id from public.services where slug = 'brake-service'), false),
  ('d9505667-5775-5022-b986-608eb3aaa86f', (select id from public.services where slug = 'battery-replacement'), false),
  ('d9505667-5775-5022-b986-608eb3aaa86f', (select id from public.services where slug = 'full-service'), false),
  ('d9505667-5775-5022-b986-608eb3aaa86f', (select id from public.services where slug = 'diagnostics'), false),
  ('66c5e75d-2019-506f-8a8c-5ff198fe4b1c', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('66c5e75d-2019-506f-8a8c-5ff198fe4b1c', (select id from public.services where slug = 'oil-change'), false),
  ('66c5e75d-2019-506f-8a8c-5ff198fe4b1c', (select id from public.services where slug = 'chain-sprocket'), false),
  ('66c5e75d-2019-506f-8a8c-5ff198fe4b1c', (select id from public.services where slug = 'puncture-repair'), false),
  ('66c5e75d-2019-506f-8a8c-5ff198fe4b1c', (select id from public.services where slug = 'battery-replacement'), false),
  ('66c38d5f-60d8-5f45-973d-20d6294a379a', (select id from public.services where slug = 'spare-parts'), false),
  ('66c38d5f-60d8-5f45-973d-20d6294a379a', (select id from public.services where slug = 'battery-replacement'), false),
  ('b5622957-d285-509a-9b99-6a4430f1689c', (select id from public.services where slug = 'engine-repair'), false),
  ('b5622957-d285-509a-9b99-6a4430f1689c', (select id from public.services where slug = 'oil-change'), false),
  ('b5622957-d285-509a-9b99-6a4430f1689c', (select id from public.services where slug = 'brake-service'), false),
  ('b5622957-d285-509a-9b99-6a4430f1689c', (select id from public.services where slug = 'battery-replacement'), false),
  ('b5622957-d285-509a-9b99-6a4430f1689c', (select id from public.services where slug = 'full-service'), false),
  ('b5622957-d285-509a-9b99-6a4430f1689c', (select id from public.services where slug = 'diagnostics'), false),
  ('ab5b9935-c12b-56e8-9b52-147fdf968326', (select id from public.services where slug = 'tyre-replacement'), false),
  ('ab5b9935-c12b-56e8-9b52-147fdf968326', (select id from public.services where slug = 'wheel-alignment'), false),
  ('ab5b9935-c12b-56e8-9b52-147fdf968326', (select id from public.services where slug = 'puncture-repair'), false),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', (select id from public.services where slug = 'oil-change'), false),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', (select id from public.services where slug = 'chain-sprocket'), false),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', (select id from public.services where slug = 'puncture-repair'), false),
  ('fdc71e0b-a7ae-567e-bc62-6c74bb02f40f', (select id from public.services where slug = 'battery-replacement'), false),
  ('3b1f85da-f619-55ae-a9c6-e5465b4bb2f8', (select id from public.services where slug = 'engine-repair'), false),
  ('3b1f85da-f619-55ae-a9c6-e5465b4bb2f8', (select id from public.services where slug = 'oil-change'), false),
  ('3b1f85da-f619-55ae-a9c6-e5465b4bb2f8', (select id from public.services where slug = 'brake-service'), false),
  ('3b1f85da-f619-55ae-a9c6-e5465b4bb2f8', (select id from public.services where slug = 'battery-replacement'), false),
  ('3b1f85da-f619-55ae-a9c6-e5465b4bb2f8', (select id from public.services where slug = 'full-service'), false),
  ('3b1f85da-f619-55ae-a9c6-e5465b4bb2f8', (select id from public.services where slug = 'diagnostics'), false),
  ('7f38d712-9437-5a74-9c5d-31a5d2a02484', (select id from public.services where slug = 'engine-repair'), false),
  ('7f38d712-9437-5a74-9c5d-31a5d2a02484', (select id from public.services where slug = 'oil-change'), false),
  ('7f38d712-9437-5a74-9c5d-31a5d2a02484', (select id from public.services where slug = 'brake-service'), false),
  ('7f38d712-9437-5a74-9c5d-31a5d2a02484', (select id from public.services where slug = 'battery-replacement'), false),
  ('7f38d712-9437-5a74-9c5d-31a5d2a02484', (select id from public.services where slug = 'full-service'), false),
  ('7f38d712-9437-5a74-9c5d-31a5d2a02484', (select id from public.services where slug = 'diagnostics'), false),
  ('2d6b009a-7e20-5772-a9ea-47528a7f8838', (select id from public.services where slug = 'tyre-replacement'), false),
  ('2d6b009a-7e20-5772-a9ea-47528a7f8838', (select id from public.services where slug = 'wheel-alignment'), false),
  ('2d6b009a-7e20-5772-a9ea-47528a7f8838', (select id from public.services where slug = 'puncture-repair'), false),
  ('509bc816-c709-573f-b29f-7c2d88c0f222', (select id from public.services where slug = 'engine-repair'), false),
  ('509bc816-c709-573f-b29f-7c2d88c0f222', (select id from public.services where slug = 'oil-change'), false),
  ('509bc816-c709-573f-b29f-7c2d88c0f222', (select id from public.services where slug = 'brake-service'), false),
  ('509bc816-c709-573f-b29f-7c2d88c0f222', (select id from public.services where slug = 'battery-replacement'), false),
  ('509bc816-c709-573f-b29f-7c2d88c0f222', (select id from public.services where slug = 'full-service'), false),
  ('509bc816-c709-573f-b29f-7c2d88c0f222', (select id from public.services where slug = 'diagnostics'), false),
  ('3475b516-42cd-512d-aa34-22519cd8100f', (select id from public.services where slug = 'engine-repair'), false),
  ('3475b516-42cd-512d-aa34-22519cd8100f', (select id from public.services where slug = 'oil-change'), false),
  ('3475b516-42cd-512d-aa34-22519cd8100f', (select id from public.services where slug = 'brake-service'), false),
  ('3475b516-42cd-512d-aa34-22519cd8100f', (select id from public.services where slug = 'battery-replacement'), false),
  ('3475b516-42cd-512d-aa34-22519cd8100f', (select id from public.services where slug = 'full-service'), false),
  ('3475b516-42cd-512d-aa34-22519cd8100f', (select id from public.services where slug = 'diagnostics'), false),
  ('9a33a2b0-730c-5c9c-b198-5b0296062f08', (select id from public.services where slug = 'engine-repair'), false),
  ('9a33a2b0-730c-5c9c-b198-5b0296062f08', (select id from public.services where slug = 'oil-change'), false),
  ('9a33a2b0-730c-5c9c-b198-5b0296062f08', (select id from public.services where slug = 'brake-service'), false),
  ('9a33a2b0-730c-5c9c-b198-5b0296062f08', (select id from public.services where slug = 'battery-replacement'), false),
  ('9a33a2b0-730c-5c9c-b198-5b0296062f08', (select id from public.services where slug = 'full-service'), false),
  ('9a33a2b0-730c-5c9c-b198-5b0296062f08', (select id from public.services where slug = 'diagnostics'), false),
  ('edbbf22f-6ab7-5bf5-b528-0aba17954a9a', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('edbbf22f-6ab7-5bf5-b528-0aba17954a9a', (select id from public.services where slug = 'oil-change'), false),
  ('edbbf22f-6ab7-5bf5-b528-0aba17954a9a', (select id from public.services where slug = 'chain-sprocket'), false),
  ('edbbf22f-6ab7-5bf5-b528-0aba17954a9a', (select id from public.services where slug = 'puncture-repair'), false),
  ('edbbf22f-6ab7-5bf5-b528-0aba17954a9a', (select id from public.services where slug = 'battery-replacement'), false),
  ('b2a4522b-64f2-5e4a-bc48-373c6e451fb9', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('b2a4522b-64f2-5e4a-bc48-373c6e451fb9', (select id from public.services where slug = 'oil-change'), false),
  ('b2a4522b-64f2-5e4a-bc48-373c6e451fb9', (select id from public.services where slug = 'chain-sprocket'), false),
  ('b2a4522b-64f2-5e4a-bc48-373c6e451fb9', (select id from public.services where slug = 'puncture-repair'), false),
  ('b2a4522b-64f2-5e4a-bc48-373c6e451fb9', (select id from public.services where slug = 'battery-replacement'), false),
  ('84b06730-7d0e-5bdd-acb8-ca13ff3ceabd', (select id from public.services where slug = 'engine-repair'), false),
  ('84b06730-7d0e-5bdd-acb8-ca13ff3ceabd', (select id from public.services where slug = 'oil-change'), false),
  ('84b06730-7d0e-5bdd-acb8-ca13ff3ceabd', (select id from public.services where slug = 'brake-service'), false),
  ('84b06730-7d0e-5bdd-acb8-ca13ff3ceabd', (select id from public.services where slug = 'battery-replacement'), false),
  ('84b06730-7d0e-5bdd-acb8-ca13ff3ceabd', (select id from public.services where slug = 'full-service'), false),
  ('84b06730-7d0e-5bdd-acb8-ca13ff3ceabd', (select id from public.services where slug = 'diagnostics'), false),
  ('5dcdd688-baa2-53d0-b925-afc60f05a57e', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('5dcdd688-baa2-53d0-b925-afc60f05a57e', (select id from public.services where slug = 'oil-change'), false),
  ('5dcdd688-baa2-53d0-b925-afc60f05a57e', (select id from public.services where slug = 'chain-sprocket'), false),
  ('5dcdd688-baa2-53d0-b925-afc60f05a57e', (select id from public.services where slug = 'puncture-repair'), false),
  ('5dcdd688-baa2-53d0-b925-afc60f05a57e', (select id from public.services where slug = 'battery-replacement'), false),
  ('df013ac4-a81d-563d-a8bc-598c7bea79f5', (select id from public.services where slug = 'spare-parts'), false),
  ('df013ac4-a81d-563d-a8bc-598c7bea79f5', (select id from public.services where slug = 'battery-replacement'), false),
  ('5bc5a230-985f-57c1-b97c-fd933e1956dc', (select id from public.services where slug = 'engine-repair'), false),
  ('5bc5a230-985f-57c1-b97c-fd933e1956dc', (select id from public.services where slug = 'oil-change'), false),
  ('5bc5a230-985f-57c1-b97c-fd933e1956dc', (select id from public.services where slug = 'brake-service'), false),
  ('5bc5a230-985f-57c1-b97c-fd933e1956dc', (select id from public.services where slug = 'battery-replacement'), false),
  ('5bc5a230-985f-57c1-b97c-fd933e1956dc', (select id from public.services where slug = 'full-service'), false),
  ('5bc5a230-985f-57c1-b97c-fd933e1956dc', (select id from public.services where slug = 'diagnostics'), false),
  ('aedaec1a-f936-5fb5-9721-0f9f97d1d710', (select id from public.services where slug = 'tyre-replacement'), false),
  ('aedaec1a-f936-5fb5-9721-0f9f97d1d710', (select id from public.services where slug = 'wheel-alignment'), false),
  ('aedaec1a-f936-5fb5-9721-0f9f97d1d710', (select id from public.services where slug = 'puncture-repair'), false),
  ('17573d2e-ec16-507b-98b9-17097804b284', (select id from public.services where slug = 'tyre-replacement'), false),
  ('17573d2e-ec16-507b-98b9-17097804b284', (select id from public.services where slug = 'wheel-alignment'), false),
  ('17573d2e-ec16-507b-98b9-17097804b284', (select id from public.services where slug = 'puncture-repair'), false),
  ('1f7ff5fa-8081-5d55-8202-85fb5527d9e0', (select id from public.services where slug = 'engine-repair'), false),
  ('1f7ff5fa-8081-5d55-8202-85fb5527d9e0', (select id from public.services where slug = 'oil-change'), false),
  ('1f7ff5fa-8081-5d55-8202-85fb5527d9e0', (select id from public.services where slug = 'brake-service'), false),
  ('1f7ff5fa-8081-5d55-8202-85fb5527d9e0', (select id from public.services where slug = 'battery-replacement'), false),
  ('1f7ff5fa-8081-5d55-8202-85fb5527d9e0', (select id from public.services where slug = 'full-service'), false),
  ('1f7ff5fa-8081-5d55-8202-85fb5527d9e0', (select id from public.services where slug = 'diagnostics'), false),
  ('52bb81d6-feb9-57c7-bb02-252272efcd03', (select id from public.services where slug = 'engine-repair'), false),
  ('52bb81d6-feb9-57c7-bb02-252272efcd03', (select id from public.services where slug = 'oil-change'), false),
  ('52bb81d6-feb9-57c7-bb02-252272efcd03', (select id from public.services where slug = 'brake-service'), false),
  ('52bb81d6-feb9-57c7-bb02-252272efcd03', (select id from public.services where slug = 'battery-replacement'), false),
  ('52bb81d6-feb9-57c7-bb02-252272efcd03', (select id from public.services where slug = 'full-service'), false),
  ('52bb81d6-feb9-57c7-bb02-252272efcd03', (select id from public.services where slug = 'diagnostics'), false),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', (select id from public.services where slug = 'oil-change'), false),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', (select id from public.services where slug = 'chain-sprocket'), false),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', (select id from public.services where slug = 'puncture-repair'), false),
  ('90beff6a-a2f9-591c-8e95-121f4cd04fc1', (select id from public.services where slug = 'battery-replacement'), false),
  ('a824ade5-02ce-5aa6-8633-8116a23fca8c', (select id from public.services where slug = 'engine-repair'), false),
  ('a824ade5-02ce-5aa6-8633-8116a23fca8c', (select id from public.services where slug = 'oil-change'), false),
  ('a824ade5-02ce-5aa6-8633-8116a23fca8c', (select id from public.services where slug = 'brake-service'), false),
  ('a824ade5-02ce-5aa6-8633-8116a23fca8c', (select id from public.services where slug = 'battery-replacement'), false),
  ('a824ade5-02ce-5aa6-8633-8116a23fca8c', (select id from public.services where slug = 'full-service'), false),
  ('a824ade5-02ce-5aa6-8633-8116a23fca8c', (select id from public.services where slug = 'diagnostics'), false),
  ('75c8edd6-f282-54f2-a4cb-ab3773553847', (select id from public.services where slug = 'engine-repair'), false),
  ('75c8edd6-f282-54f2-a4cb-ab3773553847', (select id from public.services where slug = 'oil-change'), false),
  ('75c8edd6-f282-54f2-a4cb-ab3773553847', (select id from public.services where slug = 'brake-service'), false),
  ('75c8edd6-f282-54f2-a4cb-ab3773553847', (select id from public.services where slug = 'battery-replacement'), false),
  ('75c8edd6-f282-54f2-a4cb-ab3773553847', (select id from public.services where slug = 'full-service'), false),
  ('75c8edd6-f282-54f2-a4cb-ab3773553847', (select id from public.services where slug = 'diagnostics'), false),
  ('e56a17fb-97ec-5eb0-b12a-c2d79f8cb79d', (select id from public.services where slug = 'spare-parts'), false),
  ('e56a17fb-97ec-5eb0-b12a-c2d79f8cb79d', (select id from public.services where slug = 'battery-replacement'), false),
  ('565f6c71-855e-5ac9-ac81-2d5f2c0fc3ba', (select id from public.services where slug = 'engine-repair'), false),
  ('565f6c71-855e-5ac9-ac81-2d5f2c0fc3ba', (select id from public.services where slug = 'oil-change'), false),
  ('565f6c71-855e-5ac9-ac81-2d5f2c0fc3ba', (select id from public.services where slug = 'brake-service'), false),
  ('565f6c71-855e-5ac9-ac81-2d5f2c0fc3ba', (select id from public.services where slug = 'battery-replacement'), false),
  ('565f6c71-855e-5ac9-ac81-2d5f2c0fc3ba', (select id from public.services where slug = 'full-service'), false),
  ('565f6c71-855e-5ac9-ac81-2d5f2c0fc3ba', (select id from public.services where slug = 'diagnostics'), false),
  ('e91a9f05-ec7e-52f4-bb93-2314c5042cd7', (select id from public.services where slug = 'engine-repair'), false),
  ('e91a9f05-ec7e-52f4-bb93-2314c5042cd7', (select id from public.services where slug = 'oil-change'), false),
  ('e91a9f05-ec7e-52f4-bb93-2314c5042cd7', (select id from public.services where slug = 'brake-service'), false),
  ('e91a9f05-ec7e-52f4-bb93-2314c5042cd7', (select id from public.services where slug = 'battery-replacement'), false),
  ('e91a9f05-ec7e-52f4-bb93-2314c5042cd7', (select id from public.services where slug = 'full-service'), false),
  ('e91a9f05-ec7e-52f4-bb93-2314c5042cd7', (select id from public.services where slug = 'diagnostics'), false),
  ('172b35c2-4221-5187-8d0b-70578ed1a3c6', (select id from public.services where slug = 'engine-repair'), false),
  ('172b35c2-4221-5187-8d0b-70578ed1a3c6', (select id from public.services where slug = 'oil-change'), false),
  ('172b35c2-4221-5187-8d0b-70578ed1a3c6', (select id from public.services where slug = 'brake-service'), false),
  ('172b35c2-4221-5187-8d0b-70578ed1a3c6', (select id from public.services where slug = 'battery-replacement'), false),
  ('172b35c2-4221-5187-8d0b-70578ed1a3c6', (select id from public.services where slug = 'full-service'), false),
  ('172b35c2-4221-5187-8d0b-70578ed1a3c6', (select id from public.services where slug = 'diagnostics'), false),
  ('dc638d2c-c1c2-5723-8a72-b178482e4232', (select id from public.services where slug = 'engine-repair'), false),
  ('dc638d2c-c1c2-5723-8a72-b178482e4232', (select id from public.services where slug = 'oil-change'), false),
  ('dc638d2c-c1c2-5723-8a72-b178482e4232', (select id from public.services where slug = 'brake-service'), false),
  ('dc638d2c-c1c2-5723-8a72-b178482e4232', (select id from public.services where slug = 'battery-replacement'), false),
  ('dc638d2c-c1c2-5723-8a72-b178482e4232', (select id from public.services where slug = 'full-service'), false),
  ('dc638d2c-c1c2-5723-8a72-b178482e4232', (select id from public.services where slug = 'diagnostics'), false),
  ('60ee3b69-87ae-5c3d-95db-e592d0056cd2', (select id from public.services where slug = 'spare-parts'), false),
  ('60ee3b69-87ae-5c3d-95db-e592d0056cd2', (select id from public.services where slug = 'battery-replacement'), false),
  ('42084bbd-7221-5f97-b03f-a7fb63e0642e', (select id from public.services where slug = 'engine-repair'), false),
  ('42084bbd-7221-5f97-b03f-a7fb63e0642e', (select id from public.services where slug = 'oil-change'), false),
  ('42084bbd-7221-5f97-b03f-a7fb63e0642e', (select id from public.services where slug = 'brake-service'), false),
  ('42084bbd-7221-5f97-b03f-a7fb63e0642e', (select id from public.services where slug = 'battery-replacement'), false),
  ('42084bbd-7221-5f97-b03f-a7fb63e0642e', (select id from public.services where slug = 'full-service'), false),
  ('42084bbd-7221-5f97-b03f-a7fb63e0642e', (select id from public.services where slug = 'diagnostics'), false),
  ('f66ab8d7-3dc2-5463-b54a-c28701a4141b', (select id from public.services where slug = 'spare-parts'), false),
  ('f66ab8d7-3dc2-5463-b54a-c28701a4141b', (select id from public.services where slug = 'battery-replacement'), false),
  ('7d2d673a-fa20-5046-99ea-3f61531e199e', (select id from public.services where slug = 'spare-parts'), false),
  ('7d2d673a-fa20-5046-99ea-3f61531e199e', (select id from public.services where slug = 'battery-replacement'), false),
  ('5a12694a-9660-5c4b-a0a2-71a9f18e9f26', (select id from public.services where slug = 'engine-repair'), false),
  ('5a12694a-9660-5c4b-a0a2-71a9f18e9f26', (select id from public.services where slug = 'oil-change'), false),
  ('5a12694a-9660-5c4b-a0a2-71a9f18e9f26', (select id from public.services where slug = 'brake-service'), false),
  ('5a12694a-9660-5c4b-a0a2-71a9f18e9f26', (select id from public.services where slug = 'battery-replacement'), false),
  ('5a12694a-9660-5c4b-a0a2-71a9f18e9f26', (select id from public.services where slug = 'full-service'), false),
  ('5a12694a-9660-5c4b-a0a2-71a9f18e9f26', (select id from public.services where slug = 'diagnostics'), false),
  ('943cf12f-f994-5ca4-a071-cc88e6ff66d4', (select id from public.services where slug = 'tyre-replacement'), false),
  ('943cf12f-f994-5ca4-a071-cc88e6ff66d4', (select id from public.services where slug = 'wheel-alignment'), false),
  ('943cf12f-f994-5ca4-a071-cc88e6ff66d4', (select id from public.services where slug = 'puncture-repair'), false),
  ('fd38de85-78e9-5086-9263-50f82669cace', (select id from public.services where slug = 'tyre-replacement'), false),
  ('fd38de85-78e9-5086-9263-50f82669cace', (select id from public.services where slug = 'wheel-alignment'), false),
  ('fd38de85-78e9-5086-9263-50f82669cace', (select id from public.services where slug = 'puncture-repair'), false),
  ('2be8bc86-d0fa-5c2b-b7d0-be2ccc3ef343', (select id from public.services where slug = 'spare-parts'), false),
  ('2be8bc86-d0fa-5c2b-b7d0-be2ccc3ef343', (select id from public.services where slug = 'battery-replacement'), false),
  ('5a96ee8f-7b2c-56f1-96ff-50dde21cf12f', (select id from public.services where slug = 'engine-repair'), false),
  ('5a96ee8f-7b2c-56f1-96ff-50dde21cf12f', (select id from public.services where slug = 'oil-change'), false),
  ('5a96ee8f-7b2c-56f1-96ff-50dde21cf12f', (select id from public.services where slug = 'brake-service'), false),
  ('5a96ee8f-7b2c-56f1-96ff-50dde21cf12f', (select id from public.services where slug = 'battery-replacement'), false),
  ('5a96ee8f-7b2c-56f1-96ff-50dde21cf12f', (select id from public.services where slug = 'full-service'), false),
  ('5a96ee8f-7b2c-56f1-96ff-50dde21cf12f', (select id from public.services where slug = 'diagnostics'), false),
  ('aa9cd654-43fb-52aa-9d12-74cb5ab6d5e3', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('aa9cd654-43fb-52aa-9d12-74cb5ab6d5e3', (select id from public.services where slug = 'oil-change'), false),
  ('aa9cd654-43fb-52aa-9d12-74cb5ab6d5e3', (select id from public.services where slug = 'chain-sprocket'), false),
  ('aa9cd654-43fb-52aa-9d12-74cb5ab6d5e3', (select id from public.services where slug = 'puncture-repair'), false),
  ('aa9cd654-43fb-52aa-9d12-74cb5ab6d5e3', (select id from public.services where slug = 'battery-replacement'), false),
  ('30465a0d-51f3-5353-b877-a4f6048a95b2', (select id from public.services where slug = 'engine-repair'), false),
  ('30465a0d-51f3-5353-b877-a4f6048a95b2', (select id from public.services where slug = 'oil-change'), false),
  ('30465a0d-51f3-5353-b877-a4f6048a95b2', (select id from public.services where slug = 'brake-service'), false),
  ('30465a0d-51f3-5353-b877-a4f6048a95b2', (select id from public.services where slug = 'battery-replacement'), false),
  ('30465a0d-51f3-5353-b877-a4f6048a95b2', (select id from public.services where slug = 'full-service'), false),
  ('30465a0d-51f3-5353-b877-a4f6048a95b2', (select id from public.services where slug = 'diagnostics'), false),
  ('78d18d38-7a95-57ff-8f26-15831f03b99d', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('78d18d38-7a95-57ff-8f26-15831f03b99d', (select id from public.services where slug = 'oil-change'), false),
  ('78d18d38-7a95-57ff-8f26-15831f03b99d', (select id from public.services where slug = 'chain-sprocket'), false),
  ('78d18d38-7a95-57ff-8f26-15831f03b99d', (select id from public.services where slug = 'puncture-repair'), false),
  ('78d18d38-7a95-57ff-8f26-15831f03b99d', (select id from public.services where slug = 'battery-replacement'), false),
  ('4ed52f7b-6d2d-5eb2-a21d-f88be4034033', (select id from public.services where slug = 'spare-parts'), false),
  ('4ed52f7b-6d2d-5eb2-a21d-f88be4034033', (select id from public.services where slug = 'battery-replacement'), false),
  ('79446389-617c-53ac-9a75-6419a6a4df1b', (select id from public.services where slug = 'spare-parts'), false),
  ('79446389-617c-53ac-9a75-6419a6a4df1b', (select id from public.services where slug = 'battery-replacement'), false),
  ('6685bb83-90d1-5d76-b6cb-a63b5d9b4e20', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('6685bb83-90d1-5d76-b6cb-a63b5d9b4e20', (select id from public.services where slug = 'oil-change'), false),
  ('6685bb83-90d1-5d76-b6cb-a63b5d9b4e20', (select id from public.services where slug = 'chain-sprocket'), false),
  ('6685bb83-90d1-5d76-b6cb-a63b5d9b4e20', (select id from public.services where slug = 'puncture-repair'), false),
  ('6685bb83-90d1-5d76-b6cb-a63b5d9b4e20', (select id from public.services where slug = 'battery-replacement'), false),
  ('7feb06e1-9638-5aba-b492-f6981d87a1fc', (select id from public.services where slug = 'engine-repair'), false),
  ('7feb06e1-9638-5aba-b492-f6981d87a1fc', (select id from public.services where slug = 'oil-change'), false),
  ('7feb06e1-9638-5aba-b492-f6981d87a1fc', (select id from public.services where slug = 'brake-service'), false),
  ('7feb06e1-9638-5aba-b492-f6981d87a1fc', (select id from public.services where slug = 'battery-replacement'), false),
  ('7feb06e1-9638-5aba-b492-f6981d87a1fc', (select id from public.services where slug = 'full-service'), false),
  ('7feb06e1-9638-5aba-b492-f6981d87a1fc', (select id from public.services where slug = 'diagnostics'), false),
  ('5b37b787-1b76-5ad9-9bc8-f4569617da3e', (select id from public.services where slug = 'tyre-replacement'), false),
  ('5b37b787-1b76-5ad9-9bc8-f4569617da3e', (select id from public.services where slug = 'wheel-alignment'), false),
  ('5b37b787-1b76-5ad9-9bc8-f4569617da3e', (select id from public.services where slug = 'puncture-repair'), false),
  ('a88d1a86-eccc-5818-933e-cbdf60d67d7d', (select id from public.services where slug = 'spare-parts'), false),
  ('a88d1a86-eccc-5818-933e-cbdf60d67d7d', (select id from public.services where slug = 'battery-replacement'), false),
  ('b34e44e5-8167-57bb-b845-48d6350b0352', (select id from public.services where slug = 'spare-parts'), false),
  ('b34e44e5-8167-57bb-b845-48d6350b0352', (select id from public.services where slug = 'battery-replacement'), false),
  ('48a46ed3-32b6-5f19-9143-80370d02ed0f', (select id from public.services where slug = 'tyre-replacement'), false),
  ('48a46ed3-32b6-5f19-9143-80370d02ed0f', (select id from public.services where slug = 'wheel-alignment'), false),
  ('48a46ed3-32b6-5f19-9143-80370d02ed0f', (select id from public.services where slug = 'puncture-repair'), false),
  ('6bb0b361-1a69-5b51-bb21-3fca3d278ab3', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('6bb0b361-1a69-5b51-bb21-3fca3d278ab3', (select id from public.services where slug = 'oil-change'), false),
  ('6bb0b361-1a69-5b51-bb21-3fca3d278ab3', (select id from public.services where slug = 'chain-sprocket'), false),
  ('6bb0b361-1a69-5b51-bb21-3fca3d278ab3', (select id from public.services where slug = 'puncture-repair'), false),
  ('6bb0b361-1a69-5b51-bb21-3fca3d278ab3', (select id from public.services where slug = 'battery-replacement'), false),
  ('e8c6e7ef-c014-5d10-b1ae-0d64a9a43743', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('e8c6e7ef-c014-5d10-b1ae-0d64a9a43743', (select id from public.services where slug = 'oil-change'), false),
  ('e8c6e7ef-c014-5d10-b1ae-0d64a9a43743', (select id from public.services where slug = 'chain-sprocket'), false),
  ('e8c6e7ef-c014-5d10-b1ae-0d64a9a43743', (select id from public.services where slug = 'puncture-repair'), false),
  ('e8c6e7ef-c014-5d10-b1ae-0d64a9a43743', (select id from public.services where slug = 'battery-replacement'), false),
  ('32f7ccf7-5ef9-59d9-9560-1fddb9153be5', (select id from public.services where slug = 'tyre-replacement'), false),
  ('32f7ccf7-5ef9-59d9-9560-1fddb9153be5', (select id from public.services where slug = 'wheel-alignment'), false),
  ('32f7ccf7-5ef9-59d9-9560-1fddb9153be5', (select id from public.services where slug = 'puncture-repair'), false),
  ('03757d5f-45df-5f35-80f0-f4aa8de0bb55', (select id from public.services where slug = 'spare-parts'), false),
  ('03757d5f-45df-5f35-80f0-f4aa8de0bb55', (select id from public.services where slug = 'battery-replacement'), false),
  ('38df482a-84c4-5ebe-b5b8-685619ff2508', (select id from public.services where slug = 'tyre-replacement'), false),
  ('38df482a-84c4-5ebe-b5b8-685619ff2508', (select id from public.services where slug = 'wheel-alignment'), false),
  ('38df482a-84c4-5ebe-b5b8-685619ff2508', (select id from public.services where slug = 'puncture-repair'), false),
  ('0fbaf6fb-441d-5dd3-8c06-97da9d7f139e', (select id from public.services where slug = 'spare-parts'), false),
  ('0fbaf6fb-441d-5dd3-8c06-97da9d7f139e', (select id from public.services where slug = 'battery-replacement'), false),
  ('2c75a59f-7c47-5f67-b46d-cb69d695cbaa', (select id from public.services where slug = 'spare-parts'), false),
  ('2c75a59f-7c47-5f67-b46d-cb69d695cbaa', (select id from public.services where slug = 'battery-replacement'), false),
  ('3fe1df63-b04f-5264-a423-bc13b4f9f6b4', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('3fe1df63-b04f-5264-a423-bc13b4f9f6b4', (select id from public.services where slug = 'oil-change'), false),
  ('3fe1df63-b04f-5264-a423-bc13b4f9f6b4', (select id from public.services where slug = 'chain-sprocket'), false),
  ('3fe1df63-b04f-5264-a423-bc13b4f9f6b4', (select id from public.services where slug = 'puncture-repair'), false),
  ('3fe1df63-b04f-5264-a423-bc13b4f9f6b4', (select id from public.services where slug = 'battery-replacement'), false),
  ('68578a90-09b3-5c48-b381-17a54a22f94f', (select id from public.services where slug = 'tyre-replacement'), false),
  ('68578a90-09b3-5c48-b381-17a54a22f94f', (select id from public.services where slug = 'wheel-alignment'), false),
  ('68578a90-09b3-5c48-b381-17a54a22f94f', (select id from public.services where slug = 'puncture-repair'), false),
  ('1b4e7fab-46d1-5e48-b02b-3d92efc2e391', (select id from public.services where slug = 'tyre-replacement'), false),
  ('1b4e7fab-46d1-5e48-b02b-3d92efc2e391', (select id from public.services where slug = 'wheel-alignment'), false),
  ('1b4e7fab-46d1-5e48-b02b-3d92efc2e391', (select id from public.services where slug = 'puncture-repair'), false),
  ('7e8005eb-bd3d-565b-aeeb-a11a5065733f', (select id from public.services where slug = 'tyre-replacement'), false),
  ('7e8005eb-bd3d-565b-aeeb-a11a5065733f', (select id from public.services where slug = 'wheel-alignment'), false),
  ('7e8005eb-bd3d-565b-aeeb-a11a5065733f', (select id from public.services where slug = 'puncture-repair'), false),
  ('92679091-7654-5db3-93c5-24f1d3aaa0c1', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('92679091-7654-5db3-93c5-24f1d3aaa0c1', (select id from public.services where slug = 'oil-change'), false),
  ('92679091-7654-5db3-93c5-24f1d3aaa0c1', (select id from public.services where slug = 'chain-sprocket'), false),
  ('92679091-7654-5db3-93c5-24f1d3aaa0c1', (select id from public.services where slug = 'puncture-repair'), false),
  ('92679091-7654-5db3-93c5-24f1d3aaa0c1', (select id from public.services where slug = 'battery-replacement'), false),
  ('fa74b232-8e05-5cec-b8d0-513227343ba9', (select id from public.services where slug = 'engine-repair'), false),
  ('fa74b232-8e05-5cec-b8d0-513227343ba9', (select id from public.services where slug = 'oil-change'), false),
  ('fa74b232-8e05-5cec-b8d0-513227343ba9', (select id from public.services where slug = 'brake-service'), false),
  ('fa74b232-8e05-5cec-b8d0-513227343ba9', (select id from public.services where slug = 'battery-replacement'), false),
  ('fa74b232-8e05-5cec-b8d0-513227343ba9', (select id from public.services where slug = 'full-service'), false),
  ('fa74b232-8e05-5cec-b8d0-513227343ba9', (select id from public.services where slug = 'diagnostics'), false),
  ('42a5fb0b-d5a0-5090-b630-080a2727447d', (select id from public.services where slug = 'denting-painting'), true),
  ('42a5fb0b-d5a0-5090-b630-080a2727447d', (select id from public.services where slug = 'battery-replacement'), true),
  ('42a5fb0b-d5a0-5090-b630-080a2727447d', (select id from public.services where slug = 'body-repair'), true),
  ('42a5fb0b-d5a0-5090-b630-080a2727447d', (select id from public.services where slug = 'tyre-replacement'), true),
  ('42a5fb0b-d5a0-5090-b630-080a2727447d', (select id from public.services where slug = 'spare-parts'), true),
  ('42a5fb0b-d5a0-5090-b630-080a2727447d', (select id from public.services where slug = 'engine-repair'), true),
  ('42a5fb0b-d5a0-5090-b630-080a2727447d', (select id from public.services where slug = 'oil-change'), false),
  ('42a5fb0b-d5a0-5090-b630-080a2727447d', (select id from public.services where slug = 'brake-service'), false),
  ('42a5fb0b-d5a0-5090-b630-080a2727447d', (select id from public.services where slug = 'full-service'), false),
  ('42a5fb0b-d5a0-5090-b630-080a2727447d', (select id from public.services where slug = 'diagnostics'), false),
  ('ddd5345f-09af-59ce-8cbc-b3560c599250', (select id from public.services where slug = 'diagnostics'), true),
  ('ddd5345f-09af-59ce-8cbc-b3560c599250', (select id from public.services where slug = 'tyre-replacement'), true),
  ('ddd5345f-09af-59ce-8cbc-b3560c599250', (select id from public.services where slug = 'inspection'), true),
  ('ddd5345f-09af-59ce-8cbc-b3560c599250', (select id from public.services where slug = 'brake-service'), true),
  ('ddd5345f-09af-59ce-8cbc-b3560c599250', (select id from public.services where slug = 'oil-change'), true),
  ('ddd5345f-09af-59ce-8cbc-b3560c599250', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('ddd5345f-09af-59ce-8cbc-b3560c599250', (select id from public.services where slug = 'chain-sprocket'), false),
  ('ddd5345f-09af-59ce-8cbc-b3560c599250', (select id from public.services where slug = 'puncture-repair'), false),
  ('ddd5345f-09af-59ce-8cbc-b3560c599250', (select id from public.services where slug = 'battery-replacement'), false),
  ('c4267dff-692f-59ae-a013-cd8214211b60', (select id from public.services where slug = 'engine-repair'), false),
  ('c4267dff-692f-59ae-a013-cd8214211b60', (select id from public.services where slug = 'oil-change'), false),
  ('c4267dff-692f-59ae-a013-cd8214211b60', (select id from public.services where slug = 'brake-service'), false),
  ('c4267dff-692f-59ae-a013-cd8214211b60', (select id from public.services where slug = 'battery-replacement'), false),
  ('c4267dff-692f-59ae-a013-cd8214211b60', (select id from public.services where slug = 'full-service'), false),
  ('c4267dff-692f-59ae-a013-cd8214211b60', (select id from public.services where slug = 'diagnostics'), false),
  ('9999637a-daad-51ce-b786-7c6075fe51a2', (select id from public.services where slug = 'engine-repair'), false),
  ('9999637a-daad-51ce-b786-7c6075fe51a2', (select id from public.services where slug = 'oil-change'), false),
  ('9999637a-daad-51ce-b786-7c6075fe51a2', (select id from public.services where slug = 'brake-service'), false),
  ('9999637a-daad-51ce-b786-7c6075fe51a2', (select id from public.services where slug = 'battery-replacement'), false),
  ('9999637a-daad-51ce-b786-7c6075fe51a2', (select id from public.services where slug = 'full-service'), false),
  ('9999637a-daad-51ce-b786-7c6075fe51a2', (select id from public.services where slug = 'diagnostics'), false),
  ('bf5a5545-dff7-5e6e-b3f5-9e421e2bec67', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('bf5a5545-dff7-5e6e-b3f5-9e421e2bec67', (select id from public.services where slug = 'oil-change'), false),
  ('bf5a5545-dff7-5e6e-b3f5-9e421e2bec67', (select id from public.services where slug = 'chain-sprocket'), false),
  ('bf5a5545-dff7-5e6e-b3f5-9e421e2bec67', (select id from public.services where slug = 'puncture-repair'), false),
  ('bf5a5545-dff7-5e6e-b3f5-9e421e2bec67', (select id from public.services where slug = 'battery-replacement'), false),
  ('2491f426-0c4a-5915-bedf-c707927e4520', (select id from public.services where slug = 'spare-parts'), false),
  ('2491f426-0c4a-5915-bedf-c707927e4520', (select id from public.services where slug = 'battery-replacement'), false),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', (select id from public.services where slug = 'engine-repair'), false),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', (select id from public.services where slug = 'oil-change'), false),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', (select id from public.services where slug = 'brake-service'), false),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', (select id from public.services where slug = 'battery-replacement'), false),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', (select id from public.services where slug = 'full-service'), false),
  ('d6fce0cb-f52a-57bf-81e4-aad008a41afe', (select id from public.services where slug = 'diagnostics'), false),
  ('dc665694-ab79-56d3-997d-9fae550a02da', (select id from public.services where slug = 'full-service'), true),
  ('dc665694-ab79-56d3-997d-9fae550a02da', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('dc665694-ab79-56d3-997d-9fae550a02da', (select id from public.services where slug = 'oil-change'), false),
  ('dc665694-ab79-56d3-997d-9fae550a02da', (select id from public.services where slug = 'chain-sprocket'), false),
  ('dc665694-ab79-56d3-997d-9fae550a02da', (select id from public.services where slug = 'puncture-repair'), false),
  ('dc665694-ab79-56d3-997d-9fae550a02da', (select id from public.services where slug = 'battery-replacement'), false),
  ('f38ba497-c36a-5b5b-8c86-267a344f8a5c', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('f38ba497-c36a-5b5b-8c86-267a344f8a5c', (select id from public.services where slug = 'oil-change'), false),
  ('f38ba497-c36a-5b5b-8c86-267a344f8a5c', (select id from public.services where slug = 'chain-sprocket'), false),
  ('f38ba497-c36a-5b5b-8c86-267a344f8a5c', (select id from public.services where slug = 'puncture-repair'), false),
  ('f38ba497-c36a-5b5b-8c86-267a344f8a5c', (select id from public.services where slug = 'battery-replacement'), false),
  ('8a1633d9-5872-5336-b6b2-15efc76e67b2', (select id from public.services where slug = 'engine-repair'), false),
  ('8a1633d9-5872-5336-b6b2-15efc76e67b2', (select id from public.services where slug = 'oil-change'), false),
  ('8a1633d9-5872-5336-b6b2-15efc76e67b2', (select id from public.services where slug = 'brake-service'), false),
  ('8a1633d9-5872-5336-b6b2-15efc76e67b2', (select id from public.services where slug = 'battery-replacement'), false),
  ('8a1633d9-5872-5336-b6b2-15efc76e67b2', (select id from public.services where slug = 'full-service'), false),
  ('8a1633d9-5872-5336-b6b2-15efc76e67b2', (select id from public.services where slug = 'diagnostics'), false),
  ('88819774-5f3e-5117-921d-2dfd4be13da2', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('88819774-5f3e-5117-921d-2dfd4be13da2', (select id from public.services where slug = 'oil-change'), false),
  ('88819774-5f3e-5117-921d-2dfd4be13da2', (select id from public.services where slug = 'chain-sprocket'), false),
  ('88819774-5f3e-5117-921d-2dfd4be13da2', (select id from public.services where slug = 'puncture-repair'), false),
  ('88819774-5f3e-5117-921d-2dfd4be13da2', (select id from public.services where slug = 'battery-replacement'), false),
  ('7098ea6c-f0bb-5f22-ac3f-fd1eb787f281', (select id from public.services where slug = 'tyre-replacement'), false),
  ('7098ea6c-f0bb-5f22-ac3f-fd1eb787f281', (select id from public.services where slug = 'wheel-alignment'), false),
  ('7098ea6c-f0bb-5f22-ac3f-fd1eb787f281', (select id from public.services where slug = 'puncture-repair'), false),
  ('7777e087-1250-5078-8aab-43362c480091', (select id from public.services where slug = 'spare-parts'), false),
  ('7777e087-1250-5078-8aab-43362c480091', (select id from public.services where slug = 'battery-replacement'), false),
  ('13bc52bb-5233-589d-a770-8dba399c0144', (select id from public.services where slug = 'spare-parts'), false),
  ('13bc52bb-5233-589d-a770-8dba399c0144', (select id from public.services where slug = 'battery-replacement'), false),
  ('02a4330e-1742-5336-adb6-ef74783c7300', (select id from public.services where slug = 'spare-parts'), false),
  ('02a4330e-1742-5336-adb6-ef74783c7300', (select id from public.services where slug = 'battery-replacement'), false),
  ('776ee3ec-85cb-5d23-a01f-1ef7c73b14a5', (select id from public.services where slug = 'spare-parts'), false),
  ('776ee3ec-85cb-5d23-a01f-1ef7c73b14a5', (select id from public.services where slug = 'battery-replacement'), false),
  ('33161b2f-8f4a-54f4-82df-ae5417b83023', (select id from public.services where slug = 'two-wheeler-service'), false),
  ('33161b2f-8f4a-54f4-82df-ae5417b83023', (select id from public.services where slug = 'oil-change'), false),
  ('33161b2f-8f4a-54f4-82df-ae5417b83023', (select id from public.services where slug = 'chain-sprocket'), false),
  ('33161b2f-8f4a-54f4-82df-ae5417b83023', (select id from public.services where slug = 'puncture-repair'), false),
  ('33161b2f-8f4a-54f4-82df-ae5417b83023', (select id from public.services where slug = 'battery-replacement'), false),
  ('6ebec59a-1b01-5e93-ab75-55ae97918648', (select id from public.services where slug = 'spare-parts'), false),
  ('6ebec59a-1b01-5e93-ab75-55ae97918648', (select id from public.services where slug = 'battery-replacement'), false),
  ('a43a47bf-62f2-59ce-b61c-52cde76a676d', (select id from public.services where slug = 'tyre-replacement'), false),
  ('a43a47bf-62f2-59ce-b61c-52cde76a676d', (select id from public.services where slug = 'wheel-alignment'), false),
  ('a43a47bf-62f2-59ce-b61c-52cde76a676d', (select id from public.services where slug = 'puncture-repair'), false),
  ('53020bd6-40bf-5952-a1dc-081003b29821', (select id from public.services where slug = 'tyre-replacement'), false),
  ('53020bd6-40bf-5952-a1dc-081003b29821', (select id from public.services where slug = 'wheel-alignment'), false),
  ('53020bd6-40bf-5952-a1dc-081003b29821', (select id from public.services where slug = 'puncture-repair'), false),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', (select id from public.services where slug = 'two-wheeler-service'), true),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', (select id from public.services where slug = 'oil-change'), false),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', (select id from public.services where slug = 'chain-sprocket'), false),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', (select id from public.services where slug = 'puncture-repair'), false),
  ('6e6d29c8-18c8-50cc-8287-38b456dd2e0a', (select id from public.services where slug = 'battery-replacement'), false),
  ('75947c24-0dfd-5ed0-bd04-fd1ed22eb24a', (select id from public.services where slug = 'spare-parts'), false),
  ('75947c24-0dfd-5ed0-bd04-fd1ed22eb24a', (select id from public.services where slug = 'battery-replacement'), false),
  ('6b840f4c-1847-58dd-9be7-e7d8475e8a83', (select id from public.services where slug = 'engine-repair'), false),
  ('6b840f4c-1847-58dd-9be7-e7d8475e8a83', (select id from public.services where slug = 'oil-change'), false),
  ('6b840f4c-1847-58dd-9be7-e7d8475e8a83', (select id from public.services where slug = 'brake-service'), false),
  ('6b840f4c-1847-58dd-9be7-e7d8475e8a83', (select id from public.services where slug = 'battery-replacement'), false),
  ('6b840f4c-1847-58dd-9be7-e7d8475e8a83', (select id from public.services where slug = 'full-service'), false),
  ('6b840f4c-1847-58dd-9be7-e7d8475e8a83', (select id from public.services where slug = 'diagnostics'), false),
  ('17f857d1-a183-55b6-9b25-f9d199209633', (select id from public.services where slug = 'diagnostics'), true),
  ('17f857d1-a183-55b6-9b25-f9d199209633', (select id from public.services where slug = 'denting-painting'), true),
  ('17f857d1-a183-55b6-9b25-f9d199209633', (select id from public.services where slug = 'body-repair'), true),
  ('17f857d1-a183-55b6-9b25-f9d199209633', (select id from public.services where slug = 'full-service'), true),
  ('17f857d1-a183-55b6-9b25-f9d199209633', (select id from public.services where slug = 'electrical-work'), true),
  ('17f857d1-a183-55b6-9b25-f9d199209633', (select id from public.services where slug = 'spare-parts'), true),
  ('17f857d1-a183-55b6-9b25-f9d199209633', (select id from public.services where slug = 'inspection'), true),
  ('17f857d1-a183-55b6-9b25-f9d199209633', (select id from public.services where slug = 'brake-service'), true),
  ('17f857d1-a183-55b6-9b25-f9d199209633', (select id from public.services where slug = 'engine-repair'), true),
  ('17f857d1-a183-55b6-9b25-f9d199209633', (select id from public.services where slug = 'oil-change'), true),
  ('17f857d1-a183-55b6-9b25-f9d199209633', (select id from public.services where slug = 'battery-replacement'), false),
  ('38f571b2-fa52-5d09-936e-e073b4359673', (select id from public.services where slug = 'engine-repair'), false),
  ('38f571b2-fa52-5d09-936e-e073b4359673', (select id from public.services where slug = 'oil-change'), false),
  ('38f571b2-fa52-5d09-936e-e073b4359673', (select id from public.services where slug = 'brake-service'), false),
  ('38f571b2-fa52-5d09-936e-e073b4359673', (select id from public.services where slug = 'battery-replacement'), false),
  ('38f571b2-fa52-5d09-936e-e073b4359673', (select id from public.services where slug = 'full-service'), false),
  ('38f571b2-fa52-5d09-936e-e073b4359673', (select id from public.services where slug = 'diagnostics'), false),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', (select id from public.services where slug = 'diagnostics'), true),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', (select id from public.services where slug = 'denting-painting'), true),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', (select id from public.services where slug = 'battery-replacement'), true),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', (select id from public.services where slug = 'body-repair'), true),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', (select id from public.services where slug = 'wheel-alignment'), true),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', (select id from public.services where slug = 'spare-parts'), true),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', (select id from public.services where slug = 'inspection'), true),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', (select id from public.services where slug = 'engine-repair'), true),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', (select id from public.services where slug = 'oil-change'), true),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', (select id from public.services where slug = 'brake-service'), false),
  ('c5d3fbb5-c506-5f60-b6bd-915706efbc7d', (select id from public.services where slug = 'full-service'), false),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', (select id from public.services where slug = 'engine-repair'), false),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', (select id from public.services where slug = 'oil-change'), false),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', (select id from public.services where slug = 'brake-service'), false),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', (select id from public.services where slug = 'battery-replacement'), false),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', (select id from public.services where slug = 'full-service'), false),
  ('6aab4e81-1ce6-5dcb-9fee-97be057a1d06', (select id from public.services where slug = 'diagnostics'), false),
  ('269d804b-13ee-570a-826d-b9e412a0e1c5', (select id from public.services where slug = 'engine-repair'), false),
  ('269d804b-13ee-570a-826d-b9e412a0e1c5', (select id from public.services where slug = 'oil-change'), false),
  ('269d804b-13ee-570a-826d-b9e412a0e1c5', (select id from public.services where slug = 'brake-service'), false),
  ('269d804b-13ee-570a-826d-b9e412a0e1c5', (select id from public.services where slug = 'battery-replacement'), false),
  ('269d804b-13ee-570a-826d-b9e412a0e1c5', (select id from public.services where slug = 'full-service'), false),
  ('269d804b-13ee-570a-826d-b9e412a0e1c5', (select id from public.services where slug = 'diagnostics'), false),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', (select id from public.services where slug = 'two-wheeler-service'), true),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', (select id from public.services where slug = 'oil-change'), false),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', (select id from public.services where slug = 'chain-sprocket'), false),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', (select id from public.services where slug = 'puncture-repair'), false),
  ('56f7a449-7b26-5251-a935-4682a9d1fc0c', (select id from public.services where slug = 'battery-replacement'), false)
on conflict (mechanic_id, service_id) do update set is_declared = excluded.is_declared;

-- Mark the geohash cell each city was probed from as already imported, so a
-- user searching from that centre does not trigger a redundant provider fetch.
-- Cells away from the centre are fetched on demand, which is correct: a 10 km
-- probe only partially covers a neighbouring cell.
insert into public.search_tiles (geohash, source, radius_m, mechanic_count) values
  ('tduz1', 'osm', 10000, 1) /* Kolhapur */,
  ('te7ud', 'osm', 10000, 34) /* Mumbai */,
  ('tek92', 'osm', 10000, 66) /* Pune */,
  ('tepff', 'osm', 10000, 40) /* Hyderabad */,
  ('tes3z', 'osm', 10000, 2) /* Nashik */,
  ('tsvch', 'osm', 10000, 15) /* Jaipur */,
  ('ttnfu', 'osm', 10000, 48) /* Delhi */
on conflict (geohash, source) do update set
  mechanic_count = excluded.mechanic_count, fetched_at = now();
