// Request handler of hitpay-create-payment (see index.ts). DORMANT while online
// payment is off by the owner's decision: it refuses before touching HitPay.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export type Env = (name: string) => string | undefined;
export type Sleep = (ms: number) => Promise<void>;
const realSleep: Sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// deno-lint-ignore no-explicit-any
export type ClientFactory = (url: string, key: string, options: any) => any;

/**
 * The request handler, with its outside world passed in (so the off state can be
 * tested without network access): `createClient` is supabase-js's, `env` reads
 * the function's secrets, `fetchFn` reaches HitPay.
 */
export function makeHandler(createClient: ClientFactory, env: Env, fetchFn: typeof fetch = fetch, sleep: Sleep = realSleep) {
  return async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "Please sign in again." }, 401);

  let orderId = "";
  try {
    const body = await req.json();
    orderId = typeof body?.order_id === "string" ? body.order_id.trim() : "";
  } catch (_) {
    return json({ error: "Invalid request." }, 400);
  }
  if (!orderId) return json({ error: "order_id is required." }, 400);

  const supabaseUrl = env("SUPABASE_URL");
  const anonKey = env("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !anonKey) {
    console.error("hitpay-create-payment: missing environment configuration");
    return json({ error: "Online payment is not configured." }, 500);
  }

  // Caller-scoped client: RLS guarantees these rows belong to the caller.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // OWNER DECISION: online payment is OFF (public.payment_settings, migrations
  // 20261017000000 + 20261018000000). Checked FIRST and fail-closed: unless the
  // database answers exactly `true`, no payment page is opened, whatever else is
  // configured. The text shown is the database's own message.
  const { data: onlineEnabled, error: switchError } = await userClient.rpc("online_payment_enabled");
  if (switchError || onlineEnabled !== true) {
    const { data: message } = await userClient.rpc("online_payment_disabled_message");
    return json({
      error: typeof message === "string" && message.trim() !== ""
        ? message
        : "Online payment is unavailable.",
    }, 403);
  }

  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  const apiKey = env("HITPAY_API_KEY");
  const redirectUrl = env("HITPAY_REDIRECT_URL");
  if (!serviceKey || !apiKey || !redirectUrl) {
    console.error("hitpay-create-payment: missing environment configuration");
    return json({ error: "Online payment is not configured." }, 500);
  }

  const { data: order, error: orderError } = await userClient
    .from("orders")
    .select("id, firebase_uid, status, total")
    .eq("id", orderId)
    .maybeSingle();
  if (orderError) {
    console.error("hitpay-create-payment: order lookup failed", orderError.message);
    return json({ error: "Could not load your order." }, 500);
  }
  if (!order) return json({ error: "Order not found." }, 404);
  if (order.status === "cancelled" || order.status === "refunded") {
    return json({ error: "This order can no longer be paid." }, 409);
  }

  const { data: payment, error: paymentError } = await userClient
    .from("payments")
    .select("id, method, status, amount")
    .eq("order_id", orderId)
    .maybeSingle();
  if (paymentError) {
    console.error("hitpay-create-payment: payment lookup failed", paymentError.message);
    return json({ error: "Could not load your payment." }, 500);
  }
  if (!payment) return json({ error: "Payment not found." }, 404);
  if (payment.method === "cash") {
    return json({ error: "This order is paid in cash." }, 409);
  }
  if (!["pending", "processing", "failed"].includes(payment.status)) {
    return json({ error: "This order is already paid." }, 409);
  }

  const adminClient = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // One payment request at a time: hitpay_claim_checkout locks the payment row.
  // A still-fresh link is reused; an expired one never is (HITPAY_LINK_MAX_AGE_MINUTES,
  // default 60: keep it at or below HitPay's own link expiry). When another call
  // (a double tap) is creating the link right now, wait for its result.
  const maxAge = Number(env("HITPAY_LINK_MAX_AGE_MINUTES") ?? "60");
  let claim: Record<string, unknown> | null = null;
  for (let tries = 0; tries < 5; tries++) {
    const { data, error: claimError } = await adminClient.rpc("hitpay_claim_checkout", {
      p_order_id: order.id,
      p_max_age_minutes: Number.isFinite(maxAge) && maxAge > 0 ? Math.floor(maxAge) : 60,
    });
    if (claimError) {
      console.error("hitpay-create-payment: could not claim checkout", claimError.message);
      return json({ error: "Could not start the payment. Please try again." }, 500);
    }
    claim = data && typeof data === "object" ? data as Record<string, unknown> : null;
    if (claim?.action !== "busy") break;
    await sleep(1000);
  }
  if (claim?.action === "reuse") {
    return json({ checkout_url: claim.checkout_url, payment_request_id: claim.payment_request_id });
  }
  if (claim?.action === "closed") return json({ error: "This order is already paid." }, 409);
  if (claim?.action !== "create") {
    return json({ error: "Your payment is still being prepared. Please try again in a moment." }, 409);
  }
  // From here this call holds the claim; give it back if no link gets stored.
  const release = () => adminClient.rpc("hitpay_release_checkout", { p_order_id: order.id });

  const total = Number(order.total);
  if (!Number.isFinite(total) || total <= 0) {
    await release();
    return json({ error: "This order has nothing to pay." }, 409);
  }

  const { data: profile } = await userClient
    .from("customer_profiles")
    .select("full_name, email")
    .eq("firebase_uid", order.firebase_uid)
    .maybeSingle();

  const base = env("HITPAY_ENV") === "live"
    ? "https://api.hit-pay.com"
    : "https://api.sandbox.hit-pay.com";

  const form = new URLSearchParams();
  form.set("amount", total.toFixed(2));
  form.set("currency", "PHP");
  form.set("reference_number", order.id);
  form.set("purpose", `Melai Nuts order ${order.id}`);
  form.set("redirect_url", redirectUrl);
  if (profile?.full_name) form.set("name", profile.full_name);
  if (profile?.email) form.set("email", profile.email);

  let hitpayResponse: Response;
  try {
    hitpayResponse = await fetchFn(`${base}/v1/payment-requests`, {
      method: "POST",
      headers: {
        "X-BUSINESS-API-KEY": apiKey,
        "Content-Type": "application/x-www-form-urlencoded",
        "X-Requested-With": "XMLHttpRequest",
      },
      body: form.toString(),
    });
  } catch (e) {
    console.error("hitpay-create-payment: HitPay unreachable", String(e));
    await release();
    return json({ error: "The payment service is unreachable. Please try again." }, 502);
  }

  const result = await hitpayResponse.json().catch(() => null);
  if (!hitpayResponse.ok || !result?.id || !result?.url) {
    console.error("hitpay-create-payment: HitPay rejected the request", hitpayResponse.status, result?.message ?? "");
    await release();
    return json({ error: "The payment service could not start the payment. Please try again." }, 502);
  }

  const { error: setError } = await adminClient.rpc("hitpay_set_checkout", {
    p_order_id: order.id,
    p_payment_id: String(result.id),
    p_url: String(result.url),
  });
  if (setError) {
    console.error("hitpay-create-payment: could not store checkout", setError.message);
    await release();
    return json({ error: "Could not save the payment. Please try again." }, 500);
  }

  return json({ checkout_url: result.url, payment_request_id: result.id });
};
}
