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

// ---- Switch ON: one payment request at a time, no expired links (review fix 7) ------------------

/** A stateful stand-in for the database: same rules as hitpay_claim_checkout / hitpay_set_checkout. */
function liveDb(payment: Record<string, unknown>, now: () => number = Date.now) {
  const calls: string[] = [];
  const rpcs: Record<string, (args: Record<string, unknown>) => unknown> = {
    online_payment_enabled: () => true,
    hitpay_claim_checkout: (args) => {
      if (!["pending", "processing", "failed"].includes(payment.status as string)) return { action: "closed", status: payment.status };
      const maxAgeMs = Number(args.p_max_age_minutes) * 60_000;
      const created = payment.gateway_checkout_created_at as number | null;
      if (payment.status !== "failed" && payment.gateway_checkout_url && payment.gateway_payment_id && created && created > now() - maxAgeMs) {
        return { action: "reuse", checkout_url: payment.gateway_checkout_url, payment_request_id: payment.gateway_payment_id };
      }
      const started = payment.checkout_started_at as number | null;
      if (started && started > now() - 60_000) return { action: "busy" };
      payment.checkout_started_at = now();
      return { action: "create" };
    },
    hitpay_release_checkout: () => { payment.checkout_started_at = null; return null; },
    hitpay_set_checkout: (args) => {
      Object.assign(payment, {
        gateway_payment_id: args.p_payment_id, gateway_checkout_url: args.p_url,
        gateway_checkout_created_at: now(), checkout_started_at: null,
        status: ["pending", "failed"].includes(payment.status as string) ? "processing" : payment.status,
      });
      return null;
    },
  };
  const rows: Record<string, unknown> = {
    orders: { id: "ORD-T-1", firebase_uid: "u1", status: "pending", total: 250 },
    payments: payment,
    customer_profiles: null,
  };
  const factory = () => ({
    rpc: (fn: string, args: Record<string, unknown> = {}) => {
      calls.push(`rpc:${fn}`);
      const impl = rpcs[fn];
      return Promise.resolve(impl ? { data: impl(args), error: null } : { data: null, error: { message: "missing" } });
    },
    from: (table: string) => {
      const q = { select: () => q, eq: () => q, maybeSingle: () => Promise.resolve({ data: rows[table] ?? null, error: null }) };
      return q;
    },
  });
  return { factory, calls, payment };
}

function hitpay(counter: { n: number }, delayMs = 0) {
  return async (): Promise<Response> => {
    counter.n++;
    if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
    return new Response(JSON.stringify({ id: `req-${counter.n}`, url: `https://pay.test/${counter.n}` }), { status: 200 });
  };
}

const quickSleep = () => new Promise<void>((r) => setTimeout(r, 10));

Deno.test("double tap: two calls at once create ONE HitPay payment request and get the same link", async () => {
  const db = liveDb({ id: "PAY-1", method: "gcash", status: "pending", amount: 250 });
  const sent = { n: 0 };
  const handler = makeHandler(db.factory, (k) => fullEnv[k], hitpay(sent, 25), quickSleep);
  const [a, b] = await Promise.all([handler(request()), handler(request())]);
  assertEquals(sent.n, 1, "HitPay called once");
  assertEquals([a.status, b.status], [200, 200]);
  const [ja, jb] = [await a.json(), await b.json()];
  assertEquals(ja, jb, "both taps get the same link");
  assertEquals(ja.checkout_url, "https://pay.test/1");
});

Deno.test("a fresh stored link is reused without calling HitPay", async () => {
  const db = liveDb({ id: "PAY-1", method: "gcash", status: "processing", amount: 250,
    gateway_payment_id: "req-old", gateway_checkout_url: "https://pay.test/old", gateway_checkout_created_at: Date.now() - 5 * 60_000 });
  const handler = makeHandler(db.factory, (k) => fullEnv[k], neverFetch, quickSleep);
  const res = await handler(request());
  assertEquals(await res.json(), { checkout_url: "https://pay.test/old", payment_request_id: "req-old" });
});

Deno.test("an expired stored link is not reused: a new payment request is made", async () => {
  const db = liveDb({ id: "PAY-1", method: "gcash", status: "processing", amount: 250,
    gateway_payment_id: "req-old", gateway_checkout_url: "https://pay.test/old", gateway_checkout_created_at: Date.now() - 2 * 3600_000 });
  const sent = { n: 0 };
  const handler = makeHandler(db.factory, (k) => fullEnv[k], hitpay(sent), quickSleep);
  const res = await handler(request());
  assertEquals(sent.n, 1);
  assertEquals((await res.json()).checkout_url, "https://pay.test/1");
  assertEquals(db.payment.gateway_payment_id, "req-1");
});

Deno.test("a HitPay failure gives the claim back so the next tap can try at once", async () => {
  const db = liveDb({ id: "PAY-1", method: "gcash", status: "pending", amount: 250 });
  const failing = () => Promise.resolve(new Response(JSON.stringify({ message: "nope" }), { status: 422 }));
  const res = await makeHandler(db.factory, (k) => fullEnv[k], failing, quickSleep)(request());
  assertEquals(res.status, 502);
  assertEquals(db.payment.checkout_started_at, null);
  assertEquals(db.calls.includes("rpc:hitpay_release_checkout"), true);
});
