// Small security helpers shared by email-verification and auth-guard.
// No network, no secrets in here: callers pass the pepper in.

const encoder = new TextEncoder();

/**
 * A uniformly random 6-digit code from the platform CSPRNG. Rejection sampling avoids the
 * modulo bias of `random % 1_000_000` (2^32 is not a multiple of 10^6).
 */
export function generateCode(random: (buf: Uint32Array) => Uint32Array = (b) => crypto.getRandomValues(b)): string {
  const limit = Math.floor(0x1_0000_0000 / 1_000_000) * 1_000_000; // largest multiple of 10^6 below 2^32
  const buf = new Uint32Array(1);
  for (let i = 0; i < 100; i++) {
    const n = random(buf)[0];
    if (n < limit) return String(n % 1_000_000).padStart(6, "0");
  }
  throw new Error("random source failed");
}

function toHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Hex HMAC-SHA256 of `message` keyed with `secret`. Used for codes, e-mails, IPs and device ids. */
export async function hmacHex(secret: string, message: string): Promise<string> {
  if (!secret) throw new Error("missing pepper");
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return toHex(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
}

/** The stored form of a verification code: bound to the account, never the code itself. */
export function codeHash(pepper: string, uid: string, code: string): Promise<string> {
  return hmacHex(pepper, `code:${uid}:${code}`);
}

/** A keyed, one-way id for an e-mail / IP / device / captcha token (no raw values stored). */
export function keyHash(pepper: string, kind: "email" | "ip" | "device" | "captcha", value: string): Promise<string> {
  return hmacHex(pepper, `${kind}:${value}`);
}

/** Constant-time comparison of two strings (length differences are folded in too). */
export function constantTimeEqual(a: string, b: string): boolean {
  const x = encoder.encode(a);
  const y = encoder.encode(b);
  let diff = x.length ^ y.length;
  const length = Math.max(x.length, y.length);
  for (let i = 0; i < length; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

/** Lower-case, trimmed; null when it does not look like an address at all. */
export function normalizeEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const email = raw.trim().toLowerCase();
  if (email.length < 3 || email.length > 254) return null;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  return email;
}

/**
 * The caller's IP. `trustedHeader` (secret AUTH_GUARD_IP_HEADER, default cf-connecting-ip) is
 * read first because the platform edge sets it; x-forwarded-for's first hop is the fallback.
 * Returns null when nothing usable is present (the IP key is then simply not counted).
 */
export function clientIp(req: Request, trustedHeader = "cf-connecting-ip"): string | null {
  const pick = (v: string | null) => {
    const s = (v ?? "").split(",")[0].trim();
    return s.length > 0 && s.length <= 64 && /^[0-9a-fA-F:.]+$/.test(s) ? s : null;
  };
  return pick(req.headers.get(trustedHeader)) ?? pick(req.headers.get("x-forwarded-for")) ?? pick(req.headers.get("x-real-ip"));
}
