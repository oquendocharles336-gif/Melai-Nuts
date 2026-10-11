# Melai Nuts — feature audit (2026-10-10)

How this was checked: every SQL file was applied to a fresh local PostgreSQL 16
(with `supabase/tests/local_supabase_stub.sql`) and all existing SQL suites were
run; the Laravel suite was run in mock mode and against that database
(`--group=supabase`); the Flutter code was **read, not run** (the Flutter SDK
cannot be downloaded in the build environment).

Baseline before any change: SQL suites 134 + 82 + 9 + 126 + 52 + 44 + 69 PASS,
0 FAIL. Laravel 50 passed (mock), 15/15 passed (Supabase group).

Status key: **Done** = complete and verified by an executed test ·
**Needs test** = implemented, no executed test covers it · **Partial** ·
**Missing** · **Blocked** = needs credentials or hardware.

## 1. Online ordering

| Feature | Status | Evidence |
|---|---|---|
| Catalog, categories, images, availability, search | Done | `search_customer_products`, `product_search_test.sql` |
| Cart with server pricing | Done | `get_cart_pricing`, `_calculate_cart_pricing` |
| Checkout: server-side totals, discounts, delivery fee, idempotency, stock lock, no overselling | Done | `place_order`, `order_integrity_test.sql`, `concurrency_test.sh` |
| Stock restored on cancel | Done | `reverse_order_on_cancel` trigger |
| Order history, details, repeat order, tracking, notifications | Needs test | Flutter screens + realtime migration (no widget tests run) |
| Saved addresses | Needs test | `customer_addresses` + screen |
| Branch selection by delivery coverage | Partial | branch flags `supports_delivery/pickup`; no distance-based coverage (branches have no coordinates) |

## 2. POS

| Feature | Status | Evidence |
|---|---|---|
| Branch POS sale, server pricing, FEFO stock deduction, idempotency | Done | `staff_create_pos_sale`, cross-branch suite |
| Walk-in and loyalty customer, cash / GCash / card (reference) | Done | same |
| Receipts, sales history | Needs test | Flutter POS screens |
| Opening cash, closing cash, expected cash, difference | **Missing** | no table/function |
| Voided transaction records | **Missing** | completed orders can only go to refund; no POS void |
| Daily cashier summary (gross, net, count) | **Missing** | dashboard only shows today totals |
| Returns for walk-in POS sales | **Missing** | `request_refund` needs the customer's own login |
| Offline POS queue | Partial | SQLite sync queue exists for staff context; POS sale is online-only (idempotency key makes a retry safe) |
| Barcode scanning | Partial | search box says "scan barcode" but there is no scanner package |

## 3. Inventory

| Feature | Status | Evidence |
|---|---|---|
| Branch inventory, batches, expiry, FEFO, movements | Done | `inventory_batches`, `_consume_batches_fefo`, tests |
| Receive, adjust (with reason, audited), idempotent | Done | `staff_receive_batch`, `staff_adjust_batch` |
| Transfers request/ship/receive/reject/cancel | Done | `staff_request_transfer`, `staff_respond_transfer` |
| Low / out-of-stock alerts | Done | `_trg_staff_notify_stock` |
| Central **warehouse** location | Missing | only branches exist (a warehouse can be modelled as a branch) |
| Supplier records, purchase receipts | **Missing** | no tables |
| Returned stock received back into a batch | **Missing** | `finalize_order_refund` never restocks and nothing else does |
| Expiring-soon alerts | Partial | FEFO screen shows expiry; no notification |
| Reorder suggestions (sales velocity + lead time) | **Missing** | |
| Inventory valuation | Partial | `product_variant_costs` exists; no valuation report |

## 4. Driver and delivery

| Feature | Status | Evidence |
|---|---|---|
| Staff create runs, route order, dispatch, cancel, per-stop status | Done (staff side) | `delivery_module.sql` |
| **Driver accounts** | **Missing** | Owners can create a "delivery" Firebase account, but it is never registered in Supabase, so a rider who signs in gets no data at all |
| Assignment, accept/reject, picked up, in transit, delivered, failed | **Missing** | runs only carry a free-text `rider_name` |
| GPS location, customer live tracking | **Missing** | screens say "simulated" |
| Proof of delivery | Partial | free-text note only, "simulated photo" |
| Failed delivery / return to branch | Partial | `delayed`/`skipped` stops, no order hand-back |
| Delivery performance analytics | Missing | |

## 5–6. Admin portal and analytics

| Feature | Status | Evidence |
|---|---|---|
| Dashboard, sales, products, inventory, users, logs, refunds, loyalty | Done | Laravel suites (deliveries removed from the website 2026-10-16: app only, `NoDeliveryOnWebsiteTest`) |
| Reports page | **Placeholder** | INTEGRATION.md §3 |
| Gross vs net, refunds, refund rate, payment-method breakdown, category, slow movers | **Missing** | `owner_sales_summary` counts completed orders' totals only |
| Customer growth / repeat purchase | Missing | |
| CSV export | Missing | |
| Driver map | Moved to the app (2026-10-16) | Live driver map in Delivery Management; the website has no map |

## 7. Payments

| Feature | Status | Evidence |
|---|---|---|
| GCash / Maya / card via **HitPay** hosted checkout | Needs test | Edge Functions; HMAC-SHA256 webhook check, constant-time compare, amount + currency check, `hitpay_apply_payment` is idempotent. **Blocked** on HitPay sandbox credentials for an end-to-end run |
| COD / counter cash with staff confirmation | Done | `staff_confirm_payment` |
| PayMongo | Not used | kept only for the admin mock mode; HitPay already supports GCash, so no second provider was added |

## 8. Refunds

| Feature | Status | Evidence |
|---|---|---|
| Customer request (partial by item), amount validation, one active request per order | Done | `request_refund`, tests |
| Review approve / reject / process / complete; points clawback; payment → refunded | Done | `staff_review_refund`, triggers |
| Separate states request → approved → completed | Done | `enforce_refund_transition` |
| Restock only when items are received | **Missing** | see Inventory |
| Refund through HitPay API | Blocked | done by hand in the HitPay dashboard (documented) |

## 9–12

| Feature | Status (updated 2026-10-11) |
|---|---|
| OCR for supplier invoices | **Done**: admin Receiving page, Tesseract.js OCR → draft → review → approve (`purchase_receipts_test.sql` 43/43, Laravel end-to-end, parser unit tests) |
| Linear-regression forecast | **Done** 2026-10-10 (`analytics_sales_forecast`) |
| RFID loyalty | **Done** in software: registry, block/replace, POS tap, admin Web Serial page, Arduino sketch (`loyalty_cards_test.sql` 69/69). **Hardware not tested** |
| Maps | **Done** (2026-10-16): OpenStreetMap in the app only — customer map picker (required for delivery checkout), driver stop pins + Navigate (Google Maps / Waze / Apple Maps), staff order pin card, create-run map, live driver map. Pin snapshot on the order (`delivery_pins_test.sql`). Website Leaflet map removed. Dart written without a Flutter SDK in that session: run `flutter analyze` / `flutter test` |
| HitPay refunds | **Done**: Refund API with no-double-refund guard (`hitpay_refunds_test.sql` 30/30, Laravel with faked HitPay). Not run against the real sandbox |

## 13–14. Security and database

Strong already: Firebase JWT → `current_firebase_uid()`, RLS on every table,
`security definer` RPCs that start with `_require_staff`, append-only audit log,
financial-edit and state-machine triggers, idempotency keys. No service-role key
in the app (startup check). Roles are `customer`, `staff` (with permission
grants), `owner`, `delivery` (Firebase only — see §4).

## Plan used for this round

1. POS cash drawer shifts, POS voids, cashier summary, returned-stock restock.
2. Driver module end to end in the database (accounts, assignment, workflow,
   location with automatic stop, customer tracking, proof, failure hand-back).
3. Analytics: consistent gross/net/refund definitions, breakdowns, linear
   regression forecast with chronological hold-out (MAE/RMSE), reorder
   suggestions.
4. Admin Reports page + CSV, forecast view, driver pins on the map.
5. Flutter repositories and screens for the above.

Left for later rounds (see `docs/ROADMAP.md`): suppliers + OCR review flow,
RFID card registry + Arduino bridge, Google Maps SDK in the app, barcode
scanner, warehouse location.
