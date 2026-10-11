'use strict';

/**
 * Fully deactivate / reactivate a Firebase account (Admin SDK). Used by
 * deactivate-user.js; dependencies are injected so the logic is unit tested.
 *
 * Why this exists: the sign-in blocking function only stops NEW sign-ins, and
 * `users/{uid}.isActive: false` only stops Firestore access. To end an account
 * you also have to disable the Auth user and revoke its refresh tokens (a token
 * already issued stays valid for up to an hour).
 *
 * Deactivate order is access-first, so a failure part-way still leaves the
 * account locked out: disable -> revoke sessions -> flag profile.
 * Reactivate order is the reverse: flag profile -> enable.
 *
 * STAFF / OWNER accounts: prefer the app's User Management screen. It also
 * updates the Supabase staff registry, which is what blocks database access
 * immediately; this script has no Supabase credentials. Use this script for
 * customers, or in an emergency (then the account is dead within the token
 * lifetime, <= 1 hour).
 */
async function activeOwnerCount(firestore) {
  const snap = await firestore.collection('users')
    .where('role', '==', 'owner')
    .where('isActive', '==', true)
    .limit(2)
    .get();
  return snap.docs.length;
}

async function deactivateAccount({ auth, firestore }, uid, { allowOwner = false } = {}) {
  const completed = [];
  const fail = (error) => { error.completedSteps = completed.slice(); throw error; };

  try {
    await auth.getUser(uid); // unknown uid -> auth/user-not-found, before anything is touched

    const ref = firestore.collection('users').doc(uid);
    const snap = await ref.get();
    const profile = snap.exists ? snap.data() : null;

    if (profile && profile.role === 'owner') {
      if (!allowOwner) {
        throw new Error('That account is an owner. Re-run with --allow-owner if you really mean it.');
      }
      if (profile.isActive !== false && (await activeOwnerCount(firestore)) <= 1) {
        throw new Error('Refusing: this is the last active owner. Create another owner first.');
      }
    }

    await auth.updateUser(uid, { disabled: true });
    completed.push('auth-disabled');
    await auth.revokeRefreshTokens(uid);
    completed.push('sessions-revoked');
    if (snap.exists) {
      await ref.update({ isActive: false });
      completed.push('profile-flagged-inactive');
    } else {
      completed.push('no-profile-to-flag');
    }
  } catch (error) {
    fail(error);
  }
  return completed;
}

async function reactivateAccount({ auth, firestore }, uid) {
  const completed = [];
  try {
    await auth.getUser(uid);
    const ref = firestore.collection('users').doc(uid);
    const snap = await ref.get();
    if (snap.exists) {
      await ref.update({ isActive: true });
      completed.push('profile-flagged-active');
    } else {
      completed.push('no-profile-to-flag');
    }
    await auth.updateUser(uid, { disabled: false });
    completed.push('auth-enabled');
  } catch (error) {
    error.completedSteps = completed.slice();
    throw error;
  }
  return completed;
}

module.exports = { deactivateAccount, reactivateAccount };
