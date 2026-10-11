-- Cash on Delivery (COD) + HitPay online payments.
--
--  1. place_order (5-arg core) accepts two new labels:
--       'Online Payment (GCash, Maya, Card)'  -> payments.method 'card' (placeholder)
--       'Cash on Delivery'                    -> payments.method 'cash', delivery only
--     The three older labels keep working. Everything else is unchanged from
--     20260928000000_customer_security_hardening.sql. Grants are untouched:
--     CREATE OR REPLACE keeps them (the 5-arg core stays internal; customers
--     call the 6-arg wrapper from 20260928010000_order_integrity.sql).
--  2. payments gets gateway columns.
--  3. forbid_financial_edits lets hitpay_apply_payment correct payments.method.
--  4. hitpay_set_checkout / hitpay_apply_payment: service_role-only functions
--     called by the hitpay-create-payment / hitpay-webhook Edge Functions.
--
-- Safe to re-run.

-- -----------------------------------------------------------------------------
-- 1. place_order (5-arg core)
-- -----------------------------------------------------------------------------
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

  -- 'Online Payment (GCash, Maya, Card)' is settled by the HitPay hosted
  -- checkout; 'card' is only the initial placeholder, the HitPay webhook
  -- (hitpay_apply_payment) records the method actually used. The three older
  -- labels stay accepted for backward compatibility with older app builds.
  if p_payment_method not in (
    'Online Payment (GCash, Maya, Card)', 'Cash on Delivery', 'Cash on Counter Pickup',
    'GCash E-Wallet', 'Maya / Credit Card'
  ) then
    raise exception 'Unsupported payment method.';
  end if;
  if p_payment_method = 'Cash on Delivery' and not p_is_delivery then
    raise exception 'Cash on Delivery is only available for delivery orders.';
  end if;
  v_payment_method_code := case p_payment_method
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

-- -----------------------------------------------------------------------------
-- 2. Gateway columns
-- -----------------------------------------------------------------------------
alter table public.payments
  add column if not exists gateway text,
  add column if not exists gateway_payment_id text,
  add column if not exists gateway_checkout_url text;

-- -----------------------------------------------------------------------------
-- 3. Immutability of financial facts (payments.method now correctable)
-- -----------------------------------------------------------------------------
create or replace function public.forbid_financial_edits()
returns trigger
language plpgsql
as $$
begin
  if tg_table_name = 'orders' then
    if (new.firebase_uid, new.branch_id, new.is_delivery, new.subtotal, new.discount,
        new.delivery_fee, new.total, new.payment_method, new.points_earned)
       is distinct from
       (old.firebase_uid, old.branch_id, old.is_delivery, old.subtotal, old.discount,
        old.delivery_fee, old.total, old.payment_method, old.points_earned) then
      raise exception 'The financial details of order % cannot be changed after it is placed.', old.id;
    end if;
  elsif tg_table_name = 'payments' then
    if (new.order_id, new.firebase_uid, new.amount)
       is distinct from (old.order_id, old.firebase_uid, old.amount) then
      raise exception 'The amount and owner of payment % cannot be changed.', old.id;
    end if;
    -- The method may only be corrected by hitpay_apply_payment, which flags
    -- its own transaction; nobody else can reach this branch (customers have
    -- no UPDATE privilege on payments).
    if new.method is distinct from old.method
       and coalesce(current_setting('app.allow_payment_method_change', true), '') <> 'on' then
      raise exception 'The method of payment % cannot be changed.', old.id;
    end if;
  elsif tg_table_name = 'refund_requests' then
    if (new.order_id, new.firebase_uid, new.amount, new.payment_method)
       is distinct from (old.order_id, old.firebase_uid, old.amount, old.payment_method) then
      raise exception 'The order, owner and amount of refund % cannot be changed.', old.id;
    end if;
  elsif tg_table_name = 'order_items' then
    -- product_id / variant_id may still be nulled by ON DELETE SET NULL.
    if (new.order_id, new.product_name, new.variant_label, new.quantity, new.unit_price)
       is distinct from (old.order_id, old.product_name, old.variant_label, old.quantity, old.unit_price) then
      raise exception 'Order lines cannot be edited after the order is placed.';
    end if;
  elsif tg_table_name = 'refund_items' then
    raise exception 'Refund lines cannot be edited.';
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. HitPay server-side helpers (service_role only)
-- -----------------------------------------------------------------------------
-- Stores the HitPay payment-request id and checkout URL. A pending (or failed,
-- i.e. being retried) payment becomes 'processing'.
create or replace function public.hitpay_set_checkout(
  p_order_id text,
  p_payment_id text,
  p_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay public.payments;
begin
  select * into v_pay from public.payments where order_id = p_order_id for update;
  if not found then raise exception 'Order % has no payment record.', p_order_id; end if;

  update public.payments
  set gateway = 'hitpay',
      gateway_payment_id = nullif(trim(coalesce(p_payment_id, '')), ''),
      gateway_checkout_url = nullif(trim(coalesce(p_url, '')), '')
  where id = v_pay.id;

  if v_pay.status in ('pending', 'failed') then
    update public.payments set status = 'processing' where id = v_pay.id;
  end if;
end;
$$;

-- Applies a HitPay payment result to the order's payment row. 'success' and
-- 'failed' only move a payment that is still open; a success is never
-- downgraded. A payment that an earlier failed attempt marked 'failed' may
-- still succeed (HitPay lets the buyer retry on the same page), so it goes
-- failed -> processing -> success, both steps valid transitions. Any other
-- status is ignored. Returns the resulting payment status (null if no row).
create or replace function public.hitpay_apply_payment(
  p_order_id text,
  p_status text,
  p_method text,
  p_gateway_payment_id text,
  p_reference_number text
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

revoke all on function public.hitpay_set_checkout(text, text, text) from public, anon, authenticated;
grant execute on function public.hitpay_set_checkout(text, text, text) to service_role;
revoke all on function public.hitpay_apply_payment(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.hitpay_apply_payment(text, text, text, text, text) to service_role;
