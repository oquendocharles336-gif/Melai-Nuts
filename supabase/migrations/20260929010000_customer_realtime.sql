-- Customer realtime: publish the customer-owned tables the app subscribes to.
--
-- The app streams (see CustomerDataStore.startRealtime):
--   * notifications  -> live notification list + unread badge
--   * orders         -> live order / delivery status (rider, ETA) in history + tracking
--   * payments       -> live payment status
--
-- `orders` and `refund_requests` were published by
-- 20260928000000_customer_security_hardening.sql. Realtime enforces the RLS
-- policies on each table per subscriber, so a customer only ever receives
-- their own rows ("customer: read own notifications/orders/payments").
--
-- Idempotent: safe to re-run.

begin;

do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['notifications', 'orders', 'payments'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime'
                       and schemaname = 'public'
                       and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

commit;
