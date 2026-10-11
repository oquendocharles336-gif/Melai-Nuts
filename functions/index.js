/**
 * Firebase Auth blocking functions — required for Supabase RLS to work.
 *
 * Supabase reads the `role` claim of the Firebase ID token to choose the
 * Postgres role for each request. Firebase tokens have NO `role` claim, so
 * without this every request runs as `anon` and the customer RPCs
 * (place_order, sync_customer_cart, request_refund, ...) are refused.
 *
 * SECURITY NOTES
 *  - `role: 'authenticated'` is a *Postgres* role only. It is NOT the app role
 *    (customer/staff/owner/delivery): that lives in Firestore `users/{uid}` and
 *    is enforced by firestore.rules. Never put an app role in this claim.
 *  - A client cannot set its own custom claims; only these functions / the
 *    Admin SDK can.
 *  - supabaseRoleOnSignIn also REFUSES sign-in when the account's Firestore
 *    profile is inactive (users/{uid}.isActive present and not true). It runs at
 *    sign-in only, not on token refresh: to end an existing session use
 *    functions/deactivate-user.js (disables the user + revokes refresh tokens).
 *  - Staff/owner/delivery accounts also receive it. That is harmless: every
 *    customer policy is scoped to the caller's own firebase_uid.
 *
 * Requires: Firebase Authentication upgraded to Identity Platform (blocking
 * functions are not available otherwise) and the Blaze plan.
 *
 * Deploy:  cd functions && npm install && cd .. && firebase deploy --only functions
 * Then run functions/backfill-role-claim.js ONCE for users created earlier.
 */
const { beforeUserCreated, beforeUserSignedIn } = require('firebase-functions/v2/identity');
const logger = require('firebase-functions/logger');
const { initializeApp, getApps } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { makeSignInHandler, CLAIMS } = require('./lib/handlers');

function firestore() {
  if (!getApps().length) initializeApp();
  return getFirestore();
}

/** The caller's Firestore profile, or null when none exists yet. */
async function readUserProfile(uid) {
  const snap = await firestore().collection('users').doc(uid).get();
  return snap.exists ? snap.data() : null;
}

exports.supabaseRoleOnCreate = beforeUserCreated(() => ({ customClaims: CLAIMS }));

// Also refuses sign-in for deactivated accounts (users/{uid}.isActive is not
// true), so that check is enforced server-side and not only in the Flutter app.
exports.supabaseRoleOnSignIn = beforeUserSignedIn(
  makeSignInHandler({ readProfile: readUserProfile, log: logger }),
);
