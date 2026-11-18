# E-mail codes, captcha and first-order prepayment: setup

Covers migrations `20261118000000_first_order_prepayment.sql` and
`20261118010000_auth_email_codes_and_sign_in_guard.sql` and the Edge Functions
`email-verification` and `auth-guard`. Nothing here contains a real key: every value comes
from your own dashboards. Never commit any of them.

**Release order** (older app builds do not read the new columns):
1. Migrations → 2. Edge Function secrets + deploy → 3. website `.env` + deploy →
4. app build with the new dart-defines → 5. Firebase App Check enforcement (last, after its
metrics show the new builds).

---

## 1. Cloudflare Turnstile (the one captcha)

Why Turnstile: one widget works on the website and, through the website's `/captcha` page in a
WebView, in the Flutter app (no native SDK needed); it is free, does not track users across
sites, is usually invisible or one tap, and tokens are verified server-side with a single
`siteverify` call. hCaptcha would also work, but needs more friction for the same result.

1. Cloudflare dashboard → **Turnstile** → **Add widget**.
2. Widget mode: **Managed**. Hostnames: your website's host (for example `shop.<your-domain>`).
   The app's captcha page is served from the same host, so one widget covers both.
3. Copy the **Site key** (public) and the **Secret key** (private).
   * Site key → website `.env` `TURNSTILE_SITE_KEY` (the app does not need it: it opens the
     website's `/captcha` page).
   * Secret key → Supabase function secret `TURNSTILE_SECRET_KEY` **only**.

## 2. Sending domain (Resend) with SPF, DKIM and DMARC

The code e-mail is sent by the Edge Function through Resend's HTTPS API (hosted functions are
not a reliable place for raw SMTP). Use the **same** Resend domain for Supabase Auth SMTP so every
Melai Nuts e-mail comes from one authenticated domain.

1. resend.com → **Domains** → **Add domain**: your domain (or a sending subdomain such as
   `mail.<your-domain>`). Region: closest to the Philippines (e.g. Tokyo/Singapore when offered).
2. Add the DNS records Resend shows, exactly as shown, at your DNS host:
   * **SPF**: an `MX` and a `TXT` record (`v=spf1 include:... ~all`) on the sending
     subdomain Resend names (for example `send.<your-domain>`).
   * **DKIM**: a `TXT` record at `resend._domainkey.<your-domain>` with the public key.
   * **DMARC** (you add this one yourself): `TXT` at `_dmarc.<your-domain>`:
     `v=DMARC1; p=none; rua=mailto:dmarc@<your-domain>; adkim=s; aspf=s`
     Start with `p=none`, check the reports for 1–2 weeks, then move to `p=quarantine`.
3. Wait until Resend shows the domain as **Verified**.
4. Resend → **API Keys** → create a key with **Sending access** for that domain only.
5. Optional but recommended — Supabase Dashboard → **Authentication → SMTP Settings** →
   Enable custom SMTP: host `smtp.resend.com`, port `465`, username `resend`, password = the API
   key, sender `no-reply@<your-domain>`, sender name `Melai Nuts`. (Supabase Auth itself sends
   nothing in this project because sign-in is Firebase; this keeps any future Supabase e-mail on
   the same branded, authenticated domain.)

## 3. Supabase: migrations, secrets, deploy

```bash
supabase link --project-ref <project-ref>
supabase db push            # applies 20261118000000 and 20261118010000

# The pepper keys every stored hash (codes, e-mails, IPs, devices). 32+ characters.
# Changing it later invalidates open codes and resets the sign-in counters (nothing else).
supabase secrets set AUTH_CODE_PEPPER="$(openssl rand -base64 48)"
supabase secrets set AUTH_GUARD_SERVER_KEY="$(openssl rand -hex 32)"   # copy it to the website .env too

supabase secrets set \
  TURNSTILE_SECRET_KEY=<turnstile secret key> \
  TURNSTILE_ALLOWED_HOSTNAMES=<website host, e.g. shop.example.com> \
  RESEND_API_KEY=<resend api key> \
  EMAIL_FROM="Melai Nuts <no-reply@<your-domain>>" \
  EMAIL_REPLY_TO=<optional support address> \
  EMAIL_LOGO_URL=https://<website host>/apple-touch-icon.png \
  EMAIL_FOOTER_ADDRESS="<business address, optional>" \
  EMAIL_SUPPORT_CONTACT="<support phone or e-mail, optional>" \
  FIREBASE_PROJECT_NUMBER=<Firebase console > Project settings > General > Project number> \
  FIREBASE_APP_CHECK_APP_IDS=<optional: comma list of your Android/iOS Firebase app ids>
# FIREBASE_PROJECT_ID and FIREBASE_SERVICE_ACCOUNT are already set for grant-role-claim.
# The service account needs the role "Firebase Authentication Admin" (it sets emailVerified).

supabase functions deploy email-verification --no-verify-jwt
supabase functions deploy auth-guard --no-verify-jwt
```

`--no-verify-jwt` is required (the tokens are Firebase's; the functions verify them with
Google's public keys, issuer and audience pinned to `FIREBASE_PROJECT_ID`).

The unpaid-first-order expiry uses the existing every-minute job; make sure it exists:

```sql
select cron.schedule('melai-cod-downpayment-expiry', '* * * * *',
                     $$ select public.expire_unpaid_cod_downpayments() $$);
```

**Client IP.** The functions read the visitor IP from `cf-connecting-ip`, then the first
`x-forwarded-for` hop. Check once in `supabase functions logs auth-guard` that it is the real
client IP on your project; set `AUTH_GUARD_IP_HEADER` if another header carries it.

## 4. Website (`admin/.env`)

```dotenv
TURNSTILE_SITE_KEY=<turnstile site key>
AUTH_GUARD_SERVER_KEY=<the same value as the function secret>
```

Behind a load balancer / reverse proxy, configure Laravel's trusted proxies so `$request->ip()`
is the visitor's IP (otherwise every visitor shares one IP in the sign-in counter).
Then `php artisan config:cache` and redeploy (`npm run build` for the assets).

## 5. App build

```bash
flutter pub get   # adds webview_flutter (pubspec.lock changes)
flutter build appbundle \
  --dart-define-from-file=env/firebase.json \
  --dart-define-from-file=env/supabase.json \
  --dart-define=CAPTCHA_PAGE_URL=https://<website host>/captcha
```

`EMAIL_API_BASE_URL` and `AUTH_GUARD_URL` default to the Supabase project's functions URL; set
them only to override. The old "link mode" is gone: the app always uses the 6-digit code.

## 6. Firebase

1. **App Check for Authentication** (stops scripts that call Firebase Auth directly with the
   public API key, which would also skip the sign-in counter):
   Firebase console → **Security → App Check** → register the Android app (Play Integrity) and
   iOS app (App Attest) if not done (docs/APP_CHECK.md) → **APIs** tab → **Authentication** →
   watch the metrics until almost all requests are verified → **Enforce**.
   ⚠ The website signs customers in **from its server** (Identity Toolkit REST). With
   enforcement on, those calls need an App Check token too, which a server can only get by
   minting one with a service account (custom provider). That is not implemented yet: enforce
   only after deciding this (see the report).
2. **Identity Platform / blocking functions**: `functions/` already uses `beforeUserSignedIn`,
   which requires Identity Platform. If it is enabled, reCAPTCHA Enterprise password-sign-in
   protection is available as an extra layer, but it is a second captcha provider and does not
   cover the website's server-side sign-in, so it was not used as the enforcing layer.
3. No e-mail template change is needed in Firebase: nothing asks Firebase to send a
   verification e-mail any more. (Password reset still uses Firebase's reset e-mail.)

## 7. Quick checks after deploy

```bash
supabase functions logs email-verification
supabase functions logs auth-guard
psql "$DATABASE_URL" -f supabase/tests/first_order_prepayment_test.sql            # dev/staging only
psql "$DATABASE_URL" -f supabase/tests/auth_codes_and_sign_in_guard_test.sql      # dev/staging only
```
