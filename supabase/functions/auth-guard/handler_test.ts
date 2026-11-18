// deno test supabase/functions/auth-guard/handler_test.ts
// The sign-in counter and its captcha gate, with fakes for Firebase, Turnstile and the
// database (the SQL itself: supabase/tests/auth_codes_and_sign_in_guard_test.sql).
import { type Deps, makeHandler } from "./handler.ts";

function assertEquals(actual: unknown, expected: unknown, msg = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${msg} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const PEPPER = "q".repeat(40);
const SERVER_KEY = "s".repeat(40);

function fakeDb() {
  const attempts: { type: string; hash: string }[] = [];
  const tokens = new Set<string>();
  const count = (type: string, hash: unknown) => hash ? attempts.filter((a) => a.type === type && a.hash === hash).length : 0;
  const rpc: Deps["rpc"] = (fn, a) => {
    if (fn === "auth_sign_in_attempt") {
      const required = [count("email", a.p_email_hash), count("ip", a.p_ip_hash), count("device", a.p_device_hash)].some((n) => n >= 15);
      if (required && a.p_captcha_ok !== true) return Promise.resolve({ data: { allowed: false, captcha_required: true }, error: null });
      for (const [type, hash] of [["email", a.p_email_hash], ["ip", a.p_ip_hash], ["device", a.p_device_hash]]) {
        if (hash) attempts.push({ type: String(type), hash: String(hash) });
      }
      return Promise.resolve({ data: { allowed: true, captcha_required: required }, error: null });
    }
    if (fn === "auth_sign_in_succeeded") {
      for (let i = attempts.length - 1; i >= 0; i--) {
        const x = attempts[i];
        if ((x.type === "email" && x.hash === a.p_email_hash) || (x.type === "device" && x.hash === a.p_device_hash)) attempts.splice(i, 1);
      }
      return Promise.resolve({ data: null, error: null });
    }
    if (fn === "auth_captcha_redeem") {
      const t = String(a.p_token_hash);
      if (tokens.has(t)) return Promise.resolve({ data: false, error: null });
      tokens.add(t);
      return Promise.resolve({ data: true, error: null });
    }
    return Promise.resolve({ data: null, error: { message: "unknown" } });
  };
  return { rpc, attempts };
}

function setup() {
  const db = fakeDb();
  const seenIps: (string | null)[] = [];
  const handler = makeHandler({
    env: (k) => ({ AUTH_CODE_PEPPER: PEPPER, AUTH_GUARD_SERVER_KEY: SERVER_KEY })[k],
    verifyIdToken: (t) => t === "good" ? Promise.resolve({ uid: "u1", email: "Ana@Example.com", emailVerified: true, signInProvider: "password" }) : Promise.reject(new Error("bad")),
    verifyCaptcha: (token, action, ip) => {
      seenIps.push(ip);
      if (typeof token !== "string" || token === "") return Promise.resolve({ ok: false, reason: "missing" });
      if (action !== "sign_in") return Promise.resolve({ ok: false, reason: "wrong_action" });
      return Promise.resolve(token.startsWith("ok-") ? { ok: true } : { ok: false, reason: "invalid" });
    },
    rpc: db.rpc,
  });
  const call = (path: string, body: unknown, headers: Record<string, string> = {}) =>
    handler(new Request(`http://fn.test/functions/v1/auth-guard${path}`, {
      method: "POST", headers: { "Content-Type": "application/json", "cf-connecting-ip": "203.0.113.7", ...headers }, body: JSON.stringify(body),
    }));
  return { db, call, seenIps };
}

const fail14 = async (s: ReturnType<typeof setup>, email = "ana@example.com", extra: Record<string, unknown> = {}) => {
  for (let i = 0; i < 15; i++) await s.call("/sign-in/precheck", { email, device_id: `device-${i}xxxx`, ...extra });
};

Deno.test("an invalid e-mail -> 400", async () => {
  const s = setup();
  assertEquals((await s.call("/sign-in/precheck", { email: "not-an-email" })).status, 400);
});

Deno.test("under 15 attempts: allowed without captcha, every attempt counted", async () => {
  const s = setup();
  for (let i = 0; i < 15; i++) {
    const res = await s.call("/sign-in/precheck", { email: "ana@example.com" });
    assertEquals(await res.json(), { allowed: true, captcha_required: false }, `attempt ${i + 1}`);
  }
  assertEquals(s.db.attempts.filter((a) => a.type === "email").length, 15);
});

Deno.test("after 15 attempts: 428 until a captcha is solved; never a lockout", async () => {
  const s = setup();
  await fail14(s);
  const gated = await s.call("/sign-in/precheck", { email: "ana@example.com" });
  assertEquals([gated.status, (await gated.json()).code], [428, "captcha_required"]);
  const ok = await s.call("/sign-in/precheck", { email: "ana@example.com", captcha_token: "ok-1" });
  assertEquals(await ok.json(), { allowed: true, captcha_required: true });
});

Deno.test("normalized e-mail: case and spaces do not get around the counter", async () => {
  const s = setup();
  await fail14(s, "  ANA@Example.COM ");
  assertEquals((await s.call("/sign-in/precheck", { email: "ana@example.com" })).status, 428);
});

Deno.test("invalid or reused captcha -> 400 captcha_invalid", async () => {
  const s = setup();
  await fail14(s);
  const bad = await s.call("/sign-in/precheck", { email: "ana@example.com", captcha_token: "forged" });
  assertEquals([bad.status, (await bad.json()).code], [400, "captcha_invalid"]);
  await s.call("/sign-in/precheck", { email: "ana@example.com", captcha_token: "ok-once" });
  const again = await s.call("/sign-in/precheck", { email: "ana@example.com", captcha_token: "ok-once" });
  assertEquals([again.status, (await again.json()).code], [400, "captcha_invalid"]);
});

Deno.test("15 attempts from one IP over many e-mails -> captcha for any e-mail from that IP", async () => {
  const s = setup();
  for (let i = 0; i < 15; i++) await s.call("/sign-in/precheck", { email: `user${i}@example.com` });
  assertEquals((await s.call("/sign-in/precheck", { email: "fresh@example.com" })).status, 428);
  const other = await s.call("/sign-in/precheck", { email: "fresh@example.com" }, { "cf-connecting-ip": "198.51.100.1" });
  assertEquals(other.status, 200);
});

Deno.test("a successful sign-in (verified ID token) resets that e-mail's counter", async () => {
  const s = setup();
  await fail14(s, "ana@example.com", {});
  assertEquals((await s.call("/sign-in/success", {}, { Authorization: "Bearer good" })).status, 200);
  const res = await s.call("/sign-in/precheck", { email: "ana@example.com" }, { "cf-connecting-ip": "198.51.100.9" });
  assertEquals(await res.json(), { allowed: true, captcha_required: false });
});

Deno.test("reset needs a real Firebase ID token", async () => {
  const s = setup();
  assertEquals((await s.call("/sign-in/success", {})).status, 401);
  assertEquals((await s.call("/sign-in/success", {}, { Authorization: "Bearer forged" })).status, 401);
});

Deno.test("the website server may pass the visitor IP only with the server key", async () => {
  const s = setup();
  for (let i = 0; i < 15; i++) {
    await s.call("/sign-in/precheck", { email: `w${i}@example.com` }, { "X-Guard-Server-Key": SERVER_KEY, "X-Client-IP": "192.0.2.50" });
  }
  // Same visitor IP through the website: gated.
  assertEquals((await s.call("/sign-in/precheck", { email: "x@example.com" }, { "X-Guard-Server-Key": SERVER_KEY, "X-Client-IP": "192.0.2.50" })).status, 428);
  // A forged header without the key is ignored: the connection IP is used instead.
  const forged = await s.call("/sign-in/precheck", { email: "y@example.com" }, { "X-Guard-Server-Key": "wrong", "X-Client-IP": "192.0.2.50", "cf-connecting-ip": "198.51.100.77" });
  assertEquals(forged.status, 200);
});
