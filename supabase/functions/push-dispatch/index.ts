// push-dispatch — sends the push outbox (public.push_outbox) through Firebase
// Cloud Messaging. Called on a schedule (docs/PUSH_NOTIFICATIONS.md), never by
// the app. Deploy with:  supabase functions deploy push-dispatch --no-verify-jwt
// (the caller proves itself with the x-dispatch-secret header).
//
// Secrets: PUSH_DISPATCH_SECRET (24+ random characters), FIREBASE_PROJECT_ID,
// FIREBASE_SERVICE_ACCOUNT (service-account JSON with the "Firebase Cloud
// Messaging API Admin" role). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are
// provided by Supabase.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@5.9.6";
import { makeHandler } from "./handler.ts";

type ServiceAccount = { client_email: string; private_key: string };
let cached: { token: string; exp: number } | null = null;

async function accessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.exp - 60 > now) return cached.token;
  const sa = JSON.parse(Deno.env.get("FIREBASE_SERVICE_ACCOUNT") ?? "{}") as ServiceAccount;
  if (!sa.client_email || !sa.private_key) throw new Error("FIREBASE_SERVICE_ACCOUNT is not set");
  const key = await importPKCS8(sa.private_key, "RS256");
  const assertion = await new SignJWT({ scope: "https://www.googleapis.com/auth/firebase.messaging" })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(sa.client_email).setSubject(sa.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now).setExpirationTime(now + 3600)
    .sign(key);
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  if (!res.ok) throw new Error(`token endpoint ${res.status}`);
  const data = await res.json();
  cached = { token: data.access_token, exp: now + (data.expires_in ?? 3600) };
  return data.access_token;
}

const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(makeHandler({
  env: (name) => Deno.env.get(name),
  rpc: async (fn, args) => {
    const { data, error } = await admin.rpc(fn, args);
    return { data, error: error ? { message: error.message } : null };
  },
  accessToken,
}));
