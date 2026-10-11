# Melai Nuts — Form fields reference

Every input the app and the admin website accept, with its rule. The same limits live in three
places and must stay in step:

| Layer | File | Role |
|---|---|---|
| App (UX) | `lib/core/utils/validation_utils.dart` (`InputLimits`, `ValidationUtils`), `lib/core/utils/input_rules.dart` (keyboard filters) | Instant, field-level messages; stops impossible characters being typed |
| Admin website | `admin/app/Http/Requests/Rules.php` + one FormRequest per form | Server-side check for the website |
| Database (authoritative) | `supabase/migrations/20261025000000_input_check_constraints.sql` | CHECK constraints + phone-normalizing trigger; a modified client cannot get past them |

Conventions used by every form (Criterion 6):

* **Label** above the field (never placeholder-only); a **hint** shows the expected format
  (e.g. `09XX XXX XXXX`); required fields are marked `*`; optional fields say “(optional)”.
* **Keyboard** matches the field (email, phone, number with decimal, text); `textInputAction` moves
  to the next field and the last one submits; autofill hints are set for names, e-mail, phone,
  passwords, address, postal code.
* **Character counter** on long text (notes, reasons, descriptions) and `maxLength` is enforced.
* **On submit** the first invalid field is focused and scrolled into view (`FormUtils.validateAndFocus`).
* Errors appear **under the field** in red with the reason (“Phone must be 11 digits starting with 09”),
  not only in a snack bar.

## Shared field rules

| Field | Required | Length | Allowed / format | Stored as | DB check |
|---|---|---|---|---|---|
| Full name | yes | 2–50 | Letters (any language, e.g. ñ, é), spaces, `-` `'` `.`; no digits | trimmed text | ≤120 (profiles, staff) |
| E-mail | yes | ≤254 | RFC e-mail; lower-cased | text | `customer_profiles`, `suppliers`: e-mail pattern, ≤254 |
| Password | yes | 8–64 | ≥1 upper, lower, digit, symbol; not a common password (leet variants too); must not contain the name or e-mail; spaces allowed but not only spaces | never stored by the app | Firebase Auth |
| Confirm password | yes | — | must equal Password | — | — |
| PH mobile phone | yes/optional per form | 11 digits (`09XXXXXXXXX`) or `+639XXXXXXXXX`; spaces/dashes ignored | `InputRules.phone` allows digits, `+`, space, `-` | **E.164** `+639XXXXXXXXX` (`normalizePhone`) | trigger `normalize_ph_mobile` + `_phone_chars_ok` |
| Address line | yes | 10–200 (app) | free text | trimmed | 1–200; order address text ≤300 |
| City / province | yes | 2–80 | letters/digits | trimmed | 1–80 |
| Postal code | optional | exactly 4 digits | `InputRules.integer` | text | `^[0-9]{4}$` |
| Address label | optional | ≤40 | free text (“Home”, “Work”) | trimmed | 1–40 |
| Notes / short text | optional | ≤300 | free text, counter shown | trimmed | order notes ≤500; stock reason, transfer note, proof note ≤300 |
| Reason (refund, cancel, delay) | yes | 10–500 (refund description), 5–300 (rider reasons) | free text, counter shown | trimmed | refund reason 1–200, refund notes ≤1000, delivery issue ≤400 |
| 6-digit code (e-mail / SMS) | yes | 6 | digits only (`InputRules.verificationCode`) | — | — |
| Voucher code | optional | ≤30 | `A–Z a–z 0–9 - _` (`InputRules.voucherCode`) | upper-cased | `^[A-Za-z0-9_-]{1,30}$` |
| Quantity | yes | 1–99,999 | whole number (`InputRules.integer`) | int | order/refund lines `> 0`; transfers ≤99,999; batches ≤999,999 |
| Price / amount (₱) | yes | 0.01–9,999,999.99 | decimal, max 2 places (`InputRules.decimal`) | numeric | product / variant price `> 0`; order line price `>= 0` |
| SKU | optional | ≤64 | `A–Z a–z 0–9 . _ -` (`InputRules.sku`) | text | ≤64, no spaces |
| Product name / title | yes | 2–100 | must contain a letter or digit | trimmed | product name 2–120; category 2–60; size label 1–40 |
| Description | optional | ≤1000 | free text, counter shown | trimmed | product description ≤2000 |
| Date (received) | yes | — | date picker; not in the future | date | — |
| Date (expiry) | yes (receive batch) | — | after today and not before the received date | date | same rule in `staff_receive_batch` |
| Search box | — | ≤100 | free text; trimmed; `%` `_` are literal | — | — |

## Forms

### Customer app

| Screen | Fields (rule from the table above) | Notes |
|---|---|---|
| Register | Full name, E-mail, Phone (optional), Password, Confirm password, **Terms & Privacy checkbox** (required, unticked), Order-update notifications (optional, unticked) | Password strength shown while typing |
| Sign in / Customer access | E-mail, Password | Brake after repeated failures |
| Phone sign-in | Phone, 6-digit code | 60 s resend cooldown |
| E-mail verification / Forgot / Reset password | 6-digit code; E-mail; Password + Confirm | |
| Edit profile | Full name, Phone (optional) | Confirm before save; “Discard changes?” on back |
| Saved addresses | Label (optional), Recipient name, Phone, Address line, City, Postal code (optional) | Delete asks first |
| Checkout | Recipient, Phone, Address (delivery), Notes (optional, ≤300), Voucher | Place-order button disabled while sending |
| Cart | Quantity steppers, Voucher code | Remove line asks first, with Undo; Clear cart asks first |
| Refund request | Items + quantities, Reason (choice), Description (10–500, required) | Rate-limited 3 / 30 min by the DB |

### Staff / owner / rider

| Screen | Fields | Notes |
|---|---|---|
| Product add / edit / variants / pricing | Name, Description, Category, SKU, Size label, Price, Cost | Confirm save; deactivate asks first |
| Receive batch | Product, Batch code (≤40), Quantity received (1–100,000), Received date (≤ today), Expiration date (after today, ≥ received), Restock level (optional, whole number) | |
| Inventory adjustment | Signed amount (e.g. `-3`), Reason, Notes | Confirm before saving |
| Stock transfer | Quantity, Note | Confirm send / accept / reject |
| POS / staff transactions | Cash received (₱, 2 decimals), Payment reference (non-cash) | Confirm cash received; cancel / void ask first |
| Cash drawer | Opening / closing amount (₱, 2 decimals), Reason for cash in / out | |
| Create delivery | Orders (stops, in order), Vehicle, Registered driver (optional), Rider name | |
| Rider: delivery confirmation | Receiver name, Cash collected (₱), Note, Proof photo (camera, ≤1 MB after compression) | Camera asked only when taking the photo |
| Rider: cancelled / delayed | Reason (5–300) | Confirm |
| User management (owner) | Full name, E-mail, Phone, Role, Branch | Deactivate / reactivate ask first |
| Barcode “type code” | SKU | |

### Admin website (Laravel)

| Form | FormRequest |
|---|---|
| Register / admin create user | `RegisterRequest`, `AdminCreateUserRequest` (name, e-mail, phone → E.164, password rules, `terms` accepted) |
| Business settings | `UpdateBusinessSettingsRequest` |
| Branch | `SaveBranchRequest` |
| Supplier | `SaveSupplierRequest` (phone normalized) |
| Purchase receipt create / update / cancel | `StorePurchaseReceiptRequest`, `UpdatePurchaseReceiptRequest`, `CancelPurchaseReceiptRequest` (reason required) |
| POS order, receive stock | `StorePosOrderRequest`, `ReceiveStockRequest` |
| Loyalty settings | `UpdateLoyaltySettingsRequest` |
| Mark paid | `MarkPaidRequest` |

Destructive website actions (deactivate user, reject refund, void payment, delete product/card,
cancel receipt) open the shared confirm modal (`resources/views/components/confirm-modal.blade.php`)
instead of the browser's `confirm()`.

## Changing a limit

1. Change `InputLimits` (app) **and** `Rules.php` constants (admin).
2. Add a **new** migration that drops / re-adds the CHECK (never edit
   `20261025000000_input_check_constraints.sql`), then run `scripts/build-resync.sh`.
3. Update this file and `test/validation_utils_test.dart`.
