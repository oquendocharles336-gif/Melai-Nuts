# Melai Nuts — dummy / hardcoded data audit

**Latest round: 2026-10-18 (Phase 0 — "no hardcoded data").** The earlier rounds (2026-10-10 and
2026-10-13) are kept below unchanged for history.

## 0. 2026-10-18: full inventory of hardcoded values and what was done

Scope: `lib/`, `admin/` (app, config, resources, routes, database/seeders, public/js), `supabase/`
(schema.sql, migrations, functions, repair), `functions/`, `hardware/`, `*.bat`, `env/`, Android
example files and the docs. Decisions: **removed**, **→ DB setting** (owner edits it on the admin
website, *Settings > Business settings* or *Loyalty*), **→ env** (per-install configuration, never in
Git), or **kept** (a true technical constant; reason given).

### 0.1 Business data and seeded records

| # | Hardcoded item | Where | Decision |
|---|---|---|---|
| 1 | 5 seeded products, their prices / descriptions, 12 stock rows at 50 units, 3 rewards, promotion "Fresh Batch Every Friday", seeded branch address / phone / hours | live database (old `schema.sql` seed) | **Removed by reviewed SQL**: `supabase/repair/20261013_cleanup_seeded_demo_records.sql` (sections A–D, F; every section ROLLBACK until the owner commits; tested by `supabase/tests/cleanup_seeded_demo_records_test.sh`). The 2 seeded products that were sold stay visible and are flagged for price review. |
| 2 | Demo orders ORD-1001…1004 | live database | **Flagged for the owner only** (section E, SELECT); never deleted by SQL — refund through the app/website if they were tests. |
| 3 | Starter loyalty rules (1 pt = ₱1 off, max 50 % of an order) | `migrations/20261001020000_seed_loyalty_cart_settings.sql` | **Removed**: the migration is now structure-only (`select 1`). Existing databases keep their row. → **DB setting** (Loyalty page). |
| 4 | Loyalty earn-rate fallback "1 point per ₱50" | `compute_points_earned()`, `get_loyalty_earn_rate()`, column default 50, `loyalty_repository.dart` (`?? 50`), `customer_data_store.dart` (`= 50`) | **→ DB setting**. No rate set = 0 points earned and "Earn rate not set yet" / "Not set" (migration `20261018000000`, `EarnRate` in the app). |
| 5 | Restock threshold fallback 20 | `_default_restock_threshold()`, `staff_repository.dart` (`?? 20`), `InventoryBatch(restockThreshold = 20)` | **→ DB setting** `business_settings.restock_threshold_default`. Not set = no "low stock" warning (out-of-stock still flagged); screens say "Restock level not set". |
| 6 | Stock-health ratios 0.4 / 0.8, sales rating ratios 0.7 / 1.0 | `admin/config/melai.php` | **→ DB setting**. Not set = "Not rated". |
| 7 | Daily sales targets (`targets`, `DEFAULT_DAILY_TARGET`) | `admin/config/melai.php`, `.env.example` | **→ DB setting**: `branches.daily_sales_target` or `business_settings.default_daily_sales_target`. Not set = "No target set". |
| 8 | "Healthy margin" lines 50 % and 55 % | `add_product_screen.dart`, `edit_product_screen.dart`, `product_pricing_screen.dart`, `product_variants_screen.dart` | **→ DB setting** `healthy_margin_percent` (`MarginIndicator` / `rateMargin`). Not set = margin shown without a rating. A variant without a cost price shows "COGS: not set" instead of ₱0.00 / 100 %. |
| 9 | Delivery fee default 0 for new branches | `branches.delivery_fee default 0` | **Removed default**: a branch must be given its real fee (`owner_save_branch`, Business settings page). |
| 10 | Branch address / phone / hours | seeded values | **→ DB** (branches table), editable on *Business settings > Branches* (`owner_save_branch`, audited). |
| 11 | "Top up to 2× threshold" restock suggestion, pre-filled receive quantity | `inventory_item.dart`, `inventory_batch.dart`, `low_stock_screen.dart`, `receive_batch_screen.dart`, `batch_details_screen.dart` | **Removed** (invented rule). Screens show "N below level" (derived from real numbers); staff type the real received quantity. The demand-based suggestion remains the database's `staff_reorder_suggestions`. |
| 12 | Online-payment "unavailable" text | trigger, app constant | **→ DB setting** `payment_settings.online_payment_disabled_message` (checkout, order trigger and `hitpay-create-payment` all show it). |

### 0.2 Accounts, identities, keys

| # | Hardcoded item | Where | Decision |
|---|---|---|---|
| 13 | Owner's personal e-mail | `README.md`, `INTEGRATION.md`, `ChangeAdminEmailCommand`, `LinkStaffCommand`, `ChangeAdminEmailTest`, `.env.example` | **Removed** → `owner@example.com` placeholder. The seeder refuses the placeholder outside tests, and refuses to run without `ADMIN_EMAIL` / `ADMIN_PASSWORD` (tests added). |
| 14 | Firebase project ID | `FirebaseConfig.php` message, `.env.example`, `grant-role-claim` (default), `supabase/functions/README.md`, `docs/FIX_ANON_ROLE.md`, `INTEGRATION.md`, `README.md`, `lib/firebase_options.dart`, test fake | **→ env**: `FIREBASE_PROJECT_ID` (admin `.env`, Edge Function secret — now required, no default — and `env/firebase.json`). |
| 15 | Firebase app IDs, sender ID, bucket, auth domain, iOS bundle ID | `lib/firebase_options.dart` | **→ env** (`env/firebase.json`, see `env/firebase.example.json`). The app refuses to start without them. |
| 16 | **Real API keys and the Supabase anon key inside the *example* files** | `env/firebase.example.json`, `env/supabase.example.json`, `android/app/google-services.json.example` (+ a duplicate in `android/app/src/`) | **Removed** → placeholders; duplicate deleted. The keys were in Git: rotate/restrict them (see `SECURITY.md`, owner checklist). |
| 17 | Default admin credential / fallback password | — | None left (checked: `config/melai.php`, `AdminSeeder`, `.env.example`). |
| 18 | Support e-mail `support@melainuts.ph` (invented) | `forgot_password_screen.dart` | **Removed** ("Ask the store owner or your branch staff"). |
| 19 | `.firebaserc` project ID | repo root | **Kept**: it is the Firebase CLI's own config file (not a secret, single place); everything else reads env. |

### 0.3 UI-only invented values

| # | Item | Where | Decision |
|---|---|---|---|
| 20 | Branch names / "Laguna" in text ("Calamba • Los Baños • Santa Cruz", "Laguna Provincial Hub", "Laguna Enterprise Overview", default province "Laguna", …) | splash, login, customer access, loyalty dashboard, forgot/reset password, owner portal, `AppConstants.hubLabel`, `customer_profile.dart` | **Removed** (branches come only from the `branches` table). |
| 21 | Sample people in hints ("Elena Santos", "elena@example.com", "Juan dela Cruz", "Laguna Van #04", "09123456789") | register, create delivery | **Removed** → format hints ("Your full name", "you@example.com", "09XXXXXXXXX"). |
| 22 | "Ready in 30 mins", "Verified Patron", "Step 1 of 2 • 50% Done" | checkout | **Removed** (not backed by data). |
| 23 | "Includes 12% Philippine VAT" | cart | **Removed** (a tax claim the data does not support). |
| 24 | "Healthy" stock badge without a threshold | `stock_status_badge.dart` | Now "In stock" (no rating claim). |
| 25 | Fallback names "Customer", "Driver", "Rider", "Branch", "Run", "Melai Nuts" | 12 places in `lib/` | **Removed** → "—". |
| 26 | Admin theme preview "₱24,180.00 ↑ 12.4%" | `settings.blade.php` | **Removed** (preview shows colours only). |
| 27 | Login placeholder `admin@melainuts.com` | `login.blade.php` | → `you@example.com`. |
| 28 | Version label "v1.0.0" | `settings_screen.dart` | **Removed** (stale constant). |
| 29 | Unused "Quick Demo Role Switcher" widget | `role_badge_card.dart` | **Deleted**. |
| 30 | Empty states that did not say how to fix them | catalog, home, POS, inventory | Now name what is missing and how to add it. |
| 31 | Customer "Low Stock" label at ≤ 10 units (found in Phase 4) | `Product.fromRow` in `lib/data/models/product.dart` | **→ DB setting** `business_settings.low_stock_badge_qty` (migration `20261023000000`, read with `get_storefront_settings()`): "Only N left" from the branch's real stock; Not set = never shown. |

### 0.4 Kept on purpose (true technical constants)

| Item | Where | Reason |
|---|---|---|
| `walk-in` customer profile | migrations, POS | Technical sentinel for anonymous counter sales; not a person. Allowed by `fresh_install_check.sql`. |
| `payment_settings` row with online payment OFF | migration `20261017000000` | Owner decision; the only row a fresh database holds. |
| Order code format `ORD-` + sequence from 1001 | `schema.sql` | Identifier format, not data. |
| App name / tagline "Melai Nuts Retailing", "Local Goodness." | `AppConstants` | Branding. |
| FEFO urgency tiers 15 / 45 days, expiring-batch window 30 days, reorder-analysis defaults (28-day lookback, 7-day lead time, 3 safety, 14 cover) | `inventory_batch.dart`, `SupabaseRepository` | Display / analysis parameters shown with their values on the page; candidates for Business settings later (not business data). |
| Timeouts, cache sizes, page sizes, login rate limit 5/min, driver GPS distance filter 20 m | various | Technical tuning. |
| `+63`, `09XXXXXXXXX`, PHP currency | phone utils, hints | Country / format rules. |
| HitPay / OpenStreetMap / Nominatim / Google identity endpoints | services | Fixed public API endpoints. |
| Test fixtures (`admin/tests/Support/*`, `test/support/*`, `supabase/tests/*`, `UserFactory`) | tests only | Never shipped; enforced by the guard below. |

### 0.5 Guards and checks added

* `scripts/check_no_fixture_data.py` (+ `scripts/test_check_no_fixture_data.py`): fails if fixture classes,
  the words demo / dummy / sample / mock / fake / lorem (in code), known fixture or old-seed strings,
  personal e-mail, the real project identifiers, or real-looking keys appear in shipping code or example
  files. Allow-list with mandatory reasons: `scripts/hardcoded-data-allowlist.txt` (2 entries). Runs in CI.
* `supabase/tests/fresh_install_check.sql`: a project built from `schema.sql` + every migration has **0**
  branches, categories, products, variants, stock, batches, rewards, promotions, vouchers, orders,
  payments, refunds, loyalty settings/accounts, business settings, staff, customers (except the
  `walk-in` sentinel), deliveries and suppliers; online payment OFF; earn rate and restock threshold
  "Not set".
* `scripts/run-sql-tests.sh` also re-runs every migration on a database holding real values and
  checks that none of them changed (branch details, loyalty rules, business settings, payment text).
* `supabase/tests/business_settings_test.sql` (39 checks), `admin/tests/Feature/BusinessSettingsTest.php`,
  `EmptyDatabaseTest.php`, `SupabaseIntegrationTest::test_business_settings_…`, Dart tests
  `earn_rate_test.dart`, `business_settings_test.dart`, `payment_config_test.dart`.

### 0.6 What remains

* The live database still holds the seeded rows until the owner runs the clean-up (staging first —
  see `docs/PRODUCTION_RUNBOOK.md`).
* On an existing database the old built-in values (threshold 20, ratios, margin 50 %) are carried over
  once into `business_settings` with `carried_over = true`; the admin page asks the owner to confirm them.
* The Flutter app could not be compiled here (no Flutter SDK can be downloaded in this environment):
  every changed Dart file was parsed with a Dart 3 grammar (tree-sitter-dart), not type-checked.

---

# Earlier rounds (history)

## Melai Nuts — dummy data audit (2026-10-10)

Scope: Flutter app (`lib/`, 218 Dart files), Laravel admin (`admin/`), Supabase SQL (`supabase/`),
Edge Functions, Firebase Functions (`functions/`), scripts, and a **read-only** look at the live
Supabase project. Every screen's data source was traced, not only keyword searches.

## 1. What was found and what was done

| # | Dummy data / simulation found | Where | Done |
|---|---|---|---|
| 1 | Demo data source as the website's **default** (`DATA_SOURCE=mock`): fake orders, customers, stock, drivers, loyalty totals (1,248 members…) | `admin/app/Services/Data/MockDataSource.php`, `config/melai.php` | Moved to `admin/tests/Support/` (tests only). Website ignores `mock` outside `APP_ENV=testing`. |
| 2 | **Simulated PayMongo refunds**: with no key it returned "accepted" with a made-up `mock_rf_…` reference | `PayMongoService`, `WebhookController`, `refunds.retry` route | Removed (the app uses HitPay). |
| 3 | **Second, local copy of business actions** (refund decisions, cash "paid", points ledger) used by demo mode | `OrderOverride`, `LoyaltyEntry`, `LoyaltySetting`, `LoyaltyService`, mock branches of Payment/Refund/Loyalty controllers | Removed; every action goes to the shared database and is confirmed by it before a success message. |
| 4 | Legacy Firestore data source (only orders/drivers wired, rest empty) | `FirestoreDataSource.php` | Removed. |
| 5 | Invented **sales targets** (₱6,000 / ₱5,000 / ₱4,500 a day) rating real sales Low/High, and invented **map coordinates** | `config/melai.php` | Targets are opt-in (`targets`, `DEFAULT_DAILY_TARGET`); without one: "No target set". Map pins come from `branches.latitude/longitude` in the database. |
| 6 | Default **demo admin account** (`admin@melainuts.test` / `ChangeMe#2026`) | `config/melai.php`, `AdminSeeder`, `.env.example` | No defaults; seeder refuses without `ADMIN_EMAIL`/`ADMIN_PASSWORD`. |
| 7 | Stale placeholder pages ("coming in a later phase", "app does not record GPS") | `section.blade.php` | Replaced; all sidebar pages are live. |
| 8 | Admin "out of stock / running low" counted products a branch never carries (quantity shown as 0) | `admin_portal_stock()` | New migration `20261012000000_admin_portal_stock_carried.sql`; dashboard ignores items not carried. |
| 9 | **Owner profile hardcoded**: "Maria Melai", "MN-OWNER-2024-001", "owner@melainuts.com" | `owner_profile_screen.dart` | Shows the signed-in owner's real record. Dead "Help & Support" button removed. |
| 10 | **Fake GPS**: animated van and "Speed (sim.) 32 km/h" | `gps_tracking_screen.dart` | Shows real positions from `staff_get_delivery_tracking` (refresh 15 s); "No live location" when none. |
| 11 | **Fake turn-by-turn directions** (template text) | `route_details_screen.dart` | Removed; real Google Maps directions when both ends have coordinates. |
| 12 | **Fake proof of delivery** (signature/photo tiles that only turned green) | `delivery_confirmation_screen.dart` | Removed; note only (photo proof is taken in the driver app). |
| 13 | **Fake "Packed" toggle and "Simulated: exported as PDF"** | `delivery_manifest_screen.dart` | Removed; real "Copy manifest" to clipboard. |
| 14 | **"Simulated: calling …"** | `next_stop_screen.dart` | Calls the order's real contact number; disabled when none. |
| 15 | "ETA shifts later" (invented impact) | `delayed_delivery_screen.dart` | Shows saved estimates and says they are not recalculated. |
| 16 | Illustrative zig-zag "map" when there are no coordinates | `route_map_screen.dart` | Removed; honest empty state. |
| 17 | "Route optimized" / "Optimized Stop Sequence" — no optimization exists | route screens, `delivery.dart` | Relabelled "Route plan" / "Stop sequence"; estimates labelled as estimates. |
| 18 | "On-Time Rate" that was really delivered ÷ all stops | `delivery_dashboard_screen.dart` | Replaced by "Stops delivered x/y" ("—" when none). |
| 19 | Unreachable legacy rider portal with "ROUTE ENGINE (SIMULATED)" | `delivery_portal_screen.dart`, `delivery_profile_screen.dart` | Deleted (riders use `DriverPortalScreen`). |
| 20 | Hardcoded branch list used for account creation, validation, branch picker, splash | `AppConstants.branches` | Removed; branches always from the `branches` table. |
| 21 | Fake "Preferred branch set to …" success (nothing saved) for staff/owner | `branch_settings_screen.dart` | Staff/driver: read-only assigned branch. Owner: real branch switch. |
| 22 | Dark mode / Language switches that changed nothing | `settings_screen.dart` | Removed. |
| 23 | Invented loyalty tiers ("Gold Tier" ≥ 500 pts) | `customer_profile_screen.dart` | Shows the real points balance. |
| 24 | "Copy" order number button that did nothing | `order_confirmation_screen.dart` | Copies for real. |
| 25 | Misleading name `dummy_data/dummy_deliveries.dart` (real data inside) | `lib/data/` | Renamed `lib/data/views/branch_deliveries.dart`. Unused "coming soon" widget deleted. |
| 26 | **Demo seed in `schema.sql`**: 5 products, 50 units of stock everywhere, rewards, promo, branch address/phone — and upserts that overwrite real branch details on every re-run | `supabase/schema.sql` | Removed from schema. The separate `supabase/seed/dev_demo_catalog.sql` was **deleted on 2026-10-13**: the project has no demo data file. |

## 1b. Follow-up (2026-10-13): real data only

| Found | Done |
|---|---|
| Files listed in `DELETED_FILES.txt` were still present (`app/Services/Data/MockDataSource.php`, `FirestoreDataSource.php`, `OrderOverride`, `LoyaltyEntry`, `LoyaltySetting`, `LoyaltyService`, `PayMongo/`, `WebhookController`, `UpdateLoyaltySettingsRequest`, the old Refund/Loyalty/Payment demo tests, and the Flutter leftovers `portal_placeholder_screen.dart`, `lib/data/dummy_data/`, `delivery_portal_screen.dart`, `delivery_profile_screen.dart`) | Deleted (nothing referenced them). |
| A `mock` switch still existed in the website code (`DATA_SOURCE`, `config('melai.data_source')` in `AppServiceProvider`, `Platform`, `StaffIdentity`, `EnsureSupabase`, `AdminEmailChanger`, `AdminSeeder`, the panel layout) | Removed. `DataSource` is always `SupabaseDataSource`; `Platform::isSupabase()` is always true. Fixtures are bound only by `tests/TestCase.php`. A test proves that `APP_ENV=production` + `DATA_SOURCE=mock` still reads Supabase and shows no fixture data. |
| `supabase/seed/dev_demo_catalog.sql` (invented catalog) | Deleted; references removed from `README.md`, `schema.sql` and the review script. Not referenced by `run-all.bat` / `start-admin.bat`. |
| Landing page hardcoded the branch names (Calamba, Los Baños, Santa Cruz) | Removed (the public page cannot read the database; it now says "every Melai Nuts branch"). |
| "Customer" / "Driver" shown when a name is missing | Shows "—". |
| Staff activity when the new SQL function is not installed yet | Shown as "—" with the file to run, never as 0. |

Still in `admin/tests/` only (never bound outside `APP_ENV=testing`, not in the production
autoloader): `MockDataSource.php`, `MockPlatform.php`, `FakeSupabase.php`, `FakeFirebase.php`.

## 2. Live database (read-only; nothing was changed)

**Re-checked 2026-10-13** with `supabase/repair/20261010_review_seeded_demo_records.sql` (SELECT
only) on the live project: still present — the 3 branches' seeded address/phone/hours; the 5 seeded
products, all active (Roasted Peanuts in 3 order lines, Gift Box in 1, the other 3 never sold);
**12 stock rows still at the seeded 50 units, never counted** (Calamba ×5, Los Baños ×5, Santa Cruz:
Mixed Nuts & Raisins, Roasted Cashew); 3 seeded rewards (active, never redeemed) and the promotion
"Fresh Batch Every Friday" (active); orders ORD-1001…1004 (2026-10-01, Santa Cruz, completed and
paid: ₱540, ₱80, ₱480, ₱90). Nothing was changed. The reviewed clean-up is
`supabase/repair/20261013_cleanup_seeded_demo_records.sql`: one section per item, each ends with
ROLLBACK until the owner changes it to COMMIT; orders are never touched by SQL.

Earlier finding (2026-10-10):

Confirmed seed records (created 2026-09-26 15:08:47 by `schema.sql`, exact seed values):
3 branch address/phone/hours, 4 categories, 5 products, 3 rewards, 1 promotion, and stock.
**12 of 15 stock rows still hold the seeded 50 units and were never counted.**
They were **not deleted**: seeded products appear in real orders and staff moved stock.
Also left for review: orders ORD-1001 to ORD-1004 (2026-10-01, project members' accounts).
`supabase/repair/20261010_review_seeded_demo_records.sql` lists all of them (SELECT only) and
explains what the owner should confirm or correct.

## 3. Remaining hardcoded values (and why)

* **Test fixtures (tests only):** `admin/tests/Support/MockDataSource.php`, `MockPlatform.php`,
  `UserFactory` (fake names), `test/support/*.dart`, SQL test fixtures. Never bound outside tests.
* **Legitimate constants:** `walk-in` customer (POS sentinel), loyalty default 1 pt per ₱50 (the
  database's own default, used only if the setting is missing), restock threshold fallback 20 (the
  database computes the real one), stock-health ratios in `config/melai.php`, app name/tagline.
* **Input hints** like "e.g. Juan dela Cruz", "09123456789": examples in empty form fields.
* **Configuration:** HitPay `sandbox` until `HITPAY_ENV=live`.
* **Obsolete local tables** `order_overrides`, `loyalty_entries`, `loyalty_settings` remain in the
  website's local SQLite (no longer read or written). They were not dropped.

## 4. Tests run (actual results)

* Laravel fast tests: **49 passed** (mock-mode tests of removed flows replaced by `AccessControlTest`).
* Full Laravel suite against real Postgres (schema without seed + all migrations): **81 passed** (new: map positions
  from DB, targets only when set, stock not carried, self-linking, KPI vs database).
* SQL suites on the seedless schema: **13/13 passed**; concurrency scripts: **4/4 passed**.
* Firebase Functions: **38 passed**. Admin production build (`npm run build`): OK.
* Flutter: **not compiled** (the Flutter SDK cannot be downloaded here). Every changed Dart file
  was syntax-checked with a Dart parser; run `flutter analyze` and `flutter test` before release.

## 5. Still needed from you

1. Run `supabase/repair/20261010_resync_live_database.sql` (from the previous fix) — it also adds
   `20261012000000`.
2. Review the seeded records (section 2) and correct real branch details, prices and stock counts.
3. Optional: add branch coordinates (`branches.latitude/longitude`) for map pins, and sales targets.
4. Set `ADMIN_EMAIL`/`ADMIN_PASSWORD` in `admin/.env` before `php artisan migrate --seed`.

## 6. Files deleted (delete them from your copy)

See `DELETED_FILES.txt`.
