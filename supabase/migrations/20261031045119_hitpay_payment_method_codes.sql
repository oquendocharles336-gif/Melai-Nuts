-- =============================================================================
-- Melai Nuts — Migration 20261031045119: real HitPay payment methods
-- =============================================================================
-- Run after 20261031034858_enable_online_payment.sql. Idempotent.
--
-- Until now only gcash, maya and card could be recorded, so a QR Ph (or any other)
-- payment stayed on the "card" placeholder and reports called it a card sale.
--
--  1. payments.method also accepts the other methods on HitPay's Philippines list,
--     plus 'online': paid through HitPay, method not known (yet).
--  2. hitpay_apply_payment records them.
--  3. staff_begin_gateway_refund accepts every non-cash method, so a QR Ph payment
--     can still be refunded through HitPay.
--  4. New checkout label 'Online Payment (GCash, QR Ph, Card)', whose placeholder is
--     'online'. HitPay's Philippines list has no Maya method of its own. The older
--     labels stay accepted (past orders, older app builds) and keep their old
--     placeholders, because older builds cannot read the new codes.
--
-- Apply this BEFORE deploying hitpay-webhook and before releasing an app build that
-- sends the new label. Release that app build before switching HitPay to live: older
-- builds cannot read a payment recorded with one of the new codes.
-- =============================================================================
begin;

-- 1. ---------------------------------------------------------------------------
alter table public.payments drop constraint if exists payments_method_check;
alter table public.payments add constraint payments_method_check check (method in (
  'gcash', 'maya', 'card', 'cash',
  'qrph', 'grabpay', 'shopeepay', 'spaylater', 'billease', 'wechat',
  'unionbank', 'instapay', 'pesonet', 'bayad', 'ecpay', 'palawan',
  'online'
));

-- 2. ---------------------------------------------------------------------------
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

  return p_status;
end;
$$;
revoke all on function public.hitpay_apply_payment(text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.hitpay_apply_payment(text, text, text, text, text, text) to service_role;

-- 3. ---------------------------------------------------------------------------
create or replace function public.staff_begin_gateway_refund(p_refund_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.refund_requests;
  v_staff public.staff_members;
  v_branch uuid;
  v_pay public.payments;
  v_live public.refund_gateway_attempts;
  a public.refund_gateway_attempts;
begin
  select * into r from public.refund_requests where id = p_refund_id for update;
  if r.id is null then raise exception 'That refund request could not be found.'; end if;
  select branch_id into v_branch from public.orders where id = r.order_id;
  v_staff := public._require_staff(v_branch, 'refunds');

  -- 'processing' = the app's "Start processing" step; still nothing has been paid back.
  if r.status not in ('approved', 'processing') then
    raise exception 'Only an approved refund can be sent to HitPay (this one is %).', r.status;
  end if;
  select * into v_pay from public.payments where order_id = r.order_id order by created_at desc limit 1 for update;
  if v_pay.id is null or v_pay.method = 'cash' then
    raise exception 'This order was not paid online. Refund the cash and mark it completed instead.';
  end if;
  if v_pay.status <> 'success' then
    raise exception 'The online payment for this order is %, so there is nothing to send back through HitPay.', v_pay.status;
  end if;
  if coalesce(v_pay.gateway, '') <> 'hitpay' or v_pay.gateway_payment_id is null then
    raise exception 'This payment has no HitPay payment id. Send the refund from the HitPay dashboard and mark it completed by hand.';
  end if;
  if r.amount <= 0 or r.amount > v_pay.amount then
    raise exception 'The refund amount does not fit the payment.';
  end if;

  select * into v_live from public.refund_gateway_attempts
  where refund_id = r.id and status in ('sending', 'pending', 'succeeded') limit 1;
  if v_live.id is not null then
    if v_live.status = 'succeeded' then
      raise exception 'This refund was already sent through HitPay.';
    elsif v_live.status = 'pending' then
      raise exception 'HitPay is still processing this refund. Check its status instead of sending it again.';
    else
      raise exception 'A HitPay refund for this request was started at % and has no answer yet. Check the HitPay dashboard before trying again.',
        to_char(v_live.started_at at time zone 'Asia/Manila', 'Mon DD HH12:MI AM');
    end if;
  end if;

  insert into public.refund_gateway_attempts (refund_id, order_id, gateway_payment_id, amount, started_by)
  values (r.id, r.order_id, v_pay.gateway_payment_id, r.amount, v_staff.firebase_uid)
  returning * into a;
  perform public._write_audit(v_staff.firebase_uid, v_branch, 'refund.gateway_send', 'refund_request', r.id,
    jsonb_build_object('attempt_id', a.id, 'amount', a.amount, 'order_id', r.order_id));
  return public._gateway_attempt_json(a);
end;
$$;

-- 4. ---------------------------------------------------------------------------
create or replace function public._trg_orders_online_payment_switch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.payment_method in (
       'Online Payment (GCash, QR Ph, Card)', 'Online Payment (GCash, Maya, Card)',
       'GCash E-Wallet', 'Maya / Credit Card'
     )
     and not public.online_payment_enabled() then
    raise exception '%', public.online_payment_disabled_message();
  end if;
  return new;
end;
$$;

create or replace function public.place_order(
  p_cart_id uuid,
  p_is_delivery boolean,
  p_delivery_address_id uuid,
  p_payment_method text,
  p_customer_notes text default ''
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_cart record;
  v_item record;
  v_available int;
  v_order_id text;
  v_subtotal numeric;
  v_voucher_discount numeric := 0;
  v_loyalty_discount numeric := 0;
  v_delivery_fee numeric;
  v_total numeric;
  v_discount numeric;
  v_points_used int := 0;
  v_balance int := 0;
  v_has_voucher boolean;
  v_voucher record;
  v_points_per_peso numeric;
  v_max_discount_percent numeric;
  v_address record;
  v_profile_phone text;
  v_contact_phone text;
  v_delivery_address_text text;
  v_payment_method_code text;
begin
  if v_uid is null then raise exception 'You must be signed in to place this order.'; end if;

  select c.* into v_cart
  from public.carts c
  where c.id = p_cart_id and c.firebase_uid = v_uid and c.status = 'open'
  for update;
  if not found then raise exception 'Your cart is no longer available.'; end if;

  -- 'Online Payment (GCash, QR Ph, Card)' is settled by the HitPay hosted
  -- checkout; 'online' is only the initial placeholder, the HitPay webhook
  -- (hitpay_apply_payment) records the method actually used. The three older
  -- online labels stay accepted, with their old placeholders, for older app builds.
  if p_payment_method not in (
    'Online Payment (GCash, QR Ph, Card)', 'Cash on Delivery', 'Cash on Counter Pickup',
    'Online Payment (GCash, Maya, Card)', 'GCash E-Wallet', 'Maya / Credit Card'
  ) then
    raise exception 'Unsupported payment method.';
  end if;
  if p_payment_method = 'Cash on Delivery' and not p_is_delivery then
    raise exception 'Cash on Delivery is only available for delivery orders.';
  end if;
  v_payment_method_code := case p_payment_method
    when 'Online Payment (GCash, QR Ph, Card)' then 'online'
    when 'Online Payment (GCash, Maya, Card)' then 'card'
    when 'GCash E-Wallet' then 'gcash'
    when 'Maya / Credit Card' then 'card'
    else 'cash'
  end;

  select phone into v_profile_phone from public.customer_profiles where firebase_uid = v_uid;

  if p_is_delivery then
    if p_delivery_address_id is null then raise exception 'Please provide a delivery address.'; end if;
    select * into v_address from public.customer_addresses
      where id = p_delivery_address_id and firebase_uid = v_uid;
    if not found then raise exception 'The selected delivery address is invalid.'; end if;
    select delivery_fee into v_delivery_fee from public.branches
      where id = v_cart.branch_id and supports_delivery and is_active;
    if not found then raise exception 'Delivery is not available for this branch.'; end if;
    v_contact_phone := nullif(trim(v_address.phone), '');
    v_delivery_address_text := trim(
      v_address.recipient_name || ', ' || v_address.line1 || ', ' || v_address.city ||
      case when coalesce(v_address.province, '') <> '' then ', ' || v_address.province else '' end ||
      case when coalesce(v_address.postal_code, '') <> '' then ' ' || v_address.postal_code else '' end
    );
  else
    if not exists (select 1 from public.branches where id = v_cart.branch_id and supports_pickup and is_active) then
      raise exception 'Pickup is not available for this branch.';
    end if;
    v_delivery_fee := 0;
    v_contact_phone := nullif(trim(coalesce(v_profile_phone, '')), '');
    v_delivery_address_text := null;
  end if;

  if v_contact_phone is null then
    raise exception 'Please add a contact phone number to your profile before checking out.';
  end if;

  -- Prices always come from the catalog, never from the cart row.
  update public.cart_items ci
  set current_price = pv.price, variant_label = pv.label, updated_at = now()
  from public.product_variants pv
  join public.products p on p.id = pv.product_id
  where ci.cart_id = v_cart.id and ci.variant_id = pv.id and p.is_active;

  if not exists (select 1 from public.cart_items where cart_id = v_cart.id) then
    raise exception 'Your cart is empty.';
  end if;

  -- Validate + lock stock in a fixed order so two checkouts cannot deadlock.
  for v_item in
    select ci.product_id, ci.variant_id, ci.quantity, p.name as product_name, p.is_active as product_active
    from public.cart_items ci
    join public.products p on p.id = ci.product_id
    where ci.cart_id = v_cart.id
    order by ci.product_id, ci.variant_id
  loop
    if not v_item.product_active then raise exception '% is no longer available.', v_item.product_name; end if;
    if v_item.variant_id is null then raise exception '% is no longer available.', v_item.product_name; end if;
    select bi.quantity into v_available
    from public.branch_inventory bi
    where bi.branch_id = v_cart.branch_id
      and bi.product_id = v_item.product_id
      and bi.variant_id = v_item.variant_id
    for update;
    if v_available is null then raise exception '% is not available at this branch.', v_item.product_name; end if;
    if v_available < v_item.quantity then
      raise exception 'Only % of % left at this branch.', v_available, v_item.product_name;
    end if;
  end loop;

  -- Lock the loyalty account before recomputing so points cannot be spent twice.
  insert into public.loyalty_accounts (firebase_uid) values (v_uid) on conflict (firebase_uid) do nothing;
  select points_balance into v_balance from public.loyalty_accounts where firebase_uid = v_uid for update;

  select coalesce(sum(current_price * quantity), 0) into v_subtotal
  from public.cart_items where cart_id = v_cart.id;

  v_has_voucher := v_cart.voucher_code is not null and trim(v_cart.voucher_code) <> '';
  if v_has_voucher then
    select * into v_voucher
    from public.vouchers v
    where upper(v.code) = upper(trim(v_cart.voucher_code))
      and v.is_active
      and (v.starts_at is null or v.starts_at <= now())
      and (v.ends_at is null or v.ends_at >= now())
    for update;
    if not found then raise exception 'Voucher is invalid or expired.'; end if;
    if v_voucher.usage_limit is not null and v_voucher.used_count >= v_voucher.usage_limit then
      raise exception 'This voucher has reached its usage limit.';
    end if;
    if v_voucher.per_customer_limit is not null and
       (select count(*) from public.voucher_usage vu
        where vu.voucher_id = v_voucher.id and vu.firebase_uid = v_uid) >= v_voucher.per_customer_limit then
      raise exception 'You have already used this voucher.';
    end if;
    if v_subtotal < v_voucher.minimum_subtotal then
      raise exception 'This voucher requires a minimum subtotal of ₱%.', v_voucher.minimum_subtotal;
    end if;
    if v_voucher.discount_type = 'percent' then
      v_voucher_discount := round(v_subtotal * v_voucher.discount_value / 100, 2);
    else
      v_voucher_discount := v_voucher.discount_value;
    end if;
    if v_voucher.maximum_discount is not null then
      v_voucher_discount := least(v_voucher_discount, v_voucher.maximum_discount);
    end if;
    v_voucher_discount := least(v_voucher_discount, v_subtotal);
  end if;

  if v_cart.redeem_points then
    select points_per_peso, max_discount_percent into v_points_per_peso, v_max_discount_percent
    from public.loyalty_cart_settings where id = 'default';
    if v_points_per_peso is null then raise exception 'Loyalty point redemption is not configured yet.'; end if;
    if v_balance <= 0 then raise exception 'You do not have loyalty points available to redeem.'; end if;
    v_points_used := least(
      v_balance,
      floor(greatest(0, least(v_subtotal - v_voucher_discount,
                              v_subtotal * v_max_discount_percent / 100)) * v_points_per_peso)::int
    );
    v_loyalty_discount := round(v_points_used / v_points_per_peso, 2);
  end if;

  v_discount := v_voucher_discount + v_loyalty_discount;
  v_total := greatest(0, v_subtotal - v_discount + v_delivery_fee);

  update public.branch_inventory bi
  set quantity = bi.quantity - ci.quantity
  from public.cart_items ci
  where ci.cart_id = v_cart.id
    and bi.branch_id = v_cart.branch_id
    and bi.product_id = ci.product_id
    and bi.variant_id = ci.variant_id;

  insert into public.orders (
    firebase_uid, branch_id, branch_name, is_delivery, delivery_address_id,
    subtotal, discount, delivery_fee, total, payment_method,
    customer_notes, contact_phone, delivery_address_text
  )
  select v_uid, v_cart.branch_id, b.name, p_is_delivery, p_delivery_address_id,
    v_subtotal, v_discount, v_delivery_fee, v_total, p_payment_method,
    left(coalesce(trim(p_customer_notes), ''), 500), v_contact_phone, v_delivery_address_text
  from public.branches b where b.id = v_cart.branch_id
  returning id into v_order_id;

  insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
  select v_order_id, ci.product_id, ci.variant_id, p.name, ci.variant_label, ci.quantity, ci.current_price
  from public.cart_items ci
  join public.products p on p.id = ci.product_id
  where ci.cart_id = v_cart.id;

  -- Created in the same transaction as the order; only a trusted server path
  -- (gateway webhook / staff tooling) may ever move it past 'pending'.
  insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number)
  values (v_order_id, v_uid, v_payment_method_code, 'pending', v_total, v_order_id);

  if v_points_used > 0 then
    update public.loyalty_accounts set points_balance = points_balance - v_points_used
    where firebase_uid = v_uid;
    insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
    values (v_uid, 'redeem', -v_points_used, 'Applied to order ' || v_order_id, v_order_id, 'order_redeem');
  end if;

  if v_has_voucher then
    update public.vouchers set used_count = used_count + 1 where id = v_voucher.id;
    insert into public.voucher_usage (voucher_id, firebase_uid, order_id, discount_amount)
    values (v_voucher.id, v_uid, v_order_id, v_voucher_discount);
  end if;

  delete from public.cart_items where cart_id = v_cart.id;
  update public.carts
  set status = 'checked_out', voucher_code = null, redeem_points = false, updated_at = now()
  where id = v_cart.id;

  return v_order_id;
end;
$$;

commit;
