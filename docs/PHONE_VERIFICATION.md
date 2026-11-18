# Verified mobile number and the first-order rule

Migration `supabase/migrations/20261118040000_verified_phone_first_order.sql` (applied on the live
project 2026-11-18). Tests: `supabase/tests/verified_phone_first_order_test.sql` (48 checks).

## What it enforces (in the database, not only in the UI)

| Rule | Where |
|---|---|
| A number counts only after Firebase verified it with an SMS code. The database reads it from the Firebase ID token (`phone_number` claim); nothing the app or website sends is trusted. | `jwt_verified_phone()`, `claim_verified_phone()` |
| One verified number = one account (E.164, `+639XXXXXXXXX`). | unique index `customer_profiles_verified_phone_key`; Firebase also refuses to link a number that is on another account |
| Every checkout needs the verified number of **this request's** token; pickup contact = that number. | `_require_verified_phone()` in `_place_order_core` |
| Returning customer (no 50 % / 100 % prepayment) only if: the account has `first_paid_order_at` **and** a verified number **and** that number is not recorded in `first_order_phones` for a different account. A new account always prepays, whatever number it uses. | `_is_first_order()` |
| Only the HitPay webhook sets `first_paid_order_at` (and records the number in `first_order_phones`). The owner's manual "confirm online payment" releases the order but never touches the flag. | `_mark_first_paid_order()` + trigger `customer_profiles_guard_first_paid` (refuses any change by an API caller outside that function) |
| The other 50 % of a first order can be paid online (or cash at pickup). Paid both ways → the owner gets a "Refund needed" notification. | `hitpay_claim_checkout`, `hitpay_set_checkout`, `hitpay_apply_payment` (routed by the balance checkout's payment-request id), Edge Function `hitpay-create-payment` |

Legacy customers (paid before this migration, no verified number yet): their first verified
number is recorded for them, so they stay returning customers.

## Clients

* **App**: checkout shows "Verify mobile number" when `first_order_quote` says `phone_verified` and
  `phone_claimable` are both false → `VerifyPhoneScreen` (Firebase `verifyPhoneNumber` →
  `linkWithCredential` / `updatePhoneNumber` → token refresh → `claim_verified_phone`). Accounts that
  signed in with a phone number already carry the claim and are claimed at checkout automatically.
  Order details: "Pay Remaining Balance".
* **Website shop**: `/shop/verify-phone` (Google reCAPTCHA required by Firebase for web phone auth →
  `accounts:sendVerificationCode` → `accounts:signInWithPhoneNumber` with the customer's ID token,
  which links the number) → `claim_verified_phone`. Checkout redirects there first. Order page:
  "Pay remaining balance".

## Firebase console (one-time)

1. Authentication → Sign-in method → **Phone**: enabled.
2. Authentication → Settings → **Authorized domains**: add the website host (needed for reCAPTCHA).
3. Android: SHA-1 and SHA-256 of the release and debug keys in Project settings (already needed
   for phone sign-in). iOS: APNs key uploaded, or SMS falls back to reCAPTCHA.
4. Authentication → Settings → SMS region policy: allow the Philippines (deny the rest, to cut SMS
   fraud cost).
