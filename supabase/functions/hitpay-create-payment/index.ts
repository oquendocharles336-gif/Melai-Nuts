// Creates (or reuses) a HitPay hosted-checkout payment request for one order.
//
// POST { "order_id": "<orders.id>" }  with the customer's Authorization header.
// -> 200 { "checkout_url": "...", "payment_request_id": "..." }
//
// Two calls at once (a double tap) never create two payment requests: the payment row is
// claimed first (hitpay_claim_checkout), and the second call waits for the first one's link.
//
// The caller is identified by RLS: the order is read with the caller's own
// token, so only the owner can see it. The amount always comes from the
// database. Writes use the service-role client through the service_role-only
// SQL function hitpay_set_checkout.
//
// Env: HITPAY_API_KEY (secret), HITPAY_ENV ('live' | anything else = sandbox),
// HITPAY_REDIRECT_URL (required when online payment is on), HITPAY_LINK_MAX_AGE_MINUTES (optional,
// default 60: a stored link older than this is never reused; keep it at or below HitPay's expiry). SUPABASE_URL / SUPABASE_ANON_KEY /
// SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
//
// OWNER DECISION: online payment is OFF. While public.payment_settings says so
// (or cannot be read), this function refuses with the database's message.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeHandler } from "./handler.ts";

Deno.serve(makeHandler(createClient, (name) => Deno.env.get(name)));


