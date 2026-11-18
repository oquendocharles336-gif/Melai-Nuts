// Server-side sign-in counter with a captcha gate (the app and the website call it).
//
//   POST /functions/v1/auth-guard/sign-in/precheck  body: {"email", "device_id"?, "captcha_token"?}
//        200 {allowed: true, captcha_required}  -> go on with the Firebase sign-in
//        428 {code: "captcha_required"}         -> show the captcha, call again with its token
//        400 {code: "captcha_invalid"}          -> the token was wrong / expired / reused
//   POST /functions/v1/auth-guard/sign-in/success   Authorization: Bearer <Firebase ID token>
//        body: {"device_id"?}                   -> clears that e-mail's (and device's) counter
//
// Every precheck counts one attempt for the e-mail, the IP and the device (all stored as
// HMACs, rolling 30 minutes). A sign-in that then succeeds clears the e-mail and device
// counters. From 15 attempts on any key, a Turnstile captcha is needed (single use, 5 minutes).
// A captcha is a gate, never a lockout. The answer never depends on whether the account exists.
//
// Deploy:  supabase functions deploy auth-guard --no-verify-jwt
// Secrets: FIREBASE_PROJECT_ID, AUTH_CODE_PEPPER, TURNSTILE_SECRET_KEY,
//          TURNSTILE_ALLOWED_HOSTNAMES, AUTH_GUARD_SERVER_KEY (the website server's key, 32+
//          characters, also in admin/.env), AUTH_GUARD_IP_HEADER? (default cf-connecting-ip).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { makeHandler } from "./handler.ts";
import { verifyFirebaseIdToken } from "../_shared/firebase_token.ts";
import { hostList, verifyCaptcha } from "../_shared/captcha.ts";

const env = (name: string) => Deno.env.get(name);
const projectId = (env("FIREBASE_PROJECT_ID") ?? "").trim();
const admin = createClient(env("SUPABASE_URL") ?? "", env("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(makeHandler({
  env,
  verifyIdToken: (token) => verifyFirebaseIdToken(token, projectId),
  verifyCaptcha: (token, action, remoteIp) =>
    verifyCaptcha({
      secret: env("TURNSTILE_SECRET_KEY") ?? "",
      token,
      action,
      remoteIp,
      hostnames: hostList(env("TURNSTILE_ALLOWED_HOSTNAMES")),
    }),
  rpc: async (fn, args) => {
    const { data, error } = await admin.rpc(fn, args);
    return { data, error: error ? { message: error.message } : null };
  },
}));
