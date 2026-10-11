/**
 * Fully deactivate (or reactivate) one account: disables the Firebase Auth
 * user, revokes their sessions and flags users/{uid}.isActive.
 *
 *   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
 *   node deactivate-user.js <uid>                  # deactivate
 *   node deactivate-user.js <uid> --reactivate
 *   node deactivate-user.js <uid> --allow-owner    # needed for owner accounts
 *
 * Staff/owner: prefer the app's User Management screen (it also updates the
 * Supabase staff registry). See lib/account-status.js for the details.
 * Run with admin credentials that stay on your machine, never in the app.
 */
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore } = require('firebase-admin/firestore');
const { deactivateAccount, reactivateAccount } = require('./lib/account-status');

async function main() {
  const args = process.argv.slice(2);
  const uid = args.find((a) => !a.startsWith('--'));
  if (!uid) {
    console.error('Usage: node deactivate-user.js <uid> [--reactivate] [--allow-owner]');
    process.exit(2);
  }
  initializeApp();
  const deps = { auth: getAuth(), firestore: getFirestore() };
  try {
    const steps = args.includes('--reactivate')
      ? await reactivateAccount(deps, uid)
      : await deactivateAccount(deps, uid, { allowOwner: args.includes('--allow-owner') });
    console.log(`Done for ${uid}: ${steps.join(', ')}`);
    if (!args.includes('--reactivate')) {
      console.log('Existing ID tokens stay valid for up to 1 hour; refresh tokens are revoked.');
    }
  } catch (e) {
    console.error(`Failed for ${uid}: ${e.message}`);
    if (e.completedSteps && e.completedSteps.length) {
      console.error(`Steps already completed: ${e.completedSteps.join(', ')}`);
    }
    process.exit(1);
  }
}

main();
