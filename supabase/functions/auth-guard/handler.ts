// Request handler of auth-guard (see index.ts): the server-side sign-in counter and its
// captcha gate. Testable without network (handler_test.ts).
import { bearer, corsHeaders, type Env, json, readJson } from "../_shared/http.ts";
import { clientIp, constantTimeEqual, keyHash, normalizeEmail } from "../_shared/security.ts";
import type { CaptchaResult } from "../_shared/captcha.ts";
import type { FirebaseUser } from "../_shared/firebase_token.ts";

export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;

export type Deps = {
  env: Env;
  verifyIdToken: (token: string) => Promise<FirebaseUser>;
  verifyCaptcha: (token: unknown, action: string, remoteIp: string | null) => Promise<CaptchaResult>;
  rpc: Rpc;
};

function fail(status: number, code: string, error: string) {
  return json({ error, code }, status);
}

/** device ids are random strings the client keeps; anything odd is ignored (not counted). */
function deviceId(raw: unknown): string | null {
  return typeof raw === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(raw) ? raw : null;
}

export function makeHandler(deps: Deps) {
  const { env } = deps;
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
    if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
    const path = new URL(req.url).pathname.replace(/\/+$/, "");

    const pepper = env("AUTH_CODE_PEPPER") ?? "";
    if (pepper.length < 32) {
      console.error("auth-guard: AUTH_CODE_PEPPER is missing or shorter than 32 characters");
      return fail(500, "not_configured", "Sign-in protection is not configured.");
    }
    const body = await readJson(req);
    if (body === null) return fail(400, "invalid_request", "Invalid request.");

    // The website's server calls on behalf of its visitors and passes their IP; it proves
    // that with the shared AUTH_GUARD_SERVER_KEY. Anyone else gets their own connection IP.
    const serverKey = env("AUTH_GUARD_SERVER_KEY") ?? "";
    const fromServer = serverKey.length >= 32 && constantTimeEqual(req.headers.get("X-Guard-Server-Key") ?? "", serverKey);
    const ip = fromServer ? (req.headers.get("X-Client-IP") ?? "").trim() || null : clientIp(req, env("AUTH_GUARD_IP_HEADER") || undefined);
    const ipHash = ip ? await keyHash(pepper, "ip", ip) : null;
    const device = deviceId(body.device_id);
    const deviceHash = device ? await keyHash(pepper, "device", device) : null;

    if (path.endsWith("/sign-in/precheck")) {
      const email = normalizeEmail(body.email);
      // Same answer shape whatever the address: nothing here says whether an account exists.
      if (!email) return fail(400, "invalid_email", "Please enter a valid email address.");
      const emailHash = await keyHash(pepper, "email", email);

      const first = await deps.rpc("auth_sign_in_attempt", {
        p_email_hash: emailHash, p_ip_hash: ipHash, p_device_hash: deviceHash, p_captcha_ok: false,
      });
      if (first.error) {
        console.error("auth-guard: attempt failed", first.error.message);
        return fail(500, "guard_failed", "Please try again.");
      }
      const r = (first.data ?? {}) as Record<string, unknown>;
      if (r.allowed === true) return json({ allowed: true, captcha_required: r.captcha_required === true });

      // 15+ recent attempts: a captcha is needed. A solved one always lets the attempt through.
      const captcha = await deps.verifyCaptcha(body.captcha_token, "sign_in", ip);
      if (!captcha.ok) {
        if (captcha.reason === "missing") return fail(428, "captcha_required", "Please complete the security check.");
        if (captcha.reason === "unavailable") return fail(503, "captcha_unavailable", "The security check is unavailable. Please try again.");
        return fail(400, "captcha_invalid", captcha.reason === "expired"
          ? "The security check expired. Please do it again."
          : "The security check failed. Please try again.");
      }
      const redeemed = await deps.rpc("auth_captcha_redeem", { p_token_hash: await keyHash(pepper, "captcha", String(body.captcha_token)) });
      if (redeemed.error || redeemed.data !== true) {
        return fail(400, "captcha_invalid", "The security check was already used. Please do it again.");
      }
      const second = await deps.rpc("auth_sign_in_attempt", {
        p_email_hash: emailHash, p_ip_hash: ipHash, p_device_hash: deviceHash, p_captcha_ok: true,
      });
      if (second.error) {
        console.error("auth-guard: attempt failed", second.error.message);
        return fail(500, "guard_failed", "Please try again.");
      }
      return json({ allowed: true, captcha_required: true });
    }

    if (path.endsWith("/sign-in/success")) {
      // Proof of a real sign-in: the Firebase ID token. Its own e-mail is reset, nothing else.
      const token = bearer(req);
      if (!token) return fail(401, "unauthorized", "Please sign in again.");
      let user: FirebaseUser;
      try {
        user = await deps.verifyIdToken(token);
      } catch (_) {
        return fail(401, "unauthorized", "Please sign in again.");
      }
      const email = normalizeEmail(user.email);
      if (!email) return json({ reset: false });
      const { error } = await deps.rpc("auth_sign_in_succeeded", {
        p_email_hash: await keyHash(pepper, "email", email), p_device_hash: deviceHash,
      });
      if (error) {
        console.error("auth-guard: reset failed", error.message);
        return fail(500, "guard_failed", "Please try again.");
      }
      return json({ reset: true });
    }

    return json({ error: "Not found." }, 404);
  };
}
