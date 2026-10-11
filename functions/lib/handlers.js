'use strict';

const { HttpsError } = require('firebase-functions/v2/identity');
const { decideSignIn } = require('./sign-in-policy');

/**
 * Marker the Flutter app looks for in the error Firebase returns when a
 * blocking function refuses a sign-in (reported as `internal-error` with this
 * text inside the message). Keep in sync with AuthService._messageFor.
 */
const DEACTIVATED_MARKER = 'ACCOUNT_DEACTIVATED';

/** The Postgres role claim every Supabase request needs (see index.js). */
const CLAIMS = { role: 'authenticated' };

/**
 * Builds the `beforeUserSignedIn` handler. Refuses deactivated accounts and
 * otherwise stamps the Supabase role claim, exactly as before.
 *
 * NOTE: this runs when a user SIGNS IN, not when an existing session's ID
 * token refreshes. To cut off an existing session as well, disable the user
 * and revoke their refresh tokens (functions/deactivate-user.js).
 */
function makeSignInHandler({ readProfile, log = console, failClosed = false }) {
  return async function onSignIn(event) {
    const uid = event && event.data && event.data.uid;
    const decision = await decideSignIn(uid, readProfile, { log, failClosed });
    if (!decision.allow) {
      log.warn('sign-in refused', { uid, reason: decision.reason });
      throw new HttpsError(
        'permission-denied',
        `${DEACTIVATED_MARKER}: This account has been deactivated. Please contact your administrator.`,
      );
    }
    return { customClaims: CLAIMS };
  };
}

module.exports = { makeSignInHandler, CLAIMS, DEACTIVATED_MARKER };
