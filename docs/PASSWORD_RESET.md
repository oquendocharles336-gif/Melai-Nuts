# Password reset (our own e-mail and link, app + website)

Accounts are Firebase accounts (the app and the website share them), but **Firebase sends no
e-mail**. The reset e-mail is ours: Supabase Edge Function `account-email`, sent through Resend
on the shared Melai Nuts layout (`supabase/functions/_shared/email-template.ts`). Supabase Auth
is not used for sign-in in this project, so there are no Supabase Auth templates either.

## Flow

1. "Forgot password?" in the app (`AuthService.sendPasswordResetEmail` → `AccountEmailService`)
   or on the website (`LoginController@forgot`, `CustomerAuthController@forgot` → `AccountEmails`)
   calls `POST /functions/v1/account-email/password-reset/request`.
   * App: App Check token, or the Turnstile captcha when App Check is unavailable.
   * Website: its server key (`AUTH_GUARD_SERVER_KEY`) plus the visitor's IP.
   * Limits: 60 s cooldown and 5/hour per e-mail, 20/hour per IP (`auth_action_issue`).
   * The answer is always the same — "If an account exists for this email, we've sent a reset
     link." — whether or not the address has an account (no account enumeration).
2. The function looks the address up with the Firebase Admin credentials, stores only an HMAC of
   a random single-use token, and e-mails **"Reset your Melai Nuts password"** with one
   **"Change your password here"** button. The link
   (`<PUBLIC_SITE_URL>/auth/action?mode=resetPassword&token=…`) lives only in the button's href
   and in the plain-text part; it expires in 30 minutes.
3. The link opens our page: on a phone with the app, `ResetPasswordLinkScreen` (Android App Link);
   otherwise the website's `AccountActionController`. Both check the link first (not used up),
   ask for the new password twice with the sign-up rules, then call `password-reset/confirm`.
   The function sets the password with the Admin API and ends every older sign-in.

Old Firebase links (`oobCode=…`) are answered with "ask for a new link".

Code: `supabase/functions/account-email/`, `lib/core/services/account_email_service.dart`,
`lib/features/auth/screens/forgot_password_screen.dart`, `reset_password_link_screen.dart`,
`admin/app/Services/Auth/AccountEmails.php`, `admin/app/Http/Controllers/Auth/AccountActionController.php`.
Tests: `supabase/functions/account-email/handler_test.ts`, `admin/tests/Feature/AccountActionTest.php`.

Setup, secrets, DNS and the Firebase console safety net: [ACCOUNT_EMAILS_SETUP.md](ACCOUNT_EMAILS_SETUP.md).

## Links to configure

| Where | Value |
|---|---|
| Supabase secret `PUBLIC_SITE_URL` | `https://<website host>` (the button links go here) |
| `admin/.env` `APP_URL` | `https://<website host>` |
| Android build (optional, opens the link in the app) | `flutter build appbundle -PmelaiWebHost=<website host>` (or env `MELAI_WEB_HOST`) |
| `admin/.env` `ANDROID_APP_LINK_SHA256` (optional, same purpose) | SHA-256 of the app signing key (Play Console → App integrity). Serves `/.well-known/assetlinks.json` |

Without the two optional rows, every reset link opens the website page, which works for app users too.
