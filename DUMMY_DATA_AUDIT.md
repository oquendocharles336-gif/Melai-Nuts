# Melai Nuts — dummy data audit (2026-10-10)

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
