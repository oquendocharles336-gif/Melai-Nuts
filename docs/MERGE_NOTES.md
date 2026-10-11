# Staff backend merge notes

Base: `Melai-Nuts-Retail-main.zip` (all other uploads were built on it).

## Merged in
* **`melai-staff-backend-changes.zip`** (backbone): `staff_backend` migration
  (`staff_members`, FEFO batches, transfers, POS sales as `orders`, refunds,
  notifications, dashboard), `StaffStore`, `StaffRepository`, and the staff /
  inventory screens.
* **`batch1-staff-foundation.zip`** (identity layer): `StaffSessionStore`,
  `RouteGuard` staff gating, `StaffSessionBlockedView`, sign-out / account-switch
  wipe, and the `SupabaseConfig` refusal of privileged keys.

## How the two were reconciled
* One registry only: `staff_members`. batch1's `staff_profiles` /
  `staff_permissions` tables and its separate migration were **not** carried
  over (two registries would disagree and are a security risk).
* New SQL function `get_my_staff_context()` (in the `staff_backend` migration)
  returns the status-style answer batch1's session store expects, built from
  `staff_members`. `StaffContext` now wraps `StaffProfile`; permissions are
  derived from `can_manage_inventory` / `can_review_refunds` (owners hold both).
* `StaffStore.start()` takes identity from `StaffSessionStore` instead of
  calling `get_my_staff_profile` itself (that Dart call was removed; the SQL
  function remains).
* Gating applies to `UserRole.staff` at sign-in, as in batch1. Owners load their
  context on demand and are not signed out if the registry row is missing, so an
  existing owner is not locked out before the one-time SQL bootstrap.
* `main.dart` / `auth_service.dart`: both sets of edits combined.
* Tests: batch1's Dart test and SQL test were rewritten for the unified model.

## Not merged (alternative designs of the same feature)
* `Melai-Nuts-Retail-main-staff-backend.zip`: `staff_branch_product_inventory`
  migration, SQLite offline outbox, product / price-history / branch-settings
  screens.
* `Melai-Nuts-Retail-staff-backend.zip`: `staff_operations` migration,
  sales-report / sync / transfers screens, audit logs. (It also lacks
  `lib/features/ocr`, which the base has.)
Each defines its own `inventory_batches` / `staff_members` shapes under the same
migration version, so they cannot run alongside this one.

## Not verified
Flutter, Dart and Postgres were not available where this was assembled. Imports
resolve and brackets balance, but nothing was compiled, analysed or run. Before
use: `flutter analyze`, `flutter test`, then run the migration and
`supabase/tests/staff_identity_test.sql` on a dev database.
