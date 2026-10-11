# Melai Nuts — Panel compliance report

Date: 2026-10-11. Scope: the 11 panel criteria (“Panel System Checking Compliance”). Every change is
in this repository; nothing was changed on the live Firebase / Supabase projects.

**How this was checked.** The work environment had no Flutter SDK and no Composer packages, so
`flutter analyze`, `flutter test` and `php artisan test` could **not** be run here. What *was* run:
all 32 SQL suites (`scripts/run-sql-tests.sh`, including the new `panel_compliance_test.sql`) — all
pass; the data/secret guard and its unit tests — pass; `scripts/build-resync.sh --check` — up to date;
`php -l` on every changed PHP file — clean; a bracket/import/l10n-key checker over every changed
Dart file. **Run the three commands above locally before merging** (see “Owner actions”).

## Summary

| # | Criterion | Status | In one line |
|---|---|---|---|
| 1 | Input validation | **Done** | One rule set in the app, the admin website (FormRequests) and the database (CHECK constraints) |
| 2 | Security | **Done** (code) — owner must rotate keys | Exposed keys removed + CI secret scan; least-privilege grants; rate limits; release hardening |
| 3 | Database (local + cloud) | **Done** | Customer side now local-first on SQLite (v2 schema) with offline search; capped, indexed cloud queries |
| 4 | Search, sort, filter | **Partial** | Shared toolkit on the main lists; a few secondary lists still have no search |
| 5 | Edit / delete confirmation | **Done** | One `ConfirmDialog`; every destructive action asks; Undo on cart remove; admin confirm modal |
| 6 | Proper field information | **Done** | Labels, hints, required/optional, counters, right keyboards, focus on first error; `docs/FORM_FIELDS.md` |
| 7 | UI / UX | **Partial** | Tokens only, adaptive grids, reduce-motion, 360/768/1280 tests; no dedicated tablet/web layouts |
| 8 | Error handling | **Done** | Global handlers + friendly error widget; no raw errors shown; admin 404/419/429/500/503 |
| 9 | Pagination / large data | **Partial** | App: server paging for orders + points history, caps everywhere; admin: SQL paging functions ready, Laravel still slices |
| 10 | Stability | **Partial** | Timeouts, double-submit guards, new tests, QA checklist; no `integration_test/` suite yet |
| 11 | Terms and permissions | **Done** (code) — owner must confirm legal text | Terms/Privacy screens + versioned acceptance; permissions asked at use with rationale |

## Details per criterion

### 1. Input validation — Done
- App: `lib/core/utils/validation_utils.dart` (`InputLimits`; Unicode names; password strength incl.
  common/leet passwords and name/e-mail; PH phone → E.164; money with 2 decimals; dates; text,
  reason, code, voucher, SKU, title, postal code), `lib/core/utils/input_rules.dart` (keyboard filters),
  `lib/core/utils/form_utils.dart` (focus first error), `lib/core/widgets/app_text_field.dart`,
  `lib/core/widgets/date_form_field.dart`; wired into every auth, profile, address, checkout, cart,
  refund, rider, product, inventory, transfer, POS, cash-drawer, user-management and barcode form.
- Database: `supabase/migrations/20261025000000_input_check_constraints.sql` (CHECKs added
  `NOT VALID` so old rows never block the migration; phone-normalizing trigger),
  `20261025001000_phone_lookup_normalized.sql` (staff phone lookup works with any format).
- Admin: `admin/app/Http/Requests/Rules.php` + 10 new FormRequests; controllers use them.
- Tests: `test/validation_utils_test.dart`, `supabase/tests/panel_compliance_test.sql`.

### 2. Security — Done (owner action required)
- Keys: placeholders in `env/firebase.example.json`, `android/app/google-services.json.example`;
  deleted `android/app/src/google-services.json.example` (it held the real keys);
  `lib/firebase_options.dart` refuses placeholders; `scripts/check_no_fixture_data.py` scans the whole
  repo for key-shaped values (+ tests).
- Database: `20261025020000_grants_hardening.sql` (anon read-only, no writes; helpers / pgcrypto not
  callable), `20261025010000_more_rate_limits.sql` (refunds 3/30 min, addresses 20/hour).
- App: release not debuggable, cleartext off (debug manifest only), each Android permission
  justified, iOS strings rewritten; logs only in debug builds; phone masking; sign-up / e-mail-code
  brakes in `auth_service.dart`.
- Admin: 2-step verification required for admins, write throttle, session hardening, CSRF-expiry
  redirect (`admin/app/Http/Middleware/*`, `admin/bootstrap/app.php`, `admin/.env.example`).
- `SECURITY.md` updated. `flutter_secure_storage` was **not** added: the app stores no tokens itself
  (Firebase Auth keeps its session in the platform keystore) — documented there.

### 3. Database, local and cloud — Done
- `lib/core/services/sqlite_service.dart` schema **v2** (append-only): `customer_records`
  (+5 indexes), `response_cache`, `customer_pending_writes`.
- `lib/core/services/customer_local_db.dart` (new): per-account store, offline search / filter /
  sort / paging in SQL, wiped on sign-out. `local_cache_service.dart` and
  `pending_writes_service.dart` moved from shared_preferences to SQLite (old data imported once).
- Local-first: `customer_data_store.dart` shows the saved copy at once with a “last updated” label.
- Cloud: explicit columns + limits in `orders_`, `notifications_`, `loyalty_`, `refunds_`,
  `payments_`, `customer_profile_repository.dart`; indexes in `20261025030000_pagination.sql`.
- Follow-up (not blocking): `products_repository.dart` still uses `select()` (all columns) on the
  catalog tables — they are small and cached, but explicit columns would be tidier.
- Docs: `docs/ARCHITECTURE.md`. Tests: `test/customer_local_db_test.dart`.

### 4. Search, sort, filter — Partial
- Toolkit: `lib/core/widgets/list_tools.dart` (debounced search, sort/filter sheet, filter chips,
  no-results with Clear filters).
- Applied to: order history, points history, notification center, staff transactions, inventory
  list, delivery history, product search (sort added; category + price filters existed).
- **Not yet**: low-stock and FEFO screens, driver directory, assigned deliveries, staff refunds,
  saved addresses, favorites (short lists; they still work, just without a search box).

### 5. Edit / delete confirmation — Done
- `lib/core/widgets/confirm_dialog.dart` (`ConfirmDialog`, `UnsavedChangesGuard`; Cancel focused).
- Used for: address delete, cart remove (with Undo) / clear, notification delete (detail + swipe),
  staff notification swipe, profile save + discard, product save / deactivate, stock adjustment,
  transfers, user (de)activation and role creation, cash received, cancel / void, rider reasons.
- Admin: `resources/views/components/confirm-modal.blade.php` + `resources/js/ui.js` replace every
  `confirm()`.
- Not added: an audit log of each edit's before/after values (the existing `AuditService` records
  staff actions; per-field history would need a new table).

### 6. Proper field information — Done
- Labels, hints, required `*` / “(optional)”, counters, keyboard types, autofill hints, next/done
  actions, inline errors on every form listed in `docs/FORM_FIELDS.md`; the Terms checkbox and the
  optional notifications consent are separate.

### 7. UI / UX — Partial
- No hard-coded colours left in `lib/features` (new tokens in `lib/core/theme/app_colors.dart`).
- Product / category / POS grids adapt (2 columns on phones, 3–5 on tablets/web).
- `FadeSlideIn` respects “reduce motion”; icon buttons have tooltips; 48 dp targets on cart controls.
- `test/responsive_layout_test.dart` renders shared widgets at 360 / 768 / 1280 px.
- `docs/DESIGN_GUIDE.md`.
- **Not yet**: purpose-built tablet / desktop layouts (master–detail, side navigation) and a dark
  theme; many existing screens still have hard-coded English strings that predate this work (new
  strings are all in the ARB files).

### 8. Error handling — Done
- `lib/main.dart`: `runZonedGuarded`, startup failure screen without raw error text in release;
  `CrashReporter.init` hooks `FlutterError.onError` / `PlatformDispatcher.onError` on every platform;
  `lib/core/widgets/friendly_error_widget.dart` replaces the error box in release builds.
- Raw `$e` removed from user messages (`branch_settings_screen.dart`, `cart_controller.dart`,
  `auth_service.dart`); debug prints guarded.
- Login: “Incorrect email or password.”, “account has been disabled”, “Too many attempts” (existing,
  verified).
- Admin: `resources/views/errors/404|419|429|500|503.blade.php`; 419 redirects to login with a message.

### 9. Pagination / large data — Partial
- App: `PagedListController` / `PagedListView` (25 per page, infinite scroll, end-of-list, pull to
  refresh, Retry). Server paging (`range` + exact count) for **order history** and **points
  history**; `fetchPage` also available for notifications and refunds. Recent lists capped (orders 50,
  notifications 100, points 100, refunds 50, payments 200, addresses 100, rewards 200; staff orders
  100 server-side).
- SQL: `owner_all_users(p_search, p_limit, p_offset)` (limit ≤2000), `admin_portal_orders_page(...)`
  (limit ≤100, returns total), `get_popular_products` capped at 50 — tested in
  `supabase/tests/all_users_test.sql` and `panel_compliance_test.sql`.
- **Not yet**: the Laravel controllers still slice arrays with `ListTools::paginate` (the SQL
  functions above are ready to be wired in); CSV export is not streamed in chunks; no 10,000-row
  performance seed; some long staff screens still build rows eagerly (`ListView(children: …)`).

### 10. Stability — Partial
- Timeouts on every repository call (`AppErrors.guard`) and in `PagedListController` (20 s);
  stale-answer protection; double-submit guards (checkout, POS, payment, refund); `mounted` checks
  after awaits in the touched screens; `disposeAfterDialog` for dialog controllers.
- New tests: `customer_local_db_test.dart`, `list_tools_test.dart`, `responsive_layout_test.dart`,
  `validation_utils_test.dart`; SQL `panel_compliance_test.sql`; admin `AdminSecurityTest.php`.
  Kill-and-restart behaviour of the queues is covered by the existing `sync_service_test.dart`,
  `pos_sale_queue_test.dart`, `checkout_attempt_store_test.dart`.
- `docs/QA_CHECKLIST.md` (airplane mode, double tap, rotate, background, kill/restart, permissions).
- **Not yet**: an `integration_test/` suite for the end-to-end flows (needs a device / emulator and a
  test Firebase project to run); a full `flutter analyze` pass (not runnable here).

### 11. Terms and permissions — Done (owner must confirm the legal text)
- `lib/core/config/legal_config.dart` (versions + sections marked for owner review),
  `lib/features/legal/screens/legal_document_screen.dart` (Terms, Privacy — English + Filipino, RA
  10173 rights), `lib/features/legal/widgets/terms_consent_field.dart` (unticked, tappable links,
  inline error), `lib/core/services/legal_service.dart` (records acceptance, works offline, asks again
  on a new version), `lib/app/route_guard.dart`, routes `/legal/terms`, `/legal/privacy`; links in
  Settings and on the login / register screens.
- DB: `20261025040000_legal_acceptance.sql` (`legal_acceptances` append-only, version columns on
  profiles, `accept_legal_terms()`).
- Admin: `/terms`, `/privacy`, footer links, `terms` checkbox at registration,
  `2026_10_25_000001_add_terms_acceptance_to_users_table.php`.
- Permissions: `lib/core/services/permission_service.dart` (rationale → request → denied / “Open
  settings”), Settings > Permissions (`permissions_screen.dart`); camera asked when scanning / taking
  the proof photo (manual “type the code” fallback), location when tapping “Use my location” or
  starting a run (manual pin fallback), notifications after the first order (`push_service.dart` no
  longer prompts at sign-in).

## Where the prompt and the code differed (code trusted)

- `android/app/google-services.json.example` already held placeholders; the real keys were in
  `env/firebase.example.json` and the duplicate `android/app/src/google-services.json.example`.
- `push_service.dart` did ask for notification permission right at sign-in — now it only registers
  when permission was already given.
- The admin website already paginated users / refunds / payments / logs (25 per page) — but by slicing
  arrays, as the prompt said.
- There was no secure-storage need: the app never stores a token or password itself.

## Owner actions (manual)

1. **Rotate and restrict the old Firebase API keys** (Google Cloud Console) — they remain in Git
   history. Checklist in `SECURITY.md`.
2. **Run the migrations** `supabase/migrations/20261025000000…20261025040000` in order (or the
   regenerated `supabase/repair/20261010_resync_live_database.sql`) on the live Supabase project.
   Optional later: `alter table … validate constraint …` once old rows are cleaned (see the migration header).
3. **Admin website**: `composer install`, `php artisan migrate`, copy the session values from
   `.env.example`, make sure every owner/admin can set up 2-step verification.
4. **Deploy** as usual (`firebase deploy --only firestore:rules` is unchanged by this work).
5. **Confirm the legal text** — sections flagged in `LegalConfig.ownerReviewSections` (refund time
   limit, notice period for loyalty rule changes, registered business name / Data Protection Officer
   contact, retention periods, deletion-request channel); they show a “draft” note until confirmed.
   Bump `termsVersion` / `privacyVersion` (and `MELAI_TERMS_VERSION`) after any change.
6. **Run locally** (could not run here): `flutter pub get && flutter gen-l10n && flutter analyze &&
   flutter test`, and `cd admin && php artisan test`. Fix anything they report before merging.
