// ---------------------------------------------------------------------------
// providers.ts — where garage listings come from.
//
// The app needs to work anywhere, and no single source delivers that:
//
//   OpenStreetMap  free, ODbL, permanently storable, no key — but thin outside
//                  metros. Measured over a 10 km radius: Koramangala 186
//                  garages, Chennai T Nagar 53, Kolkata Salt Lake 8,
//                  Ahmedabad 2, Solapur 0, Bilaspur 0. Fine as a free default,
//                  useless as a promise of national coverage.
//
//   Google Places  effectively every Indian business, ~90% with a phone. The
//                  catch is legal, not technical: the Maps Platform terms cap
//                  caching of Places lat/lng at 30 consecutive days, so rows
//                  from here carry `coords_fetched_at` and get purged. place_id
//                  may be kept, which is why it is the external_id.
//
//   Ola Maps       Indian provider, free tier. Its platform terms carry no
//                  retention cap of the kind Google imposes, so results may be
//                  stored — but they require attribution to "Ola Maps" linked to
//                  openstreetmap.org/copyright, and state the data is available
//                  under the ODbL. Which says plainly that it is at least partly
//                  OpenStreetMap-derived, so treat its coverage as unproven
//                  until measured against a real key.
//
// Adding another provider means writing one `fetch` function that returns
// NormalisedPlace[]. Nothing outside this file needs to change, and the API key
// never leaves the server.
// ---------------------------------------------------------------------------

export type ProviderName = "osm" | "google" | "ola";

export interface NormalisedPlace {
  externalId: string;
  name: string;
  nameEn: string | null;
  category: string;
  phone: string | null;
  website: string | null;
  brand: string | null;
  addressLine: string | null;
  locality: string | null;
  city: string | null;
  state: string | null;
  postcode: string | null;
  lat: number;
  lng: number;
  openingHoursRaw: string | null;
  /** Parsed weekly hours, where the provider gives something unambiguous. */
  hours: Hour[] | null;
  /** Service slugs the place itself declares, as opposed to ones we infer. */
  declaredServices: string[];
}

export interface Hour {
  day_of_week: number;
  opens: string;
  closes: string;
}

export const CATEGORY_DEFAULTS: Record<string, string[]> = {
  car: ["engine-repair", "oil-change", "brake-service", "battery-replacement",
        "full-service", "diagnostics"],
  motorcycle: ["two-wheeler-service", "oil-change", "chain-sprocket",
               "puncture-repair", "battery-replacement"],
  tyres: ["tyre-replacement", "wheel-alignment", "puncture-repair"],
  parts: ["spare-parts", "battery-replacement"],
};

const JUNK =
  /provision|kirana|grocery|supermarket|medical|pharmac|chemist|salon|parlour|restaurant|bakery|\bhotel\b|stationer/i;

/** Indian mobile/landline shapes. Anything unrecognised becomes no phone at
 *  all rather than a number that fails when tapped. */
export function normalisePhone(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const digits = String(raw).split(/[;,/]/)[0].replace(/\D/g, "");
  if (digits.length === 10 && /[6-9]/.test(digits[0])) return "+91" + digits;
  if (digits.length === 12 && digits.startsWith("91") && /[6-9]/.test(digits[2])) return "+" + digits;
  if (digits.length === 11 && digits.startsWith("0") && /[6-9]/.test(digits[1])) return "+91" + digits.slice(1);
  if (digits.length > 12 && digits.startsWith("91")) return "+" + digits.slice(0, 12);
  return null;
}

export function isJunk(name: string, nameEn: string | null): boolean {
  return JUNK.test(name) || (!!nameEn && JUNK.test(nameEn));
}

// ----------------------------------------------------------- OpenStreetMap

const OSM_SHOP_CATEGORY: Record<string, string> = {
  car_repair: "car", motorcycle_repair: "motorcycle",
  tyres: "tyres", car_parts: "parts",
};

const OSM_TAG_TO_SLUG: Record<string, string> = {
  car_repair: "engine-repair", repairs: "full-service", repair: "full-service",
  service: "full-service", mechanics: "full-service", oil_change: "oil-change",
  brakes: "brake-service", batteries: "battery-replacement",
  tyres: "tyre-replacement", alignment: "wheel-alignment",
  painting: "denting-painting", body_repair: "body-repair",
  dent_removal: "body-repair", diagnostics: "diagnostics",
  inspection: "inspection", cleaning: "car-wash", electrical: "electrical-work",
  car_parts: "spare-parts", sale: "spare-parts",
  bike: "two-wheeler-service", bike_accessories: "two-wheeler-service",
};

const DAYS: Record<string, number> = {
  su: 0, mo: 1, tu: 2, we: 3, th: 4, fr: 5, sa: 6,
  sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6,
};

function parseTime(t: string): string | null {
  let m = t.trim().match(/^(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\.?$/i);
  if (m) {
    let h = parseInt(m[1], 10);
    const mi = parseInt(m[2] ?? "0", 10);
    const pm = m[3].toLowerCase() === "p";
    if (pm && h !== 12) h += 12;
    if (!pm && h === 12) h = 0;
    return h > 23 || mi > 59 ? null : `${String(h).padStart(2, "0")}:${String(mi).padStart(2, "0")}`;
  }
  m = t.trim().match(/^(\d{1,2}):(\d{2})$/);
  if (m) {
    const h = parseInt(m[1], 10), mi = parseInt(m[2], 10);
    return h > 23 || mi > 59 ? null : `${String(h).padStart(2, "0")}:${String(mi).padStart(2, "0")}`;
  }
  return null;
}

/** Strict: anything we cannot read with confidence yields null, so the garage
 *  ends up with no hours and the app says "Hours not listed" rather than
 *  showing an Open/Closed badge it cannot justify. */
export function parseOsmHours(raw?: string | null): Hour[] | null {
  if (!raw) return null;
  const s = raw.trim();
  if (s === "24/7" || s === "Mo-Su 00:00-24:00") {
    return [0, 1, 2, 3, 4, 5, 6].map((d) => ({ day_of_week: d, opens: "00:00", closes: "23:59" }));
  }
  const out: Hour[] = [];
  let sawRange = false;
  for (let chunk of s.split(";")) {
    chunk = chunk.trim().replace(/[–—]/g, "-");
    if (!chunk) continue;
    if (/^[A-Za-z,\-\s]+off$/i.test(chunk)) continue;
    const m = chunk.match(
      /^(?:([A-Za-z,\-\s]+?)[,\s]+)?(\d{1,2}(?::\d{2})?\s*(?:[ap]\.?m\.?)?)\s*-\s*(\d{1,2}(?::\d{2})?\s*(?:[ap]\.?m\.?)?)$/i,
    );
    if (!m) return null;
    const opens = parseTime(m[2]), closes = parseTime(m[3]);
    if (!opens || !closes || closes <= opens) return null;
    const days = new Set<number>();
    const spec = m[1]?.trim();
    if (!spec) [0, 1, 2, 3, 4, 5, 6].forEach((d) => days.add(d));
    else {
      for (const part of spec.replace(/\s/g, "").split(",")) {
        if (!part) continue;
        if (part.includes("-")) {
          const [a, b] = part.split("-");
          const i = DAYS[a.toLowerCase()], j = DAYS[b.toLowerCase()];
          if (i === undefined || j === undefined) return null;
          for (let k = 0; k <= (j - i + 7) % 7; k++) days.add((i + k) % 7);
        } else {
          const d = DAYS[part.toLowerCase()];
          if (d === undefined) return null;
          days.add(d);
        }
      }
    }
    if (!days.size) return null;
    sawRange = true;
    for (const d of days) out.push({ day_of_week: d, opens, closes });
  }
  if (!sawRange) return null;
  const seen = new Set<number>();
  return out.filter((h) => !seen.has(h.day_of_week) && seen.add(h.day_of_week));
}

const OVERPASS_ENDPOINTS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
];
const USER_AGENT = "InstantMechanic/1.0 (+https://github.com/instant-mechanic)";

async function fetchOsm(lat: number, lng: number, radiusM: number): Promise<NormalisedPlace[]> {
  const tags = "^(car_repair|motorcycle_repair|tyres|car_parts)$";
  const around = `around:${radiusM},${lat},${lng}`;
  const query =
    `[out:json][timeout:60];(` +
    `node["shop"~"${tags}"](${around});way["shop"~"${tags}"](${around});` +
    `node["craft"="car_repair"](${around}););out center tags;`;

  let lastError = "";
  // Overpass refuses requests with no User-Agent and sheds load with 502s, and
  // its own error body asks for exponential backoff.
  for (let attempt = 0; attempt < OVERPASS_ENDPOINTS.length * 2; attempt++) {
    const endpoint = OVERPASS_ENDPOINTS[attempt % OVERPASS_ENDPOINTS.length];
    if (attempt > 0) await new Promise((r) => setTimeout(r, 1500 * attempt));
    try {
      const res = await fetch(endpoint, {
        method: "POST",
        headers: { "User-Agent": USER_AGENT, "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ data: query }),
        signal: AbortSignal.timeout(75_000),
      });
      if (!res.ok) { lastError = `${endpoint} -> HTTP ${res.status}`; continue; }
      const elements = (await res.json()).elements ?? [];
      return normaliseOsm(elements);
    } catch (e) {
      lastError = `${endpoint} -> ${e instanceof Error ? e.message : String(e)}`;
    }
  }
  throw new Error(`Overpass unavailable (${lastError})`);
}

function normaliseOsm(elements: any[]): NormalisedPlace[] {
  const out: NormalisedPlace[] = [];
  const seen = new Set<string>();
  for (const el of elements) {
    const t = (el.tags ?? {}) as Record<string, string>;
    const name = t.name?.trim();
    if (!name) continue;
    const nameEn = t["name:en"]?.trim() || null;
    if (isJunk(name, nameEn)) continue;
    const lat = el.lat ?? el.center?.lat;
    const lng = el.lon ?? el.center?.lon;
    if (lat == null || lng == null) continue;

    const externalId = `${el.type}/${el.id}`;
    if (seen.has(externalId)) continue;
    seen.add(externalId);

    const declared = new Set<string>();
    for (const [k, v] of Object.entries(t)) {
      if (!k.startsWith("service:vehicle:") || String(v).trim().toLowerCase() !== "yes") continue;
      const slug = OSM_TAG_TO_SLUG[k.split(":").pop()!];
      if (slug) declared.add(slug);
    }

    out.push({
      externalId,
      name,
      nameEn,
      category: OSM_SHOP_CATEGORY[t.shop] ?? (t.craft === "car_repair" ? "car" : "car"),
      phone: normalisePhone(t.phone ?? t["contact:phone"] ?? t.mobile ?? t["contact:mobile"]),
      website: t.website || null,
      brand: t.brand || null,
      addressLine: [t["addr:housenumber"], t["addr:housename"], t["addr:street"]]
        .filter(Boolean).join(" ").trim() || null,
      locality: t["addr:suburb"] || t["addr:place"] || t["addr:district"] || null,
      city: t["addr:city"] || null,
      state: t["addr:state"] || null,
      postcode: t["addr:postcode"] || null,
      lat, lng,
      openingHoursRaw: t.opening_hours || null,
      hours: parseOsmHours(t.opening_hours),
      declaredServices: [...declared],
    });
  }
  return out;
}

// ------------------------------------------------------------ Google Places

const GOOGLE_TYPE_CATEGORY: Record<string, string> = {
  car_repair: "car",
  car_wash: "car",
  auto_parts_store: "parts",
  tire_shop: "tyres",
  motorcycle_repair_shop: "motorcycle",
  motorcycle_dealer: "motorcycle",
};

/** Places API (New) returns periods with 0 = Sunday, matching Postgres `dow`. */
function parseGoogleHours(periods: any[] | undefined): Hour[] | null {
  if (!periods?.length) return null;
  const out: Hour[] = [];
  const seen = new Set<number>();
  for (const p of periods) {
    const open = p?.open, close = p?.close;
    if (open?.day == null || open.hour == null) continue;
    // No close means open 24h that day.
    const o = `${String(open.hour).padStart(2, "0")}:${String(open.minute ?? 0).padStart(2, "0")}`;
    const c = close?.hour == null
      ? "23:59"
      : `${String(close.hour).padStart(2, "0")}:${String(close.minute ?? 0).padStart(2, "0")}`;
    if (c <= o) continue;              // overnight spans: skip rather than invert
    if (seen.has(open.day)) continue;
    seen.add(open.day);
    out.push({ day_of_week: open.day, opens: o, closes: c });
  }
  return out.length ? out : null;
}

function addressComponent(place: any, type: string): string | null {
  const c = (place.addressComponents ?? []).find((x: any) => (x.types ?? []).includes(type));
  return c?.longText ?? c?.shortText ?? null;
}

async function fetchGoogle(lat: number, lng: number, radiusM: number): Promise<NormalisedPlace[]> {
  const key = Deno.env.get("PLACES_API_KEY");
  if (!key) throw new Error("PLACES_API_KEY is not set on the function.");

  // Nearby Search (New) caps a response at 20 results, so each automotive type
  // is requested separately to widen what comes back for one region.
  const types = Object.keys(GOOGLE_TYPE_CATEGORY);
  const byId = new Map<string, NormalisedPlace>();

  for (const type of types) {
    const res = await fetch("https://places.googleapis.com/v1/places:searchNearby", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": key,
        "X-Goog-FieldMask": [
          "places.id", "places.displayName", "places.formattedAddress",
          "places.location", "places.nationalPhoneNumber",
          "places.internationalPhoneNumber", "places.regularOpeningHours",
          "places.websiteUri", "places.primaryType", "places.addressComponents",
          "places.businessStatus",
        ].join(","),
      },
      body: JSON.stringify({
        includedTypes: [type],
        maxResultCount: 20,
        locationRestriction: {
          circle: { center: { latitude: lat, longitude: lng }, radius: Math.min(radiusM, 50_000) },
        },
      }),
      signal: AbortSignal.timeout(30_000),
    });

    if (!res.ok) {
      const body = await res.text().catch(() => "");
      // A bad key or disabled API should surface loudly; one empty type should not.
      if (res.status === 401 || res.status === 403) {
        throw new Error(`Places rejected the key (HTTP ${res.status}): ${body.slice(0, 200)}`);
      }
      continue;
    }

    for (const place of (await res.json()).places ?? []) {
      if (place.businessStatus && place.businessStatus !== "OPERATIONAL") continue;
      const name = place.displayName?.text?.trim();
      const id = place.id;
      const latitude = place.location?.latitude;
      const longitude = place.location?.longitude;
      if (!name || !id || latitude == null || longitude == null) continue;
      if (isJunk(name, null)) continue;
      if (byId.has(id)) continue;

      byId.set(id, {
        externalId: id,                           // place_id: the one field we may keep
        name,
        nameEn: null,
        category: GOOGLE_TYPE_CATEGORY[place.primaryType] ?? GOOGLE_TYPE_CATEGORY[type] ?? "car",
        phone: normalisePhone(place.nationalPhoneNumber ?? place.internationalPhoneNumber),
        website: place.websiteUri ?? null,
        brand: null,
        addressLine: place.formattedAddress ?? null,
        locality: addressComponent(place, "sublocality_level_1")
          ?? addressComponent(place, "sublocality"),
        city: addressComponent(place, "locality"),
        state: addressComponent(place, "administrative_area_level_1"),
        postcode: addressComponent(place, "postal_code"),
        lat: latitude,
        lng: longitude,
        openingHoursRaw:
          place.regularOpeningHours?.weekdayDescriptions?.join("; ") ?? null,
        hours: parseGoogleHours(place.regularOpeningHours?.periods),
        declaredServices: [],
      });
    }
  }
  return [...byId.values()];
}

// ---------------------------------------------------------------- Ola Maps
//
// Written against the published OpenAPI document
// (maps.olakrutrim.com/openapi/ola-maps-apis-oas.yaml), not guessed:
//
//   GET https://api.olamaps.io/places/v1/nearbysearch/advanced
//       location=lat,lng          REQUIRED
//       types=car_repair,...      comma-separated; may return zero_results
//       radius=<metres>           default 10000
//       withCentroid=true         DEFAULT IS FALSE, and without it there are no
//                                 coordinates in the response at all
//       rankBy=distance|popular
//       limit=<n>
//       api_key=<key>
//
// The "advanced" variant is used rather than the plain one because it carries
// phone, website and opening_hours inline; the basic endpoint would need a
// separate Place Details call per result.
//
// Ola's taxonomy has no two-wheeler, tyre or parts type — a real gap in India,
// where two-wheeler mechanics are a large share of the trade. The request can
// only ask for the car-ish types, but the *response* carries OSM-style strings
// in `types` (e.g. "amenity:cafe"), so the category is refined from those where
// possible rather than flattening everything to "car".

const OLA_REQUEST_TYPES = ["car_repair", "car_wash", "car_dealer"];

/** Ola returns OSM-flavoured type strings; use them to recover a real category. */
function olaCategory(types: unknown): string {
  const joined = Array.isArray(types) ? types.join(" ").toLowerCase() : "";
  if (/motorcycle|two_wheeler|bike/.test(joined)) return "motorcycle";
  if (/tyre|tire/.test(joined)) return "tyres";
  if (/car_parts|auto_parts|spare/.test(joined)) return "parts";
  return "car";
}

/**
 * `periods[].open.day` is an int, `time` a string. The documented example is
 * literally "NA", so anything that is not four digits is treated as unknown
 * rather than coerced — a wrong Open/Closed badge is worse than none.
 */
function parseOlaHours(openingHours: any): Hour[] | null {
  const periods = openingHours?.periods;
  if (!Array.isArray(periods) || !periods.length) return null;

  const out: Hour[] = [];
  const seen = new Set<number>();
  for (const p of periods) {
    const day = p?.open?.day;
    const rawOpen = String(p?.open?.time ?? "");
    const rawClose = String(p?.close?.time ?? "");
    if (typeof day !== "number" || day < 0 || day > 6) continue;
    if (!/^\d{4}$/.test(rawOpen) || !/^\d{4}$/.test(rawClose)) continue;

    const opens = `${rawOpen.slice(0, 2)}:${rawOpen.slice(2)}`;
    const closes = `${rawClose.slice(0, 2)}:${rawClose.slice(2)}`;
    if (closes <= opens) continue;           // overnight spans: skip, don't invert
    if (seen.has(day)) continue;
    seen.add(day);
    out.push({ day_of_week: day, opens, closes });
  }
  return out.length ? out : null;
}

async function fetchOla(lat: number, lng: number, radiusM: number): Promise<NormalisedPlace[]> {
  const key = Deno.env.get("PLACES_API_KEY");
  if (!key) throw new Error("PLACES_API_KEY is not set on the function.");

  const url = new URL("https://api.olamaps.io/places/v1/nearbysearch/advanced");
  url.searchParams.set("location", `${lat},${lng}`);
  url.searchParams.set("types", OLA_REQUEST_TYPES.join(","));
  url.searchParams.set("radius", String(Math.min(radiusM, 50_000)));
  url.searchParams.set("withCentroid", "true");
  url.searchParams.set("rankBy", "distance");
  url.searchParams.set("limit", "60");
  url.searchParams.set("api_key", key);

  const res = await fetch(url, {
    headers: { "X-Request-Id": crypto.randomUUID() },
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) {
    const body = (await res.text().catch(() => "")).slice(0, 200);
    if (res.status === 401 || res.status === 403) {
      throw new Error(`Ola Maps rejected the key (HTTP ${res.status}): ${body}`);
    }
    throw new Error(`Ola Maps returned HTTP ${res.status}: ${body}`);
  }

  const payload = await res.json();
  // A region with nothing matching comes back as a zero-results status rather
  // than an error, which is a legitimate answer, not a failure.
  const predictions = Array.isArray(payload?.predictions) ? payload.predictions : [];

  const out: NormalisedPlace[] = [];
  const seen = new Set<string>();
  for (const p of predictions) {
    if (p?.business_status && p.business_status !== "OPERATIONAL") continue;

    const id = p?.place_id ?? p?.reference;
    const name = (p?.structured_formatting?.main_text ?? p?.description ?? "").trim();
    // withCentroid=true is what puts this here; without it every row is dropped.
    const latitude = p?.geometry?.location?.lat;
    const longitude = p?.geometry?.location?.lng;
    if (!id || !name || typeof latitude !== "number" || typeof longitude !== "number") continue;
    if (isJunk(name, null) || seen.has(id)) continue;
    seen.add(id);

    out.push({
      externalId: String(id),
      name,
      nameEn: null,
      category: olaCategory(p?.types),
      phone: normalisePhone(p?.formatted_phone_number ?? p?.international_phone_number),
      website: p?.website ?? p?.url ?? null,
      brand: null,
      addressLine: p?.structured_formatting?.secondary_text ?? p?.description ?? null,
      locality: null,
      city: null,
      state: null,
      postcode: null,
      lat: latitude,
      lng: longitude,
      openingHoursRaw: Array.isArray(p?.opening_hours?.weekday_text) && p.opening_hours.weekday_text.length
        ? p.opening_hours.weekday_text.join("; ")
        : null,
      hours: parseOlaHours(p?.opening_hours),
      // Ola exposes a `rating`, deliberately ignored: every rating in this app
      // comes from a completed booking made through it.
      declaredServices: [],
    });
  }
  return out;
}

// ------------------------------------------------------------------ selector

export function activeProvider(): ProviderName {
  const name = (Deno.env.get("PLACES_PROVIDER") ?? "osm").toLowerCase();
  return name === "google" || name === "ola" ? name : "osm";
}

/**
 * Only Google imposes a retention limit on coordinates, so only Google rows get
 * a `coords_fetched_at` and therefore only they are ever purged.
 */
export function coordsExpire(provider: ProviderName): boolean {
  return provider === "google";
}

export function fetchPlaces(
  provider: ProviderName,
  lat: number,
  lng: number,
  radiusM: number,
): Promise<NormalisedPlace[]> {
  switch (provider) {
    case "google": return fetchGoogle(lat, lng, radiusM);
    case "ola": return fetchOla(lat, lng, radiusM);
    default: return fetchOsm(lat, lng, radiusM);
  }
}
