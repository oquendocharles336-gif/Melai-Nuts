// deno test supabase/functions/route-eta/handler_test.ts
import { makeHandler, parseLegs } from "./handler.ts";

function eq(a: unknown, b: unknown, msg = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const A = { lat: 14.21, lng: 121.16 }, B = { lat: 14.17, lng: 121.24 };
const req = (body: unknown, auth = "Bearer tok") =>
  new Request("http://fn.test", { method: "POST", headers: { Authorization: auth }, body: JSON.stringify(body) });

function handler(opts: { staff?: string; driver?: string; env?: Record<string, string>; answer?: unknown; urls?: string[] }) {
  return makeHandler({
    env: (k) => (opts.env ?? { ROUTING_PROVIDER: "osrm", ROUTING_URL: "https://osrm.test" })[k],
    callerRpc: (_a, fn) => Promise.resolve({
      data: { status: fn === "get_my_staff_context" ? (opts.staff ?? "not_provisioned") : (opts.driver ?? "not_provisioned") },
      error: null,
    }),
    fetchFn: (url) => {
      opts.urls?.push(String(url));
      return Promise.resolve(new Response(JSON.stringify(opts.answer ?? { routes: [{ legs: [{ distance: 8123.4, duration: 901.2 }] }] })));
    },
  });
}

Deno.test("a customer (not staff / driver) is refused", async () => {
  eq((await handler({})(req({ from: A, stops: [B] }))).status, 403);
});

Deno.test("an active driver gets road distance and time, labelled as an estimate", async () => {
  const urls: string[] = [];
  const res = await handler({ driver: "active", urls })(req({ from: A, stops: [B] }));
  eq(res.status, 200);
  eq(await res.json(), { legs: [{ distance_m: 8123, duration_s: 901 }], total_distance_m: 8123, total_duration_s: 901, estimate: true });
  eq(urls, ["https://osrm.test/route/v1/driving/121.16,14.21;121.24,14.17?overview=false"]);
});

Deno.test("pins at 0,0 or out of range are refused, never routed", async () => {
  eq((await handler({ staff: "active" })(req({ from: A, stops: [{ lat: 0, lng: 0 }] }))).status, 400);
  eq((await handler({ staff: "active" })(req({ from: A, stops: [{ lat: 95, lng: 1 }] }))).status, 400);
  eq((await handler({ staff: "active" })(req({ from: A, stops: [] }))).status, 400);
});

Deno.test("without a configured provider the answer is 'not configured' (no key in the app)", async () => {
  eq((await handler({ staff: "active", env: {} })(req({ from: A, stops: [B] }))).status, 503);
  eq((await handler({ staff: "active", env: { ROUTING_PROVIDER: "osrm", ROUTING_URL: "http://plain" } })(req({ from: A, stops: [B] }))).status, 503);
});

Deno.test("openrouteservice answers are read from segments", () => {
  eq(parseLegs("ors", { routes: [{ segments: [{ distance: 10, duration: 2 }, { distance: 5.6, duration: 1.4 }] }] }),
    [{ distance_m: 10, duration_s: 2 }, { distance_m: 6, duration_s: 1 }]);
  eq(parseLegs("osrm", { routes: [] }), null);
});
