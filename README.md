# Instant Mechanic — Mini Mechanic Service App

An Android app for browsing nearby mechanics and requesting a vehicle service.
Built for the Android Development Internship assignment.

## Tech stack

| Area | Choice |
|---|---|
| Language | Kotlin |
| UI | XML Views + Fragments, Material 3 |
| Architecture | MVVM + Repository, single-Activity |
| Navigation | Jetpack Navigation Component |
| Backend | Supabase — Postgres + PostgREST + Auth + Edge Functions |
| Data access | supabase-kt (`postgrest-kt`, `auth-kt`, `functions-kt`) |
| Async | Coroutines + Flow / StateFlow |
| Location | Play Services location + Android `Geocoder` |
| Garage data | OpenStreetMap via Overpass (ODbL) |
| DI | Hilt |
| View access | ViewBinding |

## Screens

**Sign in / Sign up** — email-and-password auth backed by Supabase. Sign-up also collects
a full name and phone number, which are stored as Supabase user metadata. A gate screen
sits at the start of the graph and routes to home or sign-in once the stored session has
been restored, so a returning user never sees the sign-in form. Home carries a sign-out
action.

**Location picker** — the app has no built-in city. Search runs around a point the user
chooses: their device location, a place they type ("Kolhapur", "Baner Pune", a pincode,
resolved with Android's own `Geocoder`), or the location they used last, which is stored
on their profile. Granting location is optional throughout — typing an area always works.

**Home** — garages near the chosen location, nearest first, with a radius control
(5 / 10 / 25 km), category filters, and a name/area search. Pull to refresh. Opening a
region nobody has searched before triggers a one-off import on the server.

**Mechanic details** — name, rating, address, hours, phone (tap to dial), services, and a
*Request Service* button. Every one of those can legitimately be missing, and the screen
says so rather than filling the gap.

**Request service** — name and phone arrive pre-filled from the user's profile. Service
options come from the garage's own list. Submitting writes a real row and the confirmation
reports that the request has been *sent*, with no ETA — the garage has not seen it yet.

**My requests** — every booking with its live status, the ETA once a garage commits to
one, cancel while still pending or accepted, and a star rating once the work is marked
completed.

## Architecture

```
ui/           Fragments, ViewModels, RecyclerView adapters
  auth/       Gate, sign-in and sign-up + shared field validation
  home/       Garage list, filters, location bar
  location/   Location picker (device / typed / last used)
  detail/     Garage details
  request/    Booking form
  requests/   Booking history, cancel, rate
domain/       Models + the repository interfaces the UI talks to
data/
  mapper/     PostgREST rows -> domain
  repository/ Mechanic, Request, Location, Profile, Auth implementations
di/           Hilt modules
util/         Resource wrapper, error mapping, JSON field readers
supabase/
  migrations/ Schema, views + RPCs, RLS, function grants
  seed/       Service catalog, generated OSM garages
  functions/  nearby-import Edge Function
  apply_all.sql   all of the above in one pasteable file
```

The UI never sees a DTO. `Resource<T>` (`Loading` / `Success` / `Error`) is the single
stream each screen renders from, so loading and error handling are structural rather
than bolted on per screen.

## Data: where the garages come from

There is no bundled JSON and no mock interceptor any more. Garages live in Postgres and
come from **OpenStreetMap** via the Overpass API, which is ODbL licensed — free to store
permanently, attribution required (shown in-app).

`supabase/seed/0002_mechanics_osm.sql` is generated, not hand-written: 206 real businesses
across Delhi, Mumbai, Hyderabad, Pune, Jaipur, Nashik and Kolhapur. The coverage is
genuinely patchy, and the schema is built around admitting that:

| Field | Known for |
|---|---|
| name + coordinates | 100% |
| phone | 19% |
| parseable opening hours | 10% |
| services declared by the garage | 8 of 206 |
| rating | 0% — OSM has no reviews, so every rating in this app is one a user left here |

Three deliberate consequences:

- **`is_open` is not a stored column.** It is computed from `mechanic_hours` in the
  garage's own timezone, and is `NULL` when the hours are unknown. The UI renders that as
  *"Hours not listed"* — a stored boolean is wrong the moment the clock moves.
- **`rating` and `review_count` are not stored either.** They aggregate over `reviews`,
  and a review can only be inserted against a *completed* booking the reviewer owns, which
  makes a fake rating structurally impossible rather than merely discouraged.
- **Nullable means nullable.** No phone renders no call button. The old DTO mapper
  defaulted `rating` to `0.0` and `isOpen` to `false`, which made the app look more certain
  than its data.

### Searching anywhere

`nearby_mechanics(lat, lng, radius_km, category, service, query)` does the distance maths
and filtering in Postgres: a bounding-box prefilter on btree indexes, then haversine on the
survivors. No PostGIS or earthdistance extension needed.

Regions nobody has searched are filled in on demand by the `nearby-import` Edge Function,
which keeps a ledger of fetched regions in `search_tiles` (geohash precision 5, ~5 km
cells) so the second search in an area costs nothing — and, with a metered provider, so it
stays affordable.

### Choosing a data provider

**This is the decision that determines whether the app works everywhere.** It is set by the
`PLACES_PROVIDER` env var on the Edge Function; `providers.ts` holds one adapter each.

| Provider | Coverage | Storable? | Key needed |
|---|---|---|---|
| `osm` (default) | Good in metros, thin to absent elsewhere | Yes, ODbL, forever | No |
| `google` | Effectively every Indian business, ~90% with a phone | **Coordinates: 30 days max** | Yes, billed |
| `ola` | Strong Indian POI coverage, free tier | Check current terms | Yes |

OpenStreetMap is the default because it needs no key and no billing, but measured over a
10 km radius it does not support a promise of national coverage:

```
Koramangala  186      Ahmedabad   2      ← a city of 8 million
T Nagar       53      Solapur     0
Andheri       36      Bilaspur    0
Salt Lake      8      (6 of 14 probes also hit Overpass 502s)
```

So: **OSM for a free demo, a commercial provider for real nationwide coverage.** Switching
is one env var plus a key — no app change, no schema change, and nothing to redeploy on the
client.

Google's constraint shaped the schema. Its terms cap caching of Places lat/lng at 30
consecutive days, so rows from it carry `coords_fetched_at`, the tile TTL drops to 25 days,
and `purge_expired_coordinates()` nulls them on schedule. `place_id` may be kept, which is
why it is the `external_id`. OSM rows leave `coords_fetched_at` null and are never purged.

## Error handling

`Throwable.toAuthUserMessage()` maps Supabase's `AuthErrorCode`s (invalid credentials,
unconfirmed email, duplicate account, weak password, rate limits) onto readable text and
falls through to the mapper below for anything else.

`Throwable.toUserMessage()` maps Supabase's `RestException` subclasses, `UnknownHostException`,
`SocketTimeoutException` and generic `IOException` onto messages a person can act on. It also
translates the server-side rules this app leans on — a row level security rejection reads as
a constraint violation, and the request-transition trigger raises its own messages — into
something meaningful to whoever is holding the phone. Failures render as a retryable state
view on the list and detail screens, and as a Snackbar with a retry action on the form.

## Authentication

Email/password auth runs through [supabase-kt](https://github.com/supabase-community/supabase-kt).

### Setup

1. Create a project at [supabase.com](https://supabase.com).
2. Copy the project URL and the `anon` public key from **Project Settings > API**.
3. Put them in `local.properties` (git-ignored, so they stay out of the repo):

   ```properties
   SUPABASE_URL=https://your-project.supabase.co
   SUPABASE_ANON_KEY=your-anon-key
   ```

   CI can supply the same two names as environment variables instead.
4. Re-sync Gradle.

A build with either value missing still starts: `SupabaseConfig.isConfigured` is false, the
repository never resolves its `Lazy<Auth>`, and the gate screen explains what to add instead
of throwing during injection where only logcat would see it.

Under **Authentication > Providers > Email**, *Confirm email* decides where sign-up lands:
with it off the new account is signed straight in, and with it on the app shows a "check
your inbox" dialog and sends the user back to sign in. Both paths are handled.

### Session handling

The Android artifact registers an `androidx.startup` initializer, so sessions are persisted
and refreshed automatically — no wiring needed here. `AuthRepository` exposes that session
as a `Flow<AuthState>`; `AuthGateFragment` is the only thing that reads it at launch.

Sign-out is deliberately scoped `LOCAL`. A global sign-out has to reach the server to revoke
tokens, and if that call fails the local session survives and the user is stuck inside an
app they asked to leave.

## Building

```bash
./gradlew assembleDebug
```

Requires JDK 17+ and Android SDK 37. `minSdk` is 24.

### Backend setup

The app needs its schema before it can show anything. Two steps, both one-off:

1. **Apply the schema and seed.** Open the Supabase dashboard → SQL Editor → New query,
   paste the whole of `supabase/apply_all.sql`, and run it. It is idempotent, so running it
   again is safe and refreshes the seeded garages without touching any listing a garage
   owner has claimed.

   Note that `0004_function_grants.sql` is not optional. PostgreSQL grants EXECUTE on a new
   function to `PUBLIC`, and a later `GRANT` to a named role does not displace that — so
   without it every function, including the `SECURITY DEFINER` coordinate purge, is callable
   by anyone holding the anon key that ships in the APK.

2. **Deploy the region importer.** Not optional if the app is to work outside the seven
   seeded cities — without it, every other region returns nothing, permanently.

   ```bash
   supabase functions deploy nearby-import
   ```

   It reads `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`, all three
   of which Supabase injects into deployed functions automatically.

   To use a commercial provider instead of OpenStreetMap, set its key as a secret — it
   stays on the server and never reaches the APK:

   ```bash
   supabase secrets set PLACES_PROVIDER=google PLACES_API_KEY=<your-key>
   supabase functions deploy nearby-import
   ```

   For `google`, enable **Places API (New)** on a Google Cloud project with billing, then
   restrict the key to that API. For `ola`, get a key from the Ola Maps developer console.
   Leave both unset to stay on OpenStreetMap.

3. **Schedule the coordinate purge** (only if you switch to a provider with a retention
   limit, such as Google Places). Enable `pg_cron` under Database → Extensions, then run
   the `cron.schedule` call at the bottom of `supabase/migrations/0002_views_rpc.sql`.

## Not implemented

**The garage side has a backend but no UI.** The schema, the RLS policies and the
status-transition trigger all support a garage owner claiming a listing, accepting a
request with an ETA, and marking it complete — and that path is covered by the SQL tests —
but there is no screen for it. In practice that means a booking stays `pending` until
somebody moves it on from the Supabase dashboard. Building those screens is the next
meaningful piece of work, and it is what would make request status change on its own.

Also out of scope: realtime status updates (the `realtime-kt` module would replace the
pull-to-refresh on My requests), pagination, offline caching, and unit tests — the backend
is covered by SQL-level tests, the Kotlin side is not.

Password reset is not wired up: sending the email is a one-liner, but completing the reset
needs a deep link back into the app, which is a flow of its own. Social/OAuth sign-in is
the other natural next step.
