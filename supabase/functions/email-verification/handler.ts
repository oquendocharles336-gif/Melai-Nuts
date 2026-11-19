// Request handler of email-verification (see index.ts). Everything from the outside world is
// passed in, so the whole flow is testable without network access (handler_test.ts).
import { bearer, corsHeaders, type Env, json, readJson } from "../_shared/http.ts";
import { clientIp, codeHash, constantTimeEqual, generateCode, keyHash } from "../_shared/security.ts";
import type { CaptchaResult } from "../_shared/captcha.ts";
import type { FirebaseUser } from "../_shared/firebase_token.ts";
import { renderVerificationEmail } from "../_shared/email-template.ts";
import type { SendMail } from "../_shared/mailer.ts";

export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;

export type Deps = {
  env: Env;
  verifyIdToken: (token: string) => Promise<FirebaseUser>;
  /** Resolves to the app id, rejects when the App Check token is not valid. */
  verifyAppCheck: (token: string) => Promise<string>;
  verifyCaptcha: (token: unknown, action: string, remoteIp: string | null, idempotencyKey?: unknown) => Promise<CaptchaResult>;
  rpc: Rpc;
  sendMail: SendMail;
  markEmailVerified: (uid: string) => Promise<void>;
  newCode?: () => string;
};

const CODE_MINUTES = 10;

/**
 * Error answers carry a stable `code` the app and website map to their own text:
 *   captcha_required | captcha_invalid | invalid_code | wrong_code | code_expired | code_used |
 *   too_many_attempts | cooldown | hourly_limit | not_configured | send_failed | verify_failed | unauthorized
 */
function fail(status: number, code: string, error: string, extra: Record<string, unknown> = {}, headers: Record<string, string> = {}) {
  return json({ error, code, ...extra }, status, headers);
}

export function makeHandler(deps: Deps) {
  const { env } = deps;
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
    if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

    const path = new URL(req.url).pathname.replace(/\/+$/, "");
    const route = path.endsWith("/send-code") ? "send" : path.endsWith("/verify-code") ? "verify" : null;
    if (!route) return json({ error: "Not found." }, 404);

    const pepper = env("AUTH_CODE_PEPPER") ?? "";
    if (pepper.length < 32) {
      console.error("email-verification: AUTH_CODE_PEPPER is missing or shorter than 32 characters");
      return fail(500, "not_configured", "Email verification is not configured.");
    }

    // 1. Who? Only from the verified Firebase ID token, never from the body.
    const idToken = bearer(req);
    if (!idToken) return fail(401, "unauthorized", "Please sign in again.");
    let user: FirebaseUser;
    try {
      user = await deps.verifyIdToken(idToken);
    } catch (_) {
      return fail(401, "unauthorized", "Please sign in again.");
    }
    if (!user.email) return fail(400, "no_email", "This account has no email address.");
    if (user.emailVerified) {
      return json(route === "send" ? { sent: false, already_verified: true } : { verified: true, already_verified: true });
    }

    const body = await readJson(req);
    if (body === null) return fail(400, "invalid_request", "Invalid request.");
    const ip = clientIp(req, env("AUTH_GUARD_IP_HEADER") || undefined);

    return route === "send" ? send(deps, req, user, body, ip, pepper) : verify(deps, user, body, ip, pepper);
  };
}

/** A valid captcha (single use) -> null; otherwise the error response to return. */
async function requireCaptcha(
  deps: Deps, token: unknown, action: string, ip: string | null, pepper: string, idempotencyKey?: unknown,
): Promise<Response | null> {
  const result = await deps.verifyCaptcha(token, action, ip, idempotencyKey);
  if (!result.ok) {
    if (result.reason === "missing") return fail(428, "captcha_required", "Please complete the security check.");
    if (result.reason === "unavailable") return fail(503, "captcha_unavailable", "The security check is unavailable. Please try again.");
    return fail(400, "captcha_invalid", result.reason === "expired"
      ? "The security check expired. Please do it again."
      : "The security check failed. Please try again.");
  }
  const { data, error } = await deps.rpc("auth_captcha_redeem", { p_token_hash: await keyHash(pepper, "captcha", String(token)) });
  if (error) {
    console.error("email-verification: captcha redeem failed", error.message);
    return fail(500, "verify_failed", "Please try again.");
  }
  if (data !== true) return fail(400, "captcha_invalid", "The security check was already used. Please do it again.");
  return null;
}

async function send(deps: Deps, req: Request, user: FirebaseUser, body: Record<string, unknown>, ip: string | null, pepper: string) {
  // 2. A real app (App Check) or a person (captcha): sending e-mail is a spam vector.
  const appCheck = (req.headers.get("X-Firebase-AppCheck") ?? "").trim();
  let attested = false;
  if (appCheck) {
    try {
      await deps.verifyAppCheck(appCheck);
      attested = true;
    } catch (_) {
      attested = false;
    }
  }
  if (!attested) {
    // captcha_idempotency_key: the website verified this sign-up token already (same key).
    const problem = await requireCaptcha(deps, body.captcha_token, "send_code", ip, pepper, body.captcha_idempotency_key);
    if (problem) return problem;
  }

  // 3. One code, stored hashed, with cooldown and hourly limits (auth_email_code_issue).
  const code = (deps.newCode ?? generateCode)();
  const hash = await codeHash(pepper, user.uid, code);
  const { data, error } = await deps.rpc("auth_email_code_issue", {
    p_uid: user.uid,
    p_email: user.email,
    p_email_hash: await keyHash(pepper, "email", user.email!),
    p_ip_hash: ip ? await keyHash(pepper, "ip", ip) : null,
    p_code_hash: hash,
  });
  if (error) {
    console.error("email-verification: issue failed", error.message);
    return fail(500, "send_failed", "We could not send the code. Please try again.");
  }
  const issued = (data ?? {}) as Record<string, unknown>;
  if (issued.ok !== true) {
    const wait = Number(issued.retry_after ?? 60);
    return fail(429, issued.reason === "cooldown" ? "cooldown" : "hourly_limit",
      issued.reason === "cooldown" ? "Please wait before asking for a new code." : "Too many codes were requested. Please try again later.",
      { retry_after: wait }, { "Retry-After": String(wait) });
  }

  // 4. The e-mail. If it cannot be sent, the code is discarded so a retry is allowed at once.
  try {
    await deps.sendMail(user.email!, renderVerificationEmail({
      code,
      expiresMinutes: CODE_MINUTES,
      logoUrl: deps.env("EMAIL_LOGO_URL"),
      businessAddress: deps.env("EMAIL_FOOTER_ADDRESS"),
      supportContact: deps.env("EMAIL_SUPPORT_CONTACT") || deps.env("EMAIL_REPLY_TO"),
      siteUrl: deps.env("PUBLIC_SITE_URL"),
      name: user.name,
    }));
  } catch (e) {
    console.error("email-verification: e-mail failed", e instanceof Error ? e.message : e);
    await deps.rpc("auth_email_code_discard", { p_uid: user.uid, p_code_hash: hash });
    return fail(502, "send_failed", "We could not send the code. Please try again.");
  }
  return json({ sent: true, expires_in: CODE_MINUTES * 60, resend_after: 60 });
}

async function verify(deps: Deps, user: FirebaseUser, body: Record<string, unknown>, ip: string | null, pepper: string) {
  const code = typeof body.code === "string" ? body.code.trim() : "";
  if (!/^\d{6}$/.test(code)) return fail(400, "invalid_code", "Please enter the 6-digit code.");

  // 2. The captcha FIRST: without a valid one the code is not even looked at (no try used).
  const problem = await requireCaptcha(deps, body.captcha_token, "verify_email", ip, pepper);
  if (problem) return problem;

  // 3. Count the try, then compare in constant time.
  const { data, error } = await deps.rpc("auth_email_code_begin_verify", { p_uid: user.uid });
  if (error) {
    console.error("email-verification: begin_verify failed", error.message);
    return fail(500, "verify_failed", "We could not verify the code. Please try again.");
  }
  const row = (data ?? {}) as Record<string, unknown>;
  switch (row.status) {
    case "ok":
      break;
    case "used":
      return fail(400, "code_used", "This code was already used. Please request a new one.");
    case "locked":
      return fail(429, "too_many_attempts", "Too many wrong codes. Please request a new one.");
    default:
      return fail(400, "code_expired", "This code has expired. Please request a new one.");
  }
  if (typeof row.email === "string" && row.email !== user.email) {
    return fail(400, "code_expired", "This code has expired. Please request a new one.");
  }
  const stored = String(row.code_hash ?? "");
  const candidate = await codeHash(pepper, user.uid, code);
  if (!constantTimeEqual(candidate, stored)) {
    return fail(400, "wrong_code", "That code is incorrect.", { attempts_left: Number(row.attempts_left ?? 0) });
  }

  // 4. Firebase records the e-mail as verified (rules and RLS read email_verified from it).
  try {
    await deps.markEmailVerified(user.uid);
  } catch (e) {
    console.error("email-verification: marking verified failed", e instanceof Error ? e.message : e);
    return fail(502, "verify_failed", "We could not verify the code. Please try again.");
  }
  // 5. Single use. A parallel request with the same code may have consumed it first; the
  //    e-mail is verified either way.
  await deps.rpc("auth_email_code_consume", { p_uid: user.uid, p_code_hash: stored });
  return json({ verified: true });
}
