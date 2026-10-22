// ---------------------------------------------------------------------------
// nearby-import — fill in garage coverage for a region nobody has searched yet.
//
// Why this runs on the server and not in the app:
//
//   1. The provider key must never ship in an APK. Everything in `providers.ts`
//      that needs credentials reads them from the function's own environment.
//   2. Writing `mechanics` rows is forbidden to end users by RLS and needs the
//      service_role key.
//   3. One fetch per region is shared by everyone who searches there. The
//      `search_tiles` ledger is what makes the second search free — and with a
//      metered provider, what makes it affordable.
//   4. Overpass rejects requests with no User-Agent and sheds load with 502s,
//      so it needs a single polite caller with backoff, not N phones.
//
// Which source is used is set by the PLACES_PROVIDER env var. See providers.ts
// for what each one can and cannot do.
// ---------------------------------------------------------------------------

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import {
  CATEGORY_DEFAULTS,
  activeProvider,
  coordsExpire,
  fetchPlaces,
} from "./providers.ts";

/** How long a region's import stays good before it is worth refetching. */
function tileTtlDays(provider: string): number {
  // Google's terms cap cached coordinates at 30 consecutive days, so a tile
  // must not outlive them. OSM has no such limit, so the TTL there is only
  // about picking up newly mapped garages.
  return provider === "google" ? 25 : 90;
}

const B32 = "0123456789bcdefghjkmnpqrstuvwxyz";

/** Standard geohash. Precision 5 is a ~5 km cell: fine enough to be a
 *  meaningful "region", coarse enough that neighbours reuse each other's
 *  fetches. Must stay identical to the seed generator's implementation. */
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

    // Only signed-in users may trigger an import. Otherwise this is an open
    // proxy that lets anyone burn the project's Overpass goodwill or, with a
    // metered provider, its money.
    const caller = createClient(url, anonKey, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
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

    const provider = activeProvider();
    const db = createClient(url, serviceKey);
    const tile = geohash(lat, lng);

    const { data: existing } = await db
      .from("search_tiles")
      .select("fetched_at, mechanic_count")
      .eq("geohash", tile).eq("source", provider).maybeSingle();

    if (existing) {
      const ageDays = (Date.now() - new Date(existing.fetched_at).getTime()) / 86_400_000;
      if (ageDays < tileTtlDays(provider)) {
        return json({
          tile, provider, cached: true, imported: 0,
          mechanic_count: existing.mechanic_count,
          age_days: Math.round(ageDays),
        });
      }
    }

    const places = await fetchPlaces(provider, lat, lng, radiusM);
    const fetchedAt = coordsExpire(provider) ? new Date().toISOString() : null;

    const { data: services } = await db.from("services").select("id, slug");
    const slugToId = new Map((services ?? []).map((s) => [s.slug, s.id as string]));

    const rows = places.map((p) => ({
      source: provider,
      external_id: p.externalId,
      name: p.name,
      name_en: p.nameEn,
      category: p.category,
      phone: p.phone,
      website: p.website,
      brand: p.brand,
      address_line: p.addressLine,
      locality: p.locality,
      city: p.city,
      state: p.state,
      postcode: p.postcode,
      lat: p.lat,
      lng: p.lng,
      // Non-null only where the provider's terms put a clock on coordinates.
      coords_fetched_at: fetchedAt,
      opening_hours_raw: p.openingHoursRaw,
    }));

    let importedIds = new Map<string, string>();
    if (rows.length) {
      const { data: upserted, error } = await db
        .from("mechanics")
        .upsert(rows, { onConflict: "source,external_id", ignoreDuplicates: false })
        .select("id, external_id, owner_id");
      if (error) return json({ error: `Upsert failed: ${error.message}` }, 500);
      // A listing a garage owner has claimed is theirs; imports must not stomp
      // the hours and phone they corrected by hand.
      importedIds = new Map(
        (upserted ?? []).filter((r) => !r.owner_id)
          .map((r) => [r.external_id as string, r.id as string]),
      );
    }

    if (importedIds.size) {
      const ids = [...importedIds.values()];
      await db.from("mechanic_hours").delete().in("mechanic_id", ids);

      const hourRows = places.flatMap((p) => {
        const id = importedIds.get(p.externalId);
        if (!id || !p.hours) return [];
        return p.hours.map((h) => ({ mechanic_id: id, ...h }));
      });
      if (hourRows.length) await db.from("mechanic_hours").insert(hourRows);

      const serviceRows = places.flatMap((p) => {
        const id = importedIds.get(p.externalId);
        if (!id) return [];
        const declared = new Set(p.declaredServices);
        const inferred = (CATEGORY_DEFAULTS[p.category] ?? [])
          .filter((slug) => !declared.has(slug));
        return [
          ...[...declared].map((slug) => ({ slug, is_declared: true })),
          ...inferred.map((slug) => ({ slug, is_declared: false })),
        ]
          .filter((s) => slugToId.has(s.slug))
          .map((s) => ({
            mechanic_id: id,
            service_id: slugToId.get(s.slug)!,
            is_declared: s.is_declared,
          }));
      });
      if (serviceRows.length) {
        await db.from("mechanic_services")
          .upsert(serviceRows, { onConflict: "mechanic_id,service_id", ignoreDuplicates: false });
      }
    }

    // Recorded even when the region genuinely has no garages. "Never looked" and
    // "looked, found nothing" are different facts, and the app words its empty
    // state differently for each.
    await db.from("search_tiles").upsert({
      geohash: tile, source: provider, radius_m: radiusM,
      mechanic_count: rows.length, fetched_at: new Date().toISOString(),
    }, { onConflict: "geohash,source" });

    return json({
      tile, provider, cached: false,
      imported: rows.length, mechanic_count: rows.length,
    });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 502);
  }
});
