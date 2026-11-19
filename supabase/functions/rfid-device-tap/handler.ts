// Request handler of rfid-device-tap (see index.ts). An ESP32 + RC522 card reader
// sends the UID of a tapped card; the database decides everything (link to the
// customer whose "Link my card" session is open on this reader, sync the points of
// a linked card, refuse a card of another account).
//
// The reader proves who it is with its own device code + key (X-Device-Id /
// X-Device-Key). The key is hashed here (SHA-256 of "melai-device:" + key) and only
// the hash goes to the database, which compares it with the stored hash. The
// reader never holds the service-role key; this function does.
//
// Answers JSON {result, message, points_balance, card_label}:
//   200  linked | already_linked | synced | unregistered | card_taken | card_blocked |
//        customer_has_card | invalid_card
//   401  device_rejected      400  bad request      405  not POST
//   429  rate_limited         503  database not reachable

export type Env = (name: string) => string | undefined;

export interface TapAnswer {
  result: string;
  message?: string;
  points_balance?: number | null;
  card_label?: string | null;
}

export interface Deps {
  /** Calls public.rfid_device_tap with the service-role key. */
  tapRpc: (params: { p_device_code: string; p_key_hash: string; p_card_uid: string; p_ip: string | null }) =>
    Promise<{ data: unknown; error: unknown }>;
  now?: () => number;
}

const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };

function answer(body: TapAnswer | { result: string; message: string }, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers });
}

export async function deviceKeyHash(key: string): Promise<string> {
  const bytes = new TextEncoder().encode("melai-device:" + key);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** "04:a1 b2-c3" -> "04A1B2C3"; null unless 8–20 hex digits (same rule as the database). */
export function normalizeUid(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const v = raw.toUpperCase().replace(/[\s:\-.]/g, "");
  return /^[0-9A-F]{8,20}$/.test(v) ? v : null;
}

export function clientIp(req: Request): string | null {
  const pick = (v: string | null) => {
    const s = (v ?? "").split(",")[0].trim();
    return s.length > 0 && s.length <= 64 && /^[0-9a-fA-F:.]+$/.test(s) ? s : null;
  };
  return pick(req.headers.get("cf-connecting-ip")) ?? pick(req.headers.get("x-forwarded-for"));
}

const STATUS: Record<string, number> = { device_rejected: 401, rate_limited: 429 };
const KNOWN = new Set([
  "linked", "already_linked", "synced", "unregistered", "card_taken", "card_blocked",
  "customer_has_card", "invalid_card", "device_rejected", "rate_limited",
]);

export function makeHandler(deps: Deps) {
  const now = deps.now ?? (() => Date.now());
  // First line of defence per running instance (the database enforces the real limits).
  const hits = new Map<string, number[]>();
  const limited = (key: string, max: number): boolean => {
    const t = now();
    const list = (hits.get(key) ?? []).filter((x) => t - x < 60_000);
    list.push(t);
    hits.set(key, list);
    if (hits.size > 5000) hits.clear();
    return list.length > max;
  };

  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return answer({ result: "error", message: "Use POST." }, 405);

    const ip = clientIp(req);
    if (ip && limited("ip:" + ip, 120)) {
      return answer({ result: "rate_limited", message: "Too many requests. Wait a minute." }, 429);
    }

    const deviceCode = (req.headers.get("x-device-id") ?? "").trim().toUpperCase();
    const deviceKey = (req.headers.get("x-device-key") ?? "").trim();
    if (!/^MN-RDR-[0-9A-F]{8}$/.test(deviceCode) || deviceKey.length < 32 || deviceKey.length > 128) {
      return answer({ result: "device_rejected", message: "Missing or malformed device code / key." }, 401);
    }
    if (limited("dev:" + deviceCode, 40)) {
      return answer({ result: "rate_limited", message: "Too many taps. Wait a minute." }, 429);
    }

    const text = await req.text();
    if (text.length > 1024) return answer({ result: "error", message: "Request too large." }, 400);
    let body: Record<string, unknown>;
    try {
      const v = JSON.parse(text);
      if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error("not an object");
      body = v as Record<string, unknown>;
    } catch (_) {
      return answer({ result: "error", message: "Send JSON: {\"card_uid\": \"04A1B2C3\"}." }, 400);
    }
    const uid = normalizeUid(body.card_uid);
    if (!uid) return answer({ result: "invalid_card", message: "Card UID must be 8 to 20 hex digits." }, 200);

    let data: unknown, error: unknown;
    try {
      ({ data, error } = await deps.tapRpc({
        p_device_code: deviceCode,
        p_key_hash: await deviceKeyHash(deviceKey),
        p_card_uid: uid,
        p_ip: ip,
      }));
    } catch (e) {
      error = e;
    }
    if (error || !data || typeof data !== "object") {
      console.error("rfid_device_tap failed", error);
      return answer({ result: "error", message: "Server unavailable. Try again." }, 503);
    }
    const a = data as TapAnswer;
    const result = KNOWN.has(a.result) ? a.result : "error";
    return answer({
      result,
      message: typeof a.message === "string" ? a.message : "",
      points_balance: typeof a.points_balance === "number" ? a.points_balance : null,
      card_label: typeof a.card_label === "string" ? a.card_label : null,
    }, result === "error" ? 503 : (STATUS[result] ?? 200));
  };
}
