// Account e-mails without Firebase: password reset, e-mail change, MFA security notice.
//
//   POST /functions/v1/account-email/password-reset/request   {"email", "captcha_token"?}
//   POST /functions/v1/account-email/password-reset/check     {"token"}
//   POST /functions/v1/account-email/password-reset/confirm   {"token", "password"}
//   POST /functions/v1/account-email/email-change/request     {"new_email", "captcha_token"?}  + Bearer <Firebase ID token>
//   POST /functions/v1/account-email/email-change/confirm     {"token"}
//   POST /functions/v1/account-email/email-change/cancel      {"token"}
//   POST /functions/v1/account-email/security-notice/mfa-enrolled {"email", "user_agent"}  (website server)
//        or {"user_agent"?} + Bearer <Firebase ID token>, within 10 min of staff_2fa_confirm
//
// Links point at PUBLIC_SITE_URL/auth/action?mode=resetPassword|confirmEmail|cancelEmailChange&token=…
// (the website page; the app opens the same URL as an Android App Link). Tokens are single use,
// expire (reset 30 min, e-mail change 1 h) and only their HMAC (AUTH_CODE_PEPPER) is stored.
// Requests are limited per e-mail and per IP (migration 20261118050000_account_email_actions.sql).
// The answer to a reset request never says whether the address has an account.
//
// Deploy with --no-verify-jwt (the tokens are Firebase's, verified here):
//   supabase functions deploy account-email --no-verify-jwt
//
// Secrets (supabase secrets set ...), most already set for email-verification / auth-guard:
//   FIREBASE_PROJECT_ID, FIREBASE_SERVICE_ACCOUNT, FIREBASE_PROJECT_NUMBER, FIREBASE_APP_CHECK_APP_IDS?
//   AUTH_CODE_PEPPER, AUTH_GUARD_SERVER_KEY, TURNSTILE_SECRET_KEY, TURNSTILE_ALLOWED_HOSTNAMES
//   RESEND_API_KEY + EMAIL_FROM   (or SMTP_USER + SMTP_PASSWORD), EMAIL_REPLY_TO?
//   EMAIL_LOGO_URL, EMAIL_FOOTER_ADDRESS?, EMAIL_SUPPORT_CONTACT
//   PUBLIC_SITE_URL               NEW: the website's https address, e.g. https://melainuts.com
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { makeHandler } from "./handler.ts";
import { verifyAppCheckToken, verifyFirebaseIdToken } from "../_shared/firebase_token.ts";
import { hostList, verifyCaptcha } from "../_shared/captcha.ts";
import { lookupUidByEmail, updateAccount } from "../_shared/firebase_admin.ts";
import { mailerFromEnv } from "../_shared/mailer.ts";

const env = (name: string) => Deno.env.get(name);
const projectId = (env("FIREBASE_PROJECT_ID") ?? "").trim();
const admin = createClient(env("SUPABASE_URL") ?? "", env("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

// deno-lint-ignore no-explicit-any
const runtime = (globalThis as any).EdgeRuntime as { waitUntil?: (p: Promise<unknown>) => void } | undefined;

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
  lookupUid: (email) => lookupUidByEmail(email, projectId, env("FIREBASE_SERVICE_ACCOUNT")),
  updateAccount: (uid, change) => updateAccount(uid, change, projectId, env("FIREBASE_SERVICE_ACCOUNT")),
  background: (p) => (runtime?.waitUntil ? runtime.waitUntil(p) : p.catch(() => {})),
}));
