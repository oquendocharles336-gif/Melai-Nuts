-- =============================================================================
-- Melai Nuts — Migration 20261031064602: a payment on a cancelled order is refunded
-- =============================================================================
-- Run after 20261031064416_staff_profile_photos.sql. Idempotent.
--
-- A HitPay page can stay open after its order is cancelled. If the customer then
-- pays, the money is real, but nothing told anyone it had to go back.
--
--  1. hitpay_apply_payment still records the payment, and also opens a refund
--     request for it, so it shows in the normal refund queue ("Send via HitPay").
--     The customer and the staff are told.
--  2. sync_order_status_from_refund leaves a cancelled order cancelled. It used to
--     try to move it to refundRequested, which a cancelled order refuses, and that
--     would have made the webhook fail on every retry. When the refund completes it
--     marks the payment refunded, which finalize_order_refund does for other orders.
--
-- Stock and points need nothing: cancelling returned the stock, and a cancelled
-- order earns no points. Sales reports count this payment as a sale and the
-- completed refund against it, so they net to zero.
-- =============================================================================
begin;

-- 1. ---------------------------------------------------------------------------
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
  v_order public.orders;
  v_method text := lower(trim(coalesce(p_method, '')));
  v_gateway_payment_id text := nullif(trim(coalesce(p_gateway_payment_id, '')), '');
  v_reference text := nullif(trim(coalesce(p_reference_number, '')), '');
  v_request_id text := nullif(trim(coalesce(p_payment_request_id, '')), '');
  v_refund_id text;
begin
  if p_status is null or p_status not in ('success', 'failed') then
    return null;
  end if;

  -- The order first, so a cancel running right now is seen here or sees this payment.
  select * into v_order from public.orders where id = p_order_id for update;
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
      method = case when v_method in (
        'gcash', 'maya', 'card',
        'qrph', 'grabpay', 'shopeepay', 'spaylater', 'billease', 'wechat',
        'unionbank', 'instapay', 'pesonet', 'bayad', 'ecpay', 'palawan',
        'online'
      ) then v_method else method end,
      gateway = 'hitpay',
      gateway_payment_id = coalesce(v_gateway_payment_id, gateway_payment_id),
      reference_number = coalesce(v_reference, reference_number)
  where id = v_pay.id;
  perform set_config('app.allow_payment_method_change', 'off', true);

  -- Paid after it was cancelled: the money has to go back.
  if p_status = 'success' and v_order.status = 'cancelled' and v_pay.amount > 0 then
    insert into public.refund_requests (order_id, firebase_uid, reason, notes, amount, payment_method)
    values (v_order.id, v_order.firebase_uid, 'Paid after the order was cancelled',
            'Opened automatically when HitPay reported this payment.', v_pay.amount, v_order.payment_method)
    on conflict (order_id) where status <> 'rejected' do nothing
    returning id into v_refund_id;

    perform public.notify_customer(v_order.firebase_uid, 'refund', 'Payment received for a cancelled order',
      'We received ₱' || to_char(v_pay.amount, 'FM999,999,990.00') || ' for order ' || v_order.id
        || ' after it was cancelled. We will refund it to you.');

    -- Staff with refund rights hear about it from the refund request's own trigger.
    insert into public.staff_notifications (recipient_uid, branch_id, category, title, body, reference)
    select s.firebase_uid, v_order.branch_id, 'refund', 'Refund needed: cancelled order was paid',
           'Order ' || v_order.id || ' • ₱' || to_char(v_pay.amount, 'FM999,999,990.00'), v_refund_id
    from public.staff_members s
    where s.is_active and s.role = 'owner';
  end if;

  return p_status;
end;
$$;
revoke all on function public.hitpay_apply_payment(text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.hitpay_apply_payment(text, text, text, text, text, text) to service_role;

-- 2. ---------------------------------------------------------------------------
create or replace function public.sync_order_status_from_refund()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.orders where id = new.order_id and status = 'cancelled') then
    if tg_op = 'UPDATE' and new.status = 'completed' and old.status is distinct from 'completed' then
      update public.payments set status = 'refunded'
      where order_id = new.order_id and status = 'success';
    end if;
    return new;
  end if;

  if tg_op = 'INSERT' then
    update public.orders set status = 'refundRequested' where id = new.order_id;
  elsif new.status is distinct from old.status then
    if new.status = 'completed' then
      update public.orders set status = 'refunded' where id = new.order_id;
    elsif new.status = 'rejected' then
      update public.orders set status = 'completed' where id = new.order_id;
    end if;
  end if;
  return new;
end;
$$;

commit;
