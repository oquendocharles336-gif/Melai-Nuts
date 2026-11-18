// Firebase Admin, server-side only (the REST form of the Admin SDK): marks an e-mail verified,
// finds an account by e-mail, and changes an account's password / e-mail and ends its other
// sessions (password reset and e-mail change without Firebase's own e-mails). Same least-privilege service account and
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

export type AccountRef = { uid: string; name: string | null };

/** The account's uid for an e-mail address, or null when there is no such account. */
export async function lookupUidByEmail(
  email: string,
  projectId: string,
  serviceAccountJson: string | undefined,
  fetchFn: typeof fetch = fetch,
): Promise<string | null> {
  return (await lookupAccountByEmail(email, projectId, serviceAccountJson, fetchFn))?.uid ?? null;
}

/** uid + display name (for the greeting) for an e-mail address, or null when there is no such account. */
export async function lookupAccountByEmail(
  email: string,
  projectId: string,
  serviceAccountJson: string | undefined,
  fetchFn: typeof fetch = fetch,
): Promise<AccountRef | null> {
  const sa = parseServiceAccount(serviceAccountJson);
  const token = await accessToken(sa, fetchFn);
  const res = await fetchFn(`https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:lookup`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ email: [email] }),
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) throw new Error(`accounts:lookup ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const data = await res.json();
  const user = Array.isArray(data?.users) ? data.users[0] : null;
  if (!user?.localId || user.disabled === true) return null;
  return { uid: String(user.localId), name: typeof user.displayName === "string" ? user.displayName : null };
}

export type AccountChange = { password?: string; email?: string; emailVerified?: boolean; endSessions?: boolean };

/**
 * Changes the account. endSessions sets validSince to now: every refresh token issued before
 * stops working, so the app and the website ask for the password again within the hour.
 */
export async function updateAccount(
  uid: string,
  change: AccountChange,
  projectId: string,
  serviceAccountJson: string | undefined,
  fetchFn: typeof fetch = fetch,
): Promise<void> {
  const sa = parseServiceAccount(serviceAccountJson);
  const token = await accessToken(sa, fetchFn);
  const body: Record<string, unknown> = { localId: uid };
  if (change.password !== undefined) body.password = change.password;
  if (change.email !== undefined) body.email = change.email;
  if (change.emailVerified !== undefined) body.emailVerified = change.emailVerified;
  if (change.endSessions) body.validSince = String(Math.floor(Date.now() / 1000));
  const res = await fetchFn(`https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:update`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) {
    const text = (await res.text()).slice(0, 200);
    const err = new Error(`accounts:update ${res.status}: ${text}`);
    (err as Error & { firebaseCode?: string }).firebaseCode = /EMAIL_EXISTS/.test(text) ? "EMAIL_EXISTS"
      : /WEAK_PASSWORD/.test(text) ? "WEAK_PASSWORD" : undefined;
    throw err;
  }
}
