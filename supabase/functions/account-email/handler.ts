// Request handler of account-email (see index.ts). Everything from the outside world is passed
// in, so the whole flow is testable without network access (handler_test.ts).
//
// Replaces Firebase's own account e-mails (password reset, e-mail change, MFA notice) with our
// mailer and our single-use links. Firebase stays the identity: the password / e-mail is changed
// server-side with the Firebase Admin credentials, never from a client.
import { bearer, corsHeaders, type Env, json, readJson } from "../_shared/http.ts";
import { clientIp, constantTimeEqual, hmacHex, keyHash, normalizeEmail } from "../_shared/security.ts";
import type { CaptchaResult } from "../_shared/captcha.ts";
import type { FirebaseUser } from "../_shared/firebase_token.ts";
import type { AccountChange, AccountRef } from "../_shared/firebase_admin.ts";
import {
  type Brand,
  formatWhen,
  renderEmailChangeConfirmEmail,
  renderEmailChangeNoticeEmail,
  renderMfaEnrolledEmail,
  renderPasswordResetEmail,
} from "../_shared/email-template.ts";
import type { SendMail } from "../_shared/mailer.ts";

export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;

export type Deps = {
  env: Env;
  verifyIdToken: (token: string) => Promise<FirebaseUser>;
  verifyAppCheck: (token: string) => Promise<string>;
  verifyCaptcha: (token: unknown, action: string, remoteIp: string | null) => Promise<CaptchaResult>;
  rpc: Rpc;
  sendMail: SendMail;
  /** The account for an address (uid + display name for the greeting), or null. */
  lookupAccount: (email: string) => Promise<AccountRef | null>;
  updateAccount: (uid: string, change: AccountChange) => Promise<void>;
  /** Runs work after the answer (EdgeRuntime.waitUntil); tests await it. */
  background?: (p: Promise<unknown>) => void;
  newToken?: () => string;
  now?: () => Date;
};

export const RESET_MINUTES = 30;
export const CHANGE_MINUTES = 60;
const RECENT_SIGN_IN_SECONDS = 10 * 60;
const PASSWORD_MIN = 8;
const PASSWORD_MAX = 64;

/**
 * Error answers carry a stable `code` the app and website map to their own text:
 *   not_configured | invalid_request | invalid_email | captcha_required | captcha_invalid |
 *   captcha_unavailable | cooldown | hourly_limit | unauthorized | reauth_required | same_email |
 *   link_invalid | link_expired | link_used | weak_password | email_taken | not_recent | failed
 */
function fail(status: number, code: string, error: string, extra: Record<string, unknown> = {}, headers: Record<string, string> = {}) {
  return json({ error, code, ...extra }, status, headers);
}

/** 32 random bytes, base64url (43 characters): the secret part of a link. */
export function newLinkToken(): string {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** The stored form of a link token: keyed, bound to its kind, never the token itself. */
export function linkHash(pepper: string, kind: string, token: string): Promise<string> {
  return hmacHex(pepper, `action:${kind}:${token}`);
}

/** "a•••@gmail.com": shown on the reset page, never the full address to whoever holds the link. */
export function maskEmail(email: string): string {
  const [local, domain] = email.split("@");
  if (!domain) return "•••";
  return `${local.slice(0, 1)}•••@${domain}`;
}

/** "Chrome on Windows" from a User-Agent (no version numbers, nothing identifying). */
export function deviceLabel(ua: string): string {
  const s = ua || "";
  const browser = /Edg\//.test(s) ? "Edge" : /OPR\/|Opera/.test(s) ? "Opera" : /Firefox\//.test(s) ? "Firefox"
    : /Chrome\//.test(s) ? "Chrome" : /Safari\//.test(s) ? "Safari" : /Dart\/|okhttp|CFNetwork/.test(s) ? "Melai Nuts app" : "A browser";
  const os = /Android/.test(s) ? "Android" : /iPhone|iPad|iOS/.test(s) ? "iPhone / iPad" : /Windows/.test(s) ? "Windows"
    : /Mac OS X|Macintosh/.test(s) ? "Mac" : /Linux/.test(s) ? "Linux" : "an unknown device";
  return `${browser} on ${os}`;
}

const TOKEN_RE = /^[A-Za-z0-9_-]{30,100}$/;

export function makeHandler(deps: Deps) {
  const { env } = deps;
  const background = deps.background ?? ((p: Promise<unknown>) => { p.catch(() => {}); });
  const now = deps.now ?? (() => new Date());

  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
    if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

    const path = new URL(req.url).pathname.replace(/\/+$/, "");
    const route = ["password-reset/request", "password-reset/check", "password-reset/confirm",
      "email-change/request", "email-change/confirm", "email-change/cancel", "security-notice/mfa-enrolled"]
      .find((r) => path.endsWith("/" + r));
    if (!route) return json({ error: "Not found." }, 404);

    const pepper = env("AUTH_CODE_PEPPER") ?? "";
    const site = (env("PUBLIC_SITE_URL") ?? "").trim().replace(/\/+$/, "");
    if (pepper.length < 32 || !/^https:\/\//.test(site)) {
      console.error("account-email: AUTH_CODE_PEPPER (32+ chars) or PUBLIC_SITE_URL (https) is missing");
      return fail(500, "not_configured", "Account emails are not configured.");
    }
    const body = await readJson(req);
    if (body === null) return fail(400, "invalid_request", "Invalid request.");

    // The website's server calls on behalf of its visitors and passes their IP; it proves that
    // with the shared AUTH_GUARD_SERVER_KEY (same as auth-guard). Anyone else: their own IP.
    const serverKey = env("AUTH_GUARD_SERVER_KEY") ?? "";
    const fromServer = serverKey.length >= 32 && constantTimeEqual(req.headers.get("X-Guard-Server-Key") ?? "", serverKey);
    const ip = fromServer
      ? (req.headers.get("X-Client-Ip") ?? "").trim().slice(0, 64) || null
      : clientIp(req, env("AUTH_GUARD_IP_HEADER") || undefined);
    const brand: Brand = {
      logoUrl: env("EMAIL_LOGO_URL"),
      businessAddress: env("EMAIL_FOOTER_ADDRESS"),
      supportContact: env("EMAIL_SUPPORT_CONTACT") || env("EMAIL_REPLY_TO"),
      siteUrl: site,
    };
    const ctx = { deps, req, body, ip, pepper, site, brand, fromServer, background, now };

    switch (route) {
      case "password-reset/request": return resetRequest(ctx);
      case "password-reset/check": return resetCheck(ctx);
      case "password-reset/confirm": return resetConfirm(ctx);
      case "email-change/request": return changeRequest(ctx);
      case "email-change/confirm": return changeConfirm(ctx);
      case "email-change/cancel": return changeCancel(ctx);
      default: return mfaNotice(ctx);
    }
  };
}

type Ctx = {
  deps: Deps;
  req: Request;
  body: Record<string, unknown>;
  ip: string | null;
  pepper: string;
  site: string;
  brand: Brand;
  fromServer: boolean;
  background: (p: Promise<unknown>) => void;
  now: () => Date;
};

/** The website's server (key), a real app (App Check) or a person (captcha, single use). */
async function requireHuman(c: Ctx, action: string): Promise<Response | null> {
  if (c.fromServer) return null;
  const appCheck = (c.req.headers.get("X-Firebase-AppCheck") ?? "").trim();
  if (appCheck) {
    try {
      await c.deps.verifyAppCheck(appCheck);
      return null;
    } catch (_) { /* fall through to the captcha */ }
  }
  const token = c.body.captcha_token;
  const result = await c.deps.verifyCaptcha(token, action, c.ip);
  if (!result.ok) {
    if (result.reason === "missing") return fail(428, "captcha_required", "Please complete the security check.");
    if (result.reason === "unavailable") return fail(503, "captcha_unavailable", "The security check is unavailable. Please try again.");
    return fail(400, "captcha_invalid", "The security check failed or expired. Please do it again.");
  }
  const { data, error } = await c.deps.rpc("auth_captcha_redeem", { p_token_hash: await keyHash(c.pepper, "captcha", String(token)) });
  if (error || data !== true) return fail(400, "captcha_invalid", "The security check was already used. Please do it again.");
  return null;
}

function limited(issued: Record<string, unknown>): Response {
  const wait = Number(issued.retry_after ?? 60);
  return fail(429, issued.reason === "cooldown" ? "cooldown" : "hourly_limit",
    issued.reason === "cooldown" ? "Please wait a minute before asking again." : "Too many requests. Please try again later.",
    { retry_after: wait }, { "Retry-After": String(wait) });
}

function linkProblem(status: unknown): Response {
  if (status === "used") return fail(400, "link_used", "This link was already used. Ask for a new one.");
  if (status === "expired") return fail(400, "link_expired", "This link has expired. Ask for a new one.");
  return fail(400, "link_invalid", "This link is not valid. Open the link from the most recent Melai Nuts email.");
}

function sendInBackground(c: Ctx, to: string, mail: ReturnType<typeof renderPasswordResetEmail>, what: string) {
  c.background(c.deps.sendMail(to, mail).catch((e) => {
    console.error(`account-email: ${what} e-mail failed`, e instanceof Error ? e.message : e);
  }));
}

// Exactly the same text for a known and an unknown address (no account enumeration).
export const GENERIC_SENT = "If an account exists for this email, we've sent a reset link. Check your inbox and spam folder.";

// --- Password reset ---------------------------------------------------------------------------

async function resetRequest(c: Ctx): Promise<Response> {
  const email = normalizeEmail(c.body.email);
  if (!email) return fail(400, "invalid_email", "Please enter a valid email address.");
  const human = await requireHuman(c, "reset_password");
  if (human) return human;

  let account: AccountRef | null;
  try {
    account = await c.deps.lookupAccount(email);
  } catch (e) {
    console.error("account-email: lookup failed", e instanceof Error ? e.message : e);
    return fail(503, "failed", "We could not send the email right now. Please try again.");
  }
  const uid = account?.uid ?? null;
  const token = (c.deps.newToken ?? newLinkToken)();
  const { data, error } = await c.deps.rpc("auth_action_issue", {
    p_kind: "password_reset",
    p_uid: uid,
    p_email: email,
    p_new_email: null,
    p_email_hash: await keyHash(c.pepper, "email", email),
    p_ip_hash: c.ip ? await keyHash(c.pepper, "ip", c.ip) : null,
    p_tokens: uid ? [{ kind: "password_reset", hash: await linkHash(c.pepper, "password_reset", token) }] : null,
  });
  if (error) {
    console.error("account-email: issue failed", error.message);
    return fail(500, "failed", "We could not send the email right now. Please try again.");
  }
  const issued = (data ?? {}) as Record<string, unknown>;
  if (issued.ok !== true) return limited(issued);

  // Same answer, and the e-mail goes out after it, whether or not the address has an account.
  if (uid) {
    const url = `${c.site}/auth/action?mode=resetPassword&token=${encodeURIComponent(token)}`;
    sendInBackground(c, email, renderPasswordResetEmail({ ...c.brand, name: account?.name, url, expiresMinutes: RESET_MINUTES }), "reset");
  }
  return json({ sent: true, message: GENERIC_SENT });
}

function tokenOf(c: Ctx): string | null {
  const t = typeof c.body.token === "string" ? c.body.token.trim() : "";
  return TOKEN_RE.test(t) ? t : null;
}

async function resetCheck(c: Ctx): Promise<Response> {
  const token = tokenOf(c);
  if (!token) return linkProblem("invalid");
  const { data, error } = await c.deps.rpc("auth_action_peek", { p_kind: "password_reset", p_token_hash: await linkHash(c.pepper, "password_reset", token) });
  if (error) return fail(500, "failed", "Please try again.");
  const row = (data ?? {}) as Record<string, unknown>;
  if (row.status !== "ok") return linkProblem(row.status);
  return json({ valid: true, email: String(row.email ?? ""), email_masked: maskEmail(String(row.email ?? "")), expires_in: RESET_MINUTES * 60 });
}

/** Same rules as the app (ValidationUtils.validatePassword) and the website (Rules::newPassword). */
export function passwordProblem(pw: string, email: string): string | null {
  if (pw.trim() === "") return "Password cannot be only spaces.";
  if (pw.length < PASSWORD_MIN) return `Password must be at least ${PASSWORD_MIN} characters long.`;
  if (pw.length > PASSWORD_MAX) return `Password cannot exceed ${PASSWORD_MAX} characters.`;
  if (!/[A-Z]/.test(pw) || !/[a-z]/.test(pw)) return "Password must contain upper- and lower-case letters.";
  if (!/[0-9]/.test(pw)) return "Password must contain a number.";
  if (!/[^A-Za-z0-9]/.test(pw)) return "Password must contain a symbol.";
  const local = email.split("@")[0]?.toLowerCase() ?? "";
  if (local.length >= 3 && pw.toLowerCase().includes(local)) return "Password must not contain your email address.";
  return null;
}

async function resetConfirm(c: Ctx): Promise<Response> {
  const token = tokenOf(c);
  if (!token) return linkProblem("invalid");
  const password = typeof c.body.password === "string" ? c.body.password : "";
  const hash = await linkHash(c.pepper, "password_reset", token);

  // Check the link and the password BEFORE using the link up, so a weak password can be retried.
  const peek = await c.deps.rpc("auth_action_peek", { p_kind: "password_reset", p_token_hash: hash });
  if (peek.error) return fail(500, "failed", "Please try again.");
  const seen = (peek.data ?? {}) as Record<string, unknown>;
  if (seen.status !== "ok") return linkProblem(seen.status);
  const weak = passwordProblem(password, String(seen.email ?? ""));
  if (weak) return fail(422, "weak_password", weak);

  // Single use: of two parallel submits exactly one gets here with status ok.
  const { data, error } = await c.deps.rpc("auth_action_consume", { p_kind: "password_reset", p_token_hash: hash });
  if (error) return fail(500, "failed", "Please try again.");
  const row = (data ?? {}) as Record<string, unknown>;
  if (row.status !== "ok") return linkProblem(row.status);
  try {
    // endSessions: every sign-in made with the old password ends (app and website).
    await c.deps.updateAccount(String(row.uid), { password, endSessions: true });
  } catch (e) {
    console.error("account-email: password update failed", e instanceof Error ? e.message : e);
    if ((e as { firebaseCode?: string }).firebaseCode === "WEAK_PASSWORD") {
      return fail(422, "weak_password", "That password is too weak. Ask for a new link and choose a stronger one.");
    }
    return fail(502, "failed", "Your password could not be changed. Ask for a new link and try again.");
  }
  return json({ reset: true, email: String(row.email ?? "") });
}

// --- E-mail change ------------------------------------------------------------------------------

async function changeRequest(c: Ctx): Promise<Response> {
  const idToken = bearer(c.req);
  if (!idToken) return fail(401, "unauthorized", "Please sign in again.");
  let user: FirebaseUser;
  try {
    user = await c.deps.verifyIdToken(idToken);
  } catch (_) {
    return fail(401, "unauthorized", "Please sign in again.");
  }
  // Only right after the password was entered (the app / website re-checks it first).
  const authAge = Math.floor(c.now().getTime() / 1000) - Number(user.authTime ?? 0);
  if (!user.authTime || authAge > RECENT_SIGN_IN_SECONDS) {
    return fail(401, "reauth_required", "Please enter your password again to change your email.");
  }
  const newEmail = normalizeEmail(c.body.new_email);
  if (!newEmail) return fail(400, "invalid_email", "Please enter a valid email address.");
  if (user.email && newEmail === user.email) return fail(400, "same_email", "That is already your email address.");
  const human = await requireHuman(c, "change_email");
  if (human) return human;

  let taken: boolean;
  try {
    taken = (await c.deps.lookupAccount(newEmail)) !== null;
  } catch (e) {
    console.error("account-email: lookup failed", e instanceof Error ? e.message : e);
    return fail(503, "failed", "We could not send the email right now. Please try again.");
  }
  const confirm = (c.deps.newToken ?? newLinkToken)();
  const cancel = (c.deps.newToken ?? newLinkToken)();
  const { data, error } = await c.deps.rpc("auth_action_issue", {
    p_kind: "email_change",
    p_uid: taken ? null : user.uid,
    p_email: user.email ?? "",
    p_new_email: newEmail,
    p_email_hash: await keyHash(c.pepper, "email", user.email ?? user.uid),
    p_ip_hash: c.ip ? await keyHash(c.pepper, "ip", c.ip) : null,
    p_tokens: taken ? null : [
      { kind: "email_change", hash: await linkHash(c.pepper, "email_change", confirm) },
      { kind: "email_change_cancel", hash: await linkHash(c.pepper, "email_change_cancel", cancel) },
    ],
  });
  if (error) {
    console.error("account-email: issue failed", error.message);
    return fail(500, "failed", "We could not send the email right now. Please try again.");
  }
  const issued = (data ?? {}) as Record<string, unknown>;
  if (issued.ok !== true) return limited(issued);

  // An address already used by another account gets nothing (and the answer does not say so).
  if (!taken) {
    sendInBackground(c, newEmail, renderEmailChangeConfirmEmail({
      ...c.brand,
      name: user.name,
      newEmail,
      url: `${c.site}/auth/action?mode=confirmEmail&token=${encodeURIComponent(confirm)}`,
      expiresMinutes: CHANGE_MINUTES,
    }), "change-confirm");
    if (user.email) {
      sendInBackground(c, user.email, renderEmailChangeNoticeEmail({
        ...c.brand,
        name: user.name,
        newEmail,
        cancelUrl: `${c.site}/auth/action?mode=cancelEmailChange&token=${encodeURIComponent(cancel)}`,
        secureUrl: `${c.site}/?panel=reset-password`,
        when: formatWhen(c.now()),
        expiresMinutes: CHANGE_MINUTES,
      }), "change-notice");
    }
  }
  return json({ sent: true, message: `We sent a confirmation link to ${newEmail}. Your email changes after you open it.` });
}

async function changeConfirm(c: Ctx): Promise<Response> {
  const token = tokenOf(c);
  if (!token) return linkProblem("invalid");
  const { data, error } = await c.deps.rpc("auth_action_consume", { p_kind: "email_change", p_token_hash: await linkHash(c.pepper, "email_change", token) });
  if (error) return fail(500, "failed", "Please try again.");
  const row = (data ?? {}) as Record<string, unknown>;
  if (row.status !== "ok") return linkProblem(row.status);
  const uid = String(row.uid), newEmail = String(row.new_email ?? "");
  try {
    // The new address is proven (the link was opened from it): verified, other sign-ins end.
    await c.deps.updateAccount(uid, { email: newEmail, emailVerified: true, endSessions: true });
  } catch (e) {
    console.error("account-email: e-mail update failed", e instanceof Error ? e.message : e);
    if ((e as { firebaseCode?: string }).firebaseCode === "EMAIL_EXISTS") {
      return fail(409, "email_taken", "That email address can't be used. Please choose another one.");
    }
    return fail(502, "failed", "Your email could not be changed. Please ask for a new link.");
  }
  const applied = await c.deps.rpc("auth_action_apply_email", { p_uid: uid, p_new_email: newEmail });
  if (applied.error) console.error("account-email: profile e-mail copy failed", applied.error.message);
  return json({ changed: true, email: newEmail });
}

async function changeCancel(c: Ctx): Promise<Response> {
  const token = tokenOf(c);
  if (!token) return linkProblem("invalid");
  const { data, error } = await c.deps.rpc("auth_action_consume", { p_kind: "email_change_cancel", p_token_hash: await linkHash(c.pepper, "email_change_cancel", token) });
  if (error) return fail(500, "failed", "Please try again.");
  const row = (data ?? {}) as Record<string, unknown>;
  if (row.status !== "ok") return linkProblem(row.status);
  return json({ cancelled: true });
}

// --- Security notice: a second sign-in step was added --------------------------------------------

async function mfaNotice(c: Ctx): Promise<Response> {
  // Two callers: the website's server (key) right after its own 2FA confirm, or the person
  // themselves (Firebase token) — then only if staff_2fa_confirm turned it on in the last
  // 10 minutes (auth_action_mfa_recent), and always to the account's own e-mail.
  let email: string | null;
  let name: string | null = null;
  if (c.fromServer) {
    email = normalizeEmail(c.body.email);
    name = typeof c.body.name === "string" ? c.body.name.slice(0, 100) : null;
    if (!email) return fail(400, "invalid_email", "Please enter a valid email address.");
  } else {
    const idToken = bearer(c.req);
    if (!idToken) return fail(401, "unauthorized", "Not allowed.");
    let user: FirebaseUser;
    try {
      user = await c.deps.verifyIdToken(idToken);
    } catch (_) {
      return fail(401, "unauthorized", "Not allowed.");
    }
    name = user.name ?? null;
    const recent = await c.deps.rpc("auth_action_mfa_recent", { p_uid: user.uid });
    email = normalizeEmail(recent.data);
    if (recent.error || !email) return fail(409, "not_recent", "Two-step sign-in was not just turned on.");
  }
  const { data, error } = await c.deps.rpc("auth_action_issue", {
    p_kind: "mfa_notice", p_uid: null, p_email: email, p_new_email: null,
    p_email_hash: await keyHash(c.pepper, "email", email), p_ip_hash: null, p_tokens: null,
  });
  if (error) return fail(500, "failed", "Please try again.");
  const issued = (data ?? {}) as Record<string, unknown>;
  if (issued.ok !== true) return limited(issued);
  const ua = typeof c.body.user_agent === "string" ? c.body.user_agent.slice(0, 400) : (c.req.headers.get("User-Agent") ?? "");
  sendInBackground(c, email, renderMfaEnrolledEmail({
    ...c.brand,
    name,
    when: formatWhen(c.now()),
    device: deviceLabel(ua),
    secureUrl: `${c.site}/?panel=reset-password`,
  }), "mfa-notice");
  return json({ sent: true });
}
