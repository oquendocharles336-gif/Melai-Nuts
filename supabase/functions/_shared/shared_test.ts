// deno test supabase/functions/_shared/shared_test.ts
// Code generation, hashing, constant-time compare, captcha answers, Firebase token rules
// (with locally generated keys: no network) and the e-mail template.
import { codeHash, constantTimeEqual, generateCode, keyHash, normalizeEmail } from "./security.ts";
import { verifyCaptcha } from "./captcha.ts";
import { mailerFromEnv, type SmtpConfig, type SmtpMessage } from "./mailer.ts";
import { renderVerificationEmail } from "./email-template.ts";
import { verifyAppCheckToken, verifyFirebaseIdToken } from "./firebase_token.ts";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "npm:jose@5.9.6";

function assertEquals(actual: unknown, expected: unknown, msg = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${msg} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}
async function rejects(p: Promise<unknown>, msg: string) {
  try {
    await p;
  } catch (_) {
    return;
  }
  throw new Error(`expected a rejection: ${msg}`);
}

// --- codes & hashing ------------------------------------------------------------------------
Deno.test("codes are 6 digits, leading zeros kept", () => {
  for (let i = 0; i < 2000; i++) assert(/^\d{6}$/.test(generateCode()), "6 digits");
  assertEquals(generateCode((b) => { b[0] = 42; return b; }), "000042");
});

Deno.test("codes: biased values above the last full block of 10^6 are drawn again", () => {
  const values = [0xFFFFFFFF, 0xFFFFFFF0, 123456];
  assertEquals(generateCode((b) => { b[0] = values.shift()!; return b; }), "123456");
});

Deno.test("hash: keyed, bound to the account, never the code itself", async () => {
  const a = await codeHash("pepper-1".repeat(5), "uid-1", "123456");
  assert(/^[0-9a-f]{64}$/.test(a) && !a.includes("123456"), "hex sha-256");
  assert(a !== await codeHash("pepper-1".repeat(5), "uid-2", "123456"), "other account, other hash");
  assert(a !== await codeHash("pepper-2".repeat(5), "uid-1", "123456"), "other pepper, other hash");
  assertEquals(a, await codeHash("pepper-1".repeat(5), "uid-1", "123456"));
  assert(await keyHash("x".repeat(32), "email", "a@b.c") !== await keyHash("x".repeat(32), "ip", "a@b.c"), "kinds are separated");
});

Deno.test("constant-time compare", () => {
  assert(constantTimeEqual("abc", "abc"), "equal");
  assert(!constantTimeEqual("abc", "abd"), "differs");
  assert(!constantTimeEqual("abc", "abcd"), "length differs");
  assert(!constantTimeEqual("", "a"), "empty");
});

Deno.test("e-mail normalization", () => {
  assertEquals(normalizeEmail("  Ana@Example.COM "), "ana@example.com");
  assertEquals(normalizeEmail("nope"), null);
  assertEquals(normalizeEmail(42), null);
});

// --- captcha --------------------------------------------------------------------------------
function cf(answer: unknown, status = 200): typeof fetch {
  return () => Promise.resolve(new Response(JSON.stringify(answer), { status }));
}

Deno.test("captcha: missing token is reported without calling Cloudflare", async () => {
  const never: typeof fetch = () => { throw new Error("must not call"); };
  assertEquals(await verifyCaptcha({ secret: "s", token: "", action: "sign_in", fetchFn: never }), { ok: false, reason: "missing" });
});

Deno.test("captcha: success, failure, duplicate, wrong action, wrong host, outage", async () => {
  const base = { secret: "s", token: "t", action: "sign_in", hostnames: ["shop.example.com"] };
  assertEquals(await verifyCaptcha({ ...base, fetchFn: cf({ success: true, action: "sign_in", hostname: "shop.example.com" }) }), { ok: true });
  assertEquals(await verifyCaptcha({ ...base, fetchFn: cf({ success: false, "error-codes": ["invalid-input-response"] }) }), { ok: false, reason: "invalid" });
  assertEquals(await verifyCaptcha({ ...base, fetchFn: cf({ success: false, "error-codes": ["timeout-or-duplicate"] }) }), { ok: false, reason: "expired" });
  assertEquals(await verifyCaptcha({ ...base, fetchFn: cf({ success: true, action: "verify_email", hostname: "shop.example.com" }) }), { ok: false, reason: "wrong_action" });
  assertEquals(await verifyCaptcha({ ...base, fetchFn: cf({ success: true, action: "sign_in", hostname: "evil.example" }) }), { ok: false, reason: "wrong_host" });
  assertEquals(await verifyCaptcha({ ...base, fetchFn: cf({}, 500) }), { ok: false, reason: "unavailable" });
  assertEquals(await verifyCaptcha({ ...base, secret: "" }), { ok: false, reason: "unavailable" });
});

Deno.test("captcha: the secret and the token go to siteverify, with the visitor IP", async () => {
  let sent = "";
  const spy: typeof fetch = (_u, init) => { sent = String(init?.body); return Promise.resolve(new Response('{"success":true}')); };
  await verifyCaptcha({ secret: "sec", token: "tok", action: "sign_in", remoteIp: "203.0.113.1", fetchFn: spy });
  const p = new URLSearchParams(sent);
  assertEquals([p.get("secret"), p.get("response"), p.get("remoteip")], ["sec", "tok", "203.0.113.1"]);
  assert((p.get("idempotency_key") ?? "").length === 36, "idempotency key");
});

Deno.test("captcha: a token the website already verified is checked again with the website's key", async () => {
  const keys: string[] = [];
  const spy: typeof fetch = (_u, init) => {
    keys.push(new URLSearchParams(String(init?.body)).get("idempotency_key") ?? "");
    return Promise.resolve(new Response('{"success":true,"action":"send_code"}'));
  };
  const key = "6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5b";
  await verifyCaptcha({ secret: "s", token: "tok", action: "send_code", idempotencyKey: key, fetchFn: spy });
  // Anything that is not a UUID is ignored: a fresh key, so a replayed token still fails at Cloudflare.
  await verifyCaptcha({ secret: "s", token: "tok", action: "send_code", idempotencyKey: "not-a-uuid", fetchFn: spy });
  assertEquals(keys[0], key);
  assert(keys[1] !== "not-a-uuid" && keys[1].length === 36, "a fresh key for a non-UUID");
});

// --- Firebase tokens (local keys) -------------------------------------------------------------
const { publicKey, privateKey } = await generateKeyPair("RS256");
const jwk = { ...(await exportJWK(publicKey)), kid: "k1", alg: "RS256" };
const keys = createLocalJWKSet({ keys: [jwk] });
const now = Math.floor(Date.now() / 1000);
function idToken(claims: Record<string, unknown>, o: { iss?: string; aud?: string; exp?: number } = {}) {
  return new SignJWT({ email: "Ana@Example.com", email_verified: false, auth_time: now - 10, firebase: { sign_in_provider: "password" }, ...claims })
    .setProtectedHeader({ alg: "RS256", kid: "k1" })
    .setIssuer(o.iss ?? "https://securetoken.google.com/melai-test")
    .setAudience(o.aud ?? "melai-test")
    .setSubject("uid-1")
    .setIssuedAt(now - 10)
    .setExpirationTime(o.exp ?? now + 3600)
    .sign(privateKey);
}

Deno.test("ID token: a valid token gives uid, e-mail (lower-cased) and the verified flag", async () => {
  const u = await verifyFirebaseIdToken(await idToken({}), "melai-test", keys);
  const { authTime, ...rest } = u;
  assertEquals(rest, { uid: "uid-1", email: "ana@example.com", emailVerified: false, signInProvider: "password", name: null });
  assert(typeof authTime === "number" || authTime === null, "auth_time passed through for recent-sign-in checks");
});

Deno.test("ID token: other project, wrong issuer, expired, unsigned -> rejected", async () => {
  await rejects(verifyFirebaseIdToken(await idToken({}, { aud: "other-project" }), "melai-test", keys), "audience");
  await rejects(verifyFirebaseIdToken(await idToken({}, { iss: "https://securetoken.google.com/other" }), "melai-test", keys), "issuer");
  await rejects(verifyFirebaseIdToken(await idToken({}, { exp: now - 60 }), "melai-test", keys), "expired");
  const [h, p] = (await idToken({})).split(".");
  await rejects(verifyFirebaseIdToken(`${h}.${p}.`, "melai-test", keys), "no signature");
  await rejects(verifyFirebaseIdToken(await idToken({}), "", keys), "no project configured");
});

Deno.test("App Check token: issuer/audience pinned, app id allow-list", async () => {
  const tok = (aud: string[]) =>
    new SignJWT({}).setProtectedHeader({ alg: "RS256", kid: "k1" })
      .setIssuer("https://firebaseappcheck.googleapis.com/123456").setAudience(aud)
      .setSubject("1:123456:android:abc").setIssuedAt(now).setExpirationTime(now + 3600).sign(privateKey);
  assertEquals(await verifyAppCheckToken(await tok(["projects/123456", "projects/melai-test"]), "123456", "melai-test", [], keys), "1:123456:android:abc");
  await rejects(verifyAppCheckToken(await tok(["projects/999"]), "123456", "melai-test", [], keys), "other project");
  await rejects(verifyAppCheckToken(await tok(["projects/123456"]), "123456", "melai-test", ["1:123456:ios:xyz"], keys), "app not allowed");
});

// --- e-mail template -----------------------------------------------------------------------
Deno.test("template: the code and the expiry are in the subject, HTML and text", () => {
  const m = renderVerificationEmail({ code: "048213", expiresMinutes: 10 });
  assertEquals(m.subject, "Your Melai Nuts verification code: 048213");
  assert(m.html.includes("048 213") && m.text.includes("048213"), "code shown");
  assert(m.html.includes("This code expires in 10 minutes.") && m.text.includes("This code expires in 10 minutes."), "expiry shown");
  assert(m.html.includes("If you didn't request this, you can safely ignore this email.") && m.text.includes("If you didn't request this"), "ignore text");
});

Deno.test("template: no links to click at all, table layout, inline base styles", () => {
  const m = renderVerificationEmail({ code: "123456", expiresMinutes: 10, logoUrl: "https://shop.example.com/apple-touch-icon.png" });
  assert(!/<a\s/i.test(m.html) && !/href=/i.test(m.html), "no links");
  // One <style> only: the optional dark-mode / phone block; every colour is also inline.
  assert((m.html.match(/<style/gi) ?? []).length === 1 && /<table role="presentation"/.test(m.html), "inline CSS, tables");
  assert(m.html.includes('src="https://shop.example.com/apple-touch-icon.png"'), "logo");
});

Deno.test("template: footer values are escaped; non-https logo is ignored; bad codes refused", () => {
  const m = renderVerificationEmail({ code: "123456", expiresMinutes: 1, businessAddress: "<b>Calamba</b>", logoUrl: "http://x/logo.png" });
  assert(m.html.includes("&lt;b&gt;Calamba&lt;/b&gt;") && !m.html.includes("<b>Calamba"), "escaped");
  assert(!m.html.includes("http://x/logo.png"), "plain-http logo dropped");
  assert(m.html.includes("This code expires in 1 minute."), "singular");
  let threw = false;
  try { renderVerificationEmail({ code: "12345", expiresMinutes: 10 }); } catch (_) { threw = true; }
  assert(threw, "5 digits refused");
});

Deno.test("mailer: Gmail SMTP on 465 when SMTP_USER + SMTP_PASSWORD are set", async () => {
  const sent: { c: SmtpConfig; m: SmtpMessage }[] = [];
  const env: Record<string, string> = { SMTP_USER: "shop@gmail.com", SMTP_PASSWORD: "abcd efgh ijkl mnop" };
  const mail = mailerFromEnv((k) => env[k], async (c, m) => { sent.push({ c, m }); });
  await mail("buyer@example.com", { subject: "Code", html: "<p>1</p>", text: "1" });
  assertEquals(sent.length, 1);
  assertEquals(sent[0].c.host, "smtp.gmail.com");
  assertEquals(sent[0].c.port, 465);
  assertEquals(sent[0].c.password, "abcdefghijklmnop");
  assertEquals(sent[0].m.from, "Melai Nuts <shop@gmail.com>");
  assertEquals(sent[0].m.to, "buyer@example.com");
});

Deno.test("mailer: falls back to Resend without SMTP secrets, and refuses when nothing is set", async () => {
  const mail = mailerFromEnv(() => undefined, async () => { throw new Error("smtp must not be used"); });
  let err = "";
  try { await mail("a@b.c", { subject: "s", html: "h", text: "t" }); } catch (e) { err = String(e); }
  assertEquals(err.includes("RESEND_API_KEY"), true);
});
