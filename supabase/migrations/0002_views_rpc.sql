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
