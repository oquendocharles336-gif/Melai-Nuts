# Fix: `permission denied ... TO anon` on every Supabase query

Cause: the Firebase ID token has no `role: "authenticated"` claim, so Supabase
runs the request as `anon`. Do NOT `GRANT ... TO anon`.

Run these once (nothing here goes in the Flutter app):

1. Supabase Dashboard > Authentication > Sign In / Providers > Third-Party Auth
   > Firebase > enter project ID `melai-nuts-app-2026`.
2. Fix existing users (works on the free Spark plan, no Identity Platform):
   ```
   cd functions && npm install
   # Firebase Console > Project settings > Service accounts > Generate key
   set GOOGLE_APPLICATION_CREDENTIALS=C:\path\to\service-account.json   (Windows cmd)
   node backfill-role-claim.js
   ```
   Keep that JSON out of the repo.
3. Sign out and back in on the phone (or wait up to 1 hour). The app now also
   force-refreshes the token once if the claim is missing and logs a
   `[Supabase] Firebase ID token has no role=authenticated claim` message if it
   is still absent.
4. New sign-ups also need the claim. That requires deploying the blocking
   functions (`firebase deploy --only functions`), which needs the Blaze plan
   and Firebase Authentication upgraded to Identity Platform. Until then, rerun
   the backfill after creating accounts.
