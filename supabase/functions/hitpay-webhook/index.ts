// HitPay event webhook (payment_request.completed / payment_request.failed).
//
// Format, per https://docs.hitpayapp.com/apis/guide/events :
//   * POST with a JSON body and the header `Hitpay-Signature`, which is the
//     hex HMAC-SHA256 of the RAW body keyed with the webhook's salt
//     (Developers > Webhook Endpoints in the HitPay dashboard; this is the
//     per-webhook salt, not the API-key salt).
//   * payment_request payload: { id, amount, currency, status, reference_number,
//     payments: [{ id, status, payment_type, amount }] }
//
// Deploy with --no-verify-jwt: HitPay does not send a Supabase JWT. The
// signature is the authentication.
//
// Env: HITPAY_SALT (secret). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are
// provided by Supabase.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const encoder = new TextEncoder();

function respond(status: number, body: string): Response {
  return new Response(body, { status });
}

function toHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
}

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return toHex(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
}

// Constant-time comparison of two strings.
function safeEqual(a: string, b: string): boolean {
  const x = encoder.encode(a);
  const y = encoder.encode(b);
  let diff = x.length ^ y.length;
  const length = Math.max(x.length, y.length);
  for (let i = 0; i < length; i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

// Maps HitPay's payment_type onto payments.method codes; anything not clearly
// one of ours is left null so the stored method stays as it was.
function methodCode(paymentType: unknown): string | null {
  const type = typeof paymentType === "string" ? paymentType.toLowerCase() : "";
  if (type.includes("gcash")) return "gcash";
  if (type.includes("maya") || type.includes("paymaya")) return "maya";
  if (type.includes("card")) return "card";
  return null;
}

type HitpayPayment = { id?: unknown; status?: unknown; payment_type?: unknown; amount?: unknown };

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return respond(405, "Method not allowed");

  const salt = Deno.env.get("HITPAY_SALT");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!salt || !supabaseUrl || !serviceKey) {
    console.error("hitpay-webhook: missing environment configuration");
    return respond(500, "Not configured");
  }

  const rawBody = await req.text();
  const signature = (req.headers.get("Hitpay-Signature") ?? "").trim().toLowerCase();
  const expected = await hmacSha256Hex(salt, rawBody);
  if (!signature || !safeEqual(expected, signature)) {
    return respond(401, "Invalid signature");
  }

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(rawBody);
  } catch (_) {
    return respond(400, "Invalid JSON");
  }

  const orderId = typeof payload.reference_number === "string" ? payload.reference_number.trim() : "";
  const status = payload.status;
  if (!orderId) return respond(400, "Missing reference_number");
  if (status !== "completed" && status !== "failed") {
    // Not a result we act on (e.g. pending/expired); acknowledge so HitPay does not retry.
    return respond(200, "Ignored");
  }

  const payments = Array.isArray(payload.payments) ? (payload.payments as HitpayPayment[]) : [];
  const paid = payments.find((p) => p.status === "succeeded") ?? payments[0];
  const gatewayPaymentId = typeof paid?.id === "string"
    ? paid.id
    : typeof payload.id === "string"
    ? payload.id
    : "";

  const adminClient = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  if (status === "completed") {
    const { data: row, error } = await adminClient
      .from("payments")
      .select("amount")
      .eq("order_id", orderId)
      .maybeSingle();
    if (error) {
      console.error("hitpay-webhook: payment lookup failed", error.message);
      return respond(500, "Lookup failed");
    }
    if (!row) return respond(400, "Unknown order");
    const paidAmount = Number(payload.amount);
    if (!Number.isFinite(paidAmount) || Math.round(paidAmount * 100) !== Math.round(Number(row.amount) * 100)) {
      console.error("hitpay-webhook: amount mismatch for order", orderId);
      return respond(400, "Amount mismatch");
    }
    if (typeof payload.currency === "string" && payload.currency.toUpperCase() !== "PHP") {
      console.error("hitpay-webhook: currency mismatch for order", orderId);
      return respond(400, "Currency mismatch");
    }
  }

  const { error } = await adminClient.rpc("hitpay_apply_payment", {
    p_order_id: orderId,
    p_status: status === "completed" ? "success" : "failed",
    p_method: methodCode(paid?.payment_type),
    p_gateway_payment_id: gatewayPaymentId,
    p_reference_number: null,
  });
  if (error) {
    console.error("hitpay-webhook: could not apply payment", error.message);
    // 500 makes HitPay retry the delivery.
    return respond(500, "Could not apply payment");
  }

  return respond(200, "OK");
});
