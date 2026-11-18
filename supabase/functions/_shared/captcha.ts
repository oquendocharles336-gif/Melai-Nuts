// Cloudflare Turnstile, verified on the server (siteverify). The secret key lives only in the
// function secrets (TURNSTILE_SECRET_KEY); the site key is public (app dart-define / website env).
//
// A token is accepted once: Cloudflare rejects most replays itself ("timeout-or-duplicate"),
// but its reuse check is eventually consistent, so callers also record the token's hash with
// public.auth_captcha_redeem() and refuse a second use.

export const SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

export type CaptchaResult =
  | { ok: true }
  | { ok: false; reason: "missing" | "invalid" | "expired" | "wrong_action" | "wrong_host" | "unavailable" };

export type CaptchaOptions = {
  secret: string;
  token: unknown;
  remoteIp?: string | null;
  /** The widget's data-action this endpoint expects (sign_in, send_code, verify_email). */
  action: string;
  /** Hostnames the widget may be served from (empty = not checked). */
  hostnames?: string[];
  fetchFn?: typeof fetch;
};

export async function verifyCaptcha(o: CaptchaOptions): Promise<CaptchaResult> {
  const token = typeof o.token === "string" ? o.token.trim() : "";
  if (!token) return { ok: false, reason: "missing" };
  if (token.length > 2048) return { ok: false, reason: "invalid" };
  if (!o.secret) return { ok: false, reason: "unavailable" };

  const form = new URLSearchParams();
  form.set("secret", o.secret);
  form.set("response", token);
  if (o.remoteIp) form.set("remoteip", o.remoteIp);
  form.set("idempotency_key", crypto.randomUUID());

  let data: Record<string, unknown>;
  try {
    const res = await (o.fetchFn ?? fetch)(SITEVERIFY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) return { ok: false, reason: "unavailable" };
    data = await res.json();
  } catch (_) {
    return { ok: false, reason: "unavailable" };
  }
  if (data.success !== true) {
    const codes = Array.isArray(data["error-codes"]) ? data["error-codes"] as unknown[] : [];
    return { ok: false, reason: codes.includes("timeout-or-duplicate") ? "expired" : "invalid" };
  }
  if (typeof data.action === "string" && data.action !== "" && data.action !== o.action) {
    return { ok: false, reason: "wrong_action" };
  }
  const hosts = (o.hostnames ?? []).filter((h) => h !== "");
  if (hosts.length > 0 && !(typeof data.hostname === "string" && hosts.includes(data.hostname.toLowerCase()))) {
    return { ok: false, reason: "wrong_host" };
  }
  return { ok: true };
}

/** TURNSTILE_ALLOWED_HOSTNAMES="shop.example.com,www.example.com" -> list. */
export function hostList(raw: string | undefined): string[] {
  return (raw ?? "").split(",").map((h) => h.trim().toLowerCase()).filter((h) => h !== "");
}
