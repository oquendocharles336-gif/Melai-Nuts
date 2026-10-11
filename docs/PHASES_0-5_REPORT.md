# Melai Nuts — Phases 0–5 report

Every phase item was done in order with tests, except **Phase 2 item 10** (refactor oversized files),
skipped on purpose: the Flutter SDK is not available here, and moving code between big Dart files
without a compiler would risk breaking things nobody can test. Changed files per commit:
`docs/PHASES_0-5_CHANGED_FILES.txt` (26 commits after the baseline import, 292 files; this report is one more).

**Owner decisions kept:** online payment stays **off** everywhere
(`payment_settings.online_payment_enabled = false`, `ONLINE_PAYMENT_ENABLED=false`). The HitPay code is
dormant and intact, and its "off" state fails closed with the owner's message. **No hardcoded data:**
every value starts *Not set* until the owner saves it, and a CI guard blocks fixtures and keys
(`scripts/check_no_fixture_data.py`).

## What each phase delivered

| Phase | Items | Main pieces |
|---|---|---|
| 0 | 1–7 | Audit table (`DUMMY_DATA_AUDIT.md` §0, 31 rows). Owner settings in the database (`20261018`, admin *Business settings*). Seeds removed. Clean-up SQL with tests. Fresh-database check. Guard in CI. |
| 1 | 1–7 | App id `ph.melainuts.app`, release signing, R8. App Check (monitor mode). Database rate limits (`20261019`). CI workflow. Key-rotation checklist (`SECURITY.md`). Production runbook. Online payment cleanly off. |
| 2 | 8, 9, 11 | `AppErrors.report` + Crashlytics on all 96 `catch (_)`. Widget and route tests. Laravel race tests (parallel loyalty, deductions, cash refunds). **Item 10 skipped** (see above). |
| 3 | 12–18 | Offline POS queue (replays with the same key). Barcode scan with typing fallback. Counter returns. Push notifications (outbox + `push-dispatch`). Road ETA (`route-eta`) and driver foreground service. Warehouse as a branch. RFID checklist and manual entry. |
| 4 | 19–22 | WCAG AA colours, 48 dp targets, tooltips. English + Filipino (gen-l10n, Settings → Language). Favourites, reorder by variant id, order-ready pushes, owner-set "Only N left" (this replaced a hardcoded "≤ 10"). Owner daily digest. Profit report (current cost). Stock value. CSV + print-to-PDF. |
| 5 | 23–26 | Secure cookie by default in production. CSP and security headers. Self-hosted Tesseract.js. Optional TOTP two-step sign-in. Password asked again for refunds and points. Search, pagination and CSV on Orders, Payments, Refunds and Activity logs. `docs/DEPLOYMENT.md`. |

## Test results (final run, exact commands)

| Suite | Command | Result |
|---|---|---|
| SQL (fresh DB, migrations applied twice, resync, all suites + concurrency) | `PGADMIN_URL=postgresql://postgres:postgres@127.0.0.1:5432/postgres bash scripts/run-sql-tests.sh` | **31 passed, 0 failed** |
| Resync file up to date | `bash scripts/build-resync.sh --check` | up to date |
| Laravel incl. real-DB integration + route budgets | `bash admin/tests/Supabase/prepare-test-db.sh` then `SUPABASE_TEST_ADMIN_URL=… SUPABASE_TEST_PORTAL_URL=… php artisan test` | **247 passed** (2,167 assertions) |
| Firebase Functions | `cd functions && npm test` | **38 passed** |
| Edge Functions | `deno test --no-remote supabase/functions/<fn>/handler_test.ts` | **15 passed** (5 + 5 + 5) |
| Hardcoded-data guard | `python3 scripts/check_no_fixture_data.py` and `python3 scripts/test_check_no_fixture_data.py` | OK / OK |
| Self-hosted OCR under the CSP | headless Chromium on a local page | read "MELAI NUTS 250", **0 requests to other sites** |
| Website pages under the CSP | headless Chromium on `/` and `/login` | no CSP violations (the Google Fonts load is blocked by this sandbox's network, not by the CSP) |
| Dart | tree-sitter syntax check, 271 files | 0 syntax errors (**not compiled**, see below) |

## What was NOT verified (honestly)

- **Flutter:** `flutter analyze` and `flutter test` were not run because there is no Flutter SDK here.
  The Dart code is syntax-checked and its imports resolve, but it is not type-checked. The new tests
  (`test/*.dart`) have never run. Coverage (target 60 %) was not measured. `lib/l10n/generated/` is
  created by `flutter pub get` and was not generated here.
- **Builds:** Gradle, Android, iOS, R8 and signing were not built. The versions of the Crashlytics
  Gradle plugin and the new pub packages were not checked against the registries.
- **Firestore rules tests:** not run (the emulator download is blocked here).
- **Arduino sketch:** not compiled. The RFID reader was not tested on hardware.
- **On a device:** nothing was tried on a phone: push, App Check, barcode camera, background
  location, offline replay.
- **Production / staging:** nothing was run on the live Supabase project. A read-only check showed the
  seeded rows and that the new migrations are not applied. There is no staging project yet.
- **Filipino text:** written by a non-native speaker. It needs review.
- **CSP:** it still allows `'unsafe-inline'` and `'unsafe-eval'` (needed by the inline page scripts
  and Alpine). It blocks every other origin.

## What you need to do

1. **Rotate the keys** that were in Git (`SECURITY.md`, owner checklist). Re-register the apps in
   Firebase under `ph.melainuts.app`.
2. Add the new keys to your local `env/firebase.json`: `FIREBASE_PROJECT_ID`,
   `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_STORAGE_BUCKET`, `FIREBASE_AUTH_DOMAIN`,
   `FIREBASE_IOS_BUNDLE_ID`, `FIREBASE_APP_ID_*`. Keep `ONLINE_PAYMENT_ENABLED` as `"false"`.
3. Delete the files listed in `DELETED_IN_THIS_CHANGE.txt` from your copy.
4. Run `flutter pub get && flutter analyze && flutter test --coverage` and fix what the analyzer reports.
5. Follow `docs/DEPLOYMENT.md` §0 on a **staging** project first, then production.

## Next steps

See `docs/ROADMAP.md` → *Next round*: compile the app; refactor the large files (item 10); test on
real phones; create staging; tighten the CSP.
