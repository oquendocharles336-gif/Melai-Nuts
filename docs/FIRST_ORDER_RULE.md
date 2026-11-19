# The first-order rule (no phone verification)

Migrations `20261118015010_first_order_prepayment.sql` (the rule) and
`20261119000000_remove_phone_verification.sql` (no SMS check, phone-match safeguard).
Tests: `supabase/tests/first_order_prepayment_test.sql`, `supabase/tests/first_order_phone_safeguard_test.sql`.

The mobile number is an ordinary profile / contact field. The app and the website only check its
format (`09171234567`, 11 digits starting with 09); nobody is sent a code.

| Rule | Where |
|---|---|
| A customer's first order is paid online first: 50% or 100% (HitPay) before staff see it. Later orders: normal checkout. | `_place_order_core`, `first_order_quote` |
| "First order" is decided on the server, from the **account** (`customer_profiles.first_paid_order_at`, Firebase UID). The client never decides it. | `_is_first_order()` |
| Only the HitPay webhook sets the flag. The owner's manual "confirm online payment" releases the order but never touches it (guard trigger). | `_mark_first_paid_order()`, trigger `customer_profiles_guard_first_paid` |
| **Phone-match safeguard.** The webhook records the (normalized) profile number of every account whose online payment it confirms in `first_order_phones`. An account whose profile number another account already paid with, and that never paid with that number itself, prepays again. A number can only add the prepayment, never remove it. Sign-up is never refused for this. | `_is_first_order()`, `first_order_phones` |
| The other 50% of a first order can be paid online too, or in cash at pickup / on delivery. | `hitpay_claim_checkout`, `hitpay_set_checkout`, `hitpay_apply_payment` |

Existing accounts: a number that was verified before is kept as the profile number (when the profile
had none) and every customer who already paid is recorded with their current number, so nobody who
paid is asked to prepay again. Customers who verified a phone with Firebase keep that sign-in
method on Android ("Log in with phone number"); it is a sign-in option, not a checkout step.
