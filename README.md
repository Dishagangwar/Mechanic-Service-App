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
| Networking | Retrofit + OkHttp |
| JSON | Moshi |
| Async | Coroutines + Flow / StateFlow |
| Auth | Supabase (supabase-kt `auth-kt`) |
| DI | Hilt |
| View access | ViewBinding |

## Screens

**Sign in / Sign up** — email-and-password auth backed by Supabase. Sign-up also collects
a full name and phone number, which are stored as Supabase user metadata. A gate screen
sits at the start of the graph and routes to home or sign-in once the stored session has
been restored, so a returning user never sees the sign-in form. Home carries a sign-out
action.

**Home** — list of mechanics showing garage name, rating and review count, distance,
location, the services offered as chips, and an open/closed badge. Pull to refresh.

**Mechanic details** — garage name, rating, full address, working hours, phone number
(tap to open the dialer), every service offered, and a *Request Service* button.

**Request service** — form for customer name, phone number, vehicle number, service
(populated from the selected garage's own service list) and a problem description.
Validates every field, then shows a confirmation dialog with a request ID and ETA.

## Architecture

```
ui/           Fragments, ViewModels, RecyclerView adapter
  auth/       Gate, sign-in and sign-up screens + shared field validation
domain/       Models + the repository interface the UI talks to
data/
  remote/     Retrofit service, DTOs, mock interceptor
  mapper/     DTO -> domain
  repository/ Repository implementation
di/           Hilt modules
util/         Resource wrapper, error mapping
```

The UI never sees a DTO. `Resource<T>` (`Loading` / `Success` / `Error`) is the single
stream each screen renders from, so loading and error handling are structural rather
than bolted on per screen.

## API layer

The app runs the full Retrofit → OkHttp → Moshi → repository → ViewModel path. Two
`buildConfigField` values in `app/build.gradle.kts` control where the data comes from:

```kotlin
buildConfigField("String", "BASE_URL", "\"https://raw.githubusercontent.com/<you>/MechanicServiceApp/main/api/\"")
buildConfigField("boolean", "USE_MOCK_API", "true")
```

- `USE_MOCK_API = true` (default) — an OkHttp interceptor serves `assets/mechanics.json`
  with a simulated 700 ms latency, so the app is demoable with no hosting and no network.
- `USE_MOCK_API = false` — real HTTPS requests against `BASE_URL`. `api/mechanics.json`
  in this repo is the payload; push the repo public, set your username in `BASE_URL`,
  and the same code path hits the network for real.

Only the interceptor changes. Retrofit, the parsing, the error handling and every screen
above it behave identically either way.

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `mechanics.json` | List of mechanics |
| POST | `service-requests` | Submit a booking, returns request ID + ETA |

## Error handling

`Throwable.toAuthUserMessage()` maps Supabase's `AuthErrorCode`s (invalid credentials,
unconfirmed email, duplicate account, weak password, rate limits) onto readable text and
falls through to the mapper below for anything else.

`Throwable.toUserMessage()` maps `UnknownHostException`, `SocketTimeoutException`,
`HttpException` (by status code) and generic `IOException` onto messages a person can
act on, instead of surfacing raw exception text. Failures render as a retryable state
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

## Not implemented

Search/filter, pagination, offline caching, Firebase and unit tests were scoped out of
this submission. Hilt and Supabase authentication were the bonus items included.

Password reset is not wired up: sending the email is a one-liner, but completing the reset
needs a deep link back into the app, which is a flow of its own. Social/OAuth sign-in and a
dedicated `profiles` table (user details currently live in Supabase user metadata) are the
other natural next steps.
