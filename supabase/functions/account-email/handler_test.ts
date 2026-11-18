// deno test supabase/functions/account-email/handler_test.ts
// The whole flow with every outside service faked: Firebase, the database functions, the mailer.
import { deviceLabel, linkHash, makeHandler, maskEmail, passwordProblem, type Deps } from "./handler.ts";
import type { RenderedEmail } from "../_shared/email-template.ts";
import type { AccountChange } from "../_shared/firebase_admin.ts";

function assertEquals(actual: unknown, expected: unknown, msg = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${msg} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

const PEPPER = "p".repeat(40);
const SERVER_KEY = "k".repeat(40);
const SITE = "https://shop.example.com";

type Token = { kind: string; uid: string; email: string; new_email: string | null; hash: string; request: number; used: boolean; expired: boolean };

function setup(opts: { accounts?: Record<string, string>; authAgeSeconds?: number; captchaOk?: boolean; mfaRecent?: Record<string, string> } = {}) {
  const accounts = new Map(Object.entries(opts.accounts ?? { "ana@example.com": "uid-ana" }));
  const tokens: Token[] = [];
  const sends: Array<{ kind: string; email_hash: string }> = [];
  const mails: Array<{ to: string; mail: RenderedEmail }> = [];
  const updates: Array<{ uid: string; change: AccountChange }> = [];
  const pending: Promise<unknown>[] = [];
  const profileEmails = new Map<string, string>();
  // uid => e-mail of staff who confirmed 2FA in the last 10 minutes
  const mfaRecent = new Map<string, string>(Object.entries(opts.mfaRecent ?? { "uid-ana": "ana@example.com" }));
  let req = 0;
  let next = 0;
  const now = new Date("2026-11-18T07:41:00Z");

  const deps: Deps = {
    env: (n) => ({ AUTH_CODE_PEPPER: PEPPER, PUBLIC_SITE_URL: SITE + "/", AUTH_GUARD_SERVER_KEY: SERVER_KEY } as Record<string, string>)[n],
    verifyIdToken: (t) => t === "good"
      ? Promise.resolve({ uid: "uid-ana", email: "ana@example.com", emailVerified: true, signInProvider: "password", authTime: Math.floor(now.getTime() / 1000) - (opts.authAgeSeconds ?? 30) })
      : Promise.reject(new Error("bad")),
    verifyAppCheck: (t) => t === "app" ? Promise.resolve("app-id") : Promise.reject(new Error("bad")),
    verifyCaptcha: (t) => Promise.resolve(t ? (opts.captchaOk === false ? { ok: false, reason: "invalid" } : { ok: true }) : { ok: false, reason: "missing" }),
    rpc: (fn, a) => {
      const find = (kind: string, hash: string) => tokens.find((t) => t.kind === kind && t.hash === hash);
      const view = (t: Token | undefined) => !t ? { status: "invalid" } : t.used ? { status: "used" } : t.expired ? { status: "expired" }
        : { status: "ok", uid: t.uid, email: t.email, new_email: t.new_email };
      switch (fn) {
        case "auth_captcha_redeem": return Promise.resolve({ data: true, error: null });
        case "auth_action_issue": {
          if (sends.some((s) => s.kind === a.p_kind && s.email_hash === a.p_email_hash)) {
            return Promise.resolve({ data: { ok: false, reason: "cooldown", retry_after: 42 }, error: null });
          }
          sends.push({ kind: String(a.p_kind), email_hash: String(a.p_email_hash) });
          if (a.p_uid && Array.isArray(a.p_tokens)) {
            const r = ++req;
            tokens.filter((t) => t.uid === a.p_uid && t.kind.startsWith(String(a.p_kind).split("_")[0])).forEach((t) => t.used = true);
            for (const t of a.p_tokens as Array<{ kind: string; hash: string }>) {
              tokens.push({ kind: t.kind, uid: String(a.p_uid), email: String(a.p_email), new_email: (a.p_new_email as string) ?? null, hash: t.hash, request: r, used: false, expired: false });
            }
          }
          return Promise.resolve({ data: { ok: true }, error: null });
        }
        case "auth_action_peek": return Promise.resolve({ data: view(find(String(a.p_kind), String(a.p_token_hash))), error: null });
        case "auth_action_consume": {
          const t = find(String(a.p_kind), String(a.p_token_hash));
          const v = view(t);
          if (v.status === "ok" && t) {
            t.used = true;
            tokens.filter((x) => t.kind === "password_reset" ? x.uid === t.uid && x.kind === "password_reset" : x.request === t.request).forEach((x) => x.used = true);
          }
          return Promise.resolve({ data: v, error: null });
        }
        case "auth_action_mfa_recent": return Promise.resolve({ data: mfaRecent.get(String(a.p_uid)) ?? null, error: null });
        case "auth_action_apply_email": profileEmails.set(String(a.p_uid), String(a.p_new_email)); return Promise.resolve({ data: null, error: null });
      }
      return Promise.resolve({ data: null, error: { message: "unknown " + fn } });
    },
    sendMail: (to, mail) => { mails.push({ to, mail }); return Promise.resolve(); },
    lookupUid: (email) => Promise.resolve(accounts.get(email) ?? null),
    updateAccount: (uid, change) => { updates.push({ uid, change }); return Promise.resolve(); },
    background: (p) => { pending.push(p); },
    newToken: () => `tok${String(++next).padStart(3, "0")}`.padEnd(43, "x"),
    now: () => now,
  };
  const handle = makeHandler(deps);
  const call = async (path: string, body: unknown, headers: Record<string, string> = {}) => {
    const res = await handle(new Request(`https://fn.local/functions/v1/account-email/${path}`, {
      method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body),
    }));
    await Promise.all(pending.splice(0));
    return { status: res.status, body: await res.json() };
  };
  const tokenFrom = (text: string) => decodeURIComponent(/token=([^\s&"]+)/.exec(text)![1]);
  return { call, mails, updates, tokens, profileEmails, tokenFrom, mfaRecent };
}

const server = { "X-Guard-Server-Key": SERVER_KEY, "X-Client-Ip": "203.0.113.9" };

Deno.test("reset request: same answer with or without an account; only the account gets an e-mail", async () => {
  const s = setup();
  const known = await s.call("password-reset/request", { email: " Ana@Example.com " }, server);
  const unknown = await s.call("password-reset/request", { email: "ghost@example.com" }, server);
  assertEquals(known.status, 200);
  assertEquals(unknown.status, 200);
  assertEquals(known.body, unknown.body, "no account enumeration");
  assertEquals(s.mails.length, 1);
  assertEquals(s.mails[0].to, "ana@example.com");
  const m = s.mails[0].mail;
  assertEquals(m.subject, "Reset your Melai Nuts password");
  assert(m.text.includes(`${SITE}/auth/action?mode=resetPassword&token=`), "link to our own page");
  assert(!/firebase/i.test(m.html + m.text), "no Firebase wording");
  assert(!m.html.includes("token=tok") || /href="https:\/\/shop\.example\.com\/auth\/action\?mode=resetPassword&amp;token=/.test(m.html), "link only as a button");
  assert(!s.tokens.some((t) => t.hash.startsWith("tok")), "only the hash is stored");
});

Deno.test("reset request: a browser without the website key needs App Check or a captcha", async () => {
  const s = setup();
  assertEquals((await s.call("password-reset/request", { email: "ana@example.com" })).body.code, "captcha_required");
  assertEquals((await s.call("password-reset/request", { email: "ana@example.com" }, { "X-Firebase-AppCheck": "app" })).status, 200);
  const wrongKey = await s.call("password-reset/request", { email: "x@example.com" }, { "X-Guard-Server-Key": "nope".repeat(10) });
  assertEquals(wrongKey.body.code, "captcha_required", "a wrong server key is just a browser");
});

Deno.test("reset request: cooldown per address answers 429 with Retry-After", async () => {
  const s = setup();
  await s.call("password-reset/request", { email: "ana@example.com" }, server);
  const again = await s.call("password-reset/request", { email: "ana@example.com" }, server);
  assertEquals(again.status, 429);
  assertEquals(again.body.code, "cooldown");
});

Deno.test("reset: check does not use the link; confirm sets the password once and ends other sessions", async () => {
  const s = setup();
  await s.call("password-reset/request", { email: "ana@example.com" }, server);
  const token = s.tokenFrom(s.mails[0].mail.text);
  const check = await s.call("password-reset/check", { token });
  assertEquals(check.body.email_masked, "a•••@example.com");
  assertEquals((await s.call("password-reset/check", { token })).status, 200, "still valid after a check");

  const weak = await s.call("password-reset/confirm", { token, password: "short" });
  assertEquals(weak.body.code, "weak_password");
  assertEquals(s.updates.length, 0);
  assertEquals((await s.call("password-reset/check", { token })).status, 200, "a weak password does not use the link up");

  const ok = await s.call("password-reset/confirm", { token, password: "Cashew#2026" });
  assertEquals(ok.body, { reset: true, email: "ana@example.com" });
  assertEquals(s.updates, [{ uid: "uid-ana", change: { password: "Cashew#2026", endSessions: true } }]);
  const reuse = await s.call("password-reset/confirm", { token, password: "Cashew#2027" });
  assertEquals(reuse.body.code, "link_used");
  assertEquals(s.updates.length, 1, "single use");
});

Deno.test("reset: made-up and malformed links are refused without touching Firebase", async () => {
  const s = setup();
  assertEquals((await s.call("password-reset/confirm", { token: "x".repeat(43), password: "Cashew#2026" })).body.code, "link_invalid");
  assertEquals((await s.call("password-reset/check", { token: "../../etc" })).body.code, "link_invalid");
  assertEquals(s.updates.length, 0);
});

Deno.test("e-mail change: confirm link to the NEW address, 'was this you?' to the OLD one; applies only after confirming", async () => {
  const s = setup();
  const r = await s.call("email-change/request", { new_email: "ana.new@example.com" }, { Authorization: "Bearer good", "X-Firebase-AppCheck": "app" });
  assertEquals(r.status, 200);
  assertEquals(s.mails.map((m) => m.to), ["ana.new@example.com", "ana@example.com"]);
  assertEquals(s.mails[0].mail.subject, "Confirm your new Melai Nuts email");
  assertEquals(s.mails[1].mail.subject, "Was this you? Email change requested on Melai Nuts");
  assert(s.mails[1].mail.text.includes("Secure your account"), "secure button");
  assertEquals(s.updates.length, 0, "nothing changes before confirming");

  const confirm = s.tokenFrom(s.mails[0].mail.text);
  const done = await s.call("email-change/confirm", { token: confirm });
  assertEquals(done.body, { changed: true, email: "ana.new@example.com" });
  assertEquals(s.updates, [{ uid: "uid-ana", change: { email: "ana.new@example.com", emailVerified: true, endSessions: true } }]);
  assertEquals(s.profileEmails.get("uid-ana"), "ana.new@example.com");
  const cancel = s.tokenFrom(s.mails[1].mail.text.split("Stop this change:")[1]);
  assertEquals((await s.call("email-change/cancel", { token: cancel })).body.code, "link_used", "confirmed: cancel link closed");
});

Deno.test("e-mail change: the old address can stop it", async () => {
  const s = setup();
  await s.call("email-change/request", { new_email: "ana.new@example.com" }, { Authorization: "Bearer good", "X-Firebase-AppCheck": "app" });
  const cancel = s.tokenFrom(s.mails[1].mail.text.split("Stop this change:")[1]);
  assertEquals((await s.call("email-change/cancel", { token: cancel })).body, { cancelled: true });
  const confirm = s.tokenFrom(s.mails[0].mail.text);
  assertEquals((await s.call("email-change/confirm", { token: confirm })).body.code, "link_used");
  assertEquals(s.updates.length, 0);
});

Deno.test("e-mail change: needs a recent sign-in, a real new address, and never reveals a taken one", async () => {
  assertEquals((await setup({ authAgeSeconds: 3600 }).call("email-change/request", { new_email: "n@example.com" }, { Authorization: "Bearer good" })).body.code, "reauth_required");
  assertEquals((await setup().call("email-change/request", { new_email: "n@example.com" }, { Authorization: "Bearer bad" })).body.code, "unauthorized");
  assertEquals((await setup().call("email-change/request", { new_email: "ana@example.com" }, { Authorization: "Bearer good" })).body.code, "same_email");
  const s = setup({ accounts: { "ana@example.com": "uid-ana", "ben@example.com": "uid-ben" } });
  const taken = await s.call("email-change/request", { new_email: "ben@example.com" }, { Authorization: "Bearer good", "X-Firebase-AppCheck": "app" });
  assertEquals(taken.status, 200, "same answer");
  assertEquals(s.mails.length, 0, "nobody is e-mailed");
});

Deno.test("MFA notice: a person's own token works only right after 2FA was confirmed, to their own e-mail", async () => {
  const s = setup();
  assertEquals((await s.call("security-notice/mfa-enrolled", { email: "victim@example.com" })).status, 401, "no token, no key");
  const r = await s.call("security-notice/mfa-enrolled", { email: "victim@example.com" }, { Authorization: "Bearer good" });
  assertEquals(r.status, 200);
  assertEquals(s.mails.map((m) => m.to), ["ana@example.com"], "the body's address is ignored");
  const late = await setup({ mfaRecent: {} }).call("security-notice/mfa-enrolled", {}, { Authorization: "Bearer good" });
  assertEquals(late.body.code, "not_recent");
});

Deno.test("MFA notice: from the website's server, with time and device", async () => {
  const s = setup();
  const ok = await s.call("security-notice/mfa-enrolled", { email: "ana@example.com", user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36" }, server);
  assertEquals(ok.status, 200);
  const m = s.mails[0].mail;
  assertEquals(m.subject, "Security notice: a second sign-in step was added to your Melai Nuts account");
  assert(m.text.includes("Chrome on Windows") && m.text.includes("Nov 18, 2026, 3:41 PM (Philippine time)") && m.text.includes("Secure your account"), "facts + button");
});

Deno.test("not configured without the pepper or an https site", async () => {
  const s = setup();
  const h = makeHandler({ ...({} as Deps), env: () => undefined } as Deps);
  const res = await h(new Request("https://fn.local/functions/v1/account-email/password-reset/request", { method: "POST", body: "{}" }));
  assertEquals((await res.json()).code, "not_configured");
  assert(s, "");
});

Deno.test("helpers: masking, devices, password rules, keyed link hashes", async () => {
  assertEquals(maskEmail("ana@example.com"), "a•••@example.com");
  assertEquals(deviceLabel("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Safari/604.1"), "Safari on iPhone / iPad");
  assertEquals(passwordProblem("Cashew#2026", "ana@example.com"), null);
  assert(passwordProblem("cashew#2026", "ana@example.com") !== null, "needs upper case");
  assert(passwordProblem("Anabelle#2026", "anabelle@example.com") !== null, "not the e-mail");
  const h = await linkHash(PEPPER, "password_reset", "abc");
  assert(/^[0-9a-f]{64}$/.test(h) && h !== await linkHash(PEPPER, "email_change", "abc"), "kind-bound");
});
