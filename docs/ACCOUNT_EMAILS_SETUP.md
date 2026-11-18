# Account e-mails without Firebase — setup

All four account e-mails now come from **our** Supabase Edge Functions, through
`supabase/functions/_shared/mailer.ts` (Resend), on one shared template
(`supabase/functions/_shared/email-template.ts`):

| E-mail | Sent by | Link / code |
|---|---|---|
| Email address verification | `email-verification` (unchanged flow) | 6-digit code, 10 min |
| Password reset | `account-email` `/password-reset/*` | single-use link, 30 min |
| Email address change | `account-email` `/email-change/*` | confirm link to the NEW address (1 h) + "Was this you?" with a stop link to the OLD one |
| MFA enrolment notice | `account-email` `/security-notice/mfa-enrolled` | no link; "Secure your account" button |

### Audit (every place that sends or triggers an e-mail)

| E-mail | Triggered in | Sent by now | Before |
|---|---|---|---|
| Password reset | app `forgot_password_screen.dart` → `AuthService.sendPasswordResetEmail`; website `LoginController@forgot`, `@sendMyReset`, `Shop\CustomerAuthController@forgot` | `account-email` → Resend | Firebase default template (older builds) |
| Email verification code | app `email_verification_screen.dart`; website `CustomerAuthController@resend`, `WaitingController@resendVerification` | `email-verification` → Resend | Firebase verification link (older builds) |
| Email address change (confirm + "was this you?") | app `change_email_sheet.dart` → `AuthService.requestEmailChange`; website `EmailChangeController` | `account-email` → Resend | — |
| Two-step sign-in (MFA) turned on | website `TwoFactorController` (own TOTP, not Firebase MFA) | `account-email` → Resend | — |
| Welcome / account created | — | **not sent** (sign-up ends with the verification code) | — |
| Order confirmation, receipt, status | — | **not sent by e-mail** (push notifications via `push-dispatch`) | — |
| Staff invite / role change | — | **not sent** (the owner sets the staff password in User Management) | — |

Searched: `lib/`, `admin/app`, `admin/routes`, `functions/` (Cloud Functions: blocking auth
triggers only), `supabase/functions/`, `supabase/migrations/` (no `net.http_post` mail), and
`supabase/config.toml` (no Supabase Auth e-mail settings). Nothing calls `sendPasswordResetEmail`,
`sendEmailVerification`, `verifyBeforeUpdateEmail`, `accounts:sendOobCode`, Laravel `Mail::` or a
Notification. Laravel's own mailer stays `MAIL_MAILER=log`; the website never sends mail itself.

**One system per flow:** Resend through our Edge Functions for all four. Supabase Auth e-mail
templates do not apply, because Supabase Auth is not the identity provider here (Firebase is; Supabase
only receives Firebase tokens). Firebase's own e-mails are not used for any flow.

If you still get the Firebase-style e-mail (`noreply@…firebaseapp.com`, raw `oobCode` link), it
came from an older app build or an older website deployment: install the current build and
redeploy the website and both functions (section 5).

Links open `https://<PUBLIC_SITE_URL>/auth/action?mode=resetPassword|confirmEmail|cancelEmailChange&token=…`
(the website page, and the app through the existing Android App Link on `/auth/action`).
Only an HMAC of each token is stored (`AUTH_CODE_PEPPER`), tokens are single-use, and requests are
limited per e-mail (60 s cooldown, 5/hour) and per IP (20/hour). A reset request answers the same
whether or not the address has an account. Firebase stays the identity: the function changes the
password / e-mail with the Firebase Admin credentials and sets `validSince`, so every older sign-in ends.

## 1. Database

```bash
supabase link --project-ref ieakrniwpagnowliyrtq
supabase db push          # applies 20261118050000_account_email_actions.sql
```

## 2. Secrets (Supabase → Edge Functions → Secrets)

Already set for `email-verification` / `auth-guard` (check they exist):
`FIREBASE_PROJECT_ID`, `FIREBASE_PROJECT_NUMBER`, `FIREBASE_SERVICE_ACCOUNT`, `FIREBASE_APP_CHECK_APP_IDS`,
`AUTH_CODE_PEPPER` (32+ chars), `AUTH_GUARD_SERVER_KEY` (32+ chars), `TURNSTILE_SECRET_KEY`,
`TURNSTILE_ALLOWED_HOSTNAMES`, `RESEND_API_KEY`.

Set / update:

```bash
supabase secrets set \
  PUBLIC_SITE_URL=https://melainuts.ph \
  EMAIL_FROM="Melai Nuts <no-reply@melainuts.ph>" \
  EMAIL_REPLY_TO=support@melainuts.ph \
  EMAIL_SUPPORT_CONTACT=support@melainuts.ph \
  EMAIL_LOGO_URL=https://melainuts.ph/images/email-logo.png \
  EMAIL_FOOTER_ADDRESS="<business address, optional>"
supabase functions deploy account-email --no-verify-jwt
supabase functions deploy email-verification --no-verify-jwt   # picks up the new template + footer links
```

If `SMTP_USER` / `SMTP_PASSWORD` are set, the mailer uses SMTP instead of Resend: unset them
(`supabase secrets unset SMTP_USER SMTP_PASSWORD`) so mail leaves from the verified domain.

`EMAIL_LOGO_URL` must be an https PNG/JPG (most mail clients do not show SVG). The logo is
`admin/public/images/email-logo.png` (224×224, rendered from `assets/images/logo/melai_nuts_logo.svg`,
shown at 56 px), so it is served at `<APP_URL>/images/email-logo.png` once the website is deployed.

`EMAIL_SUPPORT_CONTACT` is the "Need help?" line in every footer (falls back to `EMAIL_REPLY_TO`).

The **website** `.env` needs `AUTH_GUARD_SERVER_KEY` (the same value as the Supabase secret), plus
the existing `SUPABASE_URL` / `SUPABASE_ANON_KEY`. Without the key, reset requests from the website
are refused with "complete the security check". Then run `php artisan migrate` (adds
`users.photo_access_allowed_at`).

## 3. DNS for melainuts.ph (Resend, domain status: pending)

Add these at the DNS host, then press **Verify** in Resend → Domains:

| Type | Name | Value |
|---|---|---|
| TXT | `resend._domainkey` | `p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDY8Xqe2nwtu97q7ezhaZQoy8NhoWaU9ehYIBpv/rBc/ZSa6cPEL7v26ThB70dTqC5bzUiP4wFzBRzK4qWpldFOsuf6LZCztG223Msh/z88cC+5jLY2mxHm4/0jRxGEPRoiIHPU5iufaY94lHY74SWXKYruK+W0NY+PK5kD/5tYCQIDAQAB` (DKIM) |
| CNAME | `send` | `send.forge.rmta.net` (SPF / return path) |
| CNAME | `rsend` | `rsend-apne1.forge.rmta.net` (SPF / return path) |
| TXT | `_dmarc` | `v=DMARC1; p=none; rua=mailto:support@melainuts.ph` (recommended; move to `p=quarantine` once reports look clean) |

Copy the values from Resend → Domains → melainuts.ph if they ever change there; that page is the source.

## 4. Firebase console: safety net only

Nothing in the app or website asks Firebase to send an e-mail. These settings only make sure that
*if* anything ever falls back to Firebase (an old app build, a console "Send password reset"
click), that e-mail is branded too. Firebase's templates always print the raw link; that cannot be
hidden, which is why we do not use them.

1. **Project settings → General → Public-facing name**: `Melai Nuts`. This is the `%APP_NAME%`
   that showed as "melai-nuts-app-2026" in the subject and body.
2. **Authentication → Templates → Email templates → Password reset → ✎ (edit)**:
   * Sender name: `Melai Nuts`
   * From: click **Customize domain**, add `melainuts.ph`, add the TXT/CNAME records Firebase shows
     at your DNS host, then **Verify** (can take up to 48 h). Set the local part to `no-reply`.
   * Reply to: `support@melainuts.ph`
   * Subject: `Reset your Melai Nuts password`
   * Message: replace the text with a short note (keep `%LINK%`), e.g.
     "Hi %DISPLAY_NAME%, use the link below to choose a new Melai Nuts password. If you didn't
     request this, you can ignore this email. — Melai Nuts"
   * **Customize action URL** (link under the template): `https://melainuts.ph/auth/action`.
     Our page answers Firebase links with "ask for a new link", so the person then gets our e-mail.
   * Save.
3. Repeat step 2 for **Email address verification** (subject `Verify your Melai Nuts email`),
   **Email address change** (subject `Your Melai Nuts email was changed`) and **Multi-factor
   enrolment notification**. Firebase does not let you edit the message of some templates; set
   sender name, from, reply-to and subject there.
4. **Templates → SMTP settings** (optional, strongest): Enable, sender `no-reply@melainuts.ph`,
   host `smtp.resend.com`, port `465`, username `resend`, password = the Resend API key, security
   SSL. Fallback mail then leaves from the same authenticated domain as ours.
5. **Authentication → Settings → Authorized domains**: `melainuts.ph` is listed.

Do **not** delete the e-mail/password sign-in provider.

## 5. Deploy

```bash
supabase secrets set EMAIL_LOGO_URL=https://melainuts.ph/images/email-logo.png   # once the website is live
supabase functions deploy account-email --no-verify-jwt
supabase functions deploy email-verification --no-verify-jwt
```

Both use the shared template, so both must be redeployed after any template change.
`supabase/config.toml` also sets `verify_jwt = false` for both, so a plain deploy keeps the setting.
Then deploy the website (`APP_URL` = the same host as `PUBLIC_SITE_URL`) and ship a new app build.

## 6. Preview and test

```bash
deno run --allow-write --allow-env scripts/preview-emails.ts build/email-previews   # open the .html files
deno test --no-remote supabase/functions/                                          # template + handler tests
```

For a real-inbox check, send each preview to Gmail, Outlook and Apple Mail (or paste the HTML into
Litmus / Email on Acid). The layout is tables + inline CSS, 600 px max, with a VML button for Outlook.
