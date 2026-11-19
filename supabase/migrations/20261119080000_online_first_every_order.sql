-- =============================================================================
-- Online first, every order (anti-scam)
-- =============================================================================
-- Every customer order with something to pay is now paid online first, new or
-- returning customer, app or website:
--   * Online Payment: 100% online before the branch sees the order.
--   * Cash on Counter Pickup (and Cash on Delivery, if a branch ever delivers):
--     the downpayment set on the admin website (Business Settings) online first,
--     the rest in cash. Without a downpayment there is no cash order.
--   * No cash-only orders. While online payment is switched off, no order with
--     something to pay is taken ("Ordering is paused").
-- The first-order rule (20261118015010 / 20261118040000) is unchanged: a first
-- order still pays 50% or 100% online.
--
-- Returning customers' Online Payment orders used to go straight to 'pending'
-- (staff were told before any money arrived, with no time limit). They now get
-- an order_downpayments row of the new kind 'online' for the whole total, so they
-- wait in 'awaitingDownpayment' exactly like a first order paid 100%: HitPay pays
-- it (hitpay-create-payment / hitpay_apply_payment / _cod_downpayment_apply are
-- unchanged and already handle a downpayment that covers the whole total), staff
-- are told once it is paid, and expire_unpaid_cod_downpayments cancels it and
-- returns the stock if it is not paid in time (cod_downpayment_expiry_minutes,
-- 30 when not set). No pickup deadline forfeit applies to it (pickup_days null).
--
-- Changed, from their latest definitions (bodies matched live before this):
--   _place_order_core              (20261119000000_remove_phone_verification.sql)
--   _cod_downpayment_apply         (20261118040000_verified_phone_first_order.sql): wording only
--   expire_unpaid_cod_downpayments (20261118015010_first_order_prepayment.sql):    wording only
-- and the order_downpayments kind check gains 'online'.
--
-- Roll out AFTER the owner has set the Cash on Counter Pickup downpayment on the
-- admin website (type, value, expiry minutes, pickup days): until then this
-- refuses every Cash on Counter Pickup order.
-- =============================================================================
begin;

alter table public.order_downpayments drop constraint if exists order_downpayments_kind_check;
alter table public.order_downpayments add constraint order_downpayments_kind_check check (
  kind in ('cod', 'first_order', 'online')
  and (choice is null or choice in ('half', 'full'))
  and ((kind = 'first_order') = (choice is not null))
);

create or replace function public._place_order_core(
  p_cart_id uuid,
  p_is_delivery boolean,
  p_delivery_address_id uuid,
  p_payment_method text,
  p_customer_notes text,
  p_first_order_payment text
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
  v_downpayment numeric;
  v_first boolean := false;
  v_choice text;
  v_pending text;
  v_expiry int;
  v_online_first boolean := false;
begin
  if v_uid is null then raise exception 'You must be signed in to place this order.'; end if;

  select c.* into v_cart
  from public.carts c
  where c.id = p_cart_id and c.firebase_uid = v_uid and c.status = 'open'
  for update;
  if not found then raise exception 'Your cart is no longer available.'; end if;

  -- FIRST ORDER. The customer's profile row is locked for the rest of this transaction,
  -- so two checkouts of one account run one after the other: the second one sees the
  -- first one's unpaid first order and is refused (one unpaid first order at a time).
  perform 1 from public.customer_profiles where firebase_uid = v_uid for update;

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
    v_contact_phone := nullif(trim(v_profile_phone), '');   -- pickup: the profile's mobile number
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

  -- ONLINE FIRST, EVERY ORDER (migration 20261119080000): an order with something to pay
  -- is paid online first, in full or in part. While online payment is switched off nothing
  -- can be paid online, so no such order is taken (app and website show ordering paused).
  if v_total > 0 and not public.online_payment_enabled() then
    raise exception 'Ordering is paused because online payment is unavailable right now. Please try again later.';
  end if;

  -- A customer who never had a paid online order pays 50% or 100% online first
  -- (migration 20261118015010). Nothing to pay (a fully discounted order) = no rule.
  -- Decided here, on the server, from the account and its mobile number (_is_first_order).
  v_first := v_total > 0 and public._is_first_order(v_uid);
  if v_first then
    select o.id into v_pending
    from public.orders o
    join public.order_downpayments d on d.order_id = o.id
    where o.firebase_uid = v_uid and o.status = 'awaitingDownpayment' and d.kind = 'first_order'
    order by o.created_at
    limit 1;
    if v_pending is not null then
      raise exception 'Your first order % is still waiting for its online payment. Please pay for it, or wait for it to expire, before placing another order.', v_pending;
    end if;
    if p_payment_method not in (
      'Online Payment (GCash, QR Ph, Card)', 'Online Payment (GCash, Maya, Card)', 'GCash E-Wallet', 'Maya / Credit Card'
    ) then
      raise exception 'Your first order is paid online: choose to pay 50%% or 100%% now.';
    end if;
    if not public.online_payment_enabled() then
      raise exception 'Your first order is paid online, and online payment is unavailable right now. Please try again later.';
    end if;
    -- Older app builds send no choice; they already paid online orders in full.
    v_choice := lower(trim(coalesce(p_first_order_payment, 'full')));
    if v_choice not in ('half', 'full') then
      raise exception 'Choose to pay 50%% or 100%% of your first order now.';
    end if;
    v_downpayment := case v_choice when 'full' then round(v_total, 2) else round(v_total * 0.5, 2) end;
    -- What is left is paid in cash at pickup / on delivery. Paid in full = nothing left.
    if v_downpayment < v_total then v_payment_method_code := 'cash'; end if;
    select cod_downpayment_expiry_minutes into v_expiry from public.business_settings where id = 'default';
    v_expiry := coalesce(v_expiry, 30);
  elsif v_payment_method_code = 'cash' then
    -- Cash on Counter Pickup and Cash on Delivery: the downpayment set on the admin website
    -- is paid online first, the rest in cash. No downpayment (not set, or below its minimum
    -- order) = no cash order: there are no cash-only orders.
    v_downpayment := public._cod_downpayment_amount(v_total);
    if v_total > 0 and v_downpayment is null then
      raise exception 'Cash payment is not available for this order right now. Please choose Online Payment.';
    end if;
  elsif v_total > 0 then
    -- Online Payment, returning customer: the whole total is paid online before the branch
    -- sees the order, within the same time limit as a downpayment, or the order is cancelled
    -- and its stock returned (expire_unpaid_cod_downpayments).
    v_online_first := true;
    v_downpayment := round(v_total, 2);
    select cod_downpayment_expiry_minutes into v_expiry from public.business_settings where id = 'default';
    v_expiry := coalesce(v_expiry, 30);
  end if;

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
    customer_notes, contact_phone, delivery_address_text, status
  )
  -- A pickup order never links an address, whatever an app build sends.
  select v_uid, v_cart.branch_id, b.name, p_is_delivery,
    case when p_is_delivery then p_delivery_address_id end,
    v_subtotal, v_discount, v_delivery_fee, v_total, p_payment_method,
    left(coalesce(trim(p_customer_notes), ''), 500), v_contact_phone, v_delivery_address_text,
    case when v_downpayment is null then 'pending' else 'awaitingDownpayment' end
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
  values (v_order_id, v_uid, v_payment_method_code, 'pending', v_total - coalesce(v_downpayment, 0), v_order_id);

  -- The amount and the time limit are fixed now: changing the settings later does not
  -- touch an order already placed.
  if v_first then
    insert into public.order_downpayments (order_id, firebase_uid, amount, expires_at, pickup_days, percent, kind, choice)
    values (v_order_id, v_uid, v_downpayment, now() + make_interval(mins => v_expiry), null,
            case v_choice when 'full' then 100 else 50 end, 'first_order', v_choice);
  elsif v_online_first then
    insert into public.order_downpayments (order_id, firebase_uid, amount, expires_at, pickup_days, percent, kind)
    values (v_order_id, v_uid, v_downpayment, now() + make_interval(mins => v_expiry), null, 100, 'online');
  elsif v_downpayment is not null then
    insert into public.order_downpayments (order_id, firebase_uid, amount, expires_at, pickup_days, percent)
    select v_order_id, v_uid, v_downpayment, now() + make_interval(mins => s.cod_downpayment_expiry_minutes),
           s.cod_downpayment_pickup_days,
           case when s.cod_downpayment_type = 'percent' then s.cod_downpayment_value end
    from public.business_settings s where s.id = 'default';
  end if;

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

create or replace function public._cod_downpayment_apply(
  p_order public.orders,
  p_dp public.order_downpayments,
  p_status text,
  p_method text,
  p_gateway_payment_id text,
  p_request_id text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_dp.status in ('success', 'refunded', 'forfeited') then return p_dp.status; end if;
  if p_status = 'failed' then
    if p_dp.status in ('failed', 'expired') then return p_dp.status; end if;
    -- A "failed" event from an older link never touches the current one.
    if p_dp.gateway_payment_id is distinct from p_request_id then return p_dp.status; end if;
  end if;

  update public.order_downpayments
  set status = p_status,
      method = case when p_method in (
        'gcash', 'maya', 'card',
        'qrph', 'grabpay', 'shopeepay', 'spaylater', 'billease', 'wechat',
        'unionbank', 'instapay', 'pesonet', 'bayad', 'ecpay', 'palawan',
        'online'
      ) then p_method else method end,
      gateway = 'hitpay',
      gateway_payment_id = coalesce(p_gateway_payment_id, gateway_payment_id),
      paid_at = case when p_status = 'success' then now() else paid_at end,
      gateway_checkout_url = case when p_status = 'failed' then null else gateway_checkout_url end,
      gateway_checkout_created_at = case when p_status = 'failed' then null else gateway_checkout_created_at end,
      checkout_started_at = null
  where order_id = p_dp.order_id;

  if p_status <> 'success' then return p_status; end if;

  if p_order.status = 'awaitingDownpayment' then
    perform set_config('app.cod_downpayment_release', 'on', true);
    update public.orders set status = 'pending' where id = p_order.id;
    perform set_config('app.cod_downpayment_release', 'off', true);

    -- A fixed downpayment can cover the whole order: nothing is left to collect.
    update public.payments set status = 'success'
    where order_id = p_order.id and amount = 0 and status in ('pending', 'processing');

    -- 'online' (20261119080000): a returning customer's Online Payment, paid in full first.
    if p_dp.kind in ('first_order', 'online') and p_dp.amount >= p_order.total then
      perform public.notify_customer(p_order.firebase_uid, 'payment', 'Payment received',
        'We received ₱' || to_char(p_dp.amount, 'FM999,999,990.00') || ' for order ' || p_order.id
          || '. Your order is fully paid.');
    elsif p_dp.kind = 'first_order' then
      perform public.notify_customer(p_order.firebase_uid, 'payment', 'Payment received',
        'We received ₱' || to_char(p_dp.amount, 'FM999,999,990.00') || ' for order ' || p_order.id
          || '. The remaining ₱' || to_char(p_order.total - p_dp.amount, 'FM999,999,990.00')
          || case when public.online_payment_enabled()
                  then ' can be paid online now (open the order and tap Pay remaining balance), or in cash '
                       || case when p_order.is_delivery then 'on delivery.' else 'when you pick it up.' end
                  when p_order.is_delivery then ' is paid in cash on delivery.'
                  else ' is paid in cash when you pick it up.' end);
    else
      perform public.notify_customer(p_order.firebase_uid, 'payment', 'Downpayment received',
        'We received ₱' || to_char(p_dp.amount, 'FM999,999,990.00') || ' for order ' || p_order.id
          || '. The rest is paid in cash when you pick it up.');
    end if;
    begin
      perform public._notify_staff(p_order.branch_id, 'order',
        'New ' || case when p_order.is_delivery then 'delivery' else 'pickup' end || ' order ' || p_order.id,
        'Total ₱' || to_char(p_order.total, 'FM999,999,990.00')
          || case when p_order.total - p_dp.amount <= 0 then ' • Fully paid online'
                  else ' • Paid online ₱' || to_char(p_dp.amount, 'FM999,999,990.00') || ' • Collect ₱'
                       || to_char(p_order.total - p_dp.amount, 'FM999,999,990.00') || ' in cash' end,
        p_order.id);
    exception when others then
      raise warning 'staff order notification for % failed: %', p_order.id, sqlerrm;
    end;
  elsif p_order.status = 'cancelled' then
    perform public._cod_downpayment_open_refund(p_order, p_dp.amount, 'Downpayment paid after the order was cancelled');
  end if;

  return p_status;
end;
$$;

create or replace function public.expire_unpaid_cod_downpayments()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select o.id, o.firebase_uid, d.kind
    from public.orders o
    join public.order_downpayments d on d.order_id = o.id
    where o.status = 'awaitingDownpayment' and d.expires_at <= now()
    order by d.expires_at
    limit 200
    for update of o skip locked
  loop
    update public.orders set status = 'cancelled' where id = r.id;
    perform public.notify_customer(r.firebase_uid, 'order', 'Order cancelled',
      'Order ' || r.id || ' was cancelled because its '
        || case when r.kind in ('first_order', 'online') then 'online payment' else 'downpayment' end
        || ' was not paid in time.');
    n := n + 1;
  end loop;
  return n + public.forfeit_unclaimed_cod_downpayments();
end;
$$;

commit;
