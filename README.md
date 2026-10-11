# melai_nuts

A Prototype

> **Admin website:** the Laravel dashboard is in [`admin/`](admin/README.md) and shares this app's
> Supabase database. Start with [INTEGRATION.md](INTEGRATION.md).

## How to open the admin website

The admin website is a Laravel app in the `admin/` folder. It runs on your computer and
opens in the browser at **http://127.0.0.1:8000**.

**You need:** PHP 8.2+ (with the `pdo_pgsql` and `pdo_sqlite` extensions turned on in
`php.ini`), [Composer](https://getcomposer.org) and [Node.js](https://nodejs.org) 18+.
Check with `php -v`, `composer -V` and `node -v`.

### First time only

Open a terminal in the project folder, then:

```bash
cd admin
composer install
npm install
copy .env.example .env               # macOS/Linux: cp .env.example .env
php artisan key:generate
type nul > database\database.sqlite  # macOS/Linux: touch database/database.sqlite
```

Open `admin/.env` and set:

| Setting | What to put |
|---|---|
| `FIREBASE_WEB_API_KEY` | **required.** The app's Firebase Web API key (Firebase console > Project settings > General; same as `FIREBASE_API_KEY_WEB` in `env/firebase.json`). Website logins are app accounts: sign-in, Create Account and linking all go through Firebase |
| `FIREBASE_PROJECT_ID` | **required.** `melai-nuts-app-2026` (see `.firebaserc`). Check both with `php artisan melai:firebase-check` |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` | a fallback website login for the first set-up (use the owner's email in the app, currently `kanzeki69@gmail.com`; once the owner signs in with the app password it becomes that app account). To change it later, see "Changing the admin email" below |
| `ADMIN_STAFF_UID` | optional: the owner's Firebase UID, to link the first admin from the command line instead |
| `SUPABASE_DB_*` | the `melai_admin_portal` connection (see [INTEGRATION.md](INTEGRATION.md), step 2A) |
| `HITPAY_API_KEY`, `HITPAY_ENV` | optional, for "Send via HitPay" refunds |

Then create the website's tables and first admin, and build the page styles:

```bash
php artisan migrate --seed
npm run build
```

### Run the app and the admin website together (Windows)

* **Double-click `run-all.bat`** (or type `.\run-all.bat` in the project folder). It opens the admin
  website in its own window (http://127.0.0.1:8000, the browser opens by itself) and starts the app
  with `flutter run`. To pick a device: `.\run-all.bat emulator-5554` (ids from `flutter devices`).
* **Android Studio:** choose the run configuration **"App + Admin website"** and press Run.
  (It needs the bundled *Shell Script* plugin; if it is missing, use `run-all.bat`.)
* Only the website: double-click `start-admin.bat`. On the first run it installs everything
  (`composer install`, `.env`, database, `npm run build`) and opens `.env` in Notepad for you to fill in.

The app does not need the website to work (both talk to Supabase directly); running them
together just lets you see changes from one in the other right away.

**Install first (Windows):**
1. **PHP 8.2+**: easiest is XAMPP (PHP 8.2) — then add `C:\xampp\php` to PATH
   (Start → "Edit the system environment variables" → Environment Variables → Path → New).
   In `C:\xampp\php\php.ini` remove the `;` in front of `extension=pdo_pgsql`, `extension=pgsql`,
   `extension=pdo_sqlite`, `extension=zip`.
2. **Composer**: https://getcomposer.org/Composer-Setup.exe (it finds `php.exe` by itself).
3. **Node.js** LTS: https://nodejs.org
4. **Close and reopen** the terminal / Android Studio, then check: `php -v`, `composer -V`, `node -v`.

### Every time you want to open it

```bash
cd admin
php artisan serve
```

Open **http://127.0.0.1:8000** in your browser (Chrome or Edge if you use the USB RFID
reader) and log in with `ADMIN_EMAIL` / `ADMIN_PASSWORD`. Keep the terminal open while you
use the website; press `Ctrl + C` to stop it.

To open it from a phone or another computer on the same Wi-Fi:
`php artisan serve --host=0.0.0.0 --port=8000`, then go to `http://<your PC's IP>:8000`
(find the IP with `ipconfig`).

### Changing the admin email

Change the existing "Melai Admin" login in place (same account, password, role, access and
history) instead of creating a new admin:

```bash
cd admin
php artisan melai:change-admin-email <old email> kanzeki69@gmail.com --uid=<owner Firebase UID>
```

Then set `ADMIN_EMAIL` to the new email in `admin/.env` and run `php artisan config:clear`.
The command refuses an email another login already uses, signs the admin out everywhere, and
links the login to the app's active owner with the new email (checked in Supabase). The seeder
does the same automatically if it finds the "Melai Admin" login under a different email.

### If something goes wrong

| You see | Fix |
|---|---|
| `Vite manifest not found` | run `npm run build` in `admin/` |
| `could not find driver` | turn on `extension=pdo_pgsql` and `extension=pdo_sqlite` in `php.ini`, then restart the terminal |
| "Account not linked" / App account page shows a red state | the page names the exact problem (configuration missing, no app account, app profile missing, email mismatch, role not authorized, no branch, temporarily unavailable) and what to do. The owner must exist in `staff_members` and Firestore (INTEGRATION.md 2A) |
| "Configuration missing … FIREBASE_WEB_API_KEY" | set `FIREBASE_WEB_API_KEY` and `FIREBASE_PROJECT_ID` in `admin/.env`, `php artisan config:clear`, then `php artisan melai:firebase-check` |
| "Database unavailable" | check the `SUPABASE_DB_*` values and password, and that `melai_admin_portal` has `LOGIN` (INTEGRATION.md 2A) |
| Reports / Forecast / Cash Drawer say the database returned an unexpected error | migrations are missing on the Supabase project: run `supabase/repair/20261010_resync_live_database.sql` once |
| Port 8000 already in use | `php artisan serve --port=8001` and open http://127.0.0.1:8001 |
| Changed `.env` but nothing changed | `php artisan config:clear`, then start `php artisan serve` again |

More details: [admin/README.md](admin/README.md).

## Setup: Firebase keys (required)

Firebase API keys are **not committed**. Before running:

```bash
cp env/firebase.example.json env/firebase.json          # then fill in your keys
cp android/app/google-services.json.example android/app/google-services.json  # Android only

flutter run --dart-define-from-file=env/firebase.json --dart-define-from-file=env/supabase.json
flutter build apk --dart-define-from-file=env/firebase.json --dart-define-from-file=env/supabase.json
```

`env/firebase.json` and `android/app/google-services.json` are git-ignored.
See [SECURITY.md](SECURITY.md) for key restriction and rotation.

## Setup: Supabase backend (required)

The app stores all business data (catalog, cart, orders, loyalty, payments,
refunds, notifications, addresses) in Supabase. Firebase remains the identity
provider. The app will not start without these values.

1. In the Supabase dashboard enable **Authentication > Sign In / Providers >
   Third Party Auth > Firebase** and paste your Firebase **Project ID**.
2. Run the SQL in this order (SQL Editor or `psql`):
    1. `supabase/schema.sql` — **only on a new, empty project, and only once.** It
       contains no business data (no sample products, stock, rewards or branch
       details). Never run it again on a project that already has data; to bring an
       existing project up to date run `supabase/repair/20261010_resync_live_database.sql`.
       There is no demo / sample data file: real branches, products and stock are
       entered by the owner.
    2. `supabase/migrations/20260928000000_customer_security_hardening.sql`
    3. `supabase/migrations/20260928010000_order_integrity.sql`
    4. `supabase/migrations/20260929000000_customer_product_search.sql`
    5. `supabase/migrations/20260929010000_customer_realtime.sql`
    6. `supabase/migrations/20260930000000_staff_backend.sql` (staff side, see below)
    7. `supabase/migrations/20260930010000_staff_foundation.sql` (staff foundation: account status, permissions, audit log)
    8. …then every other file in `supabase/migrations/`, in file-name order.
3. Copy `env/supabase.example.json` to `env/supabase.json` and fill in the
   project URL and **anon** key (never the `service_role` key).
4. Run with both files:

```bash
flutter run \
  --dart-define-from-file=env/firebase.json \
  --dart-define-from-file=env/supabase.json
```

`env/supabase.json` is git-ignored. Verify a dev/staging database with the
suites in `supabase/tests/` (dev only; each rolls back its own data).

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Staff backend setup (migration `20260930000000_staff_backend.sql`)

Run it after the earlier migrations (Supabase SQL editor). It adds the staff
registry (`staff_members`), branch inventory batches (FEFO), stock transfers,
walk-in POS sales, staff notifications, the dashboard function and the
row-level-security policies that enforce staff access in the database.

1. Register the first owner once, in the SQL editor:
   `insert into public.staff_members (firebase_uid, full_name, email, role)
    values ('<owner firebase uid>', '<name>', '<email>', 'owner');`
2. Staff created from the app (Owner → User Management) are registered
   automatically. Staff that already existed must be inserted the same way
   with `role = 'staff'` and a `branch_id`.
3. Stock that existed before this migration has no batch: staff give it one
   from a product's page (Receive Stock → "Units already counted in stock").
4. Staff identity is one thing end to end: Firebase UID → `staff_members` row →
   branch + permission flags. After sign-in the app makes a single call,
   `get_my_staff_context()`, which answers `active`, `inactive` or
   `not_provisioned`. Staff screens stay locked (fail closed) until the server
   has confirmed an active row for exactly the signed-in account, and every
   staff store is wiped on sign-out or account switch. The database re-checks
   the same rules on every request, so a modified client gains nothing.
5. The app refuses to start with a `service_role` / `sb_secret_` key in
   `env/supabase.json` (only the anon / publishable key belongs in the app).
6. Verify on a dev database with `psql -v ON_ERROR_STOP=1 -f supabase/tests/staff_identity_test.sql`
   and `psql -v ON_ERROR_STOP=1 -f supabase/tests/staff_foundation_test.sql`.

### Later migrations (run in filename order after the staff foundation)

| Migration | What it does |
|---|---|
| `20261001000000_staff_product_management.sql` | Staff product/variant/cost management; adds the staff catalog read policy. |
| `20261001010000_fix_cart_updated_at.sql` | Cart `updated_at` fix. |
| `20261001020000_seed_loyalty_cart_settings.sql` | Seeds `loyalty_cart_settings`. |
| `20261008000000_owner_sales_summary.sql` | `owner_sales_summary()` for the owner analytics screens. |
| `20261008010000_fix_staff_products_policy.sql` | **Required.** Scopes the staff product policy `TO authenticated`; without it signed-out (guest) catalog reads fail. |
| `20261008020000_staff_idempotency_keys.sql` | Optional `p_idempotency_key` on `staff_adjust_batch` and `staff_request_transfer`: a retry applies once and replays the original result; the same key for a different request is refused. Apply **before** shipping the app build that sends keys. |
| `20261008030000_staff_replay_safe_receive_and_transfer.sql` | `staff_respond_transfer` (ship / reject / cancel / receive) is idempotent by outcome: asking for the state a transfer is already in succeeds as a no-op (authorization still runs first; conflicting actions still error). `staff_receive_batch` gains the optional `p_idempotency_key`, so a replay returns the original batch instead of "code already exists". Same deploy order as above: migration first. |
| `20261009000000_admin_portal.sql` | Functions and the `melai_admin_portal` login role for the Laravel admin website in `admin/` (orders, refunds, stock, products, loyalty, audit log), owner-editable loyalty earn rate (`earn_pesos_per_point`, default 50) and `get_loyalty_earn_rate` for the app. See INTEGRATION.md. |
| `20261010000000_pos_shifts_voids_returns.sql` | Cash drawer shifts (opening / expected / counted cash), paid in/out, POS voids (`void_pos_sales` permission), counter returns, receiving returned items (only sellable units go back to stock), daily cashier summary, optional `branches.pos_requires_shift`. |
| `20261010010000_driver_module.sql` | Driver registry (`drivers`), assignment, accept/reject, pick-up, delivered (proof + COD cash) / failed (order returns to branch), live location only while a run is out (deleted when it ends), customer tracking, proof-photo bucket policies, branch/address coordinates. |
| `20261010020000_analytics_forecasting.sql` | `analytics_report` (gross/net/refunds/pending, by day/branch/method/category, best/slow sellers, customers, loyalty, drivers, inventory value), `analytics_sales_forecast` (OLS + weekday effect, chronological hold-out MAE/RMSE), saved forecasts vs actuals, reorder suggestions, expiring batches. |
| `20261011000000_loyalty_cards.sql` | RFID loyalty card registry: register / replace / block / unblock (owner), tap lookup at the POS, append-only card history. Only a hash of the card UID is stored; existing `rfid_card_number` values that look like card UIDs are moved in. See `hardware/rfid-reader/`. |
| `20261011010000_suppliers_purchase_receipts.sql` | Suppliers and purchase receipts (supplier invoices). OCR fills a **draft**; stock is posted only on approval (through `staff_receive_batch`, so FEFO batches and stock movements as usual), latest purchase cost recorded, the same supplier invoice can never be posted twice. |
| `20261011020000_hitpay_refunds.sql` | Online refunds through the HitPay Refund API: one live attempt per refund (no double refunds), succeeded / pending / failed, and closing an unanswered attempt after checking the HitPay dashboard. |
| `20261016000000_delivery_pins_app_only.sql` | Delivery pins: the customer's pin is snapshot on the order at checkout (immutable once set; 0,0 refused), runs / candidate orders / customer tracking read that snapshot, riders lose a stop's address, pin and phone as soon as that stop (or the run) is finished, and `staff_order_delivery_pins` gives staff (own branch) / owner the pin for the order screen. Test: `supabase/tests/delivery_pins_test.sql`. |

Verify with the suites in `supabase/tests/`, including
`delivery_pins_test.sql`, `loyalty_cards_test.sql`, `purchase_receipts_test.sql`, `hitpay_refunds_test.sql`,
`receiving_cards_refund_concurrency_test.sh`, `pos_shift_void_return_test.sql`, `driver_module_test.sql`,
`analytics_forecast_test.sql`, `pos_driver_concurrency_test.sh`,
`staff_cross_branch_test.sql` (cross-branch isolation, permission flags, replay
behaviour) and `staff_idempotency_concurrency_test.sh` (simultaneous duplicate
requests apply once).

### Staff foundation (migration `20260930010000_staff_foundation.sql`)

Run it right after the staff backend migration (it is idempotent).

- **Account status** is now `active | inactive | suspended`
  (`staff_members.account_status`); `is_active` became a generated column, so
  the two can never disagree. Owners suspend/restore with
  `owner_set_staff_status(uid, status)`; `owner_set_staff_active` still works.
  Re-provisioning a suspended account does **not** lift the suspension.
- **Profile fields**: `phone`, `profile_image`. `email` is kept in step with the
  verified Firebase token by `staff_sync_my_identity()` (the value comes from the
  JWT on the server, never from the client).
- **Permissions**: `staff_permission_catalog()` lists the permission keys,
  `staff_permission_grants` holds explicit grants, and `staff_permission_keys()`
  is the one function that decides what a caller holds (owner = everything;
  active staff = baseline + their two legacy flags + grants; anyone else =
  nothing). `get_my_staff_context()` returns that list plus
  `authorized_branches`, so the app displays exactly what the server computed.
- **Audit log**: `staff_audit_logs` is append-only (no client INSERT/UPDATE/DELETE,
  and a trigger blocks changes even for privileged roles). Rows arrive through
  `staff_log_audit(...)`, which derives the actor and branch from the verified
  token. Server RPCs written in later batches call the internal `_write_audit`.
- **Local SQLite** (`melai_staff.db`, `lib/core/services/sqlite_service.dart`)
  holds the offline staff context cache and the sync queue. It is a cache, never
  an authority. On Linux/Windows desktop it needs the platform `sqlite3`
  library; Android/iOS use the sqflite plugin; on web it is unavailable and the
  app simply has no offline staff cache.

## Drivers (migration `20261010010000_driver_module.sql`)

Accounts the owner creates with the **Delivery** role are now registered in
the database's driver registry automatically. Drivers who already existed must
be added once: `select public.owner_upsert_driver('<uid>', '<name>', '<email>', '<branch uuid>');`
(as the owner, or insert into `public.drivers` in the SQL editor). Run
`flutter pub get` (new dependency: `geolocator`). Location is shared only while
the app is open and the driver has turned it on for a run they picked up.
Navigation opens Google Maps, Waze or Apple Maps on the customer's pin (no API key needed). See
`docs/FEATURE_AUDIT.md` and `docs/ROADMAP.md` for what is still open.

## RFID loyalty cards (Arduino)

Build the reader from `hardware/rfid-reader/README.md` (Arduino + RC522, about ₱500).
Uno/Nano: USB serial, used by the admin website's **Loyalty Cards** page (Chrome/Edge).
Pro Micro/Leonardo: acts as a keyboard, so it works with the POS app's
"Find loyalty customer" box on an Android tablet (USB-OTG) as well. In the POS app,
open the customer lookup and tap the card; to give a customer a card, find them by
phone/e-mail and press the card icon next to their name.

## Delivery (app only) and maps

Delivery lives only in the app — the admin website has no delivery function (see INTEGRATION.md):

* **Customer:** pins each saved address on a full-screen map picker (drag the map or tap; "Use my
  current location"; optional address search). A delivery order cannot be placed without a valid
  pin; checkout shows the pin for review and a one-tap "Pin on map". The pin is copied onto the
  order (migration `20261016000000_delivery_pins_app_only.sql`), so staff and the rider see exactly
  that point even if the address is edited later. Tracking shows the rider, the pin and the branch.
* **Driver:** every stop's pin on the run map (numbered, next stop highlighted, own position while
  sharing), Navigate (Google Maps / Waze / Apple Maps on the pin) and Call while the run is active.
  A stop without a pin says "Customer didn't pin a location – call them".
* **Staff / owner:** the order screen shows the customer's pin, distance from the branch and
  "Open in Maps" (pin icon on the order list); Create Delivery shows every candidate's pin with the
  branch and asks before dispatching unpinned orders; Delivery Management has the open stops' map,
  a live driver map (all branches for the owner, refreshed every 10 s), the driver directory, and
  assign / unassign driver and cancel run on each run. Staff open it from the truck icon in the
  staff portal.

Maps use OpenStreetMap tiles (`flutter_map`, no API key, attribution on every map). Set branch
coordinates once: `update branches set latitude = 14.2117, longitude = 121.1653 where name = 'Calamba';`.
For heavy traffic, point `MapTiles.url` (`lib/core/widgets/delivery_map.dart`) at a paid or own tile
server (OSM tile policy). Address search uses Nominatim (free, rate-limited); pins work without it.

## Payments (COD + HitPay)

> **Online payment is temporarily disabled.** Checkout shows "Online Payment (GCash, Maya, Card)"
> greyed out as unavailable; customers pay Cash on Delivery or Cash on Counter Pickup. Nothing was
> removed. The database refuses new online orders while `payment_settings.online_payment_enabled`
> is false (migration `20261017000000_online_payment_switch.sql`), and `hitpay-create-payment`
> refuses to open a payment page. To turn it back on: run
> `update public.payment_settings set online_payment_enabled = true where id = 'default';` in the
> SQL editor and build the app with `--dart-define=ONLINE_PAYMENT_ENABLED=true`
> (`lib/core/config/payment_config.dart`), then redeploy `hitpay-create-payment`.

Checkout offers, depending on the fulfillment method:

- **Online Payment (GCash, Maya, Card)**: always available. The order is placed first, then the customer pays on HitPay's hosted checkout (PHP). The payment becomes `success` only when HitPay's signed webhook reaches the `hitpay-webhook` Edge Function; the app just shows the live status.
- **Cash on Delivery**: delivery orders only. The customer pays the rider; staff press "Confirm Cash Received".
- **Cash on Counter Pickup**: pickup orders only; staff confirm the cash at the counter.

Setup: apply `supabase/migrations/20261007010000_cod_and_hitpay.sql`, then follow
[`supabase/functions/README.md`](supabase/functions/README.md) to create the HitPay
account, set the secrets (`HITPAY_API_KEY`, `HITPAY_SALT`, `HITPAY_ENV`,
`HITPAY_REDIRECT_URL`) and deploy `hitpay-create-payment` and `hitpay-webhook`.
No payment secrets are ever stored in the app.

**Refunds:** an approved online refund is sent back to the customer's GCash / Maya / card
with **Send via HitPay** (admin website → Refunds, or the staff app's refund card). Deploy
`hitpay-refund` (`supabase functions deploy hitpay-refund --no-verify-jwt`) and, for the
website, set `HITPAY_API_KEY` / `HITPAY_ENV` in `admin/.env`. Refunding from the HitPay
dashboard and pressing "Mark refunded" still works.

## Phone login (Android)

"Log in with phone number" (SMS one-time code) is an extra sign-in option on the
login screen. It is shown on Android only; email + password is unchanged. A phone
sign-in creates its own customer account (no email) — it is not linked to an
existing email account of the same person.

1. **Enable the provider:** Firebase console > Authentication > Sign-in method >
   Phone > Enable.
2. **Add test numbers (free, avoids the ~10 real SMS/day quota on new projects):**
   Authentication > Sign-in method > Phone > *Phone numbers for testing*. Add e.g.
   `+63 917 123 4567` with a fixed code such as `123456`. No SMS is sent for these.
3. **Add your debug fingerprints** (without them Android phone auth fails with
   "app not authorized"): Project settings > Your apps > Android app > *Add
   fingerprint* — add both **SHA-1** and **SHA-256**. Then **re-download
   `google-services.json`** and replace `android/app/google-services.json`.
4. **Read the debug SHA-1 / SHA-256 on Windows:**

   ```powershell
   cd android
   .\gradlew signingReport
   ```

   Use the values listed under the **`debug`** variant. Alternative with keytool
   and the default debug keystore:

   ```powershell
   keytool -list -v -keystore "$env:USERPROFILE\.android\debug.keystore" -alias androiddebugkey -storepass android -keypass android
   ```

   Release builds need the release keystore's fingerprints added the same way
   (and the Play App Signing certificate if you publish via Google Play).
5. **Firestore rules:** a phone-only customer has no email, so the self-sign-up
   rule for `users/{uid}` must allow the phone provider (see the rules change
   proposed alongside this feature) and be deployed:
   `firebase deploy --only firestore:rules`.