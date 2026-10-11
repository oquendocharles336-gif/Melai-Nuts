# Melai Nuts — what is still open (after the 2026-10-11 round)

Ticked items were completed and tested in this round (see
`docs/IMPLEMENTATION_REPORT_2026-10-10.md`). Open items are in priority order.

## Done this round
- [x] POS cash drawer shifts, paid in/out, expected vs counted cash, close with note
- [x] POS void (manager permission, same day, open shift) and counter returns
- [x] Returned items received back into stock only when sellable (any refund)
- [x] Daily cashier summary with consistent gross / net / refund definitions
- [x] Driver accounts, assignment, accept/reject, pick-up, delivered/failed, COD collection, proof (recipient name)
- [x] Driver location only while a run is out, deleted when it ends; customer and staff tracking
- [x] Analytics report + CSV, linear-regression forecast with hold-out MAE/RMSE, saved-forecast accuracy
- [x] Reorder suggestions (demand × lead time, expiring stock excluded), expiring-batch list
- [x] Admin: Reports, Forecast, Cash Drawer, Driver Tracking pages; inventory reorder/expiry
- [x] Flutter: driver portal, customer live-driver card, cash drawer screen, POS void
- [x] Release Android manifest now has INTERNET (was debug/profile only)

## Done 2026-10-11 (see `docs/IMPLEMENTATION_REPORT_2026-10-11.md`)
- [x] RFID loyalty cards: registry, register / replace / block / unblock, POS tap lookup, Arduino + RC522 sketch (serial and keyboard mode), admin Loyalty Cards page with Web Serial reader, "Link RFID card" in the POS app
- [x] Suppliers + purchase receipts + OCR review (admin): Tesseract.js OCR → draft → human review → approve posts batches once
- [x] HitPay Refund API: "Send via HitPay" (admin + staff app via `hitpay-refund` Edge Function), pending check, no double refunds
- [x] Embedded maps (OpenStreetMap, no key): driver run, customer live tracking, staff route screen; customers can pin an address
- [x] Proof-of-delivery photo (camera) in the driver's Delivered dialog

## Done 2026-10-16
- [x] Delivery is app-only: the admin website lost every delivery page, menu entry, JSON endpoint, KPI, map, "next stage" for delivery orders and the website driver login; owner and branch staff manage runs in the app (create, assign / unassign driver, dispatch, cancel, live driver map, driver directory)
- [x] Maps wherever a delivery location matters: customer map picker (GPS once, drag / tap, Nominatim search, pin required for delivery checkout), rider stop pins + Navigate / Call, staff order pin card + list pin icon, create-run map with unpinned-order confirmation; pin snapshot on the order (migration `20261016000000_delivery_pins_app_only.sql`)

## Done 2026-10-14
- [x] Admin **All users** page (was Team & roles, `/admin/users`): website logins merged with every app account (owners, staff, drivers, customers) by Firebase UID; filter chips, search (name, e-mail, phone, card, branch), "Needs attention" for pending approvals / waiting access, customer orders + paid total + points. Owner-only `owner_all_users()` (migration `20261014000000_admin_portal_all_users.sql`, `supabase/tests/all_users_test.sql` 23/23); falls back to the older functions if the migration is not run yet

## Done in the Phases 0–5 round (see `docs/PHASES_0-5_REPORT.md`)
- [x] Phase 0: every hardcoded value / seed / account / constant audited (`DUMMY_DATA_AUDIT.md` §0) and moved to owner settings or removed; fixture guard in CI; fresh-database check
- [x] Phase 1: app id `ph.melainuts.app`, release signing + R8, App Check (monitor mode) + database rate limits, CI, key-rotation checklist, staging/production run order, clean "online payment off" state
- [x] Phase 2: typed errors + Crashlytics, more tests, Laravel race tests (refactor of oversized files **not done**: no Flutter compiler here)
- [x] Phase 3: offline POS queue, barcode scanning, counter returns, server-triggered push, road ETA + driver foreground service, warehouse as a branch, RFID test checklist
- [x] Phase 4: accessibility (contrast, 48 dp, tooltips), English + Filipino, favourites / reorder by id / order-ready pushes / "Only N left", owner digest, profit report, inventory valuation, CSV + print-to-PDF
- [x] Phase 5: secure cookies, CSP and security headers, self-hosted OCR, optional TOTP two-step sign-in, password re-entry for refunds and points, search / pagination / CSV on Orders, Payments, Refunds, Activity logs, `docs/DEPLOYMENT.md`

## Next round (after Phases 0–5)
1. **Compile and run the Flutter app** (`flutter pub get`, `flutter analyze`, `flutter test --coverage`):
   nothing Dart was compiled in this round; fix whatever the analyzer reports, then measure coverage
   (target 60 %).
2. **Refactor the oversized Flutter files** (Phase 2 item 10) once the compiler is available.
3. On real phones: offline POS replay, barcode scan, push on Android 13+/iOS, driver location with the
   screen off, App Check debug tokens, Filipino text reviewed by a native speaker.
4. Create a staging project and run `docs/PRODUCTION_RUNBOOK.md` + `docs/DEPLOYMENT.md` there first.
5. Move inline page scripts to files and switch to Alpine's CSP build, then drop `'unsafe-inline'` /
   `'unsafe-eval'` from the website's CSP.

## Older list
1. **Compile and test the Flutter changes** — `flutter pub get`, `flutter analyze`,
   `flutter test` (includes the new `test/driver_models_test.dart`), then a device
   run of: owner creates a Delivery account → staff assign run → driver accepts,
   picks up, shares location, delivers with cash → customer sees the live card.
2. ~~Proof-of-delivery photo UI~~ — done 2026-10-11 (test on a device).
3. **Counter returns in the app** — `staff_pos_return` and
   `staff_receive_returned_items` exist; the app's order items need
   `variant_id` in `staff_list_orders` to build the item picker.
4. ~~Suppliers + purchase receipts + OCR review~~ — done 2026-10-11. Possible
   next step: OCR on the phone (`google_mlkit_text_recognition`) for staff who
   receive goods without a computer.
5. ~~RFID loyalty cards~~ — done 2026-10-11. **Must be tested on the real
   reader** (the sketch was not run on hardware here).
6. ~~Embedded map~~ — done 2026-10-11 with OpenStreetMap (no key); map picker and
   address search (Nominatim) added 2026-10-16. Still open: road distance / ETA
   (needs a routing service called from an Edge Function, never a key in the app).
7. **Background location for drivers** — needs an Android foreground service,
   iOS background mode, and store-review justification.
8. ~~HitPay refund API~~ — done 2026-10-11. Test once in the HitPay sandbox
   (GCash refunds may come back "pending"; use Check HitPay).
9. **Warehouse location** — model the warehouse as a branch with
   `supports_delivery/pickup = false`; transfers already work branch-to-branch.
10. **Barcode scanning** in the POS (`mobile_scanner`) against `product_variants.sku`.
11. **Offline POS queue** — sales already carry an idempotency key, so a queued
    replay is safe; the queue itself is not built.

## Credentials / setup still needed
- Supabase: run the new migrations in order (README table), including the three
  2026-10-11 ones; deploy `hitpay-refund`.
- Admin `.env`: `HITPAY_API_KEY`, `HITPAY_ENV` for "Send via HitPay" (optional).
- `flutter pub get` (new: `flutter_map`, `latlong2`, `image_picker`).
- HitPay: `HITPAY_API_KEY`, `HITPAY_SALT`, `HITPAY_ENV`, `HITPAY_REDIRECT_URL` (unchanged).
- Storage bucket `delivery-proofs` is created by the driver migration on a real Supabase project.
- Optional: branch latitude/longitude (`update branches set latitude=…, longitude=…`) for maps.
- Optional: grant managers `void_pos_sales` and `view_reports`
  (`insert into staff_permission_grants (firebase_uid, permission) values (…)`).
