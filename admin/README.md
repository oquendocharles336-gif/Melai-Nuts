# Melai Nuts Admin (web)

The owner/staff web dashboard for the Melai Nuts platform. It is a Laravel 12 app that lives in
`admin/` next to the Flutter app and works on **the same Supabase database** the app uses.
See `../INTEGRATION.md` for how the pieces fit together.

## What it does

| Page | With `DATA_SOURCE=supabase` (real data) |
|---|---|
| Dashboard | Net/gross paid sales, refunds, average order value, orders by status, sales by payment method, unpaid/failed payments, customers, low/out-of-stock for today/week/month (plus today's figures when a longer period is shown); sales per branch vs. target, top branches, stock health per branch, loyalty totals. **Owners:** every branch by default with a branch filter, and every staff account (role, branch, status, POS sales per cashier, shifts, open drawers, last activity, top cashiers). Staff: their own branch only. Updates by itself when data changes (live pulse, `MELAI_LIVE_POLL_SECONDS`); database answers are cached 45 s per account (`DASHBOARD_CACHE_SECONDS`, `?fresh=1` skips it) |
| Sales | Revenue per branch (today / 7 days / window), daily revenue, top products and **sales per cashier** across all branches (owners); own branch (staff) |
| Products | Full catalog with variants, prices and stock; admins can hide/show a product in the app |
| Inventory | All-branch overview (carried / low / out of stock per branch) and, per branch, stock per variant, restock thresholds, recent stock movements |
| Cash Drawer | Shifts and the per-cashier daily summary; owners see all branches added up by default, or one branch |
| Payments | All orders' payments, totals per method, **mark cash paid** |
| Refunds | Refund requests from the app: approve (cash: one step), mark online refunds completed with the HitPay reference, reject with a reason the customer sees |
| Loyalty | Members, balances, history; owners edit the earn/redeem rules and add/deduct points |
| Users | Website logins, access, activation, approvals; which app account each login is linked to (unlink if needed); **disable / enable** a staff member's or customer's app account (with an "Are you sure?" step; needs migration `20261029000000_admin_portal_account_status.sql`) |
| Activity Logs | This website's log + the app's append-only staff audit log |

**Delivery is not on the website.** Runs, dispatch, riders, live tracking and customer map pins are handled only in the
Melai Nuts app (owner / staff create and dispatch runs, riders deliver, customers track). Riders sign in to the app only:
a website login with any role other than admin / staff is refused. Delivery orders still appear on Orders, Sales, Reports
and Refunds as a read-only channel ("Online · delivery"), with no address, map, rider or "next stage" button.

There is no demo mode on the website: every number comes from the Supabase database, and the
website's code has no other data source (no `DATA_SOURCE` setting). Test fixtures live only in
`admin/tests/` (`tests/Support/MockDataSource.php`, `MockPlatform.php`, `FakeSupabase.php`) and are
bound only by the test suite. When real data is missing the pages say so ("No sales yet",
"No target set", "—"); nothing is invented.

## Setup

Requirements: PHP 8.2+ with `pdo_pgsql` and `pdo_sqlite`, Composer, Node 18+.

```bash
cd admin
composer install
npm install
cp .env.example .env
php artisan key:generate
touch database/database.sqlite        # Windows: type nul > database\database.sqlite
```

Fill in `.env` (see `.env.example`): `FIREBASE_WEB_API_KEY` + `FIREBASE_PROJECT_ID` (required),
`ADMIN_*` and the `SUPABASE_DB_*` connection for the `melai_admin_portal` role (setup in
`../INTEGRATION.md`, step 2). Check Firebase with `php artisan melai:firebase-check`. Then:

```bash
php artisan migrate                   # local website tables
php artisan db:seed                   # the one real admin from ADMIN_EMAIL / ADMIN_PASSWORD, linked to the owner
npm run build                         # or `npm run dev` while developing
php artisan serve                     # http://127.0.0.1:8000
```

Sign in with `ADMIN_EMAIL` + `ADMIN_PASSWORD` (or the owner's app email + password when Firebase is
set up). The "Melai Admin" login acts as the owner's app account straight away: there is no
"link my account" step, no second sign-in, and no "Account not linked" page anywhere.

## Sign-in flow (automatic link)

At **every** successful sign-in, before the person is signed in, `App\Services\Auth\AutoLinker`
sets `users.staff_uid`, so a missing or changed link repairs itself:

* **Website password** (Firebase not configured, or the website's own password):
  1. the current `staff_uid`, if it still checks out;
  2. admin login: `ADMIN_STAFF_UID` from `.env` (the standard setup);
  3. the active `staff_members` row whose email equals the login's email, with the role that fits
     the login (admin → `owner`, staff → `staff`), found by `portal_staff_uid_for_email()` — a
     function only the website's own database login may call, which returns a UID and nothing else.
  A login bound to a Firebase account only ever uses that account's UID.
* **Firebase** (app email + password): the UID in the verified ID token (as before).

Every candidate is **verified by Supabase as that UID** (`get_my_staff_context()` through
`SupabaseGateway::actingAs()`): active, same email, right role, not linked to another login. Only
then is `staff_uid` saved and `account.auto_linked` logged. If nothing matches (no owner/staff row
with that email, `ADMIN_STAFF_UID` is not an active owner, deactivated account, database
unreachable), the **login page** shows the exact reason and the sign-in is refused
(`auth.autolink_failed`). A website registration still waiting for approval goes to "Waiting".

During the session every query runs `actingAs(users.staff_uid)`, so RLS and the SQL role checks
apply; the account's status is checked with Supabase on every request, and a deactivated or
suspended account is signed out to the login page with the reason. Sessions that signed in with
Firebase also keep the ID token check (refreshed silently; revoked or disabled accounts are cut
off). The UID never comes from a request, a cookie or other input. Passwords are never stored.

**Security trade-off (by request):** a website password is now enough to act as the linked app
account; there is no separate app sign-in. Keep `ADMIN_PASSWORD` strong and private, and give
website logins only to people who should have that app account's rights.

## Accounts and permissions

* Website logins are Melai Nuts app accounts (Firebase Authentication). Sign-in and Create Account
  go through Firebase; the website verifies the Firebase ID token (Google signature, project,
  expiry) and keeps it in the session. The local `users` table only stores website flags
  (access, active, role) and the links (`firebase_uid`, `staff_uid`).
* Create Account makes a new Firebase account and waits (no access, no rights) until an active
  owner approves it on Users, which registers it in the app (staff with a branch, or owner).
* What it can **see and do with business data** is decided by Supabase: each login is linked
  (`users.staff_uid`) to an app account in `staff_members`, and every database call runs as that
  account. Owners see all branches; staff see only their branch and only have the permissions
  the owner gave them in the app.
* Linking happens at sign-in (see "Sign-in flow") and is always confirmed by Supabase (active,
  same email, right role). One app account can be linked to one login only (unique
  `users.staff_uid`). Admins can still unlink on the Users page or use
  `php artisan melai:link-staff`. Every query runs through `SupabaseGateway::actingAs()` as that
  UID, so RLS and the SQL role checks apply. Only accounts whose Supabase role is `owner` get the
  all-branch view; staff stay limited to their own branch.
* Deactivating someone in the app's User Management cuts their website access to data
  immediately, even if the website login is still active.

## Tests

```bash
php artisan test                      # fast tests: fake data, plus FakeSupabase/FakeFirebase for the
                                      # sign-in and owner/staff scope tests; the Postgres tests are skipped
```

Supabase integration tests (real Postgres with the app's schema, local only):

```bash
PGADMIN_URL=postgresql://postgres@127.0.0.1:5432/postgres bash tests/Supabase/prepare-test-db.sh
SUPABASE_TEST_ADMIN_URL=postgresql://postgres@127.0.0.1:5432/melai_portal_test \
SUPABASE_TEST_PORTAL_URL=postgresql://melai_admin_portal:portal-test-pw@127.0.0.1:5432/melai_portal_test \
  php artisan test --group=supabase
```

## Where to change things

* Brand colors / login photo: `resources/css/melai.css`.
* Optional daily sales targets per branch: `config/melai.php` → `targets` (matched to the app's
  branches by name) or `DEFAULT_DAILY_TARGET`. Without a target a branch shows its real sales and
  "No target set" — no target is invented. Stock-health thresholds are also in `config/melai.php`.
* Loyalty rules: on the Loyalty page (owners) — they are stored in Supabase and used by the app.
