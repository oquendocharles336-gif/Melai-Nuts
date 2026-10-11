# Melai Nuts — production deployment guide

One page for putting the whole platform live: database, Edge Functions, Firebase, the admin
website and the mobile app. Each step says where the details are. Do **staging first**, then
production in the same order.

> **Owner decision:** online payment (HitPay: GCash, Maya, card) stays **OFF**. Do not set the HitPay
> secrets, do not deploy the HitPay functions for customers, keep `payment_settings.online_payment_enabled
> = false` and `ONLINE_PAYMENT_ENABLED=false`. Customers pay Cash on Delivery or Cash on Counter Pickup;
> in-store POS sales work as before.

---

## 0. First-time setup checklist

Tick each line on staging, then again on production. Nothing here is done by the code for you.

**Accounts and keys**
- [ ] Rotate every key that was ever committed or shared (`SECURITY.md` → *Owner checklist — exposed keys*).
- [ ] Firebase: apps registered under the new id `ph.melainuts.app` (Android + iOS); new
      `google-services.json` / `GoogleService-Info.plist` downloaded (not committed).
- [ ] `env/firebase.json` and `env/supabase.json` filled from the `*.example.json` files, including the
      newer keys `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_STORAGE_BUCKET`,
      `FIREBASE_AUTH_DOMAIN`, `FIREBASE_IOS_BUNDLE_ID`, `FIREBASE_APP_ID_*`; `ONLINE_PAYMENT_ENABLED` = `"false"`.
- [ ] Android upload key created and `android/key.properties` filled (`docs/RELEASE.md` §2). Keep the
      keystore and its passwords in a password manager — a lost key means a new Play listing.

**Database (Supabase)**
- [ ] Backup / PITR time noted (Dashboard → Database → Backups).
- [ ] All migrations applied in order (`supabase/migrations/`), or once
      `supabase/repair/20261010_resync_live_database.sql` on an older project.
- [ ] `melai_admin_portal` given a long random password (`INTEGRATION.md` §2A.2).
- [ ] First owner exists in Firebase Auth, Firestore `users/{uid}` and `staff_members` (`INTEGRATION.md` §2A.4).
- [ ] Seeded demo rows cleaned up (`docs/PRODUCTION_RUNBOOK.md` §1), real branch address / phone / hours typed.
- [ ] `select public.online_payment_enabled()` returns **false**.

**Owner settings (admin website → Business settings, Loyalty)** — every value starts *Not set*
- [ ] Each branch: address, phone, hours, delivery fee (0 if free), pickup / delivery switches; warehouse marked if any.
- [ ] Restock threshold, stock / sales ratios, daily target, healthy margin, expiry-alert days,
      "Only N left" — or leave *Not set* on purpose (the app then shows plain figures, no ratings).
- [ ] Loyalty earn and redeem rules (no rule = customers earn no points).
- [ ] Product costs entered in the app (profit and stock value stay *Not set* without them).

**Server pieces**
- [ ] Edge Functions deployed with their secrets (§2).
- [ ] `pg_cron` jobs: push dispatch (every minute), expiry alerts and owner digest (daily) (§2.3).
- [ ] Firebase: Email/Password sign-in on, Firestore rules + Functions deployed, App Check registered
      (monitor first, enforce later — `docs/APP_CHECK.md`), FCM v1 + APNs key (`docs/PUSH_NOTIFICATIONS.md`).
- [ ] Admin website on HTTPS with the production `.env` (§3); `php artisan melai:firebase-check` passes.

**Before announcing**
- [ ] Sign in to the app as owner, staff, driver and customer; place a Cash on Counter Pickup order and
      complete it; ring up a POS sale; record a counter return; check the push arrives.
- [ ] Sign in to the website, open Dashboard, Orders, Payments, Refunds, Reports, Profit & stock value.
- [ ] RFID reader checked on site (`hardware/rfid-reader/TEST_CHECKLIST.md`).
- [ ] Owner turned on two-step sign-in on the website (optional but recommended: Settings → Profile).

---

## 1. Database

```bash
# staging first; DATABASE_URL = Supabase → Connect → Session pooler (postgres user)
for f in supabase/migrations/*.sql; do psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"; done
# or, on a project that is behind / was hand-edited:
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/repair/20261010_resync_live_database.sql
```

Every migration is idempotent and runs in one transaction. The newest ones, in order:
`20261017` online-payment switch (off) · `20261018` business settings · `20261019` rate limits ·
`20261020` staff order ids · `20261021` push notifications · `20261022` warehouse ·
`20261023` customer features (favourites, "Only N left", order-ready messages) ·
`20261024` owner reports and daily digest.

Rehearse locally before touching staging: `PGADMIN_URL=postgresql://… bash scripts/run-sql-tests.sh`
builds a fresh database, applies everything twice, and runs all suites.

## 2. Edge Functions

### 2.1 Secrets (Supabase → Edge Functions → Secrets)

| Function | Secrets |
|---|---|
| `grant-role-claim` | `FIREBASE_SERVICE_ACCOUNT`, `FIREBASE_PROJECT_ID` |
| `push-dispatch` | `FIREBASE_SERVICE_ACCOUNT` (role *Firebase Cloud Messaging API Admin*), `FIREBASE_PROJECT_ID`, `PUSH_DISPATCH_SECRET` (24+ random characters) |
| `route-eta` | `ROUTING_PROVIDER=ors` + `ORS_API_KEY`, or `ROUTING_PROVIDER=osrm` + `ROUTING_URL` (optional: without it no road ETA is shown) |
| HitPay functions | **not set** — online payment is off by the owner's decision |

### 2.2 Deploy

```bash
supabase functions deploy grant-role-claim --no-verify-jwt
supabase functions deploy push-dispatch   --no-verify-jwt
supabase functions deploy route-eta       --no-verify-jwt
```
(`--no-verify-jwt`: the callers use Firebase tokens or the dispatch secret, which each function checks itself.)

### 2.3 Schedules (Database → Extensions: enable `pg_cron`, `pg_net`)

```sql
select vault.create_secret('<PUSH_DISPATCH_SECRET>', 'push_dispatch_secret');
select cron.schedule('melai-push-dispatch', '* * * * *', $$
  select net.http_post(
    url := 'https://<project-ref>.supabase.co/functions/v1/push-dispatch',
    headers := jsonb_build_object('x-dispatch-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'push_dispatch_secret')))
$$);
select cron.schedule('melai-expiry-alerts', '0 23 * * *', $$ select public.enqueue_expiring_batch_alerts() $$);  -- 07:00 Manila
select cron.schedule('melai-owner-digest',  '5 23 * * *', $$ select public.enqueue_owner_daily_digest() $$);   -- 07:05 Manila
```

## 3. Admin website (Laravel 12)

Server: PHP 8.3 with `pdo_pgsql`, `intl`, `mbstring`; Node 20+ for the build; HTTPS in front
(nginx / Caddy / a PaaS). The web root is `admin/public`.

```bash
cd admin
composer install --no-dev --optimize-autoloader
npm ci && npm run build            # also copies self-hosted OCR into public/vendor/tesseract
cp .env.example .env && php artisan key:generate
```

Production `.env` (in addition to `INTEGRATION.md` §2B):

| Variable | Production value |
|---|---|
| `APP_ENV` / `APP_DEBUG` | `production` / `false` |
| `APP_URL` | `https://<your admin domain>` |
| `SESSION_SECURE_COOKIE` | `true` (the default in production; never `false` on HTTPS) |
| `SECURITY_CSP` / `SECURITY_HSTS` | `true` / `true` |
| `PASSWORD_CONFIRM_SECONDS` | `300` (refunds and points adjustments ask for the password again after this) |
| `FIREBASE_WEB_API_KEY`, `FIREBASE_PROJECT_ID` | from Firebase (server-IP-restricted key, `INTEGRATION.md` §2D.2) |
| `SUPABASE_DB_*` | the `melai_admin_portal` connection |
| `ADMIN_EMAIL` | the owner's real app email (the seeder refuses the `example.com` placeholder) |
| `LOG_LEVEL` | `warning` |

```bash
php artisan migrate --force          # website tables only (users, activity log, two-step sign-in columns)
php artisan db:seed --force          # first admin login (only once)
php artisan melai:firebase-check     # key accepted by Firebase and belongs to FIREBASE_PROJECT_ID
php artisan config:cache && php artisan route:cache && php artisan view:cache
```

Check after deploying: `curl -sI https://<domain>/login` shows `Content-Security-Policy`,
`Strict-Transport-Security`, `X-Frame-Options: DENY`, and the session cookie has `secure; httponly`.
The Receiving page must read a test invoice photo without loading anything from another site.

Updating later: pull, `composer install --no-dev`, `npm ci && npm run build`, `php artisan migrate --force`,
`php artisan optimize:clear && php artisan config:cache && php artisan route:cache && php artisan view:cache`.

## 4. Firebase

The repository has no `firebase.json` yet (the Firebase CLI needs one). Create it once at the
repository root — it only points at the files that are already here:

```json
{ "firestore": { "rules": "firestore.rules" }, "functions": { "source": "functions" } }
```

```bash
firebase use <project-id>
(cd functions && npm ci)
firebase deploy --only firestore:rules,functions
node functions/backfill-role-claim.js   # once, for accounts that existed before the blocking functions (SECURITY.md)
```
Then the console steps in `INTEGRATION.md` §2D, `docs/APP_CHECK.md` (register Play Integrity / App
Attest; **monitor before enforcing**) and `docs/PUSH_NOTIFICATIONS.md` (FCM v1, APNs key).

## 5. Mobile app

```bash
flutter pub get                       # also generates translations (lib/l10n)
flutter analyze --no-fatal-infos --fatal-warnings && flutter test
flutter build appbundle --release \
  --dart-define-from-file=env/firebase.json --dart-define-from-file=env/supabase.json
flutter build ipa --release \
  --dart-define-from-file=env/firebase.json --dart-define-from-file=env/supabase.json
```
Details, signing and store notes: `docs/RELEASE.md`. Release builds must use `ONLINE_PAYMENT_ENABLED=false`.
Have a native speaker review the Filipino text (`lib/l10n/app_fil.arb`) before release.

## 6. Rollback

| Piece | How |
|---|---|
| Database | each migration is one transaction; after COMMIT restore the backup / PITR point noted first |
| Edge Function | `supabase functions deploy <name>` from the previous Git tag |
| Website | redeploy the previous tag, `php artisan optimize:clear` (website tables are additive) |
| App | halt the staged rollout in Play Console / App Store Connect; the database stays compatible |
