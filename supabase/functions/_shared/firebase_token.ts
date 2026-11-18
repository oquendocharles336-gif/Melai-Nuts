// Verifies Firebase ID tokens and Firebase App Check tokens against Google's public keys,
// with issuer and audience pinned to this project (same rules as grant-role-claim).
import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "npm:jose@5.9.6";

export type FirebaseUser = {
  uid: string;
  email: string | null;
  emailVerified: boolean;
  signInProvider: string | null;
  /** When the person last entered their password (seconds since 1970), for "recent sign-in" checks. */
  authTime?: number | null;
  /** The account's display name (the `name` claim), for the e-mail greeting only. */
  name?: string | null;
};

const ID_TOKEN_JWKS_URL = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";
const APP_CHECK_JWKS_URL = "https://firebaseappcheck.googleapis.com/v1/jwks";

let idTokenKeys: JWTVerifyGetKey | null = null;
let appCheckKeys: JWTVerifyGetKey | null = null;

/** Throws on any problem (bad signature, expired, other project, no subject). */
export async function verifyFirebaseIdToken(
  token: string,
  projectId: string,
  keys: JWTVerifyGetKey = idTokenKeys ??= createRemoteJWKSet(new URL(ID_TOKEN_JWKS_URL)),
): Promise<FirebaseUser> {
  if (!projectId) throw new Error("FIREBASE_PROJECT_ID is not set");
  const { payload } = await jwtVerify(token, keys, {
    issuer: `https://securetoken.google.com/${projectId}`,
    audience: projectId,
    algorithms: ["RS256"],
  });
  if (typeof payload.sub !== "string" || payload.sub.length === 0 || payload.sub.length > 128) throw new Error("no sub");
  // Firebase also requires auth_time in the past.
  if (typeof payload.auth_time === "number" && payload.auth_time > Math.floor(Date.now() / 1000) + 60) {
    throw new Error("auth_time in the future");
  }
  const firebase = (payload.firebase ?? {}) as Record<string, unknown>;
  return {
    uid: payload.sub,
    email: typeof payload.email === "string" ? payload.email.trim().toLowerCase() : null,
    emailVerified: payload.email_verified === true,
    signInProvider: typeof firebase.sign_in_provider === "string" ? firebase.sign_in_provider : null,
    authTime: typeof payload.auth_time === "number" ? payload.auth_time : null,
    name: typeof payload.name === "string" ? payload.name : null,
  };
}

/**
 * Firebase App Check token (header X-Firebase-AppCheck). Returns the app id it was issued to.
 * `allowedAppIds` empty = any app of this project.
 */
export async function verifyAppCheckToken(
  token: string,
  projectNumber: string,
  projectId: string,
  allowedAppIds: string[] = [],
  keys: JWTVerifyGetKey = appCheckKeys ??= createRemoteJWKSet(new URL(APP_CHECK_JWKS_URL)),
): Promise<string> {
  if (!projectNumber) throw new Error("FIREBASE_PROJECT_NUMBER is not set");
  const { payload } = await jwtVerify(token, keys, {
    issuer: `https://firebaseappcheck.googleapis.com/${projectNumber}`,
    audience: [`projects/${projectNumber}`, `projects/${projectId}`],
    algorithms: ["RS256"],
  });
  const appId = typeof payload.sub === "string" ? payload.sub : "";
  if (!appId) throw new Error("no app id");
  if (allowedAppIds.length > 0 && !allowedAppIds.includes(appId)) throw new Error("app not allowed");
  return appId;
}
