# Implementation report — 2026-11-18

First order paid online (50% / 100%), Turnstile captcha (sign-up code step + sign-in after 15
failures), and Melai Nuts' own 6-digit e-mail codes replacing Firebase's verification link.

Setup steps (Turnstile, DNS, secrets, deploy): `docs/EMAIL_CODES_AND_CAPTCHA_SETUP.md`.

---

## 1. Files

### New
| File | What |
|---|---|
| `supabase/migrations/20261118000000_first_order_prepayment.sql` | `customer_profiles.first_paid_order_at`, backfill, `is_first_order`, `first_order_quote`, first-order rule in `place_order`, webhook sets the column |
| `supabase/migrations/20261118010000_auth_email_codes_and_sign_in_guard.sql` | code table, send log, sign-in attempts, captcha redemptions, their functions (service role only) |
| `supabase/functions/_shared/{security,http,captcha,firebase_token,firebase_admin,mailer,email-template}.ts` | shared helpers; the e-mail template is one file |
| `supabase/functions/_shared/shared_test.ts` | codes, hashing, constant-time compare, captcha answers, ID-token / App Check rules (local keys), template |
| `supabase/functions/email-verification/{index,handler,handler_test}.ts` | `/send-code`, `/verify-code` |
| `supabase/functions/auth-guard/{index,handler,handler_test}.ts` | `/sign-in/precheck`, `/sign-in/success` |
| `supabase/tests/first_order_prepayment_test.sql` | 58 checks |
| `supabase/tests/first_order_concurrency_test.sh` | N first orders at once, N webhooks at once |
| `supabase/tests/auth_codes_and_sign_in_guard_test.sql` | 40 checks (RLS, cooldown, limits, tries, single use, gate) |
| `lib/core/config/captcha_config.dart` | `CAPTCHA_PAGE_URL`, function URLs |
| `lib/core/services/sign_in_guard_service.dart` | app client of `auth-guard` |
| `lib/core/services/device_id_store.dart` | random install id (third counter key) |
| `lib/core/widgets/turnstile_captcha.dart` | Turnstile in a WebView: loading / solved / expired / error / offline / unavailable |
| `lib/features/customer/widgets/first_order_payment_choice.dart` | "Pay 50% now" / "Pay 100% now" (DownpaymentNote styling) |
| `test/first_order_and_email_code_test.dart` | models, choice widget, e-mail answer texts |
| `admin/app/Services/Auth/{EmailCodes,EmailCodeException,SignInGuard}.php` | website clients of the two functions |
| `admin/app/Http/Controllers/CaptchaController.php`, `admin/resources/views/captcha/app.blade.php` | `/captcha`, the page the app shows |
| `admin/resources/views/shop/partials/turnstile.blade.php` | widget partial (explicit render when visible) |
| `docs/EMAIL_CODES_AND_CAPTCHA_SETUP.md`, this report | |

### Changed
App: `pubspec.yaml` (+`webview_flutter`), `lib/core/services/{auth_service,email_verification_service}.dart`,
`lib/core/utils/app_error.dart`, `lib/data/models/cod_downpayment.dart`,
`lib/data/repositories/{orders_repository,payments_repository}.dart`,
`lib/features/auth/screens/{login_screen,customer_access_screen,email_verification_screen}.dart`,
`lib/features/customer/screens/{checkout_screen,order_details_screen}.dart`,
`lib/features/payments/screens/online_payment_screen.dart`,
`lib/features/staff/screens/staff_transactions_screen.dart`, `lib/l10n/app_{en,fil}.arb`.

Website: `admin/.env.example`, `admin/config/melai.php`, `admin/routes/web.php`,
`admin/app/Http/Controllers/Auth/{LoginController,WaitingController}.php`,
`admin/app/Http/Controllers/Shop/{CheckoutController,CustomerAuthController}.php`,
`admin/app/Http/Middleware/SecurityHeaders.php` (CSP allows challenges.cloudflare.com),
`admin/app/Services/Firebase/FirebaseAuthClient.php` (sendEmailVerification removed),
`admin/app/Services/Shop/{CustomerAccounts,ShopOrders}.php`,
`admin/resources/views/{auth/waiting,shop/auth/verify,shop/checkout,shop/order,shop/partials/auth-panel}.blade.php`,
`admin/tests/Feature/ShopTest.php`, `admin/tests/Support/FakeShopSupabase.php`.

Supabase/docs: `supabase/config.toml` (`verify_jwt = false` for the two functions),
`supabase/functions/README.md`, `SECURITY.md`; existing SQL / shell test fixtures now mark their
customers as returning (one line each) because they test the normal checkout:
`admin_portal, business_settings, cod_downpayment, customer_rls_security (also the new 7-arg
place_order signature), delivery_pins, driver_module, hitpay_refunds, online_payment_switch,
order_integrity, owner_only_online_paid, rate_limits, refund_request_window, staff_cross_branch`
and `cod_downpayment_concurrency, concurrency, pos_driver_concurrency, receiving_cards_refund_concurrency`.

## 2. Database changes

**20261118000000_first_order_prepayment**
- `customer_profiles.first_paid_order_at timestamptz` (customers can't write it: column grants only, explicit revoke).
- `order_downpayments.kind` (`cod` | `first_order`) and `choice` (`half` | `full`), with a check constraint.
- Backfill: every customer with a paid or completed **online** (non-POS) order gets `first_paid_order_at` = their first such order.
- `_is_first_order(uid)` / `is_first_order(uid)` (service role) read the column.
- `_mark_first_paid_order(order_id)`: conditional `update … where first_paid_order_at is null`, skips cancelled orders and POS sales.
- `hitpay_apply_payment` (the webhook) calls it in the same transaction, only when the payment becomes paid now and the order was not cancelled first.
- `place_order` → body moved to `_place_order_core(…, p_first_order_payment)`; the API wrapper is now `place_order(…, p_idempotency_key, p_first_order_payment default null)` (the 6-arg version is dropped so PostgREST never sees two candidates; older builds keep working).
  For a first order: locks the customer's profile row (serializes that account's checkouts), refuses a second unpaid first order, refuses COD / Cash on Counter, refuses when online payment is off, validates `half` | `full` (older builds that send nothing pay online in `full`), amount = `round(total × 0.5, 2)` or the total, order created as `awaitingDownpayment`, balance in `payments` as cash (0 for full). Expiry = `business_settings.cod_downpayment_expiry_minutes`, or 30 min when not set.
- `first_order_quote(cart_id, is_delivery)`: checkout preview (amounts from the server's cart pricing, pending first order, switch state).
- `_cod_downpayment_apply` / `expire_unpaid_cod_downpayments`: first-order wording ("fully paid", "remaining ₱X in cash", "online payment was not paid in time").

**20261118010000_auth_email_codes_and_sign_in_guard**
- Tables `auth_email_codes`, `auth_email_code_sends`, `auth_sign_in_attempts`, `auth_captcha_redemptions`: RLS on, no policies, all privileges revoked from `anon` / `authenticated`.
- Functions (service role only): `auth_email_code_issue / _discard / _begin_verify / _consume`, `auth_captcha_redeem`, `auth_sign_in_attempt`, `auth_sign_in_succeeded`, `_auth_limits()` (10 min, 5 tries, 60 s, 5/h per account, 5/h per e-mail, 20/h per IP, 15 attempts / 30 min).

## 3. Firebase changes

No code change in `functions/`. Manual (console): enforce **App Check for Authentication** once the
metrics allow it — but read decision 6 below first. No e-mail template change needed: nothing asks
Firebase to send a verification e-mail any more.

## 4. Secrets / env vars

Supabase function secrets: `AUTH_CODE_PEPPER`, `AUTH_GUARD_SERVER_KEY`, `TURNSTILE_SECRET_KEY`,
`TURNSTILE_ALLOWED_HOSTNAMES`, `RESEND_API_KEY`, `EMAIL_FROM`, optional `EMAIL_REPLY_TO`,
`EMAIL_LOGO_URL`, `EMAIL_FOOTER_ADDRESS`, `EMAIL_SUPPORT_CONTACT`, `FIREBASE_PROJECT_NUMBER`,
optional `FIREBASE_APP_CHECK_APP_IDS`, `AUTH_GUARD_IP_HEADER`; existing `FIREBASE_PROJECT_ID`,
`FIREBASE_SERVICE_ACCOUNT`.
Website `.env`: `TURNSTILE_SITE_KEY`, `AUTH_GUARD_SERVER_KEY`.
App dart-define: `CAPTCHA_PAGE_URL` (optional overrides `EMAIL_API_BASE_URL`, `AUTH_GUARD_URL`).

## 5. DNS / SMTP, deploy

See `docs/EMAIL_CODES_AND_CAPTCHA_SETUP.md` §2–§5. In short: verify the domain in Resend (its SPF
MX/TXT and DKIM `resend._domainkey` records), add DMARC `_dmarc` (`p=none` → `p=quarantine`),
optionally point Supabase Auth SMTP at `smtp.resend.com:465` (user `resend`), then:

```bash
supabase db push
supabase functions deploy email-verification --no-verify-jwt
supabase functions deploy auth-guard --no-verify-jwt
```

Why not Supabase's Auth mailer for the code: it only sends Supabase-Auth e-mails for Supabase-Auth
users; identities here are Firebase's. The function sends through the same provider/domain instead.

## 6. Test results

| What | Result |
|---|---|
| SQL suites on a fresh PostgreSQL 16 built from `schema.sql` + every migration | **33 / 33 pass** (31 existing + 2 new); `fresh_install_check.sql` passes; both new migrations re-run cleanly (idempotent) |
| Shell concurrency suites (committed data) | **7 / 7 pass**, incl. `first_order_concurrency_test.sh` (8 first orders at once → 1 created, 7 refused; 8 webhooks at once → released once) |
| Deno (`supabase/functions/**`) with type checking | **82 pass** (46 new, 36 existing) |
| `functions/` Node tests (deps installed in a temp copy) | **38 pass** (unchanged) |
| `php -l` on every changed PHP file | no syntax errors |
| Laravel PHPUnit | **not run**: `vendor/` is not in the zip and Packagist is not reachable from my workspace. Tests were updated (sign-up code flow, 3 new first-order checkout tests); please run `php artisan test`. |
| `flutter analyze` / `flutter test` | **not run**: the Flutter SDK and pub.dev are not reachable from my workspace. I reviewed the Dart changes by hand; please run `flutter pub get && flutter analyze && flutter test` and send me any output. New test: `test/first_order_and_email_code_test.dart`. |

## 7. Manual test checklist

1. **First order, 50%** (new account, pickup): checkout shows "Your first order", Pay 50% / 100% with exact pesos and the balance; cash options hidden. Choose 50% → HitPay asks for half → after paying, order goes to staff as pending; staff see "Paid online ₱X • Remaining balance (cash) ₱Y"; customer pays the rest at the counter.
2. **First order, 100%**: HitPay asks for the total; after paying, staff see "fully paid online"; nothing to collect.
3. **Returning customer**: normal checkout (cash options, existing downpayment setting).
4. **Refunded first order still counts**: refund the paid first order → next order checks out normally (no first-order step).
5. **POS order does not count**: a walk-in sale for that customer → their online checkout still shows the first-order step.
6. **Cancelled-before-payment still first**: place a first order, don't pay, wait for expiry (or the job) → cancelled, stock back → next checkout shows the first-order step again.
7. **Two simultaneous first orders**: two devices/branches place at once → one goes to HitPay, the other says the first order is still waiting; checkout offers "Pay for this order".
8. **Wrong code**: "That code is incorrect" with tries left; after 5 → "Too many wrong codes".
9. **Expired code**: wait 10 minutes → "That code has expired".
10. **No / invalid captcha**: on verify without solving → refused, code not used; tamper the token → refused.
11. **15 failed sign-ins then captcha**: 15 wrong passwords for one e-mail (or from one network) in 30 min → the sign-in shows the security check; solving it lets the attempt through; a correct sign-in clears the e-mail's counter.
12. **Resend cooldown**: "Resend code" disabled for 60 s; a forced resend gets "Please wait N seconds".
13. Website: sign-up panel has the check; verify page sends/accepts the code; owner "waiting" page sends a code and verifies it.
14. E-mail: arrives from `Melai Nuts <no-reply@…>`, subject "Your Melai Nuts verification code: 123456", no link, readable in Gmail (light/dark), Outlook, Apple Mail; SPF/DKIM/DMARC "pass" in "Show original".

## 8. What is enforced server-side — and what could still be bypassed

Server-side, not bypassable by a modified client:
- First-order rule, amounts (rounded), methods, one unpaid first order, race safety, "paid" only from HitPay's signed webhook, expiry, stock.
- E-mail codes: uid/e-mail from the verified token, hashed storage, expiry, tries, single use, cooldown, hourly limits, captcha (or App Check on send) checked before the code, `emailVerified` set only by the function.
- Website sign-in: the Laravel server calls the guard before every Firebase password sign-in.

Still possible:
- **App sign-in counter**: a script that calls Firebase Auth's REST API directly (public API key) never calls the guard. Closing that needs App Check enforcement on Authentication (decision 6). Firebase's own throttling still applies. The app also lets sign-in continue if the guard is unreachable (fail-open by design: a captcha gate must not take sign-in down).
- **Device id** is client-chosen (rotating it only resets that key; e-mail and IP keys remain).
- **IP key** quality depends on the header Supabase passes (`cf-connecting-ip`, check the logs) and on Laravel's trusted proxies.
- **Password reset** still sends Firebase's link e-mail (not changed, see 9).

## 9. Decisions for you / not fully done

1. **Optional phone check — not implemented, on purpose.** Phone numbers are not verified, so "phone already had a paid order ⇒ not first-time" would let a new account *skip* the prepayment by typing an existing customer's number. If you want it, it should only ever make the rule stricter, or use verified phones (SMS sign-in).
2. **50% balance is cash** (pickup counter / rider), recorded as a cash payment on an order labelled Online Payment. Tell me if you prefer a second online payment for the balance instead.
3. **Owner "confirm online payment" by hand** releases the order but does **not** mark the first order used (you asked: only the webhook). That customer would see the first-order step once more. Say if the owner confirmation should count.
4. **Online payment switched off ⇒ brand-new customers cannot order** (they must prepay). Decide whether new customers should then fall back to cash.
5. **Expiry for first orders** = the pickup-downpayment time limit, or 30 minutes when that setting is empty. A separate setting can be added.
6. **App Check on Firebase Authentication** would also block the website's *server-side* sign-in (Identity Toolkit REST from Laravel) unless the server mints App Check tokens with a service account (custom provider). Not implemented; enforce only after deciding. **reCAPTCHA Enterprise** (Identity Platform) was evaluated: it needs Identity Platform (the blocking functions in `functions/` already need it, I can't check your console from here), it is a second captcha provider, and it does not cover the website's server-side calls, so it was not used as the enforcing layer.
7. **Terms**: sections 3/6 describe the pickup downpayment, not the first-order rule. Update the text and bump `terms_version` (app `LegalConfig`, website `melai.legal`) if you want it in the Terms.
8. **Staff app / admin** show the paid online part and the remaining balance (reused downpayment fields) but do not label the order "first order"; that needs the staff/admin order RPCs to return `kind`.
9. **Password reset** (`forgot_password_screen.dart`, website "Reset password") still uses Firebase's link e-mail. Proposal: a `password-reset` Edge Function with the same template ("Reset your password", 6-digit code), `/send-code` with a generic answer (no account enumeration), Turnstile, per-e-mail/IP limits, then `/confirm` with code + new password → Admin `accounts:update {password}` and token revocation; app/website get a code + new-password screen. Not changed (as asked).
10. **pubspec.lock** is not updated (run `flutter pub get`). Build the website assets as usual.
11. Release order: apply the migrations **before** the new app/website (they read `kind` / `choice`).
