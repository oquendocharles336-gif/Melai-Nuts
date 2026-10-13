-- =============================================================================
-- Melai Nuts — Migration 20261028000000: a "failed" HitPay event only counts
-- for the CURRENT payment link
-- =============================================================================
-- Run after 20261027000000_review_fixes.sql. Idempotent, one transaction.
--
-- hitpay_expire_checkout already ignores an "expired" event from an older link.
-- hitpay_apply_payment did not do the same for "failed": a late "failed" event
-- from an OLD link could set a payment that is 'processing' on a NEWER link to
-- 'failed', which lets a second link be created while the customer is still
-- paying the first.
--
-- hitpay_apply_payment gets p_payment_request_id (the HitPay payment-request
-- id, sent by hitpay-webhook). A 'failed' result is ignored unless it matches
-- payments.gateway_payment_id — the current link's request id, stored by
-- hitpay_set_checkout — the same rule hitpay_expire_checkout uses. 'success'
-- is unchanged: on success the function overwrites gateway_payment_id with
-- HitPay's payment id, so the check would be wrong there.
--
-- The old 5-argument version is dropped (a second overload with a defaulted
-- 6th argument would make 5-argument calls ambiguous). Calls with 5 arguments
-- still work through the default. Otherwise the latest definition
-- (20261007010000_cod_and_hitpay.sql) with ONLY the extra check.
-- =============================================================================
begin;

drop function if exists public.hitpay_apply_payment(text, text, text, text, text);

create or replace function public.hitpay_apply_payment(
  p_order_id text,
  p_status text,
  p_method text,
  p_gateway_payment_id text,
  p_reference_number text,
  p_payment_request_id text default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay public.payments;
  v_method text := lower(trim(coalesce(p_method, '')));
  v_gateway_payment_id text := nullif(trim(coalesce(p_gateway_payment_id, '')), '');
  v_reference text := nullif(trim(coalesce(p_reference_number, '')), '');
  v_request_id text := nullif(trim(coalesce(p_payment_request_id, '')), '');
begin
  if p_status is null or p_status not in ('success', 'failed') then
    return null;
  end if;

  select * into v_pay from public.payments where order_id = p_order_id for update;
  if not found then return null; end if;

  if v_pay.status = 'success' or v_pay.status = 'refunded' then
    return v_pay.status;
  end if;
  if p_status = 'failed' and v_pay.status = 'failed' then
    return v_pay.status;
  end if;
  -- A "failed" event from an older link never touches the current one.
  if p_status = 'failed' and v_pay.gateway_payment_id is distinct from v_request_id then
    return v_pay.status;
  end if;

  if v_pay.status = 'failed' then
    update public.payments set status = 'processing' where id = v_pay.id;
  end if;

  perform set_config('app.allow_payment_method_change', 'on', true);
  update public.payments
  set status = p_status,
      method = case when v_method in ('gcash', 'maya', 'card') then v_method else method end,
      gateway = 'hitpay',
      gateway_payment_id = coalesce(v_gateway_payment_id, gateway_payment_id),
      reference_number = coalesce(v_reference, reference_number)
  where id = v_pay.id;
  perform set_config('app.allow_payment_method_change', 'off', true);

  return p_status;
end;
$$;

revoke all on function public.hitpay_apply_payment(text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.hitpay_apply_payment(text, text, text, text, text, text) to service_role;

-- The function's signature changed: let the API pick it up straight away.
notify pgrst, 'reload schema';

commit;
