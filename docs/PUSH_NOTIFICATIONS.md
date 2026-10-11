# Push notifications

**Server-triggered only.** The app never decides to send a push; it only registers its device token
(`register_push_token`) after sign-in and removes it before sign-out (`unregister_push_token`).

| Event | Created by | Recipient |
|---|---|---|
| Order status changes, refund decisions, other customer notices | existing triggers → `public.notifications` | the customer |
| New orders, low / out of stock, refunds to review | existing triggers → `public.staff_notifications` | branch staff |
| Batches expiring within N days | `public.enqueue_expiring_batch_alerts()` (daily) → `staff_notifications` | branch staff with inventory permission |
| Order ready for pickup / out for delivery / completed / cancelled | `notify_on_order_status()` (20261023000000) → `notifications` | the customer |
| Daily summary: yesterday's net sales and orders, low / out of stock, expiring batches | `public.enqueue_owner_daily_digest()` (daily, 20261024000000) → `staff_notifications` | every active owner |

Every new row in those two tables is copied into `public.push_outbox` (migration
`20261021000000_push_notifications.sql`). The Edge Function `push-dispatch` sends the outbox through
Firebase Cloud Messaging (HTTP v1), retries temporary failures (up to 5 attempts, 2 days) and deletes
tokens of uninstalled apps. The expiry window is the owner's setting
(*Business settings > "Warn branch staff about batches expiring within"*); **Not set = no expiry pushes**.

Tests: `supabase/tests/push_notifications_test.sql` (23 checks), `supabase/functions/push-dispatch/handler_test.ts`.

## Set-up (owner / developer)

1. Firebase console > Project settings > **Cloud Messaging**: make sure *Firebase Cloud Messaging API (V1)*
   is enabled. iOS: upload an **APNs authentication key** (Apple Developer > Keys) and enable *Push
   Notifications* + *Background Modes > Remote notifications* for the Runner target in Xcode.
2. Service account for sending: Google Cloud Console > IAM > Service accounts > create
   `supabase-push`, role **Firebase Cloud Messaging API Admin**, create a JSON key.
3. Supabase > Edge Functions > Secrets:
   `FIREBASE_SERVICE_ACCOUNT` (the JSON), `FIREBASE_PROJECT_ID`, `PUSH_DISPATCH_SECRET` (24+ random characters).
4. `supabase functions deploy push-dispatch --no-verify-jwt`
5. Schedule it (Supabase > Database > Extensions: enable `pg_cron` and `pg_net`; keep the secret in Vault):

```sql
select vault.create_secret('<the PUSH_DISPATCH_SECRET>', 'push_dispatch_secret');

select cron.schedule('melai-push-dispatch', '* * * * *', $$
  select net.http_post(
    url := 'https://<project-ref>.supabase.co/functions/v1/push-dispatch',
    headers := jsonb_build_object('x-dispatch-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'push_dispatch_secret')))
$$);

-- Expiring batches, every morning at 07:00 Manila time (23:00 UTC):
select cron.schedule('melai-expiry-alerts', '0 23 * * *', $$ select public.enqueue_expiring_batch_alerts() $$);

-- Owner's daily summary of yesterday, every morning at 07:05 Manila time (once per day, safe to re-run):
select cron.schedule('melai-owner-digest', '5 23 * * *', $$ select public.enqueue_owner_daily_digest() $$);
```

6. App: `flutter pub get` (adds `firebase_messaging`). Android 13+ asks for the notification permission
   after sign-in; iOS asks once.
