// Sends an APPROVED online refund back to the customer's GCash / Maya / card
// through the HitPay Refund API (POST /v1/refund), or checks a pending one.
//
//   POST { "refund_id": "RFD-12" }                         -> send
//   POST { "attempt_id": "<uuid>", "action": "check" }      -> re-check a pending refund
//   with the staff member's Authorization header (Firebase ID token).
//
// Every rule lives in the database (supabase/migrations/20261011020000_hitpay_refunds.sql),
// called with the CALLER's token, so only staff allowed to review refunds for that
// branch can send one, and a refund can never be sent twice:
//   staff_begin_gateway_refund -> HitPay -> staff_finish_gateway_refund
// The amount and HitPay payment id come from the database, never from the request.
//
// HitPay answers (https://docs.hitpayapp.com/apis/payment-request/refund):
//   200 { id, payment_id, amount_refunded, status: "succeeded" | ... }
//   4xx -> refused (attempt marked failed, refund stays approved: retry or do it by hand)
//   5xx / timeout -> unknown: the attempt stays "sending" and blocks a second send
//
// Env: HITPAY_API_KEY, HITPAY_ENV ('live' | anything else = sandbox).
// SUPABASE_URL / SUPABASE_ANON_KEY are provided by Supabase.
// Deploy: supabase functions deploy hitpay-refund --no-verify-jwt
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

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

type Outcome = { status: "succeeded" | "pending" | "failed" | "unknown"; refundId?: string; error?: string };

// Maps a HitPay HTTP answer onto what we record.
export function outcomeOf(httpStatus: number, body: Record<string, unknown> | null): Outcome {
  if (httpStatus >= 200 && httpStatus < 300 && body && typeof body.id === "string") {
    const s = String(body.status ?? "").toLowerCase();
    if (s === "succeeded" || s === "success" || s === "completed" || s === "refunded") {
      return { status: "succeeded", refundId: body.id };
    }
    if (s === "failed" || s === "cancelled" || s === "canceled" || s === "rejected") {
      return { status: "failed", refundId: body.id, error: `HitPay refund ${s}` };
    }
    return { status: "pending", refundId: body.id };
  }
  if (httpStatus >= 400 && httpStatus < 500) {
    const msg = typeof body?.message === "string" ? body.message : `HitPay refused the refund (HTTP ${httpStatus}).`;
    return { status: "failed", error: msg.slice(0, 250) };
  }
  return { status: "unknown" };
}

async function finish(client: SupabaseClient, attemptId: string, o: Outcome) {
  return await client.rpc("staff_finish_gateway_refund", {
    p_attempt_id: attemptId,
    p_status: o.status,
    p_gateway_refund_id: o.refundId ?? null,
    p_error: o.error ?? null,
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ error: "Please sign in again." }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const apiKey = Deno.env.get("HITPAY_API_KEY");
  if (!supabaseUrl || !anonKey || !apiKey) {
    console.error("hitpay-refund: missing environment configuration");
    return json({ error: "Online refunds are not configured." }, 500);
  }
  const base = Deno.env.get("HITPAY_ENV") === "live" ? "https://api.hit-pay.com" : "https://api.sandbox.hit-pay.com";

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch (_) {
    return json({ error: "Invalid request." }, 400);
  }

  // Caller-scoped client: the SQL functions check the caller's staff rights.
  const client = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ---- check a pending refund ---------------------------------------------------
  if (body.action === "check") {
    const attemptId = typeof body.attempt_id === "string" ? body.attempt_id : "";
    if (!attemptId) return json({ error: "attempt_id is required." }, 400);
    const { data: list, error } = await client.rpc("staff_refund_gateway_attempts", {
      p_refund_id: typeof body.refund_id === "string" ? body.refund_id : "",
    });
    if (error) return json({ error: error.message }, 403);
    const attempt = (list as Array<Record<string, unknown>>).find((a) => a.attempt_id === attemptId);
    if (!attempt || attempt.status !== "pending" || typeof attempt.gateway_refund_id !== "string") {
      return json({ error: "There is no pending HitPay refund to check." }, 409);
    }
    let res: Response;
    try {
      res = await fetch(`${base}/v1/refund/${encodeURIComponent(attempt.gateway_refund_id)}`, {
        headers: { "X-BUSINESS-API-KEY": apiKey, "X-Requested-With": "XMLHttpRequest" },
        signal: AbortSignal.timeout(20000),
      });
    } catch (_) {
      return json({ error: "HitPay did not answer. Try again in a moment." }, 502);
    }
    const o = outcomeOf(res.status, await res.json().catch(() => null));
    if (o.status === "unknown") return json({ error: "HitPay did not answer. Try again in a moment." }, 502);
    const { data, error: finishError } = await finish(client, attemptId, { ...o, refundId: o.refundId ?? attempt.gateway_refund_id });
    if (finishError) return json({ error: finishError.message }, 409);
    return json(data);
  }

  // ---- send ------------------------------------------------------------------------
  const refundId = typeof body.refund_id === "string" ? body.refund_id.trim() : "";
  if (!refundId) return json({ error: "refund_id is required." }, 400);

  const { data: attempt, error: beginError } = await client.rpc("staff_begin_gateway_refund", { p_refund_id: refundId });
  if (beginError) return json({ error: beginError.message }, 409);
  const a = attempt as { attempt_id: string; amount: number; gateway_payment_id: string };

  let res: Response;
  try {
    res = await fetch(`${base}/v1/refund`, {
      method: "POST",
      headers: { "X-BUSINESS-API-KEY": apiKey, "Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest" },
      body: JSON.stringify({ payment_id: a.gateway_payment_id, amount: Number(a.amount) }),
      signal: AbortSignal.timeout(25000),
    });
  } catch (e) {
    console.error("hitpay-refund: no answer from HitPay", String(e));
    return json({
      error: "HitPay did not answer. The refund may or may not have been sent: check the HitPay dashboard before trying again.",
      attempt_id: a.attempt_id,
    }, 502);
  }

  const o = outcomeOf(res.status, await res.json().catch(() => null));
  if (o.status === "unknown") {
    console.error("hitpay-refund: HitPay server error", res.status);
    return json({
      error: "HitPay had a problem (HTTP " + res.status + "). Check the HitPay dashboard before trying again.",
      attempt_id: a.attempt_id,
    }, 502);
  }
  const { data, error: finishError } = await finish(client, a.attempt_id, o);
  if (finishError) {
    console.error("hitpay-refund: could not record the result", finishError.message);
    return json({ error: "The refund result could not be saved. Check the HitPay dashboard.", attempt_id: a.attempt_id }, 500);
  }
  return json(data, o.status === "failed" ? 422 : 200);
});
