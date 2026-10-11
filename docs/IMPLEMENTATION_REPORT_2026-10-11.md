# Implementation report — 2026-10-11

## What was missing from the requested list
| Requested | Before | Now |
|---|---|---|
| Ordering online, POS per branch, inventory, driver side, admin, analytics, linear regression, GCash payment | Already built (2026-10-10 round) | unchanged |
| **RFID Arduino loyalty card** | a free-text card number only | card registry + Arduino reader + POS/admin tap |
| **OCR for the data** | missing | supplier invoice OCR → reviewed draft → approved stock |
| **GCash refund** | done by hand in the HitPay dashboard | sent through the HitPay Refund API |
| **Mapping** | app opened Google Maps by link; staff map was a drawing | real embedded maps (OpenStreetMap) |
| Driver proof photo | bucket existed, no UI | camera photo in the Delivered dialog |

## Added
| Area | Database (migration) | Admin website | Flutter app | Other |
|---|---|---|---|---|
| RFID cards | `20261011000000_loyalty_cards.sql` | Loyalty Cards page, customer card page, Web Serial reader (`public/js/melai-rfid.js`) | POS: tap card auto-attaches the customer; "Link RFID card" (link / replace) | `hardware/rfid-reader/` sketch + wiring + guide |
| OCR receiving | `20261011010000_suppliers_purchase_receipts.sql` | Receiving (OCR), review form, Suppliers | — | `ReceiptTextParser` (PHP) |
| HitPay refunds | `20261011020000_hitpay_refunds.sql` | Send via HitPay / Check HitPay / Close attempt | Send via HitPay on the refund card | Edge Function `hitpay-refund` |
| Maps | — | — | `DeliveryMap` widget: driver run, customer live card, staff route screen; address pin | — |
| Proof photo | (existing bucket) | — | Take proof photo → upload → delivered | iOS camera usage text |

## Tests actually run (local PostgreSQL 16 + PHP 8.3)
| Suite | Result |
|---|---|
| `loyalty_cards_test.sql` (new) | 69/69 |
| `purchase_receipts_test.sql` (new) | 43/43 |
| `hitpay_refunds_test.sql` (new) | 30/30 |
| `receiving_cards_refund_concurrency_test.sh` (new, 8 parallel sessions) | all pass |
| All earlier SQL suites + 3 concurrency scripts | all pass, unchanged |
| Laravel, mock mode | 62 passed (incl. 14 new unit tests: OCR parser, HitPay answer mapping) |
| Laravel against the database (`--group=supabase`) | 27/27 (6 new end-to-end: cards, OCR receiving, HitPay refunds with a faked HitPay) |
| Admin pages in headless Chromium | log in → tap card → customer card page → scan invoice → review → approve: batches in stock |
| Dart | all changed files syntax-checked with tree-sitter; **not compiled** |

Two existing tests failed only between 00:00 and 08:00 Manila time (they used the server's UTC date); they now pin Asia/Manila.

## Not tested here
- `flutter analyze` / `flutter test` / a device run (no Flutter SDK in this environment). New: `flutter_map`, `latlong2`, `image_picker`; run `flutter pub get`.
- The Arduino sketch on a real board and RC522.
- The HitPay sandbox (refund calls were tested against a fake HitPay that answers like the documented API).
- Tesseract.js OCR quality on real photos (the parser was tested on OCR-style text).

## Setup
1. Run the three new migrations in order.
2. `supabase functions deploy hitpay-refund --no-verify-jwt` (uses the existing `HITPAY_API_KEY` / `HITPAY_ENV`).
3. Admin `.env`: `HITPAY_API_KEY`, `HITPAY_ENV` (optional; without them refunds stay manual).
4. `flutter pub get`, then rebuild the app.
5. Set branch coordinates (README → Maps). Build the reader (hardware/rfid-reader/README.md).
