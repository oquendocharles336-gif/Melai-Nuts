// route-eta — road distance and driving time for a delivery run (branch -> stops),
// computed by a routing service whose key stays here (never in the app).
//
// POST { "from": {"lat":..,"lng":..}, "stops": [{"lat":..,"lng":..}, ...] }  (caller's Firebase token)
// -> { "legs": [{distance_m, duration_s}], "total_distance_m", "total_duration_s", "estimate": true }
//
// Secrets: ROUTING_PROVIDER = "ors" (+ ORS_API_KEY, openrouteservice.org) or "osrm"
// (+ ROUTING_URL, an https OSRM server you run). Not set = 503 "not configured" (the app then
// shows straight-line distance only). Deploy: supabase functions deploy route-eta --no-verify-jwt
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeHandler } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL") ?? "";
const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

Deno.serve(makeHandler({
  env: (name) => Deno.env.get(name),
  callerRpc: async (authorization, fn) => {
    const client = createClient(url, anon, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await client.rpc(fn);
    return { data, error };
  },
}));
