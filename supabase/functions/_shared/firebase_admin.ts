// Firebase Admin: marks an account's e-mail as verified (the REST form of the Admin SDK's
// updateUser(uid, { emailVerified: true })). Same least-privilege service account and
// secrets as grant-role-claim: FIREBASE_SERVICE_ACCOUNT (JSON) and FIREBASE_PROJECT_ID.
import { importPKCS8, SignJWT } from "npm:jose@5.9.6";

type ServiceAccount = { client_email: string; private_key: string };

let cached: { token: string; exp: number } | null = null;

export function parseServiceAccount(raw: string | undefined): ServiceAccount {
  const sa = JSON.parse(raw ?? "");
  if (!sa?.client_email || !sa?.private_key) throw new Error("FIREBASE_SERVICE_ACCOUNT is incomplete");
  return sa;
}

async function accessToken(sa: ServiceAccount, fetchFn: typeof fetch): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.exp - 60 > now) return cached.token;
  const key = await importPKCS8(sa.private_key, "RS256");
  const assertion = await new SignJWT({ scope: "https://www.googleapis.com/auth/cloud-platform" })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);
  const res = await fetchFn("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) throw new Error(`token endpoint ${res.status}`);
  const data = await res.json();
  cached = { token: data.access_token, exp: now + (data.expires_in ?? 3600) };
  return data.access_token;
}

/** Sets emailVerified = true on the account. Throws when Google refuses. */
export async function markEmailVerified(
  uid: string,
  projectId: string,
  serviceAccountJson: string | undefined,
  fetchFn: typeof fetch = fetch,
): Promise<void> {
  const sa = parseServiceAccount(serviceAccountJson);
  const token = await accessToken(sa, fetchFn);
  const res = await fetchFn(`https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:update`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ localId: uid, emailVerified: true }),
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) throw new Error(`accounts:update ${res.status}: ${(await res.text()).slice(0, 200)}`);
}
