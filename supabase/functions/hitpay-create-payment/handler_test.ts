// deno test supabase/functions/hitpay-create-payment/handler_test.ts
// The OFF state (owner decision): the function refuses before HitPay is ever called.
import { makeHandler } from "./handler.ts";

function assertEquals(actual: unknown, expected: unknown, msg = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${msg} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const fullEnv: Record<string, string> = {
  SUPABASE_URL: "http://supabase.test", SUPABASE_ANON_KEY: "anon", SUPABASE_SERVICE_ROLE_KEY: "service",
  HITPAY_API_KEY: "hitpay-key", HITPAY_REDIRECT_URL: "https://shop.test/paid",
};

/** A supabase-js stand-in: rpc answers from `rpcs`, tables from `tables`. */
function client(rpcs: Record<string, { data?: unknown; error?: unknown }>, calls: string[]) {
  return () => ({
    rpc: (fn: string) => {
      calls.push(`rpc:${fn}`);
      return Promise.resolve(rpcs[fn] ?? { data: null, error: { message: "missing" } });
    },
    from: (table: string) => {
      calls.push(`from:${table}`);
      const q = { select: () => q, eq: () => q, maybeSingle: () => Promise.resolve({ data: null, error: null }) };
      return q;
    },
  });
}

function request() {
  return new Request("http://fn.test", {
    method: "POST", headers: { Authorization: "Bearer token" }, body: JSON.stringify({ order_id: "ORD-T-1" }),
  });
}

function neverFetch(): Promise<Response> {
  throw new Error("HitPay must not be called while online payment is off");
}

Deno.test("switch off: refused with the database message, HitPay never called, no order read", async () => {
  const calls: string[] = [];
  const handler = makeHandler(client({
    online_payment_enabled: { data: false },
    online_payment_disabled_message: { data: "Paying online is paused." },
  }, calls), (k) => fullEnv[k], neverFetch);
  const res = await handler(request());
  assertEquals(res.status, 403);
  assertEquals(await res.json(), { error: "Paying online is paused." });
  assertEquals(calls.filter((c) => c.startsWith("from:")), [], "no table was read");
});

Deno.test("switch unreadable (older database / error): fail closed", async () => {
  const calls: string[] = [];
  const handler = makeHandler(client({}, calls), (k) => fullEnv[k], neverFetch);
  const res = await handler(request());
  assertEquals(res.status, 403);
  assertEquals(await res.json(), { error: "Online payment is unavailable." });
});

Deno.test("switch answers something other than true: fail closed", async () => {
  for (const value of [null, "true", 1]) {
    const handler = makeHandler(client({ online_payment_enabled: { data: value } }, []), (k) => fullEnv[k], neverFetch);
    assertEquals((await handler(request())).status, 403, `value ${JSON.stringify(value)}`);
  }
});

Deno.test("off is checked before the HitPay secrets: no key configured still answers 'unavailable'", async () => {
  const env: Record<string, string> = { SUPABASE_URL: "http://supabase.test", SUPABASE_ANON_KEY: "anon" };
  const handler = makeHandler(client({ online_payment_enabled: { data: false } }, []), (k) => env[k], neverFetch);
  assertEquals((await handler(request())).status, 403);
});

Deno.test("switch on but no redirect URL configured: refused, no invented URL", async () => {
  const env = { ...fullEnv };
  delete (env as Record<string, string>).HITPAY_REDIRECT_URL;
  const handler = makeHandler(client({ online_payment_enabled: { data: true } }, []), (k) => env[k], neverFetch);
  const res = await handler(request());
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { error: "Online payment is not configured." });
});
