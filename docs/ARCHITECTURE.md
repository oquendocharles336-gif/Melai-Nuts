# Melai Nuts — Architecture

Last updated 2026-10-11 (panel compliance work). This is the map a new developer or a panel
reviewer needs: what runs where, where the data lives, and how the app behaves offline.

## 1. The pieces

```
┌──────────────────────────── Flutter app (lib/) ────────────────────────────┐
│ Customer · Staff/POS · Owner · Rider portals (one app, role-based routes)  │
│                                                                            │
│  features/*/screens  ──►  core/services (stores, sync, auth, legal, perms) │
│                             │                    │                         │
│                             ▼                    ▼                         │
│                  data/repositories      SQLite on the device               │
│                  (Supabase / Firebase)  (sqflite, SqliteService v2)         │
└──────────────┬───────────────────────────────┬─────────────────────────────┘
               │ HTTPS (anon/publishable key    │ Firebase SDK
               │  + Firebase ID token)          │
               ▼                                ▼
     Supabase Postgres (cloud)            Firebase (cloud)
     tables + RLS + SECURITY DEFINER      Auth (identity), Firestore users/{uid}
     functions, CHECK constraints,        (role record), Cloud Messaging,
     rate-limit triggers                  Crashlytics, App Check, Functions
               ▲
               │ server-side (Laravel's own DB role; never in the app)
     Admin website (admin/, Laravel 12) — owner/admin back office
```

* **Identity**: Firebase Auth. **Role / branch / active flag**: Firestore `users/{uid}`, enforced by
  `firestore.rules` and mirrored to Supabase (`staff_members`, `drivers`, `customer_profiles`).
* **Business data** (catalog, stock, orders, payments, refunds, loyalty, notifications, deliveries):
  Supabase Postgres. Every rule that matters (prices, totals, stock, points, who may see what) is in
  SQL — RLS policies, `SECURITY DEFINER` functions, triggers, CHECK constraints. Dart is never trusted.
* **Admin website** (`admin/`): Laravel 12 + Blade + Alpine. Reads/writes the same Supabase database
  server-side. Its own users table holds admin logins (2-step verification required for admins).

## 2. Code layout (Flutter)

| Folder | What is in it |
|---|---|
| `lib/app/` | `MelaiNutsApp`, named routes + access policy (`routes.dart`), `RouteGuard` (role check, Terms re-acceptance) |
| `lib/core/config/` | Non-secret constants (`LegalConfig` versions, …) |
| `lib/core/services/` | Long-lived state and I/O: `AuthService`, `CustomerDataStore`, `StaffStore`, `SyncService`, `CustomerLocalDb`, `SqliteService`, `LegalService`, `PermissionService`, `PushService`, `CrashReporter`, … |
| `lib/core/utils/` | Pure helpers: `ValidationUtils` + `InputLimits`, `InputRules` (formatters), `FormUtils`, `AppErrors`, `format_utils` (`peso`, `maskPhone`, `friendlyTime`) |
| `lib/core/widgets/` | Shared UI: `AppTextField`, `DateFormField`, `ConfirmDialog` / `UnsavedChangesGuard`, `list_tools.dart` (search / sort / filter / paging), `state_views.dart` (loading / empty / error), `FriendlyErrorBox` |
| `lib/data/models/` | Plain models with `fromRow` / `fromJson` |
| `lib/data/repositories/` | One class per table / RPC group; the only code that talks to Supabase |
| `lib/features/<area>/` | Screens and widgets per portal |
| `lib/l10n/` | `app_en.arb`, `app_fil.arb` (English + Filipino); generated with `flutter gen-l10n` |

## 3. Local vs cloud database (Criterion 3)

### On the device — SQLite (`lib/core/services/sqlite_service.dart`)

Schema versions are an **append-only list** of migrations (`SqliteService.migrations`). Never edit
an existing version; add a new one.

| Version | Tables | Used by |
|---|---|---|
| 1 | `staff_cache`, `sync_metadata`, `sync_operations` | Staff/POS offline cache and the offline operation queue (`SyncService`, `PosSaleQueue`) |
| 2 | `customer_records` (+5 indexes), `response_cache`, `customer_pending_writes` | Customer side: `CustomerLocalDb`, `LocalCache` / `OfflineReadCacheClient`, `PendingWritesService` |

`customer_records` keeps one row per server record (`scope` = Firebase UID or `anon`, `kind`,
`id`) with indexed columns `title`, `search_text`, `status`, `category`, `amount`, `sort_time`, and
the untouched server row in `json`. That lets the device **search, sort, filter and page offline**
with SQL instead of scanning lists in memory.

Rules:

1. **The server always wins.** A live fetch of a list replaces the stored copy (`replaceAll`); a
   paged fetch upserts its rows. Nothing on the device is authoritative.
2. **Local-first.** On the first load after sign-in, `CustomerDataStore` shows the saved copy at once
   (orders, points history, notifications, refunds, addresses) and labels it
   *“Saved data · last updated …”* until the live load finishes.
3. **Separated per account.** Rows are keyed by Firebase UID; sign-out runs
   `CustomerDataStore.prepareForSignOut` → `LocalCache.clearScope(uid)`, which deletes that account's
   rows and saved responses. Other accounts' scopes are dropped on account switch (`keepOnly`).
4. **No secrets.** No passwords, tokens or keys are stored (a unit test checks the column names).
   Firebase Auth keeps its own session in the platform keystore.
5. **Web**: no SQLite → every `CustomerLocalDb` call is a no-op and screens read live.

### Writes made offline

* Customer: `PendingWritesService` (table `customer_pending_writes`) — mark-read, delete
  notification, profile name/phone. Flushed before every load; a refused write is reverted and the
  person is told.
* Staff/POS: `SyncService` + `sync_operations` with idempotency keys; POS cash sales queue in
  `PosSaleQueue` (see `docs/PRODUCTION_RUNBOOK.md`).

### In the cloud — Supabase Postgres

* Migrations: `supabase/migrations/<timestamp>_<name>.sql`, **never edited after release**; new
  behaviour = new file. `scripts/build-resync.sh` regenerates
  `supabase/repair/20261010_resync_live_database.sql` (all migrations in order, idempotent) and
  `--check` verifies it is current (CI).
* Tests: `supabase/tests/*.sql`, run by `scripts/run-sql-tests.sh` against a throw-away Postgres.

### Performance rules

* Repositories select **explicit columns** (no `select *` on hot paths) and always set a `limit`.
* In-memory "recent" lists are capped: orders 50, notifications 100, points history 100, refunds 50,
  payments 200, staff orders 100 (server-side `p_limit`). Older records are read **page by page**
  (`.range(offset, offset+limit-1)` + exact count) through `PagedListController`.
* Indexes added for every paged / searched column (`20261025030000_pagination.sql`).
* Admin website: `owner_all_users(p_search, p_limit, p_offset)` and `admin_portal_orders_page(...)`
  page in SQL (limit capped at 100 / 2000).

## 4. Lists: search, sort, filter, pagination (Criteria 4 and 9)

`lib/core/widgets/list_tools.dart`:

| Piece | Job |
|---|---|
| `AppSearchBar` | Debounced (350 ms) search field with clear button |
| `SortOption`, `FilterGroup`, `FilterChoice`, `ListQuery` | Describe a list's sorts / filters; `ListQuery` = search + sort + filters |
| `SortFilterSheet`, `SortFilterButton`, `ActiveFilterChips` | Bottom sheet to choose; removable chips for active filters |
| `applyListQuery` | Same query applied in memory (lists already fully on the device) |
| `PagedListController` + `PagedListView` | Server paging: 25 per page, infinite scroll, pull-to-refresh, loading / empty / no-results / error-with-Retry states, stale answers ignored |
| `NoResultsView`, `LastUpdatedBanner` | "No results for …" + Clear filters; saved-data label |

Where used: customer **order history** (server paging, offline fallback to the local DB), **points
history** (server paging), **notification center** (search / filter / sort + swipe-to-delete with
confirm), staff **transactions** (search / sort / payment + channel filters), **inventory list**
(search / sort / stock filter), **delivery history** (search / sort / status). Product catalog and
search results already had search and category filters.

## 5. Errors and stability (Criteria 8 and 10)

* Every repository call goes through `AppErrors.guard` (timeouts, mapping to `AppError` with
  customer-safe wording). Screens show `StateErrorView` with Retry; snack bars use
  `AppErrors.showSnack`.
* Uncaught errors: `CrashReporter.init` hooks `FlutterError.onError` and
  `PlatformDispatcher.instance.onError` (Crashlytics on mobile, debug log elsewhere);
  `installFriendlyErrorWidget` replaces the grey error box in release builds.
* Double-submit guards on payment, checkout, refund and POS buttons; idempotency keys on orders and
  POS sales; `mounted` checks after every `await` that touches `context`.

## 6. Legal and permissions (Criterion 11)

* `LegalConfig.termsVersion` / `privacyVersion`; screens at `/legal/terms` and `/legal/privacy`
  (public). Sign-up requires an unticked-by-default checkbox; acceptance is stored through
  `accept_legal_terms()` (append-only `legal_acceptances`). `RouteGuard` asks again when the version
  changes. Admin website has the same pages at `/terms` and `/privacy`.
* `PermissionService`: camera, location, notifications are asked **only when needed**, after a short
  rationale; denial shows a helpful dialog with "Open settings". Settings > Permissions shows each
  permission's status.
