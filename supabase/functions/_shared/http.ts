// JSON responses with the same CORS headers as the other functions.
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-firebase-appcheck, x-guard-server-key, x-client-ip",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store", ...extra },
  });
}

/** The bearer token of the request, or "" when there is none. */
export function bearer(req: Request): string {
  const h = req.headers.get("Authorization") ?? "";
  return h.startsWith("Bearer ") ? h.slice(7).trim() : "";
}

/** The request body as an object ({} for an empty body); null when it is not JSON. */
export async function readJson(req: Request): Promise<Record<string, unknown> | null> {
  const text = await req.text();
  if (text.trim() === "") return {};
  try {
    const v = JSON.parse(text);
    if (Array.isArray(v) && v.length === 0) return {}; // an empty PHP array arrives as []
    return v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;
  } catch (_) {
    return null;
  }
}

export type Env = (name: string) => string | undefined;
