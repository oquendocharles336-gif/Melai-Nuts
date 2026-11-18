// The sign-up e-mail code (replaces Firebase's verification link).
//
//   POST /functions/v1/email-verification/send-code    body: {"captcha_token"?: "..."}
//   POST /functions/v1/email-verification/verify-code  body: {"code": "123456", "captcha_token": "..."}
//   Both: Authorization: Bearer <Firebase ID token>
//
// The account (uid) and the address come ONLY from the verified Firebase ID token.
// send-code needs a valid Firebase App Check token (header X-Firebase-AppCheck) or a Turnstile
// captcha token. verify-code always needs a captcha token, checked BEFORE the code (a missing,
// invalid, expired or reused token never uses up a try). A correct code makes Firebase mark the
// e-mail verified (Identity Toolkit accounts:update, the Admin SDK's updateUser).
//
// Deploy with --no-verify-jwt (the tokens are Firebase's, verified here):
//   supabase functions deploy email-verification --no-verify-jwt
//
// Secrets (supabase secrets set ...):
//   FIREBASE_PROJECT_ID, FIREBASE_SERVICE_ACCOUNT       (same as grant-role-claim)
//   FIREBASE_PROJECT_NUMBER                             (App Check issuer; Project settings > General)
//   FIREBASE_APP_CHECK_APP_IDS                          (optional, comma list of allowed app ids)
//   AUTH_CODE_PEPPER                                    (random, 32+ characters; never change casually)
//   TURNSTILE_SECRET_KEY, TURNSTILE_ALLOWED_HOSTNAMES   (Cloudflare Turnstile)
//   SMTP_USER + SMTP_PASSWORD (Gmail App Password)   OR   RESEND_API_KEY + EMAIL_FROM
//   EMAIL_FROM_NAME?, EMAIL_REPLY_TO?                   (see _shared/mailer.ts)
//   EMAIL_LOGO_URL?, EMAIL_FOOTER_ADDRESS?, EMAIL_SUPPORT_CONTACT?
//   AUTH_GUARD_IP_HEADER?                               (default cf-connecting-ip)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { makeHandler } from "./handler.ts";
import { verifyAppCheckToken, verifyFirebaseIdToken } from "../_shared/firebase_token.ts";
import { hostList, verifyCaptcha } from "../_shared/captcha.ts";
import { markEmailVerified } from "../_shared/firebase_admin.ts";
import { mailerFromEnv } from "../_shared/mailer.ts";

const env = (name: string) => Deno.env.get(name);
const projectId = (env("FIREBASE_PROJECT_ID") ?? "").trim();
const admin = createClient(env("SUPABASE_URL") ?? "", env("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(makeHandler({
  env,
  verifyIdToken: (token) => verifyFirebaseIdToken(token, projectId),
  verifyAppCheck: (token) =>
    verifyAppCheckToken(token, (env("FIREBASE_PROJECT_NUMBER") ?? "").trim(), projectId,
      (env("FIREBASE_APP_CHECK_APP_IDS") ?? "").split(",").map((s) => s.trim()).filter(Boolean)),
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
  sendMail: mailerFromEnv(env),
  markEmailVerified: (uid) => markEmailVerified(uid, projectId, env("FIREBASE_SERVICE_ACCOUNT")),
}));
