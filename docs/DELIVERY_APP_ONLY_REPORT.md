# Delivery moved to the app + maps everywhere a delivery location matters

Migration: `supabase/migrations/20261016000000_delivery_pins_app_only.sql` (run after 20261015).

## 1. Files

### Admin website (`admin/`)
Deleted: `resources/views/ops/deliveries.blade.php`, `resources/views/ops/driver-tracking.blade.php`.

Changed:
- Routes / controllers: `routes/web.php` (no `dashboard.drivers`), `DashboardController` (no `drivers()`, no `deliveries` / `driver-tracking` slugs), `OperationsController` (no `deliveries()` / `driverTracking()`), `OrdersController` (delivery orders read-only: advance answers 422, no ETA reads; New order refuses `type`, `order_type`, `is_delivery`, `delivery_address(_id)`, `fulfillment`), `Admin/UserController` (copy).
- Services / data: `Contracts/DataSource` (no `drivers()` / `deliveries()`), `Data/SupabaseDataSource`, `Supabase/SupabaseRepository` (no `deliveries()`, `driverPositions()`, `drivers()`, `branchLocations()`; the `drivers` list of `owner_all_users` is dropped), `DashboardService`, `OverviewService`, `Support/DashboardKpis` (no `deliveries_active`), `Platform` (no branch map positions), `UserDirectory` (no riders), `AdminActions::nextStatus` (delivery orders have no next stage).
- Driver role: `Models/User` (`ROLE_DRIVER` removed; `WEBSITE_ROLES` + `canUseWebsite()`), `Auth/LoginController` (refuses non-website roles, `APP_ONLY_MESSAGE`), `Middleware/EnsureUserIsActive` (ends such sessions), `Middleware/EnsureRole`, `Requests/AdminCreateUserRequest` (staff only), `Requests/LoginRequest`, `Auth/AccountLinkStatus`, `Auth/AccountProvisioner`, `Auth/AutoLinker`, `Auth/LinkState`, `Supabase/StaffLinker`. No DB migration needed (`users.role` is a plain string); existing rows are kept.
- Views / assets: `layouts/panel` (no Deliveries / Driver tracking), `dashboard` (no "Driver and delivery tracking" section, no "Deliveries in progress"), `orders/index` (no "Expected" row; read-only note for delivery orders), `admin/users/index` + `create` (no driver rows, chip, badge or Tracking link; staff-only create), `landing`, `auth/login`, `components/icon` (no `truck` / `map-pin`), `resources/js/ui.js` (no `driverMap`, Leaflet loader, `g d` shortcut, delivery stage mapping), `resources/css/melai.css` (no `.map` / `.track` / `.deliveries`), `config/melai.php` (sections, `locations_seconds`).
- Docs: `admin/README.md`.

### App (`lib/`)
Added:
- `core/utils/geo_utils.dart` — pin validation (null / range / 0,0), distance, checkout pin gate, far-from-branch warning, Google Maps / Waze / Apple Maps links.
- `core/widgets/location_picker.dart` — full-screen map picker (center pin, drag / tap, "Use my current location", permission messages + Open settings, Nominatim search + reverse lookup, Confirm pin).
- `core/widgets/navigation_sheet.dart` — Navigate sheet, Open in Maps, Call.
- `core/services/device_location.dart` — one-shot GPS, platform-guarded (Linux → friendly message).
- `core/services/geocoding_service.dart` — Nominatim (User-Agent, debounced by the picker, fails to "nothing found").
- `features/delivery/widgets/run_map_card.dart` — `RunMap`, `RunMapCard`, `NoPinNotice`, `StopNavigationActions`.
- `features/delivery/screens/live_delivery_map_screen.dart` — live driver map (owner: all branches / one; staff: own branch), 10 s refresh while on screen, tap a driver → run, stops, ETA, call.
- `features/delivery/screens/driver_directory_screen.dart` — drivers per branch.

Changed:
- `core/widgets/delivery_map.dart` — one shared map: `MapTiles` (single tile URL constant, user agent, attribution), `MapMarkerStyle`, customer pin, several drivers / branches, highlighted next stop, grey candidates, legend, zoom + recenter, fit-to-bounds, invalid points dropped.
- `app/routes.dart` — delivery management open to staff (own branch) and owner; new `/delivery/live-map`, `/delivery/drivers`; route map can focus a stop.
- Customer: `saved_addresses_screen.dart` (picker, pin map on each card, "No map pin" warning + Pin on map, save-without-pin warning), `checkout_screen.dart` (pin review map, Use a saved address, one-tap Pin on map, delivery blocked without a valid pin, pin saved on the address before the order), `order_tracking_screen.dart` (branch + pin even without a rider position; missing-pin note).
- Driver: `driver_portal_screen.dart` (run map with own position and next stop, Navigate sheet, Call, no-pin notice), `next_stop_screen.dart`, `active_delivery_screen.dart`, `delivery_route_screen.dart`, `route_details_screen.dart`, `route_map_screen.dart`, `gps_tracking_screen.dart`, `delivery_manifest_screen.dart`.
- Staff / owner: `staff_transactions_screen.dart` (`DeliveryPinCard`: map, address, contact, distance, Open in Maps), `staff_portal_screen.dart` (pin icon on delivery orders, Deliveries button), `create_delivery_screen.dart` (candidates map, tap to add, driver picker, confirm unpinned), `route_optimization_screen.dart` (map, confirm unpinned before dispatch), `delivery_details_screen.dart` (map, assign / unassign driver, cancel run, Navigate / Call), `delivery_dashboard_screen.dart` (open-stops map, Live driver map, Drivers).
- Data: `models/delivery.dart` (`branchId`, `driverPhone`), `models/branch.dart` (latitude / longitude), `models/customer_profile.dart` (`isPinned` uses the shared rule), `repositories/delivery_repository.dart` (`listDrivers`, `assignDriver`, `unassignDriver`, `activeDriverPositions`, `orderDeliveryPins`, pins on candidates), `repositories/customer_profile_repository.dart` (`updateAddressPin`), `core/services/staff_store.dart` (delivery pins for the order list).
- `android/app/src/main/AndroidManifest.xml` — `<queries>` for https links and the dialer.

### Database (`supabase/`)
- Added `migrations/20261016000000_delivery_pins_app_only.sql`.
- Added `tests/delivery_pins_test.sql` (43 checks); extended `tests/driver_module_test.sql` (+5).

### Tests / docs
- Added `admin/tests/Feature/NoDeliveryOnWebsiteTest.php`, `test/delivery_pins_test.dart`.
- Updated Laravel tests and fakes: `DashboardTest`, `AdminRedesignTest`, `AdminActionsSupabaseTest`, `AdminUserManagementTest`, `AllUsersPageTest`, `FirebaseAuthTest`, `SupabaseIntegrationTest`, `Unit/DashboardKpisTest`, `Support/FakeSupabase`, `Support/MockDataSource`, `Support/MockPlatform`.
- Docs: `README.md`, `INTEGRATION.md`, `admin/README.md`, `docs/FEATURE_AUDIT.md`, `docs/ROADMAP.md`, this report.

## 2. Verified / not verified

Verified here:
- Laravel: `php artisan test` → 160 passed; with a local Postgres built from `schema.sql` + every migration (incl. the new one), the `--group=supabase` integration suite → 48 passed (0 skipped in total).
- SQL: every file in `supabase/tests/` on a fresh database with the new migration: all pass (delivery_pins 43/43, driver_module 91/91, customer_rls 134/134, staff_cross_branch 126/126, admin_portal 69/69, order_integrity 82/82, …) and the four concurrency scripts pass.

Not verified:
- **Flutter was not run.** The workspace could not download the Dart SDK or pub packages (storage.googleapis.com and pub.dev are blocked), so `flutter pub get`, `flutter analyze` and `flutter test` were not run. The Dart was checked by hand against the flutter_map 7.0.2 source (cloned from GitHub). Please run `flutter analyze` and `flutter test` first.
- No device / emulator: GPS, permission prompts, Google Maps / Waze / Apple Maps hand-off, tiles and Nominatim were not tried on a phone.
- No real Supabase project: the migration was applied to a local Postgres built with the repo's stub.

## 3. Leftover grep (`admin/`, case-insensitive: deliver, driver, truck, outForDelivery, leaflet, map-pin)

| File | Why it stays |
|---|---|
| `config/{app,auth,cache,database,filesystems,logging,mail,queue,session}.php`, `.env.example`, `phpunit.xml`, `app/Services/Auth/AdminEmailChanger.php`, `app/Console/Commands/ChangeAdminEmailCommand.php`, `tests/Feature/ChangeAdminEmailTest.php`, `tests/Feature/SupabaseIntegrationTest.php` (connection arrays) | Laravel "driver" = database / cache / session / mail driver, not delivery |
| `app/Http/Controllers/OrdersController.php`, `app/Services/AdminActions.php`, `resources/views/orders/index.blade.php` | Read-only label "delivery" and the guards that stop delivery orders from being advanced or created |
| `app/Services/Data/SupabaseDataSource.php` | `isDelivery` flag used for the read-only label |
| `app/Services/OverviewService.php`, `app/Support/DashboardKpis.php`, `resources/js/ui.js`, `resources/css/melai.css`, `resources/views/dashboard.blade.php`, `resources/views/components/stepper.blade.php` | Reporting labels: "Online · delivery" channel, "Out for delivery" in orders-by-status, the generic "Delivered" pipeline stage (= completed), "Cash on delivery" payment method, "without delivery fees" note |
| `app/Http/Controllers/ReportsController.php`, `resources/views/ops/reports.blade.php` | Reporting: delivery fees, delivered/failed counts and the driver-performance table of `analytics_report` (no address, pin, position or action) |
| `app/Http/Controllers/Admin/PaymentController.php`, `app/Services/Platform.php`, `database/migrations/2026_09_30_000001_create_order_overrides_table.php`, `resources/views/admin/refunds/index.blade.php` | Payments / refunds: cash collected "on delivery" (COD) |
| `app/Models/User.php`, `app/Services/Supabase/SupabaseRepository.php` | Comments explaining that riders are app-only and that the `drivers` list is dropped |
| `database/migrations/2026_09_28_000001_add_admin_fields_to_users_table.php` | Old migration comment (`admin | staff | driver`); old migrations are not edited |
| `README.md` | The note that delivery is not on the website |
| `tests/**` (`NoDeliveryOnWebsiteTest`, `DashboardTest`, `AdminRedesignTest`, `AdminActionsSupabaseTest`, `AdminUserManagementTest`, `AllUsersPageTest`, `SupabaseIntegrationTest`, `Unit/DashboardKpisTest`, `Support/*`) | Tests asserting the removal (404s, no sidebar entries, no riders, no driver login) and fixtures that mirror real database answers (`is_delivery`, `owner_all_users().drivers`, sales channels) |

`leaflet`, `truck`, `map-pin`: 0 hits outside these tests.

## 4. Decisions & assumptions
1. **Delivery orders are fully read-only on the website** (no "next stage" at any status, not only into / through delivery): confirming / preparing them is part of the app's delivery flow. Pickup and in-store orders still advance.
2. **Driver performance stays on the Reports page** as reporting (allowed by the brief); it has no address, pin, position or action. Easy to drop if you want zero rider data on the website.
3. **The website no longer reads branch coordinates** (they only fed the removed map); this also saves one database round trip per page.
4. **Pin is required in the app, not by the database**: checkout blocks a delivery order without a valid pin; the server still accepts unpinned orders so older app builds keep working. Staff see "no pin" warnings and must confirm before dispatching such orders.
5. **Pin snapshot by trigger**: `place_order()` is unchanged; a BEFORE INSERT trigger copies the address pin onto the order, immutable afterwards. Only open orders were backfilled.
6. **Riders lose a stop's address, pin and phone as soon as that stop is finished** (stricter than before; the run-level rule is unchanged).
7. **Staff manage deliveries in the app**: Delivery Management (and the shared run screens) are now open to staff for their own branch — the `staff_*` delivery functions already enforce branch access; nothing in the database changed for that.
8. **Live map refresh** polls every 10 s while the screen is visible (delivery tables have no realtime select policy).
9. **No macOS changes**: macOS location / network entitlements were not added (out of scope; macOS sandbox builds already lack `network.client`).

Follow-ups: run `flutter analyze` / `flutter test`; consider a server-side pin requirement once every app build sends pins; road routing / ETA through an Edge Function; background location for drivers.

## 5. Manual QA checklist
1. Customer: Saved Addresses → Add → Pin on map (GPS, drag, tap, search) → Confirm → fields prefilled where empty → Save. The card shows the pin map.
2. Customer: checkout as Delivery with an unpinned address → blocked with "Pin on map" → pin → map review shows pin + branch → place order.
3. Staff: Orders list shows the green pin icon → order details show the map, address, phone, distance and Open in Maps.
4. Staff: Deliveries (truck icon) → Create Delivery → candidates map with branch, tap pins to add; unpinned order asks for confirmation; pick a registered driver → create → route plan map → dispatch.
5. Driver: sign in to the app → driver portal → accept → picked up → share location → the run map shows the pins, next stop highlighted, own position → Navigate (pick Waze / Google Maps / Apple Maps) → Call → Delivered (name / cash / photo). After the stop: address and pin hidden.
6. Customer: order tracking shows rider, pin and branch while out for delivery.
7. Owner: Delivery Management → Live driver map (All branches) shows the driver, tap → run details; Drivers lists drivers per branch.
8. Admin website: no Deliveries / Driver tracking in the sidebar; `/s/deliveries`, `/s/driver-tracking`, `/dashboard/drivers.json` are 404; a delivery order on Orders has no "Move to next stage"; a `driver` login is refused.
