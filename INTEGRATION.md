# Melai Nuts platform: mobile app + admin website

This repository now holds both parts of the platform:

```
melai-nuts/
├── lib/ android/ ios/ web/ ...   Flutter app (customers, staff, owner)       ← unchanged structure
├── supabase/                     Shared database: schema, migrations, tests   ← THE source of truth
│   ├── migrations/20261009000000_admin_portal.sql    (new)
│   └── tests/admin_portal_test.sql, local_supabase_stub.sql (new)
├── functions/                    Firebase Cloud Functions (sign-in policy, role claim)
├── firestore.rules               Firestore rules (account/role records only)
└── admin/                        Laravel 12 admin website (was melai-admin.zip)
```

## 1. How the two apps work together

```
 Flutter app ──(Firebase ID token)──►  Supabase API (PostgREST)  ─┐
                                                                   ├─► Supabase Postgres
 Admin website ──(melai_admin_portal role, SET ROLE authenticated   │   (orders, payments, refunds,
                  + linked staff UID)──► Postgres directly ─────────┘    stock, products, deliveries,
                                                                         loyalty, staff, audit log)
```

* **Delivery is app-only (2026-10-16).** Runs, driver assignment, dispatch, live driver tracking and
  the customers' map pins are handled only in the Flutter app: owner / branch staff create and
  dispatch runs (Delivery Management, live driver map, driver directory), drivers deliver from the
  driver portal, customers pin their address and track the rider. The admin website has no delivery
  page, menu entry, JSON endpoint, map or action, does not call any delivery function, and riders
  cannot sign in to it. Delivery orders still appear on the website's Orders, Sales, Reports and
  Refunds pages as a read-only channel ("Online · delivery") with no address, pin or rider, and the
  website cannot move them to another stage or create one. See
  `supabase/migrations/20261016000000_delivery_pins_app_only.sql` for the pin snapshot and access rules.

* **One database, one set of rules.** Before, the admin website read made-up data and saved its
  own copies of refund decisions, COD confirmations and loyalty points in a local SQLite file —
  a second source of truth. Now every business read and write goes to the app's Supabase
  database through the **same SQL functions and Row Level Security** the app uses
  (`staff_confirm_payment`, `staff_review_refund`, `staff_set_product_active`, …) plus a few new
  ones for the website. So a change made on either side is the same row the other side reads.
  Nothing is synchronised or copied.
* **Who the website acts as.** Website logins are Melai Nuts app accounts: people sign in with
  the same email + password as in the app, checked by **Firebase Authentication**. Each login is
  linked to the person's account in the app (`staff_members.firebase_uid`). Every request runs
  inside a transaction that sets that UID as the JWT `sub` and switches to the `authenticated`
  role — exactly what Supabase does for the app — and only while the session holds a **verified
  Firebase ID token of that same UID** (expired tokens are refreshed; revoked, disabled, forged or
  other-project tokens are rejected). Owners see all branches; staff see only their branch and
  permissions. The database login the website uses (`melai_admin_portal`) has **no privileges of
  its own**.
* **What stays local to the website** (its SQLite/MySQL database): website logins, sessions,
  access/activation flags, the link to the app account, and the website's own activity log.
* **Duplicates and races** are prevented by the database: rows are locked, state machines refuse
  invalid moves (e.g. paying twice, approving a refund twice), and loyalty adjustments carry a
  per-form request key so a double-submit applies once.

### Services you run

| Service | What | Where it runs |
|---|---|---|
| Supabase project | Postgres + API + Edge Functions (HitPay) | Supabase cloud (already in use) |
| Firebase | Sign-in, role records, Cloud Functions | Firebase (already in use) |
| Flutter app | Android/iOS/web build | Devices |
| **Admin website** | `admin/` Laravel app | Any PHP 8.2 host (or `php artisan serve` locally) |

The website needs no Firebase service-account file, Supabase `service_role` key or JWT secret.
It talks to Firebase with the app's public Web API key (`FIREBASE_WEB_API_KEY`) through the same
REST API the Firebase Web SDK uses: `accounts:signInWithPassword` (sign-in), `accounts:signUp`
(Create Account), `accounts:sendOobCode` (verification / password-reset emails), the Secure
Token API (refreshing the session's ID token) and, with the **owner's own ID token**, Firestore
`users/{uid}` (approving a registration, under the same `firestore.rules` as the app). Every ID
token is verified on the server against Google's public keys, `aud`/`iss` =
`FIREBASE_PROJECT_ID`, and expiry. Passwords are never stored or logged; the refresh token is
kept encrypted in the server-side session.

## 2. Setup

### A. Database (once)

1. Run the new migration in the Supabase SQL editor (after all earlier ones):
   `supabase/migrations/20261009000000_admin_portal.sql`. It is idempotent and does not change
   or delete existing data. Default loyalty earn rate stays 1 point per ₱50.
2. Give the website's database login a password (SQL editor; keep it out of Git):
   ```sql
   alter role melai_admin_portal with login password '<long random password>';
   ```
3. Connection string: Supabase dashboard → **Connect** → *Session pooler*. Use user
   `melai_admin_portal.<project-ref>` with the password above (or the direct connection with
   user `melai_admin_portal` if your host supports IPv6).
4. **First owner (one-time bootstrap).** Every later account is created by an owner, so the very
   first owner is set up by whoever manages Firebase and Supabase. Skip a step that is already done.
   1. Firebase console → Authentication → Users → **Add user** (owner's email + a strong password).
      Copy the **User UID**.
   2. Firebase console → Firestore → collection `users` → document id = that UID, fields:
      `email` (string), `name` (string), `role` = `owner`, `isActive` = `true` (boolean),
      `createdAt` (timestamp). The app and `firestore.rules` read the role from here.
   3. Supabase SQL editor:
      ```sql
      insert into public.staff_members (firebase_uid, full_name, email, role, account_status)
      values ('<owner firebase uid>', '<owner full name>', lower('<owner email>'), 'owner', 'active');
      ```
   **Without this owner row nobody can be linked** and the login page says
   "App profile missing". The owner then signs in to the app and to the website with that email +
   password; the website creates/links the admin login by itself (no manual link step).
   The row's `email` must be the owner's Firebase email and `role` must be `owner`.
5. Check that every migration is applied. If an older project is missing some, or `schema.sql`
   was run again after the migrations, run `supabase/repair/20261010_resync_live_database.sql`
   once (re-runs all migrations in order; no business rows are deleted). Never run `schema.sql`
   on a project that already has data.

### B. Admin website

```bash
cd admin
composer install && npm install
cp .env.example .env && php artisan key:generate
touch database/database.sqlite
# edit .env:
#   FIREBASE_WEB_API_KEY  (recommended) Firebase console > Project settings > General > Web API key
#                          (= FIREBASE_API_KEY_WEB in ../env/firebase.json)
#   FIREBASE_PROJECT_ID   (required) your Firebase project ID (Project settings > General > Project ID; same as .firebaserc)
#   SUPABASE_DB_*         from step A3
#   ADMIN_EMAIL / ADMIN_PASSWORD  the "Melai Admin" login (use the owner's app email, e.g. owner@example.com)
#   ADMIN_STAFF_UID        the owner's Firebase UID in staff_members (standard). The admin login acts as
#                          that owner automatically; Supabase must confirm an ACTIVE OWNER with ADMIN_EMAIL.
#                          Empty: the active owner row whose email equals ADMIN_EMAIL is used.
#   DASHBOARD_CACHE_SECONDS optional, default 45 (0 = off)
#   (to change ADMIN_EMAIL later: php artisan melai:change-admin-email <old> <new>, never a second admin)
php artisan config:clear
php artisan melai:firebase-check # key accepted by Firebase AND belongs to FIREBASE_PROJECT_ID?
php artisan migrate --seed       # website tables (adds users.firebase_uid) + fallback admin
npm run build
php artisan serve                # http://127.0.0.1:8000
```

Open the website and **log in with the owner's app email + password** (the ones from step A4 /
the app). Firebase checks the password, the website verifies the ID token, Supabase confirms the
account is an active owner with the same email, and the admin login is created (or the seeded
`ADMIN_EMAIL` login is taken over) and linked — no extra step. You land on the dashboard with every
branch and every staff account. If something is missing, the login page says exactly what.

| Variable | Required | Where to get it |
|---|---|---|
| `FIREBASE_WEB_API_KEY` | yes | Firebase console → Project settings → General → *Web API key*. Not a secret, but keep `.env` out of Git |
| `FIREBASE_PROJECT_ID` | yes | Same page → *Project ID* (the same ID as `.firebaserc`). ID tokens of any other project are refused |
| `FIREBASE_REQUIRE_VERIFIED_EMAIL` | no (`false`) | `true` = only accounts whose email Firebase reports verified may sign in. App-created staff never get a verification email, so leave `false` unless they all verified |
| `SUPABASE_DB_*` | yes | step A3 |

A missing variable is logged at start-up and shown by name on the login, Create Account and App
account pages ("Configuration missing … FIREBASE_WEB_API_KEY is empty").

### C. Flutter app

No new configuration. Rebuild as before:
```bash
flutter run --dart-define-from-file=env/firebase.json --dart-define-from-file=env/supabase.json
```

### D. Firebase console (manual, once)

1. **Authentication → Sign-in method → Email/Password: enabled** (the app already uses it).
2. **API key restrictions** (Google Cloud console → APIs & Services → Credentials → the Web key):
   if the key is restricted to HTTP referrers (browser use only), server calls from the website are
   refused ("The Web API key is restricted…"). Either allow the website server's IP for the
   *Identity Toolkit API* and *Token Service API*, or create a separate key for the website
   restricted to those two APIs + *Cloud Firestore API* and the server's IP, and put that one in
   `FIREBASE_WEB_API_KEY`.
3. Optional: Authentication → Templates → set the sender name / action URL of the verification
   and password-reset emails (Firebase's defaults work).
4. Nothing else changes: the blocking functions in `functions/` and `firestore.rules` are used as
   they are (deploy them as before if not yet deployed).

### E. Accounts: how people get into the website

| Who | How |
|---|---|
| **First owner** | Bootstrap once (2A step 4), then log in to the website with the app email + password → admin login, linked. |
| **Staff registered in the app** (owner → User Management) | Log in to the website with the same email + password → staff login created and linked automatically (branch from the app). |
| **New staff, from the website** | *Create Account* → a new Firebase account is created and Firebase emails a verification link; the login waits with **no access and no rights**. After the email is verified, an owner opens **Users** and presses **Approve** (choose branch, or Owner). That registers the account in the app exactly like User Management: `owner_upsert_staff_member` as the owner + Firestore `users/{uid}` with the owner's token; on any failure both are rolled back. The person can then use the app and the website with the same password. |
| **Staff created by an admin on the website** | *Users → Create account → Staff* (choose branch): Firebase account + app registration + linked login in one step, all-or-nothing (same as the app's User Management). Riders are app accounts only (created in the app's User Management); a website login with any role other than admin / staff is refused. |
| **"Melai Admin" / other website logins with a website password** | Logging in with the website password links the login on the server: admin → `ADMIN_STAFF_UID` or the active owner row with the same email; staff → the active staff row with the same email. Supabase verifies it as that UID; no second sign-in. Logging in with the **app** password instead binds the login to that Firebase account (then only the app password works). |
| **Forgot password** | *Forgot password?* sends Firebase's reset email; the new password works in the app and the website. |

Owner rights are only ever granted by an active owner (Approve → Owner, or the app's User
Management) or by the bootstrap; registering on the website, editing a form, or changing the
website's own `role` column cannot create an owner — the Supabase function refuses non-owners.

**Sign-in is the link.** Every successful sign-in links the login to its `staff_members` row
automatically, verified by Supabase as that UID (see `admin/README.md`, "Sign-in flow"): with the
website password by `ADMIN_STAFF_UID` (admin) or by email; with Firebase by the token's UID. There is
no "App account" page (`/account/link` redirects to the dashboard). When the link is impossible,
the **login page** says why and nobody is signed in:

| Message on the login page | Meaning / what to do |
|---|---|
| Invalid email or password | Neither Firebase nor the website password matched |
| App profile missing: No active owner … has the email X | No active `staff_members` owner with the admin's email, and `ADMIN_STAFF_UID` empty or wrong → set `ADMIN_STAFF_UID` or fix the email |
| App profile missing: No staff account … has the email X | Staff login without a staff row of that email → owner registers it in the app |
| "…does not match this login's email" / "Admin logins must be linked to an owner account" | `ADMIN_STAFF_UID` (or the row found) has another email or is not an owner |
| "…has been deactivated / is suspended" | The app account is not active |
| "…needs the database function portal_staff_uid_for_email" | Run migration `20261013000000_admin_portal_owner_overview.sql` (or set `ADMIN_STAFF_UID`) |
| Configuration missing | Firebase settings empty or wrong — only for logins that sign in with Firebase |
| Temporarily unavailable | Firebase or the database could not be reached; nothing changed |

Pending website registrations (no access yet) still go to "Waiting for access". During a session the
account's status is checked on every request; a deactivated account is signed out to the login page
with the reason.

## 3. What is integrated

| Area | Status | Notes |
|---|---|---|
| Orders & payments | ✅ Live | Payments page lists real orders; **Mark as paid** for cash calls `staff_confirm_payment` (customer notified). Online payments stay automatic via HitPay. |
| Refunds | ✅ Live | Cash: approve = completed in one step. Online: approve → refund in HitPay dashboard → **Mark refunded** with reference. Reject needs a reason, sent to the customer. Stock, points clawback and payment status are handled by the existing triggers. Amount comes from the customer's request (cannot be changed on the website). |
| Loyalty | ✅ Live | Members/balances/history from the ledger; owners change earn rate, redeem rate and max discount (used by checkout immediately) and add/deduct points (appended to the ledger, customer notified, audited). |
| Dashboard | ✅ Live | Owners: all branches by default + branch filter, every staff account (`owner_staff_overview`: role, branch, status, POS sales per cashier, shifts, open drawers, last activity), top branches and cashiers, today's figures; staff: own branch only. Net / gross paid sales, refunds, average order value, orders by status, paid sales by payment method, unpaid/failed payments, customers who ordered, low/out-of-stock counts — for today / this week / this month, all from the database; plus sales vs. target per branch, stock health, refunds, loyalty totals. Refreshes every minute; a failed refresh keeps the last real numbers and says so. |
| Sales | ✅ Live | `owner_sales_summary` for owners; own branch for staff. |
| Products | ✅ Live | Full catalog + stock; admins hide/show products (`staff_set_product_active`). Editing details stays in the app. |
| Inventory | ✅ Live (read) | Stock per branch/variant, thresholds, stock movements. Receiving/adjusting/transfers stay in the app (batch/FEFO screens). |
| Deliveries | App only | Removed from the website (2026-10-16): runs, drivers, dispatch and maps are in the app. Delivery orders are listed read-only (no "next stage"). |
| Users & roles | ✅ | Website logins **are** app accounts (Firebase sign-in, ID tokens verified on the server) and are linked to `staff_members` after Supabase verifies them (active, same email, admin↔owner, staff↔staff with branch). Create Account makes a Firebase account; owners approve it on Users (registers it in Supabase + Firestore). Deactivating in the app, disabling the Firebase user or revoking its sessions blocks the website. |
| Activity logs | ✅ | Website log + the app's append-only `staff_audit_logs`. |
| Driver map | App only | The app's live driver map (Delivery Management → Live driver map) shows the runs being carried right now; the website's Driver Tracking page, dashboard map and `/dashboard/drivers.json` are gone (404). |
| Reports | ✅ Live | Reports page (gross / discounts / refunds / net / revenue, pending payments apart, by day/branch/method/category, best & slow sellers, customers, loyalty, drivers, inventory value) + CSV per section (export is logged). Owner: all branches; staff need `view_reports`. |
| Forecast | ✅ Live | Linear regression with chronological hold-out MAE/RMSE and naive baseline; forecasts can be saved and compared with actual sales later. |
| Cash Drawer | ✅ Live (read) | Shifts, expected vs counted cash, per-cashier daily summary, voids; owners see all branches added up by default. Opening/closing/voiding happens in the app. |
| Inventory | ✅ + | Also reorder suggestions and batches expiring within 30 days. |
| Loyalty Cards (RFID) | ✅ Live | Tap a card (USB reader via Web Serial, or keyboard-mode reader) to see whose it is; link / replace / block cards; owner unblocks and sees every card. |
| Receiving (OCR) + Suppliers | ✅ Live | Photo of a supplier invoice → OCR (Tesseract.js, in the browser) → draft with matched products → person reviews → **Approve** posts FEFO batches once. Photo kept privately in `storage/app/private/receipts`. Owner or staff with inventory permission. |
| HitPay refunds | ✅ Live | Refunds page: **Send via HitPay** for approved online refunds (needs `HITPAY_API_KEY`), **Check HitPay** for pending ones, **Close attempt** if HitPay never answered. |
| Points expiry | ❌ Not available | The app has no expiry; the setting was removed in live mode rather than faked. |
| PayMongo | Removed | The app uses HitPay. The old PayMongo code (which reported refunds as accepted when no key was set) and its webhook were removed. |
| Customer app | ✅ | "Earn 1 pt per ₱X" now shows the owner's setting (`get_loyalty_earn_rate`). |

The website always shows the app's real data. The old demo data lives only in the test suite
(`admin/tests/Support/MockDataSource.php`, `MockPlatform.php`); `DATA_SOURCE=mock` is ignored outside
`APP_ENV=testing`. The local "override" tables (`order_overrides`, `loyalty_entries`,
`loyalty_settings`) that the demo mode used as a second copy of refunds, cash payments and points
are no longer read or written; every action goes to the shared database.

## 4. Database changes (`20261009000000_admin_portal.sql`)

* `loyalty_cart_settings.earn_pesos_per_point` (default 50); `compute_points_earned()` reads it.
* `loyalty_transactions.source` also accepts `admin_adjust` (constraint widened, nothing removed).
* Read functions: `admin_portal_orders`, `admin_portal_stock`, `admin_portal_products`,
  `admin_portal_stock_movements`, `admin_portal_loyalty_summary`, `admin_portal_loyalty_members`,
  `admin_portal_loyalty_member`, `admin_portal_loyalty_settings`, `admin_portal_audit_logs`,
  `admin_portal_staff_directory`, `get_loyalty_earn_rate` (public).
* Writes: `admin_portal_review_refund` (wraps `staff_review_refund`), `owner_adjust_loyalty_points`,
  `owner_update_loyalty_settings`. All check the caller's staff row, lock rows and write the audit log.
* Role `melai_admin_portal` (NOINHERIT, member of `authenticated` only).

Also fixed: `supabase/schema.sql` repeated the delivery module, which references `staff_members`
before it exists, so a fresh install stopped with an error. The block now lives only in
`migrations/20261002010000_delivery_module.sql` (identical content). Existing databases are unaffected.

### Added 2026-10-13 (`20261013000000_admin_portal_owner_overview.sql`, run after the others; safe to re-run)

* `owner_staff_overview(p_from, p_to, p_branch_id)` — OWNER ONLY (`_require_owner`), read-only: one
  row per `staff_members` account with POS transactions/sales/refunds rung up in the window, shifts
  opened, open drawer, last activity; all branches or one.
* `staff_registration_for_my_email()` — for the signed-in caller only: is the email **in their own
  JWT** in `staff_members`, and under the same UID? Used to explain "App profile missing". Takes no
  parameter, changes nothing.
* `portal_staff_uid_for_email(p_email, p_role)` — executable ONLY by the website's database login
  `melai_admin_portal` (not by app users): the UID of the one row with that email and
  role. Returns a UID, nothing else; the website verifies it with `get_my_staff_context()` AS that UID
  before linking. Used when `ADMIN_STAFF_UID` is empty and for staff website logins.
* The first two are granted to `authenticated` only. No table or RLS change.
* Until this migration runs: `ADMIN_STAFF_UID` logins still work; the dashboard shows the staff list
  from `admin_portal_staff_directory()` with activity "—" (never 0) and says which file to run.

### Added 2026-10-15 (`20261015000000_refunds_in_analytics.sql`, run after the others; safe to re-run)

Refunds now count the same way on every screen of the app and the website, computed once in SQL:

* **Definition** — gross sales = orders with a successful payment (`success` or `refunded`), by order
  date; refunds = `refund_requests.amount` of **completed** refunds (partial ones included), dated by the
  `completed` event; **net sales = gross − discounts − refunds** (the headline); refund rate = refunds ÷
  (gross − discounts), null when that is 0; pending / approved / processing refunds are shown apart and
  never deducted. Asia/Manila days; POS refunds count against the cashier who made the sale.
* **One place**: `_sales_facts`, `_sales_line_facts`, `_pending_refund_facts`, `_sales_money_json`
  (internal). New `sales_overview(from, to, branch)` (dashboard, sales page, reports, CSV, payments
  totals on the website); `owner_sales_summary`, `staff_get_dashboard`, `analytics_report`,
  `owner_staff_overview`, `get_product_sales_30d`, `get_popular_products` rebuilt on it (old keys kept).
  Order lists carry `refund_summary`; customers read `get_my_order_refunds()`.
* **Loyalty**: a partial refund reverses points in proportion to the amount refunded (once).
* **No over-refunding**: a refund can never exceed what was paid minus refunds already completed.
* **Audit**: app refund decisions (`staff_review_refund`) are now in `staff_audit_logs`.
* The repair script `supabase/repair/20261010_resync_live_database.sql` stops at 20261012; run
  20261013, 20261014 and 20261015 after it.
* Tests: `supabase/tests/refunds_analytics_test.sql` (one branch day with a full, partial, cross-day,
  HitPay, POS cash, pending and rejected refund; every figure checked against the others).

## 5. Website routes added

`GET /s/{sales|products|inventory}` (live pages; `/s/deliveries`, `/s/driver-tracking` and `/dashboard/drivers.json` were removed 2026-10-16 and answer 404), `POST /products/{id}/toggle-active`,
`POST /admin/refunds/{order}/complete`, `POST /admin/users/{user}/link|unlink`,
`GET|POST /account/link` (removed 2026-10-13: redirects to the dashboard, linking happens at sign-in). Artisan:
`php artisan melai:link-staff {email} {uid} [--unlink]`. To change the admin login's email in place
(same user, re-linked to the owner with the new email): `php artisan melai:change-admin-email {old} {new} [--uid=] [--skip-link]`.

Added 2026-10-10 (Firebase sign-in): `POST /admin/users/{user}/approve`, `POST /forgot-password`,
`POST /waiting/verify-email`; `php artisan melai:firebase-check`. Local website table migration
`2026_10_10_000001_add_firebase_identity_to_users_table` (`users.firebase_uid` unique,
`users.firebase_email_verified`). **No Supabase migration and no RLS / Firestore-rules change**:
approval uses the existing `owner_upsert_staff_member` / `owner_delete_staff_member` /
`get_my_staff_context` functions.

## 6. Tests run

| Suite | Result |
|---|---|
| `supabase/tests/admin_portal_test.sql` (new) | 69 / 69 passed |
| Existing SQL suites: customer RLS, order integrity, product search, staff cross-branch, staff foundation, staff identity | 134, 82, 9, 126, 52, 44 — all passed |
| `concurrency_test.sh`, `staff_idempotency_concurrency_test.sh` | 16/16, all passed |
| Laravel, fast tests on fake data (`php artisan test`) | 67 / 67 passed (2026-10-10) |
| Laravel, Supabase integration (`--group=supabase`, end-to-end over HTTP; includes self-linking, KPI-vs-database and stock tests) | 31 / 31 passed (2026-10-10) |
| **Firebase sign-in fix (2026-10-10, later):** fast suite incl. new `FirebaseAuthTest`, `FirebaseTokenVerifierTest`, `AccountLinkStatusTest` | 93 passed; 9 failed that **already failed before this change** (Refund/Loyalty/Payment mock tests still expecting the retired local override tables) |
| **Firebase sign-in fix:** Supabase integration (`--group=supabase`, local PostgreSQL 16 + fake Firebase issuing real RS256 tokens) | 42 / 42 passed (32 existing + 10 new) |
| **Firebase sign-in fix:** all 13 `supabase/tests/*.sql`, `functions` (`npm test`) | all passed (unchanged code) |
| **Auto-link + owner dashboard (2026-10-13):** fast suite (`php artisan test`, new `FakeSupabase` helper) | 121 passed, 45 skipped (Postgres group); the 9 obsolete Refund/Loyalty/Payment mock tests were removed (their Supabase equivalents run in the integration group) |
| **Auto-link + owner dashboard:** Supabase integration (`--group=supabase`, fresh local PostgreSQL 16 with every migration incl. 20261013000000) | 45 / 45 passed (7 that failed before this change now pass) |
| **Server-side auto-link + real data only (2026-10-13, later):** full suite on fresh PostgreSQL 16 | 162 / 162 passed (117 fast + 45 integration); stale Refund/Loyalty/Payment demo tests deleted per `DELETED_FILES.txt` |
| All 13 `supabase/tests/*.sql` on a copy of the live project's state after `supabase/repair/20261010_resync_live_database.sql` | all passed (2026-10-10) |

All database tests ran on a local PostgreSQL 16 with the schema, every migration, and a stub for
the Supabase-only parts (`supabase/tests/local_supabase_stub.sql`), built from scratch.

**Not run:** `flutter analyze` / `flutter test` (the Flutter SDK could not be downloaded in the
build environment) — the Dart change is three small edits; please run both before releasing.
Nothing was run against your real Supabase project.

## 7. Still to do by hand

1. Run the migration and set the `melai_admin_portal` password (2A). If `grant authenticated to
   melai_admin_portal` is refused, run that line as the `postgres` user in the SQL editor.
2. Run `flutter analyze` and `flutter test`.
3. Online refunds: send the money back in the HitPay dashboard (no HitPay refund API is wired).
4. ~~Website and app logins are separate passwords.~~ Done 2026-10-10: website logins are app
   accounts (Firebase). Set `FIREBASE_WEB_API_KEY` + `FIREBASE_PROJECT_ID`, run
   `php artisan migrate` and `php artisan melai:firebase-check`, and check the Firebase console
   items in 2D (Email/Password enabled, API-key restrictions).
5. Rotate the keys flagged in `SECURITY.md` (unchanged by this work).
6. ~~Leaflet map tiles load from the internet (unpkg/OpenStreetMap).~~ The website has no map any more
   (2026-10-16); the app's maps use OpenStreetMap tiles (`MapTiles.url` in `lib/core/widgets/delivery_map.dart`).
