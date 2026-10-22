// ---------------------------------------------------------------------------
// nearby-import — expand garage coverage to a region nobody has searched yet.
//
// Why this runs on the server and not in the app:
//
//   1. Overpass refuses requests with no User-Agent (it returns 406) and sheds
//      load under pressure with 502s. It is volunteer infrastructure for light
//      use, so it needs a polite single caller with backoff — not N phones.
//   2. Writing `mechanics` rows is forbidden to end users by RLS. Only the
//      service_role key may do it, and that key must never ship in an APK.
//   3. One fetch per region is shared by every user who searches there. The
//      `search_tiles` ledger is what makes the second search free.
//
// Swapping in a paid provider (Google Places, Ola, Mappls) means replacing
// `fetchOverpass` and setting `SOURCE`. Nothing else here changes — which is why
// the provider key would live here too, never on the device.
// ---------------------------------------------------------------------------

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

const SOURCE = "osm";
// OSM data is ODbL: no retention limit, so this TTL is only about picking up
// newly mapped garages. A provider with a 30-day cache cap would set 30 here.
const TILE_TTL_DAYS = 90;
const USER_AGENT = "InstantMechanic/1.0 (+https://github.com/instant-mechanic)";
const ENDPOINTS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
];

const SHOP_CATEGORY: Record<string, string> = {
  car_repair: "car",
  motorcycle_repair: "motorcycle",
  tyres: "tyres",
  car_parts: "parts",
};

const TAG_TO_SLUG: Record<string, string> = {
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

const CATEGORY_DEFAULTS: Record<string, string[]> = {
  car: ["engine-repair", "oil-change", "brake-service", "battery-replacement",
        "full-service", "diagnostics"],
  motorcycle: ["two-wheeler-service", "oil-change", "chain-sprocket",
               "puncture-repair", "battery-replacement"],
  tyres: ["tyre-replacement", "wheel-alignment", "puncture-repair"],
  parts: ["spare-parts", "battery-replacement"],
};

const JUNK =
  /provision|kirana|grocery|supermarket|medical|pharmac|chemist|salon|parlour|restaurant|bakery|\bhotel\b|stationer/i;

const DAYS: Record<string, number> = {
  su: 0, mo: 1, tu: 2, we: 3, th: 4, fr: 5, sa: 6,
  sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6,
};

// ----------------------------------------------------------------- geohash

const B32 = "0123456789bcdefghjkmnpqrstuvwxyz";

/** Standard geohash encode. Precision 5 is a ~5x5 km cell, which is the grain
 *  we cache at: fine enough to be a meaningful "region", coarse enough that
 *  neighbours in a city reuse each other's fetches. */
function geohash(lat: number, lng: number, precision = 5): string {
  let latMin = -90, latMax = 90, lngMin = -180, lngMax = 180;
  let hash = "", bits = 0, bit = 0, even = true;
  while (hash.length < precision) {
    if (even) {
      const mid = (lngMin + lngMax) / 2;
      if (lng >= mid) { bits = (bits << 1) + 1; lngMin = mid; }
      else { bits = bits << 1; lngMax = mid; }
    } else {
      const mid = (latMin + latMax) / 2;
      if (lat >= mid) { bits = (bits << 1) + 1; latMin = mid; }
      else { bits = bits << 1; latMax = mid; }
    }
    even = !even;
    if (++bit === 5) { hash += B32[bits]; bits = 0; bit = 0; }
  }
  return hash;
}

// ------------------------------------------------------------ normalisation

function normalisePhone(tags: Record<string, string>): string | null {
  const raw = ["phone", "contact:phone", "mobile", "contact:mobile"]
    .map((k) => tags[k]?.trim()).find(Boolean);
  if (!raw) return null;
  const digits = raw.split(/[;,/]/)[0].replace(/\D/g, "");
  if (digits.length === 10 && /[6-9]/.test(digits[0])) return "+91" + digits;
  if (digits.length === 12 && digits.startsWith("91") && /[6-9]/.test(digits[2])) return "+" + digits;
  if (digits.length === 11 && digits.startsWith("0") && /[6-9]/.test(digits[1])) return "+91" + digits.slice(1);
  return null; // unrecognised shape -> no phone rather than a broken dial
}

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

type Hour = { day_of_week: number; opens: string; closes: string };

/** Strict on purpose: any clause we cannot read with confidence invalidates the
 *  whole string, so the garage ends up with NO hours rows and the app says
 *  "Hours not listed". A wrong Open/Closed badge is worse than no badge. */
function parseHours(raw?: string): Hour[] | null {
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
    if (!spec) { [0, 1, 2, 3, 4, 5, 6].forEach((d) => days.add(d)); }
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
  return out.filter((h) => !seen.has(h.day_of_week) && seen.add(h.day_of_week)) ?? null;
}

// -------------------------------------------------------------- overpass I/O

async function fetchOverpass(lat: number, lng: number, radiusM: number) {
  const tags = "^(car_repair|motorcycle_repair|tyres|car_parts)$";
  const around = `around:${radiusM},${lat},${lng}`;
  const query =
    `[out:json][timeout:60];(` +
    `node["shop"~"${tags}"](${around});` +
    `way["shop"~"${tags}"](${around});` +
    `node["craft"="car_repair"](${around});` +
    `);out center tags;`;

  let lastError = "";
  // One polite pass per mirror, with widening backoff. Overpass explicitly asks
  // for exponential backoff in its 502 body.
  for (let attempt = 0; attempt < ENDPOINTS.length * 2; attempt++) {
    const endpoint = ENDPOINTS[attempt % ENDPOINTS.length];
    if (attempt > 0) await new Promise((r) => setTimeout(r, 1500 * attempt));
    try {
      const res = await fetch(endpoint, {
        method: "POST",
        headers: {
          "User-Agent": USER_AGENT,
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({ data: query }),
        signal: AbortSignal.timeout(75_000),
      });
      if (res.ok) return (await res.json()).elements ?? [];
      lastError = `${endpoint} -> HTTP ${res.status}`;
    } catch (e) {
      lastError = `${endpoint} -> ${e instanceof Error ? e.message : String(e)}`;
    }
  }
  throw new Error(`Overpass unavailable (${lastError})`);
}

// ------------------------------------------------------------------ handler

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, content-type",
      },
    });
  }

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    });

  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // Only signed-in users may trigger an import; otherwise this is an open
    // proxy that lets anyone burn the project's Overpass goodwill (or, with a
    // paid provider, its money).
    const authHeader = req.headers.get("Authorization") ?? "";
    const caller = createClient(url, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: who, error: whoErr } = await caller.auth.getUser();
    if (whoErr || !who?.user) return json({ error: "Not signed in." }, 401);

    const body = await req.json().catch(() => ({}));
    const lat = Number(body.lat), lng = Number(body.lng);
    const radiusM = Math.min(Math.max(Number(body.radius_m) || 10_000, 1_000), 25_000);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) ||
        Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      return json({ error: "A valid lat and lng are required." }, 400);
    }

    const db = createClient(url, serviceKey);
    const tile = geohash(lat, lng);

    // Already covered? Then the client's own nearby_mechanics call is enough.
    const { data: existing } = await db
      .from("search_tiles")
      .select("fetched_at, mechanic_count")
      .eq("geohash", tile).eq("source", SOURCE).maybeSingle();

    if (existing) {
      const ageDays =
        (Date.now() - new Date(existing.fetched_at).getTime()) / 86_400_000;
      if (ageDays < TILE_TTL_DAYS) {
        return json({
          tile, cached: true, imported: 0,
          mechanic_count: existing.mechanic_count,
          age_days: Math.round(ageDays),
        });
      }
    }

    const elements = await fetchOverpass(lat, lng, radiusM);

    const { data: services } = await db.from("services").select("id, slug");
    const slugToId = new Map((services ?? []).map((s) => [s.slug, s.id as string]));

    const rows: Record<string, unknown>[] = [];
    const hourRows: Record<string, unknown>[] = [];
    const svcRows: Record<string, unknown>[] = [];
    const seen = new Set<string>();

    for (const el of elements) {
      const t = (el.tags ?? {}) as Record<string, string>;
      const name = t.name?.trim();
      if (!name) continue;
      const nameEn = t["name:en"]?.trim() || null;
      if (JUNK.test(name) || (nameEn && JUNK.test(nameEn))) continue;
      const elLat = el.lat ?? el.center?.lat;
      const elLng = el.lon ?? el.center?.lon;
      if (elLat == null || elLng == null) continue;

      const externalId = `${el.type}/${el.id}`;
      if (seen.has(externalId)) continue;
      seen.add(externalId);

      const category = SHOP_CATEGORY[t.shop] ?? (t.craft === "car_repair" ? "car" : "car");
      const address = [t["addr:housenumber"], t["addr:housename"], t["addr:street"]]
        .filter(Boolean).join(" ").trim() || null;

      rows.push({
        source: SOURCE,
        external_id: externalId,
        name,
        name_en: nameEn,
        category,
        phone: normalisePhone(t),
        website: t.website || null,
        brand: t.brand || null,
        operator: t.operator || null,
        address_line: address,
        locality: t["addr:suburb"] || t["addr:place"] || t["addr:district"] || null,
        city: t["addr:city"] || null,
        state: t["addr:state"] || null,
        postcode: t["addr:postcode"] || null,
        lat: elLat,
        lng: elLng,
        // Null: OSM has no retention limit, so the purge job must not touch these.
        coords_fetched_at: null,
        opening_hours_raw: t.opening_hours || null,
      });

      const declared = new Set<string>();
      for (const [k, v] of Object.entries(t)) {
        if (!k.startsWith("service:vehicle:") || v?.trim().toLowerCase() !== "yes") continue;
        const slug = TAG_TO_SLUG[k.split(":").pop()!];
        if (slug) declared.add(slug);
      }

      const parsed = parseHours(t.opening_hours);
      // Keyed by external_id for now; swapped for real ids after the upsert.
      if (parsed) for (const h of parsed) hourRows.push({ externalId, ...h });
      for (const slug of declared) svcRows.push({ externalId, slug, is_declared: true });
      for (const slug of CATEGORY_DEFAULTS[category]) {
        if (!declared.has(slug)) svcRows.push({ externalId, slug, is_declared: false });
      }
    }

    let importedIds = new Map<string, string>();
    if (rows.length) {
      // ignoreDuplicates:false = update what changed. The SQL policy comment
      // explains why a claimed row must not be clobbered; we filter those out
      // by only upserting rows whose owner_id is null (checked after insert).
      const { data: upserted, error } = await db
        .from("mechanics")
        .upsert(rows, { onConflict: "source,external_id", ignoreDuplicates: false })
        .select("id, external_id, owner_id");
      if (error) return json({ error: `Upsert failed: ${error.message}` }, 500);
      importedIds = new Map(
        (upserted ?? []).filter((r) => !r.owner_id).map((r) => [r.external_id as string, r.id as string]),
      );
    }

    if (importedIds.size) {
      const ids = [...importedIds.values()];
      await db.from("mechanic_hours").delete().in("mechanic_id", ids);
      const hv = hourRows
        .filter((h) => importedIds.has(h.externalId as string))
        .map((h) => ({
          mechanic_id: importedIds.get(h.externalId as string),
          day_of_week: h.day_of_week, opens: h.opens, closes: h.closes,
        }));
      if (hv.length) await db.from("mechanic_hours").insert(hv);

      const sv = svcRows
        .filter((s) => importedIds.has(s.externalId as string) && slugToId.has(s.slug as string))
        .map((s) => ({
          mechanic_id: importedIds.get(s.externalId as string),
          service_id: slugToId.get(s.slug as string),
          is_declared: s.is_declared,
        }));
      if (sv.length) {
        await db.from("mechanic_services")
          .upsert(sv, { onConflict: "mechanic_id,service_id", ignoreDuplicates: false });
      }
    }

    // Recorded even when the region genuinely has zero garages — that is the
    // difference between "never looked" and "looked, found nothing", and the app
    // words its empty state differently for each.
    await db.from("search_tiles").upsert({
      geohash: tile, source: SOURCE, radius_m: radiusM,
      mechanic_count: rows.length, fetched_at: new Date().toISOString(),
    }, { onConflict: "geohash,source" });

    return json({ tile, cached: false, imported: rows.length, mechanic_count: rows.length });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 502);
  }
});
