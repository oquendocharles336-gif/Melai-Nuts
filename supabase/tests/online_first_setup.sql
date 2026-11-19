-- =============================================================================
-- Melai Nuts — "online first, every order" setup for the SQL suites
-- =============================================================================
-- Since migration 20261119080000 every customer order with something to pay is paid
-- online first: Online Payment 100%, Cash on Counter Pickup the owner's downpayment
-- (no downpayment = no cash order), and no orders at all while online payment is off.
--
-- A suite that places customer orders includes this right after `begin;`:
--
--   \ir online_first_setup.sql
--
-- Inside the suite's own rolled-back transaction it:
--   * switches online payment on (it is off on a fresh install);
--   * sets the Cash on Counter Pickup downpayment to the owner's live values
--     (50% of the total, unpaid orders cancelled after 30 minutes, pick up within 2 days);
--   * adds pg_temp.pay_online(order_id): HitPay confirms the order's online part
--     (downpayment, first-order payment or Online Payment) exactly as the webhook does,
--     so the order leaves 'awaitingDownpayment' for 'pending'. It returns the result of
--     hitpay_apply_payment, or null when the order has no open online part.
--     Call it as the test's admin role (not inside call_as / act_as).
--
-- Not a suite itself: run-sql-tests.sh only runs *_test.sql files.
-- =============================================================================

update public.payment_settings set online_payment_enabled = true where id = 'default';

insert into public.business_settings (id, cod_downpayment_type, cod_downpayment_value, cod_downpayment_min_order,
                                      cod_downpayment_expiry_minutes, cod_downpayment_pickup_days)
values ('default', 'percent', 50, null, 30, 2)
on conflict (id) do update set
  cod_downpayment_type = excluded.cod_downpayment_type,
  cod_downpayment_value = excluded.cod_downpayment_value,
  cod_downpayment_min_order = excluded.cod_downpayment_min_order,
  cod_downpayment_expiry_minutes = excluded.cod_downpayment_expiry_minutes,
  cod_downpayment_pickup_days = excluded.cod_downpayment_pickup_days;

create function pg_temp.pay_online(p_order text) returns text language plpgsql as $$
declare
  v_key text := 'online-first-' || p_order;
begin
  if not exists (select 1 from public.order_downpayments
                 where order_id = p_order and status in ('pending', 'processing', 'failed')) then
    return null;
  end if;
  perform public.hitpay_set_checkout(p_order, 'preq-' || v_key, 'https://pay.example/' || v_key);
  return public.hitpay_apply_payment(p_order, 'success', 'qrph', 'pay-' || v_key, null, 'preq-' || v_key);
end $$;
