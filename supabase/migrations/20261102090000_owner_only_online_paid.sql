-- =============================================================================
-- Melai Nuts — only HitPay or the owner can mark online money as paid.
--
-- staff_confirm_payment let any branch staff mark an online order as paid by
-- typing any reference of 4 or more characters. Nothing proved the money arrived.
-- Now:
--   * staff_confirm_payment is for cash only, for every role.
--   * hitpay_apply_payment (the webhook) stays the normal way online money is
--     recorded.
--   * owner_confirm_online_payment is the fallback when HitPay's message never
--     arrives. Owner only, a reason is required, and it is written to
--     staff_audit_logs. It covers full online payments and pickup downpayments.
-- =============================================================================

create or replace function public.staff_confirm_payment(p_order_id text, p_reference text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  o public.orders;
  pay public.payments;
  v_ref text := nullif(trim(coalesce(p_reference, '')), '');
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'That order could not be found.'; end if;
  perform public._require_staff(o.branch_id);
  if o.status = 'awaitingDownpayment' then raise exception 'That order could not be found.'; end if;
  if o.status in ('cancelled', 'refunded') then raise exception 'This order is % and cannot be paid.', o.status; end if;
  select * into pay from public.payments where order_id = p_order_id for update;
  if not found then raise exception 'This order has no payment record.'; end if;
  if pay.status not in ('pending', 'processing') then raise exception 'This payment is already %.', pay.status; end if;
  if pay.method <> 'cash' then
    raise exception 'Online payments are confirmed by HitPay. If this one looks stuck, ask the owner to check it.';
  end if;
  update public.payments
  set status = 'success', reference_number = coalesce(v_ref, reference_number)
  where id = pay.id;
  perform public.notify_customer(o.firebase_uid, 'payment', 'Payment received',
    'We received your payment for order ' || o.id || '.');
end;
$$;

-- Returns what was confirmed: 'payment' or 'downpayment'.
create or replace function public.owner_confirm_online_payment(
  p_order_id text,
  p_reason text,
  p_reference text default null
)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_owner public.staff_members;
  o public.orders;
  dp public.order_downpayments;
  pay public.payments;
  v_reason text := trim(coalesce(p_reason, ''));
  v_ref text := nullif(trim(coalesce(p_reference, '')), '');
  v_kind text;
  v_amount numeric;
  v_from text;
begin
  v_owner := public._require_owner();
  if length(v_reason) < 10 or length(v_reason) > 300 then
    raise exception 'Give a reason of 10 to 300 characters.';
  end if;
  if length(v_ref) > 100 then raise exception 'The reference is too long.'; end if;

  -- Same lock order as hitpay_apply_payment, so a webhook arriving now waits and
  -- then finds the payment already recorded.
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'That order could not be found.'; end if;
  if o.status in ('cancelled', 'refundRequested', 'refunded') then
    raise exception 'This order is % and cannot be paid.', o.status;
  end if;

  select * into dp from public.order_downpayments where order_id = p_order_id for update;
  if found then
    if dp.status not in ('pending', 'processing', 'failed') then
      raise exception 'This downpayment is already %.', dp.status;
    end if;
    v_kind := 'downpayment';
    v_amount := dp.amount;
    v_from := dp.status;
    -- Releases the order to staff and tells the customer, as the webhook does.
    perform public._cod_downpayment_apply(o, dp, 'success', null, null, null);
  else
    select * into pay from public.payments where order_id = p_order_id for update;
    if not found then raise exception 'This order has no payment record.'; end if;
    if pay.method = 'cash' then raise exception 'This is a cash order. Use Mark as paid once the cash is collected.'; end if;
    if pay.status not in ('pending', 'processing', 'failed') then
      raise exception 'This payment is already %.', pay.status;
    end if;
    v_kind := 'payment';
    v_amount := pay.amount;
    v_from := pay.status;
    if pay.status = 'failed' then
      update public.payments set status = 'processing' where id = pay.id;
    end if;
    update public.payments
    set status = 'success', reference_number = coalesce(v_ref, reference_number)
    where id = pay.id;
    perform public.notify_customer(o.firebase_uid, 'payment', 'Payment received',
      'We received your payment for order ' || o.id || '.');
  end if;

  perform public._write_audit(v_owner.firebase_uid, o.branch_id, 'payment.owner_confirmed_online', 'order', o.id,
    jsonb_build_object('kind', v_kind, 'reason', v_reason, 'reference', v_ref, 'amount', v_amount, 'from_status', v_from));
  return v_kind;
end;
$$;

revoke all on function public.owner_confirm_online_payment(text, text, text) from public, anon;
grant execute on function public.owner_confirm_online_payment(text, text, text) to authenticated;
