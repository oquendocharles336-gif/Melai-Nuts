// Request handler of route-eta (see index.ts): ROAD distance and driving time
// for a delivery run, from a routing service whose key lives only here (never
// in the app). Callers must be an active staff member, owner or driver.

export type Env = (name: string) => string | undefined;
export interface Point { lat: number; lng: number }
export interface Leg { distance_m: number; duration_s: number }

export interface Deps {
  env: Env;
  /** Runs an RPC as the CALLER (their Authorization header). */
  callerRpc: (authorization: string, fn: string) => Promise<{ data: unknown; error: unknown }>;
  fetchFn?: typeof fetch;
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

function validPoint(p: unknown): p is Point {
  const q = p as Point;
  return !!q && Number.isFinite(q.lat) && Number.isFinite(q.lng) && Math.abs(q.lat) <= 90 && Math.abs(q.lng) <= 180 &&
    !(q.lat === 0 && q.lng === 0);
}

async function isActive(deps: Deps, authorization: string, fn: string): Promise<boolean> {
  const { data, error } = await deps.callerRpc(authorization, fn);
  return !error && (data as { status?: string } | null)?.status === "active";
}

/** Legs from the provider's answer (OSRM: routes[0].legs; ORS: routes[0].segments). */
export function parseLegs(provider: string, body: unknown): Leg[] | null {
  // deno-lint-ignore no-explicit-any
  const r = (body as any)?.routes?.[0];
  // deno-lint-ignore no-explicit-any
  const legs: any[] | undefined = provider === "ors" ? r?.segments : r?.legs;
  if (!Array.isArray(legs) || legs.length === 0) return null;
  const out = legs.map((l) => ({ distance_m: Math.round(Number(l.distance)), duration_s: Math.round(Number(l.duration)) }));
  return out.every((l) => Number.isFinite(l.distance_m) && Number.isFinite(l.duration_s)) ? out : null;
}

export function makeHandler(deps: Deps) {
  const fetchFn = deps.fetchFn ?? fetch;
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
    if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
    const authorization = req.headers.get("Authorization") ?? "";
    if (!authorization.startsWith("Bearer ")) return json({ error: "Please sign in again." }, 401);

    let points: Point[] = [];
    try {
      const body = await req.json();
      points = [body?.from, ...(Array.isArray(body?.stops) ? body.stops : [])];
    } catch (_) {
      return json({ error: "Invalid request." }, 400);
    }
    if (points.length < 2 || points.length > 26 || !points.every(validPoint)) {
      return json({ error: "Send the branch and 1 to 25 pinned stops." }, 400);
    }

    const allowed = await isActive(deps, authorization, "get_my_staff_context") ||
      await isActive(deps, authorization, "get_my_driver_context");
    if (!allowed) return json({ error: "Only branch staff, owners and drivers can ask for road distances." }, 403);

    const provider = (deps.env("ROUTING_PROVIDER") ?? "").toLowerCase();
    const coords = points.map((p) => [p.lng, p.lat]);
    let res: Response;
    try {
      if (provider === "ors") {
        const key = deps.env("ORS_API_KEY");
        if (!key) return json({ error: "Road distance is not configured." }, 503);
        res = await fetchFn("https://api.openrouteservice.org/v2/directions/driving-car", {
          method: "POST",
          headers: { Authorization: key, "Content-Type": "application/json" },
          body: JSON.stringify({ coordinates: coords, instructions: false }),
        });
      } else if (provider === "osrm") {
        const base = (deps.env("ROUTING_URL") ?? "").replace(/\/+$/, "");
        if (!base.startsWith("https://")) return json({ error: "Road distance is not configured." }, 503);
        res = await fetchFn(`${base}/route/v1/driving/${coords.map((c) => c.join(",")).join(";")}?overview=false`);
      } else {
        return json({ error: "Road distance is not configured." }, 503);
      }
    } catch (_) {
      return json({ error: "The routing service is unreachable." }, 502);
    }
    const legs = res.ok ? parseLegs(provider, await res.json().catch(() => null)) : null;
    if (!legs) return json({ error: "No road route was found for these pins." }, 502);
    return json({
      legs,
      total_distance_m: legs.reduce((a, l) => a + l.distance_m, 0),
      total_duration_s: legs.reduce((a, l) => a + l.duration_s, 0),
      estimate: true,
    });
  };
}
