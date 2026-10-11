# Fix: Firebase sign-in, admin registration and app-account linking (admin website)

Date: 2026-10-10 · Scope: `admin/` (Laravel website) + docs. No change to the Flutter app,
Supabase SQL / RLS, Firestore rules or Cloud Functions.

## 1. Root cause

1. **The website never used Firebase to register or sign in.** `RegisterController`,
   `UserController::store` and `AdminSeeder` created rows only in the website's own SQLite `users`
   table with a website-only bcrypt password, and `LoginController` checked only that local
   password. So an account "registered" on the website never existed in Firebase Authentication,
   and there was nothing for the app or Supabase to recognise.
2. **Linking depended on a key that was empty, and the page hid every other cause behind it.**
   The only Firebase call was on *App account* (`FirebaseAccountVerifier`), which needs
   `FIREBASE_WEB_API_KEY`. With the key empty, `account/link.blade.php` showed "Not linked … set
   FIREBASE_WEB_API_KEY" before checking anything else, so a missing Firebase account, a missing
   `staff_members` profile, a wrong role or a missing branch all looked the same.
3. **Nothing tied the Supabase identity to a live Firebase sign-in.** Once `users.staff_uid` was
   set, any session of that website login, proven only by the local password, acted as the
   app account in Supabase. Disabling the Firebase user or revoking its sessions had no effect on
   the website. No Firebase ID token was ever verified.
4. Smaller issues: the login page never showed the `auth` error (wrong password showed nothing),
   there was no project check (a key from another Firebase project would have "worked"), and
   *Forgot password* was a dead end.

Setting `FIREBASE_WEB_API_KEY` alone would only have fixed the self-link form. Registration
would still not create Firebase accounts, and data access would still not be backed by Firebase.

## 2. What was implemented

* **Firebase is the website's identity.** Login and Create Account go through Firebase
  Authentication (Identity Toolkit REST, the same API as the Web SDK). Every ID token is verified
  on the server (`FirebaseTokenVerifier`: Google RS256 keys, `aud`/`iss` = `FIREBASE_PROJECT_ID`,
  expiry, subject) using PHP's OpenSSL, with no new package. The token, its expiry and the
  encrypted refresh token are kept in the server-side session (`FirebaseSession`).
* **Data access requires that token.** `StaffIdentity::uid()` (the only way the website acts as
  an app account in Supabase) now also requires a verified Firebase token in this session for the
  same UID. Expired tokens are refreshed. Revoked, disabled, deleted, forged or other-project
  tokens are rejected (401 for JSON; HTML pages redirect to *App account*).
* **Registration** (`RegisterController`). If the email already has an app account and the
  password is right, the login is created from it, but only when Supabase says it is an active
  owner or staff member. Otherwise a new Firebase account is created (`accounts:signUp`) and a
  verification email is sent. The login waits with no access and no rights. If saving the login
  fails, the new Firebase account is deleted, so nothing is left orphaned. Duplicate emails are
  refused with a clear message.
* **Approval** (`AccountProvisioner`, Users page → *Approve*). An active owner registers a
  verified registration as staff (with a branch) or owner. This does the same as the app's User
  Management: `owner_upsert_staff_member` runs as the owner, and Firestore `users/{uid}` is
  written with the owner's own ID token, so the existing rules decide. A failure rolls back the
  Supabase row (only if new) and the Firestore doc. *Create account → Staff* does Firebase account
  + approval in one all-or-nothing step.
* **Linking** (`FirebaseLogin`, `AccountLinkStatus`). The verified UID is matched to the website
  login by `firebase_uid`, or else by normalised email. Binding replaces the old local password,
  so whoever created that row can no longer use it. Supabase (`get_my_staff_context` as that UID)
  must report active status, the same email and the right role (admin↔owner, staff↔staff with a
  branch). An existing valid link is kept. An unlinked staff login whose verified app account is an
  active owner becomes admin only at sign-in. Owner rights come only from the app's staff registry.
* **Link states** (`LinkState`). The App account page shows one of these, decided from the real
  backends: configuration missing (names the variable), not authenticated, email not verified, no
  app account, app profile missing, email mismatch, role not authorized, no branch, linked,
  temporarily unavailable.
* **Configuration.** `FIREBASE_WEB_API_KEY` and `FIREBASE_PROJECT_ID` are required.
  `FIREBASE_REQUIRE_VERIFIED_EMAIL` is optional. Missing values are logged at start-up and shown by
  name on the login, register and App account pages. `php artisan melai:firebase-check` confirms
  Firebase accepts the key and that the key belongs to the right project.
* **Also fixed:** the login and register pages now show the `auth` error, and Forgot password
  sends Firebase's reset email.
* Legacy logins that were never bound to Firebase (for example drivers) can still sign in with the
  local password, but such a session can never act as an app account.

## 3. Files changed

| File | Why |
|---|---|
| `admin/app/Services/Firebase/FirebaseConfig.php` (new) | Reads and validates the Firebase env settings; produces the exact "missing X" message |
| `admin/app/Services/Firebase/FirebaseAuthClient.php` (new) | Identity Toolkit / Secure Token REST calls (sign-in, sign-up, refresh, emails, delete, key→project), with Firebase error codes mapped to actionable messages |
| `admin/app/Services/Firebase/FirebaseAuthException.php` (new) | Typed reasons (credentials, exists, disabled, config, network, …) |
| `admin/app/Services/Firebase/FirebaseTokenVerifier.php` (new) | Server-side ID-token verification |
| `admin/app/Services/Firebase/FirebaseSession.php` (new) | Keeps, re-verifies and refreshes the session's Firebase sign-in |
| `admin/app/Services/Firebase/FirestoreProfiles.php` (new) | Firestore `users/{uid}` create/get/delete with the owner's token (approval and rollback) |
| `admin/app/Services/Firebase/FirebaseAccountVerifier.php` (deleted) | Replaced by the client and verifier above (it trusted the response without verifying a token) |
| `admin/app/Services/Auth/LinkState.php` (new) | The link states and their instructions |
| `admin/app/Services/Auth/AccountLinkStatus.php` (new) | Decides the state from Firebase + Supabase; links when valid |
| `admin/app/Services/Auth/FirebaseLogin.php` (new) | Firebase sign-in → find, bind or create the website login (create only for verified app owner/staff) |
| `admin/app/Services/Auth/AccountProvisioner.php` (new) | Owner approval / staff creation, with rollback |
| `admin/app/Exceptions/AccountLinkException.php`, `FirebaseSessionRequiredException.php` (new) | Carry a link state; rendered as 401 / redirect |
| `admin/app/Services/Supabase/StaffIdentity.php` | Requires a verified Firebase session for the linked UID; `forget()` for the context cache |
| `admin/app/Http/Controllers/Auth/LoginController.php` | Firebase sign-in first, legacy local fallback only for unbound logins; forgot-password |
| `admin/app/Http/Controllers/Auth/RegisterController.php` | Firebase registration, waiting page re-check, resend verification |
| `admin/app/Http/Controllers/AccountLinkController.php` | Real link states; sign-in with app account binds and links |
| `admin/app/Http/Controllers/Admin/UserController.php` | Approve action; staff creation creates the app account |
| `admin/app/Http/Requests/LoginRequest.php` | Local auth limited to unbound logins; rate-limit helpers |
| `admin/app/Models/User.php` | `firebase_email_verified` cast, `usesFirebase()` |
| `admin/app/Providers/AppServiceProvider.php` | Scoped `FirebaseSession`; start-up warning for missing config |
| `admin/app/Console/Commands/FirebaseCheckCommand.php` (new) | `php artisan melai:firebase-check` |
| `admin/bootstrap/app.php` | Renders the new exceptions |
| `admin/routes/web.php` | approve, forgot-password POST, resend verification |
| `admin/config/services.php`, `admin/.env.example` | `FIREBASE_PROJECT_ID`, `FIREBASE_REQUIRE_VERIFIED_EMAIL`; placeholders only |
| `admin/database/migrations/2026_10_10_000001_add_firebase_identity_to_users_table.php` (new) | `users.firebase_uid` (unique) and `users.firebase_email_verified` in the website's own database |
| `admin/resources/views/account/link.blade.php` | State-driven page |
| `admin/resources/views/auth/{login,register,waiting,forgot}.blade.php`, `errors/backend.blade.php`, `admin/users/{index,create}.blade.php` | Error and config banners, waiting steps, reset form, Approve UI, branch picker |
| `admin/tests/Support/FakeFirebase.php` (new) | Fake Firebase + Firestore that issues real RS256 tokens |
| `admin/tests/Unit/FirebaseTokenVerifierTest.php`, `AccountLinkStatusTest.php`, `admin/tests/Feature/FirebaseAuthTest.php` (new) | New tests |
| `admin/tests/Feature/SupabaseIntegrationTest.php`, `AuthTest.php`, `admin/tests/TestCase.php` | Sessions carry a Firebase sign-in; 10 new end-to-end tests; stray HTTP blocked in tests |
| `INTEGRATION.md`, `README.md`, `admin/README.md` | Setup, env vars, first owner, staff flows, console steps, states |

## 4. Tests (run 2026-10-10 in the build environment)

| Suite | Result |
|---|---|
| `php artisan test` (fast, fake data + fake Firebase) | **93 passed, 9 failed, 42 skipped.** The 9 failures (LoyaltyTest ×5, PaymentTest ×1, RefundTest ×3) fail the same way on the untouched original code: they expect the retired local override tables |
| `php artisan test --group=supabase` (local PostgreSQL 16 with schema + all migrations, fake Firebase with real signed tokens) | **42 / 42 passed** (32 existing, adapted to need a Firebase sign-in, + 10 new) |
| `supabase/tests/*.sql` (13 suites) | all passed (69, 47, 134, 86, 30, 69, 82, 84, 9, 43, 126, 52, 44) |
| `functions` `npm test` | 38 / 38 passed |
| Flutter `flutter test` / `flutter analyze` | **not run**: no Flutter SDK here. No Dart file was changed |
| Firestore rules emulator tests | **not run**: needs the Firebase emulator (Java); `firestore.rules` unchanged |

Scenarios covered: new owner signs in → linked admin; app staff signs in → linked staff limited to
their branch even with `?branch=` of another branch; Firebase account without app profile refused
(nothing created) vs. unknown account (generic error); missing `FIREBASE_WEB_API_KEY` /
`FIREBASE_PROJECT_ID` reported by name; duplicate email (local and Firebase); email mismatch and an
already-linked account never re-linked; unverified email blocked when verification is required;
staff cannot reach approval and a website role change cannot create an owner (the database
refuses); expired token refreshed; revoked, disabled, forged and other-account tokens rejected
(401 / redirect); registration → verification → owner approval → Supabase row + Firestore
profile + linked login; Firestore failure rolls back the Supabase row; admin-created staff can sign
in; seeded local admin is bound and its local password stops working; dashboard KPIs match the
database (existing test).

**Not tested against the real Firebase project or the real Supabase project.** The website's
calls follow Google's documented REST contracts, but run `php artisan melai:firebase-check`
and a real sign-in once after deploying.
