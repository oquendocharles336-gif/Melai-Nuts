// deno test supabase/functions/rfid-device-tap/handler_test.ts
import { deviceKeyHash, makeHandler, normalizeUid } from "./handler.ts";

function eq(a: unknown, b: unknown, msg = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const CODE = "MN-RDR-1A2B3C4D";
const KEY = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";

function req(body: unknown, h: Record<string, string> = { "X-Device-Id": CODE, "X-Device-Key": KEY }, method = "POST") {
  return new Request("http://fn.test", {
    method,
    headers: { "Content-Type": "application/json", ...h },
    body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined,
  });
}

function handler(answer: unknown, calls: unknown[] = [], error: unknown = null) {
  return makeHandler({
    tapRpc: (p) => {
      calls.push(p);
      return Promise.resolve({ data: answer, error });
    },
  });
}

Deno.test("UID normalised like the database", () => {
  eq(normalizeUid("04:a1 b2-c3"), "04A1B2C3");
  eq(normalizeUid("12AB"), null);
  eq(normalizeUid(42), null);
});

Deno.test("the key is hashed; the plain key never reaches the database", async () => {
  const calls: Record<string, unknown>[] = [];
  const res = await handler({ result: "synced", message: "Points synced.", points_balance: 12, card_label: "GK-1" }, calls)(
    req({ card_uid: "04a1b2c3" }),
  );
  eq(res.status, 200);
  eq((await res.json()).points_balance, 12);
  eq(calls[0].p_key_hash, await deviceKeyHash(KEY));
  eq(JSON.stringify(calls).includes(KEY), false, "plain key leaked");
  eq(calls[0].p_card_uid, "04A1B2C3");
});

Deno.test("missing / malformed device headers: 401 without a database call", async () => {
  const calls: unknown[] = [];
  eq((await handler({}, calls)(req({ card_uid: "04A1B2C3" }, {}))).status, 401);
  eq((await handler({}, calls)(req({ card_uid: "04A1B2C3" }, { "X-Device-Id": "x", "X-Device-Key": KEY }))).status, 401);
  eq(calls.length, 0);
});

Deno.test("database answers map to HTTP status", async () => {
  eq((await handler({ result: "device_rejected", message: "Wrong" })(req({ card_uid: "04A1B2C3" }))).status, 401);
  eq((await handler({ result: "rate_limited", message: "Wait" })(req({ card_uid: "04A1B2C3" }))).status, 429);
  eq((await handler({ result: "card_taken", message: "x" })(req({ card_uid: "04A1B2C3" }))).status, 200);
  eq((await handler(null, [], { message: "down" })(req({ card_uid: "04A1B2C3" }))).status, 503);
});

Deno.test("bad body and bad UID", async () => {
  eq((await handler({})(req("not json"))).status, 400);
  const r = await handler({})(req({ card_uid: "zz" }));
  eq((await r.json()).result, "invalid_card");
  eq((await handler({})(req(null, undefined, "GET"))).status, 405);
});

Deno.test("burst from one device is cut off before the database", async () => {
  const calls: unknown[] = [];
  let t = 1_000_000;
  const h = makeHandler({
    tapRpc: (p) => {
      calls.push(p);
      return Promise.resolve({ data: { result: "synced" }, error: null });
    },
    now: () => t,
  });
  let last = 0;
  for (let i = 0; i < 45; i++) last = (await h(req({ card_uid: "04A1B2C3" }))).status;
  eq(last, 429);
  eq(calls.length, 40);
  t += 61_000;
  eq((await h(req({ card_uid: "04A1B2C3" }))).status, 200);
});
