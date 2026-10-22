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
