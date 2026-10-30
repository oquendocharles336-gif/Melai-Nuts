-- =============================================================================
-- Melai Nuts — Migration 20261030000000: turn online payment (HitPay) on
-- =============================================================================
-- Run after 20261029000000_admin_portal_account_status.sql. Idempotent.
--
-- Switches payment_settings.online_payment_enabled on, so customers can pay
-- online through HitPay's hosted checkout (GCash, Maya, card) besides Cash on
-- Delivery / Cash on Counter Pickup. Nothing else changes: place_order(), the
-- orders_online_payment_switch trigger and the hitpay-* Edge Functions already
-- read this switch.
--
-- BEFORE applying, set the HitPay secrets and deploy hitpay-create-payment and
-- hitpay-webhook (supabase/functions/README.md §2–3). Otherwise customers can
-- pick online payment but the payment page answers "Online payment is not
-- configured." (the order is kept and can be paid later).
--
-- Turn it off again (SQL editor, as the owner / postgres):
--   update public.payment_settings set online_payment_enabled = false, updated_at = now()
--   where id = 'default';
-- =============================================================================
begin;

insert into public.payment_settings (id, online_payment_enabled)
values ('default', true)
on conflict (id) do update
  set online_payment_enabled = true,
      updated_at = now();

commit;
