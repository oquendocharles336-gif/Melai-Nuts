# Melai Nuts — Security setup & responsibilities

> This project uses **Firebase Auth** for identity, **Cloud Firestore** for
> account/role records (`users/{uid}`), and **Supabase Postgres** for customer
> business data (catalog, carts, orders, payments, refunds, loyalty,
> notifications). Firestore Security Rules (`firestore.rules`) and Supabase Row
> Level Security (`supabase/migrations/…`) are the server-side gates; nothing in
> Dart is trusted.

## What is enforced where

| Concern | Enforced by | Where |
|---|---|---|
| Who you are | Firebase Auth | Firebase |
| Your role / branch / active flag | `users/{uid}` document, read **server-side** by rules | `firestore.rules` |
| Who can read/write Firestore | Firestore Security Rules: only `users` is open; **every other collection is denied to everyone** | `firestore.rules` (deploy it!) |
| Whether a deactivated account can sign in | `supabaseRoleOnSignIn` blocking function (server-side), plus the app's own check | `functions/index.js` |
| Who can read/write each Supabase table / call each function | Postgres grants + RLS + `SECURITY DEFINER` functions | `supabase/schema.sql` then `supabase/migrations/*.sql` |
| Prices, totals, stock, points, refund amounts | Server-side SQL functions/triggers | `place_order`, `request_refund`, triggers |
| Screens shown for a role | `RouteGuard` (UX / defence-in-depth only) | `lib/app/route_guard.dart` |
| Rate limiting / brute force | Firebase Auth throttling + App Check (sign-in); on-device brakes for sign-in, sign-up and e-mail codes; database limits on voucher codes (10/15 min), order bursts (5/10 min), refund requests (3/30 min), new addresses (20/hour); admin website throttles every write (default 60/min per user) and login | Firebase Console; `migrations/20261019000000_rate_limits.sql`, `migrations/20261025010000_more_rate_limits.sql`; `admin/app/Http/Middleware/ThrottleWrites.php` |
| Bad input (length, format, phone, price) | App validators (UX) **and** database CHECK constraints + phone-normalizing triggers (authoritative) **and** Laravel FormRequests | `lib/core/utils/validation_utils.dart`; `migrations/20261025000000_input_check_constraints.sql`; `admin/app/Http/Requests/*` |
| Least privilege (grants) | `anon` read-only on the public catalog; no writes; internal helpers and pgcrypto not callable from the app | `migrations/20261025020000_grants_hardening.sql` (audited by `supabase/tests/panel_compliance_test.sql`) |
| Terms / Privacy acceptance | Append-only `legal_acceptances` table written only by `accept_legal_terms()` | `migrations/20261025040000_legal_acceptance.sql` |

A modified app can bypass anything in Dart. It cannot bypass Firestore rules or Postgres grants/RLS.

## Owner checklist — exposed keys (do this first)

Until 2026-10-11 the *example* file `env/firebase.example.json` and a duplicate
`android/app/src/google-services.json.example` contained the project's **real** Firebase API keys
(web, Android, iOS), the project id and the sender id. Both are fixed: `env/firebase.example.json`
now holds only `YOUR_…` placeholders and the duplicate under `android/app/src/` was deleted (the
only template is `android/app/google-services.json.example`). The old keys are **still in Git
history**, so changing the files is not enough. CI now fails on any key-shaped value anywhere in
the repository (`scripts/check_no_fixture_data.py`: `AIza…` keys, JWTs, `sk_live_`/`rk_live_`,
`sb_secret_`, a filled-in `SERVICE_ROLE_KEY`, private-key blocks). Treat the old values as public:

- [ ] **Firebase keys — restrict** (Google Cloud Console > APIs & Services > Credentials), for each key:
  - [ ] Android key: *Application restrictions* = Android apps, package **`ph.melainuts.app`** + the
        release and debug **SHA-1** fingerprints (see `docs/RELEASE.md`).
  - [ ] iOS key: iOS apps, bundle id **`ph.melainuts.app`**.
  - [ ] Web key: HTTP referrers = your web domain(s) only.
  - [ ] Windows / macOS (if used): their own key, *API restrictions* only.
  - [ ] Every key: *API restrictions* = only Identity Toolkit API, Token Service API, Cloud Firestore
        API (and Firebase App Check API, Firebase Installations API once App Check is on).
- [ ] **Firebase keys — rotate**: create new keys with the restrictions above, put them in your local
      `env/firebase.json` and `android/app/google-services.json`, ship a build, then **delete the old
      keys**. In GitHub > Security > Secret scanning, close each alert as *Revoked*.
- [ ] **Supabase anon key**: it is a public key by design (RLS and the SQL functions protect the data),
      but it identifies the project. Optionally move to the new *publishable* key (Supabase dashboard >
      Project Settings > API Keys) and disable the legacy anon key after the app is updated. **Never**
      put the `service_role` / secret key anywhere in the app, `env/` or Git.
- [ ] **HitPay** (dormant, online payment is off): no HitPay key should be set anywhere until the owner
      re-enables online payment. If one was ever set as a Supabase secret, rotate it in the HitPay
      dashboard.
- [ ] Turn on **App Check** in monitor mode (`docs/APP_CHECK.md`).
- [ ] Rewriting Git history does not un-leak a key — restriction and rotation do. (You may still
      purge the old files from history with `git filter-repo` to stop future scanners flagging them.)

## Must-do steps outside the Flutter project

1. **Deploy the rules** — `firebase deploy --only firestore:rules`. Until you do,
   whatever rules are currently live in the console apply (the repo file is not
   automatically active). Run `firestore-tests/` against the emulator first
   (`cd firestore-tests && npm install && npm test`).
2. **Restrict every Firebase API key** (Google Cloud Console → APIs & Services →
   Credentials):
   - Android key: *Android apps* restriction (package `ph.melainuts.app` +
     release **and** debug SHA-1s).
   - Web key: *HTTP referrers* restriction for your web domain(s).
   - Windows desktop uses the *web* app config and cannot be app-restricted —
     give it its **own** key restricted by **API** only (Identity Toolkit,
     Token Service, Firestore).
   - On every key use *API restrictions*: only the Firebase APIs you use.
3. **API keys are injected at build time, not committed.**
   `lib/firebase_options.dart` reads keys via `--dart-define`, and
   `android/app/google-services.json` is git-ignored. Local setup:
   ```
   cp env/firebase.example.json env/firebase.json                       # fill in keys
   cp android/app/google-services.json.example android/app/google-services.json
   flutter run --dart-define-from-file=env/firebase.json
   ```
   The Android key in `env/firebase.json` and in `google-services.json` **must be
   the same key** (otherwise `core/duplicate-app`). Use one dedicated key per
   platform (web, android, ios, macos, windows).
4. **Treat every previously committed key as exposed and rotate it.** The old
   keys are still in Git history and GitHub secret scanning flagged them.
   Rewriting history does not un-leak a key; restriction/rotation does:
   1. Create *new* keys (Google Cloud Console → Credentials → Create API key),
      restricted as in step 2.
   2. Put them in `env/firebase.json` / `google-services.json` and ship a build.
   3. Delete the old keys in Google Cloud Console.
   4. In GitHub → Security → Secret scanning, close each alert as *Revoked*.
   For CI, store the JSON as a repository secret and write it to
   `env/firebase.json` before `flutter build`.
5. **Enable Firebase App Check** (Play Integrity for Android, App Attest for iOS,
   reCAPTCHA v3 for web). The app side is done (`lib/core/services/app_check_service.dart`);
   the console steps and the enforcement caveat for the admin website are in
   `docs/APP_CHECK.md`. Voucher-code guessing and order bursts are additionally
   rate-limited in the database (migration `20261019000000_rate_limits.sql`).
6. **Auth settings** (Firebase Console → Authentication → Settings):
   turn on *email enumeration protection*; set a password policy at least as
   strong as the app's (8+ chars, upper, number, symbol); consider requiring
   email verification for customers. Review the authorized domains list.
7. **First Owner account**: create the Firebase Auth user, then create
   `users/{uid}` in the console with `role: "owner"`, `isActive: true`,
   `email`, `name`. Owners create all other staff/owner/delivery accounts in-app.
8. **Release signing / package id**: done — applicationId / bundle id `ph.melainuts.app`,
   release signing from `android/key.properties` (git-ignored; a release build fails
   without it), R8 on. Build with `--obfuscate --split-debug-info=...`. See `docs/RELEASE.md`.

## Deactivating an account

Three layers, because each stops something different:

| Layer | Stops | Takes effect |
|---|---|---|
| App "User Management" screen (`setAccountActive`) | Staff/owner/rider data access (it updates the **Supabase staff registry first**, then `users/{uid}.isActive`) | Immediately |
| `supabaseRoleOnSignIn` blocking function | **New sign-ins** of any account whose profile has `isActive` present and not `true`. This replaces reliance on the app's own client-side check, which a modified app can skip. A missing profile is allowed (registration), and a Firestore outage does not lock everyone out (it fails open and logs) | At next sign-in |
| `functions/deactivate-user.js <uid>` | Disables the Firebase Auth user and **revokes refresh tokens**, then flags the profile. Use it for **customers** (the app cannot deactivate them) and in emergencies | Existing ID tokens live up to 1 hour |

The blocking function does **not** run when an existing session refreshes its token, so on its
own it cannot end a live session; that is what the script's disable + revoke is for. The script
refuses to deactivate an owner without `--allow-owner` and never deactivates the last active
owner. For staff and owners prefer the app screen (the script has no Supabase credentials).

Tests: `cd functions && npm install && npm test` (runs offline) and
`cd firestore-tests && npm install && npm test` (needs Java and the Firestore emulator).

## Supabase (customer data) — setup and guarantees

**Run order** (Supabase SQL Editor, or `psql`): `supabase/schema.sql` →
`supabase/migrations/20260928000000_customer_security_hardening.sql` →
`supabase/migrations/20260928010000_order_integrity.sql` (if you ever re-run the
first migration, re-run the second afterwards). Then the tests, all on a
**dev/staging** project, never production, each must finish with 0 failed:
`supabase/tests/customer_rls_security_test.sql` (access control),
`supabase/tests/order_integrity_test.sql` (atomicity and consistency; rolled
back), and `supabase/tests/concurrency_test.sh` (real racing sessions; commits
then removes its own `CONC-*`/`conc_*` rows).

**One-time dashboard/Firebase steps (cannot be done in SQL):**

1. Supabase → Authentication → Sign In / Providers → **Third-Party Auth → Firebase**
   → paste the Firebase **Project ID**. Supabase then verifies Firebase ID tokens.
2. **Give Firebase tokens the `authenticated` role.** Firebase tokens have no
   `role` claim, so without this every request is `anon` and checkout, cart
   sync, refunds and redemptions are refused. Upgrade Firebase Auth to Identity
   Platform, then `cd functions && npm install && cd .. && firebase deploy --only
   functions` (blocking functions in `functions/index.js`), then run
   `functions/backfill-role-claim.js` once for existing users. The claim is a
   *Postgres* role only — never put the app role (customer/staff/owner) in it.
3. Inject `SUPABASE_URL` and the **anon/publishable** key via
   `--dart-define-from-file=env/supabase.json`. The `service_role`/secret key
   must never appear in Flutter, `env/*.json` or Git.
4. Self-hosting only: add the restrictive issuer/audience RLS policy from
   Supabase's Firebase guide, because Firebase signs all projects with shared keys.

**What a customer can and cannot do (verified by the test suite):**

| A customer… | Enforced by |
|---|---|
| reads only their own profile/addresses/cart/orders/payments/refunds/loyalty/notifications | RLS `firebase_uid = token sub`, policies `TO authenticated` |
| cannot write orders, order lines, payments, refunds, carts, loyalty, redemptions, voucher usage | no INSERT/UPDATE/DELETE grant **and** no policy |
| cannot change prices, totals, stock, payment/refund status | totals/stock computed inside `place_order`; no write access to catalog/inventory |
| cannot choose a refund amount or line price | `request_refund()` recomputes from the order; client values are ignored |
| cannot farm loyalty points | points awarded only when an order is `completed`; cancel returns redeemed points/stock/voucher; refund claws points back |
| cannot inject notifications | `notify_customer()` is not executable by client roles; triggers only |
| cannot see product cost (COGS) | moved to `product_variant_costs`, RLS with no policy |
| cannot edit `rfid_card_number`, `email`, or `firebase_uid` on their profile | column-level UPDATE grant is name/phone/default branch only |
| cannot create a profile without a verified, matching email | RLS insert check on `email_verified` + `email` claims |
| cannot elevate their role | there is no role column in Supabase; app roles live in Firestore, writable only by owners |

New tables are **not** exposed by default (default privileges are revoked). When
you add one the app must read, `grant` it and add a policy explicitly.

**Data integrity (verified by `order_integrity_test.sql` and `concurrency_test.sh`):**

- **Checkout is one transaction.** `place_order` validates customer, branch,
  products, variants, stock, prices, voucher and loyalty, then writes order,
  lines, stock deduction, payment, points ledger, voucher usage and cart
  conversion together. The tests force *each* of those writes to fail in turn
  and prove the database is left byte-for-byte unchanged; the customer's cart
  survives so they can retry.
- **No overselling / double spending.** Stock, the voucher and the loyalty
  account are row-locked, in a fixed order. Racing sessions cannot take the
  last unit twice, exceed a voucher limit, or spend points twice.
- **Retries are safe.** The checkout key is serialised per customer: a
  double-tap or a network retry returns the one real order rather than an error
  or a duplicate. (The app creates one key per checkout attempt.)
- **An order cannot exist half-created.** At COMMIT, any order (from any code
  path, including future staff/POS tools) must have items adding up to its
  subtotal and a payment for exactly its total; CHECKs pin
  `total = subtotal - discount + delivery fee`.
- **State machines** for orders, payments and refunds reject invalid moves for
  every writer, including staff and the service role (no `cancelled → completed`,
  no un-paying, no completing an unpaid order, no "out for delivery" on pickup).
- **Immutable facts.** Order money fields, order lines, payment amount/method
  and refund amount cannot be edited after the fact; the loyalty ledger is
  append-only. `loyalty_ledger_drift` (owner-only view) lists any balance that
  no longer equals the sum of its ledger; it should always be empty.
- **Non-critical side effects** (notifications) can fail without rolling back a
  checkout.
- **Not atomic by design:** a delivery address is saved just before the order
  in a separate call, so a failed checkout can leave an extra saved address.
  It is customer-owned data, not part of the money/stock consistency.

**Not solved by the database — do these before real money moves:**

- **Payments.** There is no payment gateway. Every payment is created `pending`
  and only trusted server code may advance it. Online GCash/Maya/card needs a
  provider (e.g. PayMongo) with the **secret key in a Supabase Edge Function**,
  and a **signature-verified webhook** that marks `payments.status`. The app
  deliberately no longer collects card numbers.
- **Brute-force / abuse.** Voucher-code guessing via `sync_customer_cart` and
  order spam are not rate-limited by Postgres. Add rate limiting (Edge Function
  or API gateway) and Firebase App Check.
- **Staff/owner/delivery writes** to Supabase (confirming payments, moving order
  status, restocking, approving refunds) do not exist yet. Orders can only be
  completed after a payment is confirmed, so this tooling is required before
  any order can finish. Build them as
  `SECURITY DEFINER` functions that verify a staff role server-side, or as Edge
  Functions using the service role. Do not loosen the customer policies.
- **Reward fulfilment.** `redeem_reward()` deducts points and logs the
  redemption, but issues no voucher/redemption code for staff to honour.
- Leaked keys in Git history (see steps 3–4 above) still need rotation.

## Email verification (only real emails can register)

Registration is two steps: (1) create the Firebase account (no profile, no
access yet), (2) prove the email, then the customer profile is created.
**Enforcement is server-side:** `firestore.rules` refuses the customer profile
unless the caller's token has `email_verified == true`. A client cannot set that
flag, so a modified app cannot skip verification. Unverified accounts have no
profile and therefore no access to anything.

One mode: a **6-digit code e-mailed by Melai Nuts** (no link). Firebase's verification-link
e-mail is not used anywhere (removed from the app's `EmailVerificationService` and from the
website's `FirebaseAuthClient` / `CustomerAccounts` / `WaitingController`).

Backend: Supabase Edge Function `email-verification` (migration
`20261118010000_auth_email_codes_and_sign_in_guard.sql`), used by the app and the website:

- `POST /functions/v1/email-verification/send-code` — needs a valid **Firebase App Check**
  token (`X-Firebase-AppCheck`, sent by the app) **or** a Cloudflare **Turnstile** token
  (`captcha_token`; the website always uses this). 428 when neither, 429 on cooldown/limits.
- `POST /functions/v1/email-verification/verify-code` — `{"code","captcha_token"}`. The captcha
  is verified (siteverify, single use, 5 minutes) **before** the code is looked at: a
  missing / invalid / expired / reused token never uses up a try.

What the function enforces (all server-side):
1. The uid and e-mail come **only from the Firebase ID token**, verified against Google's
   public keys with issuer/audience pinned to `FIREBASE_PROJECT_ID`.
2. Codes are 6 digits from the CSPRNG (no modulo bias), stored as an **HMAC** (secret pepper
   `AUTH_CODE_PEPPER`), never in plain text; compared in constant time.
3. 10-minute expiry, 5 tries (counted atomically before the compare), single use, one active
   code per account, 60 s resend cooldown, hourly send limits per account (5), per e-mail
   address (5) and per IP (20). 429 + `Retry-After` on limits.
4. On the right code it calls Identity Toolkit `accounts:update {emailVerified: true}` (the
   Admin SDK's `updateUser`) with the service account in the function secrets only, so
   `firestore.rules` / RLS that read `email_verified` keep working.
5. The tables (`auth_email_codes`, `auth_email_code_sends`, `auth_captcha_redemptions`) have
   RLS on and no privileges for `anon` / `authenticated`; only the service role (the function)
   reaches them, through security-definer functions.

Password reset (`forgot_password_screen.dart`, website "Reset password") **still sends
Firebase's reset link**; see the report for the proposed branded replacement (not changed).

**Housekeeping:** abandoned unverified accounts keep their email address tied up.
The app deletes them when the person taps "Use a different email", but run a
scheduled job that deletes Auth users with `emailVerified == false` and no
`users/{uid}` document older than ~24h. Existing customers who registered before
this change already have profiles and are unaffected.

## Sign-in: captcha after 15 failed attempts (server-side)

Supabase Edge Function `auth-guard` + table `auth_sign_in_attempts` (same migration):

- Every password sign-in is announced first (`/sign-in/precheck`): one attempt is counted per
  normalized e-mail, per IP and per device id (all stored as HMACs), rolling 30 minutes.
- A successful sign-in (`/sign-in/success`, proven by the Firebase ID token) clears that
  e-mail's and device's counters (not the IP's, so one working account cannot hide a spray).
- From 15 attempts on any key the next sign-in needs a **Turnstile** token, verified by the
  function (siteverify + single-use table). It is a **gate, never a lockout**: a solved check
  always lets the attempt through, so nobody can lock a victim out by failing on purpose.
- Wrong e-mail and wrong password give the same message (app and website).
- Reinstalling the app or clearing its data does not reset the counter (it lives on the server).
  `AuthService._FailureBrake` stays as an on-device UX brake only.

**Enforced server-side:** for the **website** fully (the Laravel server calls the guard before
every Firebase password sign-in and passes the visitor IP with `AUTH_GUARD_SERVER_KEY`).
For the **app**, the guard is called by the app; a script that talks to Firebase Auth directly
skips it **unless Firebase App Check is enforced for Authentication** (Firebase console >
Security > App Check > APIs > Authentication > Enforce). See the report for what that needs
for the website's server-side sign-in.

## Staff foundation (Batch 1): identity, offline and audit

**Who decides what**

| Layer | Authority for |
|---|---|
| Firebase Auth | who you are (UID, login, password reset, verification) |
| Supabase (`staff_members`, RLS, RPCs) | what you may do: role, branch, permissions, account status |
| SQLite on the device | nothing — a cache and a retry queue |

A Firebase account alone grants no staff access. After sign-in the app asks
`get_my_staff_context()`, and staff screens stay locked until the server confirms
an **active** profile with a valid role and branch for exactly that UID.
`inactive`, `suspended`, no profile, an unknown role or a missing branch each
produce their own access-denied state; nothing is auto-created.

**Offline sessions (the honest limits)**

- Firebase persists the signed-in session itself. The app never stores a password
  and there is no offline "login".
- After every server confirmation the context is saved to SQLite. If the next
  start cannot reach the server, a copy for the *same UID*, confirmed active within
  the last **72 hours** (`StaffLocalRepository.maxOfflineAge`), restores the session
  read-only-ish: `StaffSessionStore.isServerValidated` is `false`.
- Sensitive actions must call `StaffSessionStore.requireServerValidation()` (or use
  `canSensitive`) and wait for the backend. The database enforces every rule on
  each request regardless.
- The moment the server says inactive / suspended / not set up / invalid, the cached
  copy is deleted, so a revoked account cannot be restored offline. A cached row is
  also rejected if it is expired, dated in the future, corrupt, for a different UID,
  or not `active`.
- **Residual risk:** an account revoked while a device stays offline keeps its cached
  read access for up to 72 hours (it cannot write anything — writes need the server).
  Shorten `maxOfflineAge` if that is too long for your business. The SQLite file is
  not encrypted at rest.

**No leakage between accounts.** The store is bound to one Firebase UID; on any
identity change it clears synchronously, drops late responses meant for the previous
account, runs every registered reset hook (later staff stores must register one with
`StaffSessionStore.registerResetHook`) and purges other accounts' cached data.
Queued operations are owned by a UID and every query is scoped to it.

**Sign-out** flushes queued work (bounded, best effort), deletes the cached
authorization, tidies *synced* queue rows, and **keeps unsent/failed operations** for
their owner. Nothing unsynced is deleted silently.

**Audit log.** `staff_audit_logs` is append-only. Actor, branch and time are set by the
server from the verified token; clients cannot insert, update or delete rows.
`AuditService.record` goes through the sync queue with an idempotency key, so entries
made offline are recorded exactly once later. Never put secrets or full customer
details in audit metadata.

**Secrets.** Only the anon/publishable Supabase key belongs in the app (the app
refuses a `service_role` / `sb_secret_` key). Note: `env/firebase.example.json` and
`android/app/google-services.json` carry Firebase *client* config; they are not
secrets but are tied to your project — keep `google-services.json` out of Git (it is
in `.gitignore`) and restrict the keys in the Google Cloud console.

## Known limits (cannot be fully fixed from the Flutter client)

- **Account creation by Owner** still creates the Auth user client-side. Moving it
  to a Cloud Function using the Admin SDK removes the need for any client to be
  able to create privileged Auth users.
- **Remote sign-out of other devices** and true account deletion need the Admin SDK.
  "Change password" ends other sessions.
- **2FA / biometric / PIN toggles** on the security screens are UI mock-ups; real
  MFA needs Firebase MFA (Identity Platform) or a `local_auth` flow.
- The Firestore offline cache is not encrypted at rest by Firestore. It is
  size-bounded and wiped at app start when no user is signed in.
- Order/price integrity is now enforced in Postgres (`place_order`, `request_refund`).
  The prototype's Firestore `products`/`inventory`/`orders`/`deliveries`/`refunds` rules were
  removed (those collections are now denied to everyone); they are archived, with their
  known defects, in `docs/firestore-dormant-collections.md`.

## Panel compliance hardening (2026-10-11)

What changed for the security criterion (details in `docs/PANEL_COMPLIANCE_REPORT.md`):

- **Exposed keys**: placeholders only in `env/firebase.example.json` and
  `android/app/google-services.json.example`; the duplicate `android/app/src/google-services.json.example`
  was deleted; CI scans the whole repository for key-shaped values. **Owner action:** restrict and
  rotate the old Firebase keys (checklist at the top of this file).
- **Release builds**: Android `release` is not debuggable, cleartext HTTP is off
  (`usesCleartextTraffic="false"`; only the debug manifest allows it for local emulators); every
  Android permission is justified in a comment in `AndroidManifest.xml`; iOS usage strings say why.
- **Logs**: `debugPrint` of errors happens in debug builds only (`kDebugMode`); release builds print
  nothing that could contain a phone number, address or token. Crash reports carry the Firebase UID
  only. Phones are masked on profile screens (`maskPhone`).
- **Errors shown to people**: always `AppErrors.from(...)` wording (never SQL, stack traces or raw
  exception text); a widget that fails to build shows a calm translated box in release builds
  (`lib/core/widgets/friendly_error_widget.dart`); startup failure shows a plain message (details in
  debug builds only).
- **Local data**: the customer's on-device SQLite copy (`customer_records`, `response_cache`,
  `customer_pending_writes`) holds server rows only — no passwords, tokens or keys (a unit test checks
  the column names). It is namespaced by Firebase UID and wiped on sign-out / account switch. The app
  stores no auth tokens itself (Firebase Auth keeps its own session in the platform keystore), so
  `flutter_secure_storage` is not needed.
- **Admin website**: owner/admin accounts sign in with the password only (no 2-step verification;
  staff may turn it on as an option), every write is throttled (`MELAI_WRITE_LIMIT_PER_MINUTE`),
  sessions expire after 30 minutes idle and on browser close, cookies are `Secure`/`HttpOnly`/`SameSite`
  (`.env.example`), and an expired CSRF token sends the user back to log in with a message instead of
  a 419 page.
- **Passwords** (app and admin): 8–64 characters, upper + lower + digit + symbol, not a common
  password (leet-speak variants included), not containing the person's name or e-mail.

### Still the owner's job

- [ ] Restrict / rotate the old Firebase keys (above).
- [ ] Run the new migrations `supabase/migrations/20261025*.sql` (or `supabase/repair/20261010_resync_live_database.sql`)
      on the live project, then `bash scripts/run-sql-tests.sh` against a copy.
- [ ] Admin website: `php artisan migrate` (adds `terms_version` / `terms_accepted_at` to `users`), set
      `SESSION_SECURE_COOKIE=true` and the other session values from `.env.example` on the server, and
      enrol every owner/admin in 2-step verification before deploying (they are asked on next login).
- [ ] Have the Terms and Privacy Policy reviewed (sections marked for owner review in
      `lib/core/config/legal_config.dart`); when the text changes, bump `termsVersion` / `privacyVersion`
      there and `melai.legal.terms_version` in `admin/config/melai.php` — everyone is asked to accept again.

