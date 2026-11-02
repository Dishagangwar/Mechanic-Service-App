// ---------------------------------------------------------------------------
// delete-account — permanently delete the signed-in user's account.
//
// Google Play requires any app that lets people create an account to let them
// delete it from inside the app. Removing a row from auth.users needs the
// service_role key, which must never ship in an APK, so it happens here.
//
// The caller can only ever delete themselves: the user id comes from their own
// verified access token, never from the request body.
//
// Everything else follows from the schema's foreign keys (0001_schema.sql):
//   profiles, service_requests, reviews  -> on delete cascade (gone)
//   mechanics.owner_id                   -> on delete set null (garage unclaimed,
//                                           the public listing itself stays)
// ---------------------------------------------------------------------------

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

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

    const caller = createClient(url, anonKey, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: who, error: whoErr } = await caller.auth.getUser();
    if (whoErr || !who?.user) return json({ error: "Not signed in." }, 401);

    const admin = createClient(url, serviceKey);
    // shouldSoftDelete = false: a soft delete keeps the auth row (and with it the
    // email and the cascaded data), which is not what the user asked for.
    const { error } = await admin.auth.admin.deleteUser(who.user.id, false);
    if (error) {
      console.error("delete-account failed", who.user.id, error);
      return json({ error: "Couldn't delete the account right now. Please try again." }, 500);
    }

    return json({ deleted: true });
  } catch (e) {
    console.error("delete-account crashed", e);
    return json({ error: "Couldn't delete the account right now. Please try again." }, 500);
  }
});
