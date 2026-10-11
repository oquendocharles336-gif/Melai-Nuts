# Firebase App Check and rate limits

## What is in the code

* `lib/core/services/app_check_service.dart`, called in `main.dart` right after
  `Firebase.initializeApp`:
  * Android release: **Play Integrity**; debug builds: the debug provider.
  * iOS / macOS release: **App Attest** with DeviceCheck fallback; debug: the debug provider.
  * Web: **reCAPTCHA v3** with `--dart-define=FIREBASE_APPCHECK_WEB_RECAPTCHA_SITE_KEY=<site key>`
    (put it in `env/firebase.json`); without a key, web is not attested.
  * `FIREBASE_APPCHECK_DEBUG_TOKEN` (optional dart-define) fixes the debug token for emulators / CI.
* Dependency: `firebase_app_check: ^0.4.8` (matches `firebase_core` 4.15). Run `flutter pub get`.
* **Rate limits in the database** (they work whatever the client is, App Check or not —
  migration `20261019000000_rate_limits.sql`, tests `supabase/tests/rate_limits_test.sql`):
  * voucher codes: a code must be registered with `register_voucher_attempt()` before a cart can use
    it; at most **10 codes per account per 15 minutes** (failed guesses count);
  * orders: at most **5 new customer orders per account per 10 minutes** (idempotent retries and POS
    sales are not counted).

## Console steps (owner)

1. Firebase console > **App Check** > Apps:
   * Android app `ph.melainuts.app` > **Play Integrity** > register. (Needs the app in the Play Console
     and the release SHA-256 in Firebase > Project settings.)
   * iOS app `ph.melainuts.app` > **App Attest** (and DeviceCheck) > register with your Apple Team ID
     and the DeviceCheck key.
   * Web app > **reCAPTCHA v3**: create a site key at https://www.google.com/recaptcha/admin for your
     web domain(s), paste the secret in Firebase, put the site key in `env/firebase.json`.
2. Debug builds: run the app once, copy the debug token from logcat / the Xcode console
   (`Firebase App Check debug token: ...`) into App Check > Apps > ⋮ > **Manage debug tokens**.
3. Ship a build with App Check and watch **App Check > APIs > Metrics** for a few days
   ("verified" vs "unverified" requests).
4. **Enforcement — read this first.** The admin website calls Firebase Authentication and Firestore
   from its server (REST, sign-in and staff profiles) and cannot attach an App Check token. If you
   press **Enforce** on *Authentication* or *Cloud Firestore*, website sign-in and staff approval stop
   working. So:
   * enforce only after the metrics show the app's own traffic is verified, **and**
   * keep the website working first: either leave those two services unenforced (Auth still has its
     own throttling, email-enumeration protection and the blocking functions), or move the website's
     Firebase calls behind a server that sends an App Check token (Admin SDK `createToken`) before
     enforcing.
   Supabase is not covered by App Check; its protection is RLS + the rate limits above.
