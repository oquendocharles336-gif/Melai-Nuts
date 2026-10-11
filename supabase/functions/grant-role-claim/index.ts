// Gives the caller's Firebase account the custom claim { role: "authenticated" }.
//
// Why this exists: Supabase maps the `role` claim of the Firebase ID token to a
// Postgres role. Without it every request runs as `anon` and RLS refuses it
// ("permission denied for table ..."). The usual fix is Firebase blocking
// functions, which need the Blaze plan. This function does the same job from
// Supabase, with no Firebase billing.
//
// POST (no body needed) with  Authorization: Bearer <Firebase ID token>
//   -> 200 { "granted": true }            claim was just set; refresh the token
//   -> 200 { "granted": false, "already": true }
//
// SECURITY
//  * The caller is identified ONLY by a Firebase ID token verified against
//    Google's public keys, with issuer and audience pinned to this project.
//    A token from any other Firebase project is rejected.
//  * It only ever updates the account the token belongs to (its own `sub`),
//    and only to the fixed value role=authenticated. `authenticated` is a
//    Postgres role, not the app role (customer/staff/owner/delivery): the app
//    role lives in Firestore users/{uid} and is enforced by firestore.rules.
//  * Existing custom claims are preserved (merged), never wiped.
//  * The Firebase service-account key lives only in Supabase secrets.
//
// Secrets: FIREBASE_SERVICE_ACCOUNT (the service-account JSON, whole file),
// FIREBASE_PROJECT_ID (optional, defaults to melai-nuts-app-2026).
// Deploy with verify_jwt disabled: the Firebase token is verified here.
import { createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT } from "npm:jose@5.9.6";

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

const FIREBASE_JWKS = createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);

type ServiceAccount = { client_email: string; private_key: string };

let cachedAccessToken: { token: string; exp: number } | null = null;

async function googleAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedAccessToken && cachedAccessToken.exp - 60 > now) return cachedAccessToken.token;

  const key = await importPKCS8(sa.private_key, "RS256");
  const assertion = await new SignJWT({ scope: "https://www.googleapis.com/auth/cloud-platform" })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) throw new Error(`token endpoint ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const data = await res.json();
  cachedAccessToken = { token: data.access_token, exp: now + (data.expires_in ?? 3600) };
  return data.access_token;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const projectId = Deno.env.get("FIREBASE_PROJECT_ID") ?? "melai-nuts-app-2026";
  const rawKey = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
  if (!rawKey) {
    console.error("grant-role-claim: FIREBASE_SERVICE_ACCOUNT is not set");
    return json({ error: "Not configured." }, 500);
  }
  let sa: ServiceAccount;
  try {
    sa = JSON.parse(rawKey);
    if (!sa.client_email || !sa.private_key) throw new Error("incomplete");
  } catch (_) {
    console.error("grant-role-claim: FIREBASE_SERVICE_ACCOUNT is not valid service-account JSON");
    return json({ error: "Not configured." }, 500);
  }

  // 1. Who is calling? Verify the Firebase ID token (signature, expiry, project).
  const authorization = req.headers.get("Authorization") ?? "";
  const idToken = authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
  if (!idToken) return json({ error: "Please sign in again." }, 401);

  let uid: string;
  let alreadyHasRole = false;
  try {
    const { payload } = await jwtVerify(idToken, FIREBASE_JWKS, {
      issuer: `https://securetoken.google.com/${projectId}`,
      audience: projectId,
      algorithms: ["RS256"],
    });
    if (typeof payload.sub !== "string" || payload.sub.length === 0) throw new Error("no sub");
    uid = payload.sub;
    alreadyHasRole = payload.role === "authenticated";
  } catch (_) {
    return json({ error: "Please sign in again." }, 401);
  }

  if (alreadyHasRole) return json({ granted: false, already: true });

  // 2. Merge role=authenticated into the account's existing custom claims.
  try {
    const accessToken = await googleAccessToken(sa);
    const base = `https://identitytoolkit.googleapis.com/v1/projects/${projectId}`;
    const headers = { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" };

    const lookup = await fetch(`${base}/accounts:lookup`, {
      method: "POST",
      headers,
      body: JSON.stringify({ localId: [uid] }),
    });
    if (!lookup.ok) throw new Error(`lookup ${lookup.status}: ${(await lookup.text()).slice(0, 300)}`);
    const found = (await lookup.json()).users?.[0];
    if (!found) return json({ error: "Account not found." }, 404);

    let existing: Record<string, unknown> = {};
    try {
      existing = found.customAttributes ? JSON.parse(found.customAttributes) : {};
    } catch (_) {
      existing = {};
    }
    if (existing.role === "authenticated") {
      // Already set on the account; the app only needs a fresh token.
      return json({ granted: true });
    }

    const update = await fetch(`${base}/accounts:update`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        localId: uid,
        customAttributes: JSON.stringify({ ...existing, role: "authenticated" }),
      }),
    });
    if (!update.ok) throw new Error(`update ${update.status}: ${(await update.text()).slice(0, 300)}`);

    return json({ granted: true });
  } catch (e) {
    // Never echo details to the caller; they are in the function logs.
    console.error("grant-role-claim failed:", e instanceof Error ? e.message : e);
    return json({ error: "Could not update your account access. Please try again." }, 502);
  }
});
