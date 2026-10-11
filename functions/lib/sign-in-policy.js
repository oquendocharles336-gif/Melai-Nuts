'use strict';

/**
 * Decides whether a user may sign in, from their Firestore `users/{uid}`
 * profile. Pure logic with injected I/O so it can be unit tested without
 * Firebase.
 *
 * The rule mirrors firestore.rules (`activeUser()`): a profile whose
 * `isActive` field is PRESENT and not exactly `true` is inactive. A missing
 * field counts as active (the rules default it to true).
 *
 *   no profile document -> ALLOW. A brand-new account signs in once before the
 *                          client has written its profile; blocking that would
 *                          make registration impossible.
 *   isActive absent     -> allow
 *   isActive === true   -> allow
 *   isActive anything else (false, null, "false", 0, ...) -> DENY
 *
 * If the profile cannot be read (Firestore error or timeout) the default is
 * to ALLOW and log, because a Firestore hiccup must not lock every user out;
 * the Supabase staff registry and Firestore rules still gate real access.
 * Pass `failClosed: true` to deny instead.
 *
 * Blocking functions have a hard 7 s limit, so the read gets its own, shorter
 * timeout.
 */
const DEFAULT_TIMEOUT_MS = 4000;

function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`profile read timed out after ${ms} ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function decideSignIn(uid, readProfile, options = {}) {
  const { failClosed = false, timeoutMs = DEFAULT_TIMEOUT_MS, log = console } = options;

  if (typeof uid !== 'string' || uid === '') {
    return { allow: false, reason: 'missing-uid' };
  }

  let profile;
  try {
    profile = await withTimeout(Promise.resolve().then(() => readProfile(uid)), timeoutMs);
  } catch (error) {
    log.error('sign-in policy: could not read the user profile', { uid, error: String(error && error.message || error) });
    return failClosed
      ? { allow: false, reason: 'profile-unavailable' }
      : { allow: true, reason: 'profile-unavailable-allowed' };
  }

  if (profile === null || profile === undefined) {
    return { allow: true, reason: 'no-profile' };
  }
  if (Object.prototype.hasOwnProperty.call(profile, 'isActive') && profile.isActive !== true) {
    return { allow: false, reason: 'deactivated' };
  }
  return { allow: true, reason: 'active' };
}

module.exports = { decideSignIn, DEFAULT_TIMEOUT_MS };
