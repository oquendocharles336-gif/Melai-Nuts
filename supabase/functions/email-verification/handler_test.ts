// deno test supabase/functions/email-verification/handler_test.ts
// The whole send/verify flow with fakes for Firebase, Turnstile, the database and e-mail.
// The SQL behind the rpc names is tested for real in
// supabase/tests/auth_codes_and_sign_in_guard_test.sql; the fake below mirrors it.
import { type Deps, makeHandler } from "./handler.ts";
import type { FirebaseUser } from "../_shared/firebase_token.ts";
import type { RenderedEmail } from "../_shared/email-template.ts";

function assertEquals(actual: unknown, expected: unknown, msg = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${msg} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

const PEPPER = "p".repeat(40);
const USER: FirebaseUser = { uid: "uid-1", email: "ana@example.com", emailVerified: false, signInProvider: "password" };

type Row = { email: string; hash: string; attempts: number; created: number; expires: number; consumed: boolean };

/** In-memory copy of the SQL functions' rules (10 min, 5 tries, 60 s cooldown, single use). */
function memoryDb() {
  const codes = new Map<string, Row>();
  const tokens = new Set<string>();
  let clock = 1_000_000;
  const calls: string[] = [];
  const rpc: Deps["rpc"] = (fn, a) => {
    calls.push(fn);
    const uid = String(a.p_uid ?? "");
    const r = codes.get(uid);
    switch (fn) {
      case "auth_email_code_issue":
        if (r && !r.consumed && clock - r.created < 60_000) {
          return Promise.resolve({ data: { ok: false, reason: "cooldown", retry_after: 42 }, error: null });
        }
        codes.set(uid, { email: String(a.p_email), hash: String(a.p_code_hash), attempts: 0, created: clock, expires: clock + 600_000, consumed: false });
        return Promise.resolve({ data: { ok: true, expires_in: 600 }, error: null });
      case "auth_email_code_discard":
        if (r && r.hash === a.p_code_hash && !r.consumed) codes.delete(uid);
        return Promise.resolve({ data: null, error: null });
      case "auth_email_code_begin_verify":
        if (!r) return Promise.resolve({ data: { status: "none" }, error: null });
        if (r.consumed) return Promise.resolve({ data: { status: "used" }, error: null });
        if (r.expires <= clock) return Promise.resolve({ data: { status: "expired" }, error: null });
        if (r.attempts >= 5) return Promise.resolve({ data: { status: "locked" }, error: null });
        r.attempts++;
        return Promise.resolve({ data: { status: "ok", code_hash: r.hash, email: r.email, attempts_left: 5 - r.attempts }, error: null });
      case "auth_email_code_consume":
        if (r && r.hash === a.p_code_hash && !r.consumed && r.expires > clock) {
          r.consumed = true;
          return Promise.resolve({ data: true, error: null });
        }
        return Promise.resolve({ data: false, error: null });
      case "auth_captcha_redeem": {
        const t = String(a.p_token_hash);
        if (tokens.has(t)) return Promise.resolve({ data: false, error: null });
        tokens.add(t);
        return Promise.resolve({ data: true, error: null });
      }
    }
    return Promise.resolve({ data: null, error: { message: `unknown rpc ${fn}` } });
  };
  return { rpc, codes, calls, tick: (ms: number) => (clock += ms) };
}

type Setup = {
  user?: FirebaseUser;
  validAppCheck?: boolean;
  mailFails?: boolean;
  env?: Record<string, string>;
};

function setup(o: Setup = {}) {
  const db = memoryDb();
  const mails: { to: string; email: RenderedEmail }[] = [];
  const verified: string[] = [];
  let nextCode = "482913";
  const deps: Deps = {
    env: (k) => ({ AUTH_CODE_PEPPER: PEPPER, ...(o.env ?? {}) })[k],
    verifyIdToken: (t) => t === "good-id-token" ? Promise.resolve(o.user ?? USER) : Promise.reject(new Error("bad token")),
    verifyAppCheck: (t) => o.validAppCheck && t === "good-app-check" ? Promise.resolve("1:123:android:abc") : Promise.reject(new Error("bad app check")),
    // Turnstile stand-in: "ok-*" tokens pass, "expired" is expired, anything else is invalid.
    verifyCaptcha: (token) => {
      if (typeof token !== "string" || token === "") return Promise.resolve({ ok: false, reason: "missing" });
      if (token === "expired") return Promise.resolve({ ok: false, reason: "expired" });
      return Promise.resolve(token.startsWith("ok-") ? { ok: true } : { ok: false, reason: "invalid" });
    },
    rpc: db.rpc,
    sendMail: (to, email) => {
      if (o.mailFails) return Promise.reject(new Error("smtp down"));
      mails.push({ to, email });
      return Promise.resolve();
    },
    markEmailVerified: (uid) => {
      verified.push(uid);
      return Promise.resolve();
    },
    newCode: () => nextCode,
  };
  const handler = makeHandler(deps);
  const call = (path: string, body: unknown, headers: Record<string, string> = { Authorization: "Bearer good-id-token" }) =>
    handler(new Request(`http://fn.test/functions/v1/email-verification${path}`, {
      method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body),
    }));
  return { db, mails, verified, call, setCode: (c: string) => (nextCode = c) };
}

const appCheck = { Authorization: "Bearer good-id-token", "X-Firebase-AppCheck": "good-app-check" };

// --- token verification ------------------------------------------------------------------
Deno.test("no bearer token: 401", async () => {
  const s = setup();
  const res = await s.call("/send-code", {}, {});
  assertEquals(res.status, 401);
  assertEquals((await res.json()).code, "unauthorized");
});

Deno.test("an invalid / other-project Firebase token: 401, nothing stored or sent", async () => {
  const s = setup();
  const res = await s.call("/send-code", { captcha_token: "ok-1" }, { Authorization: "Bearer forged" });
  assertEquals(res.status, 401);
  assertEquals(s.db.calls, []);
  assertEquals(s.mails.length, 0);
});

Deno.test("the e-mail and uid come from the token, never from the body", async () => {
  const s = setup({ validAppCheck: true });
  const res = await s.call("/send-code", { email: "victim@evil.test", uid: "someone-else" }, appCheck);
  assertEquals(res.status, 200);
  assertEquals(s.mails.map((m) => m.to), ["ana@example.com"]);
  assert(s.db.codes.has("uid-1") && !s.db.codes.has("someone-else"), "stored for the token's uid");
});

Deno.test("pepper missing: refuses (500), never stores codes unkeyed", async () => {
  const s = setup({ env: { AUTH_CODE_PEPPER: "short" } });
  assertEquals((await s.call("/send-code", {}, appCheck)).status, 500);
});

Deno.test("already verified: nothing is sent", async () => {
  const s = setup({ user: { ...USER, emailVerified: true }, validAppCheck: true });
  const res = await s.call("/send-code", {}, appCheck);
  assertEquals(await res.json(), { sent: false, already_verified: true });
  assertEquals(s.mails.length, 0);
});

// --- send-code ---------------------------------------------------------------------------
Deno.test("send: neither App Check nor captcha -> 428 captcha_required, nothing sent", async () => {
  const s = setup();
  const res = await s.call("/send-code", {});
  assertEquals(res.status, 428);
  assertEquals((await res.json()).code, "captcha_required");
  assertEquals(s.mails.length, 0);
});

Deno.test("send: an invalid App Check token falls back to the captcha", async () => {
  const s = setup({ validAppCheck: false });
  assertEquals((await s.call("/send-code", {}, appCheck)).status, 428);
  assertEquals((await s.call("/send-code", { captcha_token: "ok-a" }, appCheck)).status, 200);
});

Deno.test("send: a valid App Check token is enough", async () => {
  const s = setup({ validAppCheck: true });
  const res = await s.call("/send-code", {}, appCheck);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { sent: true, expires_in: 600, resend_after: 60 });
});

Deno.test("send: the code is stored only as a keyed hash; the e-mail carries it", async () => {
  const s = setup({ validAppCheck: true });
  await s.call("/send-code", {}, appCheck);
  const row = s.db.codes.get("uid-1")!;
  assert(/^[0-9a-f]{64}$/.test(row.hash) && !row.hash.includes("482913"), "hashed, not plain");
  const mail = s.mails[0].email;
  assertEquals(mail.subject, "Your Melai Nuts verification code: 482913");
  assert(mail.text.includes("482913") && mail.html.includes("482 913"), "code in both parts");
});

Deno.test("send: an invalid captcha -> 400; an expired one -> 400 with its own text", async () => {
  const s = setup();
  const bad = await s.call("/send-code", { captcha_token: "nope" });
  assertEquals([bad.status, (await bad.json()).code], [400, "captcha_invalid"]);
  const old = await s.call("/send-code", { captcha_token: "expired" });
  const j = await old.json();
  assertEquals([old.status, j.code], [400, "captcha_invalid"]);
  assert(j.error.includes("expired"), "says it expired");
});

Deno.test("send: a captcha token is accepted once (replay refused)", async () => {
  const s = setup();
  assertEquals((await s.call("/send-code", { captcha_token: "ok-same" })).status, 200);
  s.db.tick(61_000);
  const again = await s.call("/send-code", { captcha_token: "ok-same" });
  assertEquals([again.status, (await again.json()).code], [400, "captcha_invalid"]);
});

Deno.test("send: resend within 60 s -> 429 cooldown with Retry-After", async () => {
  const s = setup({ validAppCheck: true });
  await s.call("/send-code", {}, appCheck);
  const res = await s.call("/send-code", {}, appCheck);
  assertEquals(res.status, 429);
  assertEquals(res.headers.get("Retry-After"), "42");
  assertEquals((await res.json()).code, "cooldown");
  assertEquals(s.mails.length, 1);
  s.db.tick(61_000);
  assertEquals((await s.call("/send-code", {}, appCheck)).status, 200);
});

Deno.test("send: e-mail failure -> 502 and the code is discarded (retry allowed at once)", async () => {
  const s = setup({ validAppCheck: true, mailFails: true });
  assertEquals((await s.call("/send-code", {}, appCheck)).status, 502);
  assertEquals(s.db.codes.size, 0);
});

// --- verify-code -------------------------------------------------------------------------
async function sent(o: Setup = {}) {
  const s = setup({ validAppCheck: true, ...o });
  await s.call("/send-code", {}, appCheck);
  return s;
}

Deno.test("verify: not 6 digits -> 400 invalid_code, before anything else", async () => {
  const s = await sent();
  for (const code of ["", "12345", "1234567", "12a456", 123456]) {
    const res = await s.call("/verify-code", { code, captcha_token: "ok-x" });
    assertEquals([res.status, (await res.json()).code], [400, "invalid_code"], `code ${JSON.stringify(code)}`);
  }
  assertEquals(s.db.codes.get("uid-1")!.attempts, 0);
});

Deno.test("verify: no captcha -> 428 and the code is NOT checked or used", async () => {
  const s = await sent();
  const res = await s.call("/verify-code", { code: "482913" });
  assertEquals([res.status, (await res.json()).code], [428, "captcha_required"]);
  assertEquals(s.db.codes.get("uid-1")!.attempts, 0);
  assertEquals(s.verified, []);
});

Deno.test("verify: invalid / expired / reused captcha -> 400, code NOT checked or used", async () => {
  const s = await sent();
  for (const token of ["bad", "expired"]) {
    const res = await s.call("/verify-code", { code: "482913", captcha_token: token });
    assertEquals([res.status, (await res.json()).code], [400, "captcha_invalid"]);
  }
  await s.call("/verify-code", { code: "000000", captcha_token: "ok-reuse" }); // one real try
  const reused = await s.call("/verify-code", { code: "482913", captcha_token: "ok-reuse" });
  assertEquals([reused.status, (await reused.json()).code], [400, "captcha_invalid"]);
  const row = s.db.codes.get("uid-1")!;
  assertEquals([row.attempts, row.consumed], [1, false]);
  assertEquals(s.verified, []);
});

Deno.test("verify: wrong code -> 400 wrong_code with tries left; 6th try -> 429", async () => {
  const s = await sent();
  for (let i = 1; i <= 5; i++) {
    const res = await s.call("/verify-code", { code: "111111", captcha_token: `ok-w${i}` });
    const j = await res.json();
    assertEquals([res.status, j.code, j.attempts_left], [400, "wrong_code", 5 - i]);
  }
  const locked = await s.call("/verify-code", { code: "482913", captcha_token: "ok-w6" });
  assertEquals([locked.status, (await locked.json()).code], [429, "too_many_attempts"]);
  assertEquals(s.verified, []);
});

Deno.test("verify: right code -> Firebase marks the e-mail verified, code consumed", async () => {
  const s = await sent();
  const res = await s.call("/verify-code", { code: "482913", captcha_token: "ok-r" });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { verified: true });
  assertEquals(s.verified, ["uid-1"]);
  assertEquals(s.db.codes.get("uid-1")!.consumed, true);
});

Deno.test("verify: replaying a used code -> 400 code_used", async () => {
  const s = await sent();
  await s.call("/verify-code", { code: "482913", captcha_token: "ok-1" });
  const res = await s.call("/verify-code", { code: "482913", captcha_token: "ok-2" });
  assertEquals([res.status, (await res.json()).code], [400, "code_used"]);
  assertEquals(s.verified, ["uid-1"]);
});

Deno.test("verify: after 10 minutes -> 400 code_expired", async () => {
  const s = await sent();
  s.db.tick(600_001);
  const res = await s.call("/verify-code", { code: "482913", captcha_token: "ok-late" });
  assertEquals([res.status, (await res.json()).code], [400, "code_expired"]);
  assertEquals(s.verified, []);
});

Deno.test("verify: a new code replaces the old one (one active code)", async () => {
  const s = await sent();
  s.db.tick(61_000);
  s.setCode("777777");
  await s.call("/send-code", {}, appCheck);
  const old = await s.call("/verify-code", { code: "482913", captcha_token: "ok-o" });
  assertEquals((await old.json()).code, "wrong_code");
  assertEquals((await s.call("/verify-code", { code: "777777", captcha_token: "ok-n" })).status, 200);
});

Deno.test("verify: no code was ever sent -> 400 code_expired", async () => {
  const s = setup();
  const res = await s.call("/verify-code", { code: "482913", captcha_token: "ok-none" });
  assertEquals([res.status, (await res.json()).code], [400, "code_expired"]);
});

Deno.test("unknown path -> 404, GET -> 405", async () => {
  const s = setup();
  assertEquals((await s.call("/other", {})).status, 404);
  const h = makeHandler({ env: () => PEPPER } as unknown as Deps);
  assertEquals((await h(new Request("http://fn.test/functions/v1/email-verification/send-code"))).status, 405);
});
