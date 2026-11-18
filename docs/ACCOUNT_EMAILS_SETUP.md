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

`EMAIL_LOGO_URL` must be an https PNG/JPG (most mail clients do not show SVG), about 112×112 px.

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

## 4. Firebase console: what is no longer used

Firebase sends none of these any more:

- Authentication → Templates → **Password reset**, **Email address change**, **Email address
  verification**, **Multi-factor enrolment notification**: nothing calls them. Leave them as they are,
  or clear their custom text. Do **not** delete the project's e-mail/password sign-in provider.
- Templates → **Customize action URL** (`<site>/auth/action`): no longer needed; old Firebase links
  (`oobCode=…`) now show "ask for a new link".
- Templates → **SMTP settings**: not needed for these e-mails.

## 5. Preview and test

```bash
deno run --allow-write --allow-env scripts/preview-emails.ts build/email-previews   # open the .html files
deno test --no-remote supabase/functions/                                          # template + handler tests
```

For a real-inbox check, send each preview to Gmail, Outlook and Apple Mail (or paste the HTML into
Litmus / Email on Acid). The layout is tables + inline CSS, 600 px max, with a VML button for Outlook.
