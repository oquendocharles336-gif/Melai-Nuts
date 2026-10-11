/**
 * One-off: give every EXISTING Firebase user the `role: 'authenticated'` claim
 * (the blocking functions only cover sign-ups/sign-ins after they are deployed).
 * Existing custom claims are preserved (merged), never overwritten.
 *
 * Run AFTER deploying the blocking functions, with admin credentials that stay
 * on your machine (never in the Flutter app):
 *   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
 *   node backfill-role-claim.js
 * Users pick the claim up on their next token refresh (sign out/in, or <= 1 h).
 */
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');

initializeApp();

async function main() {
  let pageToken;
  let updated = 0;
  let skipped = 0;
  let failed = 0;
  do {
    const page = await getAuth().listUsers(1000, pageToken);
    pageToken = page.pageToken;
    for (const user of page.users) {
      const existing = user.customClaims || {};
      if (existing.role === 'authenticated') { skipped++; continue; }
      try {
        await getAuth().setCustomUserClaims(user.uid, { ...existing, role: 'authenticated' });
        updated++;
      } catch (e) {
        failed++;
        console.error('Failed for', user.uid, e.message);
      }
    }
  } while (pageToken);
  console.log(`Done. updated=${updated} already-set=${skipped} failed=${failed}`);
  process.exit(failed ? 1 : 0);
}

main();
