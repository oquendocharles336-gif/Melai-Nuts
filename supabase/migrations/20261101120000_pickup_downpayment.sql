-- =============================================================================
-- Melai Nuts — Migration 20261101120000: the downpayment moves to Cash on Counter Pickup
-- =============================================================================
-- Run after 20261101083000_cod_downpayment.sql. Idempotent.
--
-- Melai Nuts only offers store pickup. Cash on Counter Pickup now requires the
-- downpayment; Cash on Delivery goes back to full cash. The names keep "cod" so the
-- scheduled job and the settings keep working.
--
-- OFF UNTIL THE OWNER SETS IT, and while online payment is switched off: pickup then
-- stays full cash, as before. Older app builds cannot read the new order status, so
-- the owner enters the settings only after the app is released.
--
-- NOT PICKED UP IN TIME. cod_downpayment_pickup_days counts from when staff mark the
-- order Ready for Pickup, so a slow shop never costs a customer their money. The
-- order is then cancelled and its stock, points and voucher returned, but the shop
-- keeps the downpayment (status 'forfeited'). That money is reported apart, as
-- kept_downpayments: nothing was sold, so it is not a sale.
--
-- SHOP CANCELS. Every other cancellation of a paid order refunds the downpayment.
-- If staff already confirmed the balance, the order is left for them to handle.
-- =============================================================================
begin;

-- 1. Settings and the order's own copy of them ------------------------------------
alter table public.business_settings add column if not exists cod_downpayment_pickup_days int;
alter table public.business_settings drop constraint if exists business_settings_cod_downpayment_check;
alter table public.business_settings add constraint business_settings_cod_downpayment_check check (
  (cod_downpayment_type is null or cod_downpayment_type in ('percent', 'fixed'))
  and (cod_downpayment_value is null or cod_downpayment_value > 0)
  and (cod_downpayment_type is distinct from 'percent' or cod_downpayment_value is null or cod_downpayment_value < 100)
  and (cod_downpayment_min_order is null or cod_downpayment_min_order > 0)
  and (cod_downpayment_expiry_minutes is null or cod_downpayment_expiry_minutes between 5 and 1440)
  and (cod_downpayment_pickup_days is null or cod_downpayment_pickup_days between 1 and 30));

-- Fixed when the order is placed: changing the settings never touches a placed order.
alter table public.order_downpayments add column if not exists percent numeric(5, 2);
alter table public.order_downpayments add column if not exists pickup_days int;
alter table public.order_downpayments add column if not exists forfeited_at timestamptz;
alter table public.order_downpayments drop constraint if exists order_downpayments_status_check;
alter table public.order_downpayments add constraint order_downpayments_status_check
  check (status in ('pending', 'processing', 'success', 'failed', 'expired', 'refunded', 'forfeited'));
create index if not exists order_downpayments_kept_idx on public.order_downpayments (forfeited_at) where status = 'forfeited';

-- The saved message told customers to choose Cash on Delivery. Only the original
-- wording is replaced: a message the owner wrote is left alone.
update public.payment_settings
   set online_payment_disabled_message = 'Online payment is temporarily unavailable. Please choose Cash on Counter Pickup.'
 where id = 'default'
   and online_payment_disabled_message = 'Online payment is temporarily unavailable. Please choose Cash on Delivery or Cash on Counter Pickup.';

-- 2. What an order has to pay -------------------------------------------------------

create or replace function public._cod_downpayment_amount(p_total numeric)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.business_settings;
  v numeric;
begin
  if coalesce(p_total, 0) <= 0 or not public.online_payment_enabled() then return null; end if;
  select * into s from public.business_settings where id = 'default';
  if not found or s.cod_downpayment_type is null or s.cod_downpayment_value is null
     or s.cod_downpayment_expiry_minutes is null or s.cod_downpayment_pickup_days is null then
    return null;
  end if;
  if s.cod_downpayment_min_order is not null and p_total < s.cod_downpayment_min_order then return null; end if;
  v := case s.cod_downpayment_type
         when 'percent' then round(p_total * s.cod_downpayment_value / 100, 2)
         else least(s.cod_downpayment_value, p_total)
       end;
  return case when v > 0 then v end;
end;
$$;


create or replace function public.cod_downpayment_quote(p_total numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v numeric := public._cod_downpayment_amount(p_total);
  s public.business_settings;
begin
  if v is null then
    return jsonb_build_object('required', false, 'amount', 0, 'balance', coalesce(p_total, 0),
                              'expiry_minutes', null, 'percent', null, 'pickup_days', null);
  end if;
  select * into s from public.business_settings where id = 'default';
  return jsonb_build_object('required', true, 'amount', v, 'balance', p_total - v,
    'expiry_minutes', s.cod_downpayment_expiry_minutes,
    'percent', case when s.cod_downpayment_type = 'percent' then s.cod_downpayment_value end,
    'pickup_days', s.cod_downpayment_pickup_days);
end;
$$;


create or replace function public.get_business_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  s public.business_settings;
  l public.loyalty_cart_settings;
begin
  v_staff := public._require_staff();
  select * into s from public.business_settings where id = 'default';
  select * into l from public.loyalty_cart_settings where id = 'default';
  return jsonb_build_object(
    'restock_threshold_default', s.restock_threshold_default,
    'stock_low_ratio', s.stock_low_ratio,
    'stock_plenty_ratio', s.stock_plenty_ratio,
    'sales_low_ratio', s.sales_low_ratio,
    'sales_high_ratio', s.sales_high_ratio,
    'default_daily_sales_target', s.default_daily_sales_target,
    'healthy_margin_percent', s.healthy_margin_percent,
    'expiry_alert_days', s.expiry_alert_days,
    'low_stock_badge_qty', s.low_stock_badge_qty,
    'cod_downpayment_type', s.cod_downpayment_type,
    'cod_downpayment_value', s.cod_downpayment_value,
    'cod_downpayment_min_order', s.cod_downpayment_min_order,
    'cod_downpayment_expiry_minutes', s.cod_downpayment_expiry_minutes,
    'cod_downpayment_pickup_days', s.cod_downpayment_pickup_days,
    'carried_over', coalesce(s.carried_over, false),
    'updated_at', s.updated_at,
    'loyalty', jsonb_build_object('earn_pesos_per_point', l.earn_pesos_per_point,
                                  'points_per_peso', l.points_per_peso,
                                  'max_discount_percent', l.max_discount_percent),
    'online_payment_enabled', public.online_payment_enabled(),
    'online_payment_disabled_message', public.online_payment_disabled_message(),
    'branches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', b.id, 'name', b.name, 'address', b.address, 'contact_phone', b.contact_phone,
               'operating_hours', b.operating_hours, 'is_active', b.is_active,
               'supports_delivery', b.supports_delivery, 'supports_pickup', b.supports_pickup,
               'delivery_fee', b.delivery_fee, 'daily_sales_target', b.daily_sales_target,
               'latitude', to_jsonb(b) -> 'latitude', 'longitude', to_jsonb(b) -> 'longitude',
               'is_warehouse', coalesce((to_jsonb(b) ->> 'is_warehouse')::boolean, false))
             order by b.name)
      from public.branches b
      where v_staff.role = 'owner' or b.id = v_staff.branch_id), '[]'::jsonb)
  );
end;
$$;

create or replace function public.owner_update_business_settings(p_settings jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
  v_old public.business_settings;
  v_new public.business_settings;
  k text;
  allowed text[] := array['restock_threshold_default', 'stock_low_ratio', 'stock_plenty_ratio', 'sales_low_ratio',
                          'sales_high_ratio', 'default_daily_sales_target', 'healthy_margin_percent', 'expiry_alert_days',
                          'low_stock_badge_qty', 'cod_downpayment_type', 'cod_downpayment_value',
                          'cod_downpayment_min_order', 'cod_downpayment_expiry_minutes', 'cod_downpayment_pickup_days'];
begin
  v_owner := public._require_owner();
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then
    raise exception 'Settings must be an object.';
  end if;
  for k in select jsonb_object_keys(p_settings) loop
    if not (k = any(allowed)) then raise exception 'Unknown setting: %', k; end if;
    if k = 'cod_downpayment_type' then
      if jsonb_typeof(p_settings -> k) not in ('string', 'null') then raise exception 'Setting % must be text or empty.', k; end if;
    elsif jsonb_typeof(p_settings -> k) not in ('number', 'null') then
      raise exception 'Setting % must be a number or empty.', k;
    end if;
  end loop;

  insert into public.business_settings (id) values ('default') on conflict (id) do nothing;
  select * into v_old from public.business_settings where id = 'default' for update;
  v_new := v_old;
  if p_settings ? 'restock_threshold_default' then
    v_new.restock_threshold_default := (p_settings ->> 'restock_threshold_default')::numeric::int; end if;
  if p_settings ? 'stock_low_ratio' then v_new.stock_low_ratio := (p_settings ->> 'stock_low_ratio')::numeric; end if;
  if p_settings ? 'stock_plenty_ratio' then v_new.stock_plenty_ratio := (p_settings ->> 'stock_plenty_ratio')::numeric; end if;
  if p_settings ? 'sales_low_ratio' then v_new.sales_low_ratio := (p_settings ->> 'sales_low_ratio')::numeric; end if;
  if p_settings ? 'sales_high_ratio' then v_new.sales_high_ratio := (p_settings ->> 'sales_high_ratio')::numeric; end if;
  if p_settings ? 'default_daily_sales_target' then
    v_new.default_daily_sales_target := (p_settings ->> 'default_daily_sales_target')::numeric; end if;
  if p_settings ? 'healthy_margin_percent' then
    v_new.healthy_margin_percent := (p_settings ->> 'healthy_margin_percent')::numeric; end if;
  if p_settings ? 'expiry_alert_days' then
    v_new.expiry_alert_days := (p_settings ->> 'expiry_alert_days')::numeric::int; end if;
  if p_settings ? 'low_stock_badge_qty' then
    v_new.low_stock_badge_qty := (p_settings ->> 'low_stock_badge_qty')::numeric::int; end if;
  if p_settings ? 'cod_downpayment_type' then
    v_new.cod_downpayment_type := nullif(trim(p_settings ->> 'cod_downpayment_type'), ''); end if;
  if p_settings ? 'cod_downpayment_value' then
    v_new.cod_downpayment_value := (p_settings ->> 'cod_downpayment_value')::numeric; end if;
  if p_settings ? 'cod_downpayment_min_order' then
    v_new.cod_downpayment_min_order := (p_settings ->> 'cod_downpayment_min_order')::numeric; end if;
  if p_settings ? 'cod_downpayment_expiry_minutes' then
    v_new.cod_downpayment_expiry_minutes := (p_settings ->> 'cod_downpayment_expiry_minutes')::numeric::int; end if;
  if p_settings ? 'cod_downpayment_pickup_days' then
    v_new.cod_downpayment_pickup_days := (p_settings ->> 'cod_downpayment_pickup_days')::numeric::int; end if;
  if (v_new.cod_downpayment_type is null) <> (v_new.cod_downpayment_value is null)
     or (v_new.cod_downpayment_type is not null
         and (v_new.cod_downpayment_expiry_minutes is null or v_new.cod_downpayment_pickup_days is null)) then
    raise exception 'To require a downpayment, enter its type, its amount, the time limit and the pickup days together.';
  end if;

  begin
    update public.business_settings set
      restock_threshold_default = v_new.restock_threshold_default,
      stock_low_ratio = v_new.stock_low_ratio,
      stock_plenty_ratio = v_new.stock_plenty_ratio,
      sales_low_ratio = v_new.sales_low_ratio,
      sales_high_ratio = v_new.sales_high_ratio,
      default_daily_sales_target = v_new.default_daily_sales_target,
      healthy_margin_percent = v_new.healthy_margin_percent,
      expiry_alert_days = v_new.expiry_alert_days,
      low_stock_badge_qty = v_new.low_stock_badge_qty,
      cod_downpayment_type = v_new.cod_downpayment_type,
      cod_downpayment_value = v_new.cod_downpayment_value,
      cod_downpayment_min_order = v_new.cod_downpayment_min_order,
      cod_downpayment_expiry_minutes = v_new.cod_downpayment_expiry_minutes,
      cod_downpayment_pickup_days = v_new.cod_downpayment_pickup_days,
      carried_over = false,
      updated_at = now(),
      updated_by = v_owner.firebase_uid
    where id = 'default';
  exception when check_violation then
    raise exception 'A setting is out of range (ratios: low must be below plenty / high; margin 1-99%%; threshold 0-100,000; targets above 0; expiry alerts 1-365 days; "only N left" 1-1,000; downpayment above 0, a percent below 100, time limit 5-1,440 minutes; pickup 1-30 days).';
  end;

  perform public._write_audit(v_owner.firebase_uid, null, 'business.settings_updated', 'business_settings', 'default',
    jsonb_build_object('before', to_jsonb(v_old) - 'updated_at' - 'updated_by',
                       'after', p_settings));
  return public.get_business_settings();
end;
$$;


-- 3. Placing an order ---------------------------------------------------------------

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
  v_downpayment numeric;
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

  if p_payment_method = 'Cash on Counter Pickup' then
    v_downpayment := public._cod_downpayment_amount(v_total);
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
  select v_uid, v_cart.branch_id, b.name, p_is_delivery, p_delivery_address_id,
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
  if v_downpayment is not null then
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


-- 4. Messages -----------------------------------------------------------------------

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

    perform public.notify_customer(p_order.firebase_uid, 'payment', 'Downpayment received',
      'We received ₱' || to_char(p_dp.amount, 'FM999,999,990.00') || ' for order ' || p_order.id
        || '. The rest is paid in cash when you pick it up.');
    begin
      perform public._notify_staff(p_order.branch_id, 'order', 'New pickup order ' || p_order.id,
        'Total ₱' || to_char(p_order.total, 'FM999,999,990.00') || ' • Downpayment paid ₱'
          || to_char(p_dp.amount, 'FM999,999,990.00') || ' • Collect ₱'
          || to_char(p_order.total - p_dp.amount, 'FM999,999,990.00') || ' in cash',
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

create or replace function public.notify_on_order_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_branch text;
  v_title text;
  v_body text;
begin
  begin
    select name into v_branch from public.branches where id = new.branch_id;
    if tg_op = 'INSERT' then
      v_title := 'Order placed';
      v_body := 'Your order ' || new.id || ' has been received.';
    elsif new.status is distinct from old.status then
      case new.status
        when 'confirmed' then
          v_title := 'Order ' || new.id || ' confirmed';
          v_body := 'The shop has accepted your order.';
        when 'preparing' then
          v_title := 'Order ' || new.id || ' is being prepared';
          v_body := 'Your items are being packed.';
        when 'readyForPickup' then
          v_title := 'Order ' || new.id || ' is ready for pickup';
          v_body := 'You can pick it up now' || coalesce(' at ' || v_branch, '') || '.'
            || coalesce((select ' Please pick it up within ' || d.pickup_days
                                || case when d.pickup_days = 1 then ' day' else ' days' end
                                || ', or your downpayment will not be refunded.'
                         from public.order_downpayments d
                         where d.order_id = new.id and d.status = 'success' and d.pickup_days is not null), '');
        when 'outForDelivery' then
          v_title := 'Order ' || new.id || ' is out for delivery';
          v_body := 'Your order has left' || coalesce(' ' || v_branch, ' the shop') || '.';
        when 'completed' then
          v_title := 'Order ' || new.id || ' completed';
          v_body := 'Thank you for your order.';
        when 'cancelled' then
          v_title := 'Order ' || new.id || ' cancelled';
          v_body := 'This order was cancelled.';
        else
          v_title := 'Order ' || new.id || ' updated';
          v_body := 'Status changed to ' || new.status || '.';
      end case;
    end if;
    if v_title is not null then
      perform public.notify_customer(new.firebase_uid, 'order', v_title, v_body);
    end if;
  exception when others then
    raise warning 'order notification for % failed: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;


-- 5. Not picked up in time ----------------------------------------------------------

create or replace function public._trg_cod_downpayment_on_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dp public.order_downpayments;
begin
  select * into v_dp from public.order_downpayments where order_id = new.id for update;
  if not found then return new; end if;
  if v_dp.status = 'success' then
    if coalesce(current_setting('app.cod_downpayment_forfeit', true), '') = 'on' then
      update public.order_downpayments set status = 'forfeited', forfeited_at = now() where order_id = new.id;
    else
      perform public._cod_downpayment_open_refund(new, v_dp.amount, 'Order cancelled after the downpayment was paid');
    end if;
  elsif v_dp.status in ('pending', 'processing', 'failed') then
    update public.order_downpayments
    set status = 'expired', gateway_checkout_url = null, gateway_checkout_created_at = null, checkout_started_at = null
    where order_id = new.id;
  end if;
  return new;
end;
$$;


-- Staff who already took the balance handle that order themselves, so it is skipped.
create or replace function public.forfeit_unclaimed_cod_downpayments()
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
    select o.id, o.firebase_uid, o.branch_id, d.amount
    from public.orders o
    join public.order_downpayments d on d.order_id = o.id
    where o.status = 'readyForPickup'
      and d.status = 'success'
      and d.pickup_days is not null
      and exists (select 1 from public.payments p
                  where p.order_id = o.id and p.status in ('pending', 'processing'))
      and (select max(e.created_at) from public.order_status_events e
           where e.order_id = o.id and e.status = 'readyForPickup')
          <= now() - make_interval(days => d.pickup_days)
    order by o.id
    limit 200
    for update of o skip locked
  loop
    perform set_config('app.cod_downpayment_forfeit', 'on', true);
    update public.orders set status = 'cancelled' where id = r.id;
    perform set_config('app.cod_downpayment_forfeit', 'off', true);
    perform public.notify_customer(r.firebase_uid, 'order', 'Order not picked up',
      'Order ' || r.id || ' was cancelled because it was not picked up in time. The ₱'
        || to_char(r.amount, 'FM999,999,990.00') || ' downpayment is non-refundable.');
    begin
      perform public._notify_staff(r.branch_id, 'order', 'Order not picked up: ' || r.id,
        'Cancelled automatically. Stock was returned and the ₱'
          || to_char(r.amount, 'FM999,999,990.00') || ' downpayment was kept.', r.id);
    exception when others then
      raise warning 'staff notification for % failed: %', r.id, sqlerrm;
    end;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public.forfeit_unclaimed_cod_downpayments() from public, anon, authenticated;
grant execute on function public.forfeit_unclaimed_cod_downpayments() to service_role;

-- The job already scheduled every minute does both.

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
    select o.id, o.firebase_uid
    from public.orders o
    join public.order_downpayments d on d.order_id = o.id
    where o.status = 'awaitingDownpayment' and d.expires_at <= now()
    order by d.expires_at
    limit 200
    for update of o skip locked
  loop
    update public.orders set status = 'cancelled' where id = r.id;
    perform public.notify_customer(r.firebase_uid, 'order', 'Order cancelled',
      'Order ' || r.id || ' was cancelled because its downpayment was not paid in time.');
    n := n + 1;
  end loop;
  return n + public.forfeit_unclaimed_cod_downpayments();
end;
$$;


-- 6. Reports: kept downpayments, apart from sales ------------------------------------

create or replace function public.sales_overview(
  p_from date default null,
  p_to date default null,
  p_branch_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_from date := coalesce(p_from, (now() at time zone 'Asia/Manila')::date);
  v_to date := coalesce(p_to, (now() at time zone 'Asia/Manila')::date);
  v_start timestamptz;
  v_end timestamptz;
  v_branches uuid[];
  v_detail boolean;
begin
  v_staff := public._require_staff(p_branch_id);
  if v_to < v_from then raise exception 'The end date is before the start date.'; end if;
  if v_to - v_from > 400 then raise exception 'Date range is too long (maximum 400 days).'; end if;
  if p_branch_id is not null and not exists (select 1 from public.branches where id = p_branch_id) then
    raise exception 'That branch could not be found.';
  end if;
  if v_staff.role = 'owner' then
    v_branches := case when p_branch_id is null then null else array[p_branch_id] end;
  else
    if v_staff.branch_id is null then raise exception 'Please choose a branch first.'; end if;
    v_branches := array[v_staff.branch_id];
  end if;
  v_detail := v_staff.role = 'owner' or 'view_reports' = any (public.staff_permission_keys());
  v_start := v_from::timestamp at time zone 'Asia/Manila';
  v_end := (v_to + 1)::timestamp at time zone 'Asia/Manila';

  return (
    with f as materialized (select * from public._sales_facts(v_start, v_end, v_branches)),
    l as materialized (select * from public._sales_line_facts(v_start, v_end, v_branches)),
    pr as materialized (select * from public._pending_refund_facts(v_branches)),
    scope_branches as (
      select b.id, b.name from public.branches b
      where v_branches is null or b.id = any (v_branches)
    ),
    agg_branch as (
      select f.branch_id,
             count(*) filter (where kind = 'sale') as n, sum(gross) as g, sum(discount) as d,
             sum(refund) as r, count(*) filter (where kind = 'refund') as rn, sum(delivery_fee) as fee,
             count(*) filter (where is_void) as voids
      from f group by f.branch_id
    ),
    pend_branch as (
      select pr.branch_id, count(*) as n, sum(amount) as amount from pr group by pr.branch_id
    )
    select jsonb_build_object(
      'from', v_from, 'to', v_to, 'branch_id', case when v_branches is null then null else v_branches[1] end,
      'generated_at', now(),
      'definitions', jsonb_build_object(
        'gross_sales', 'Subtotal of orders with a successful payment (before discounts, without delivery fee), by order date',
        'refunds', 'Completed refunds (the refunded amount, partial refunds included), by the day they completed',
        'net_sales', 'Gross sales - discounts - refunds',
        'refund_rate', 'Refunds / (gross sales - discounts)',
        'pending_refunds', 'Refunds requested, approved or processing right now; not deducted until completed'),
      'summary', (
        select public._sales_money_json(count(*) filter (where kind = 'sale'), sum(gross), sum(discount),
                                        sum(refund), count(*) filter (where kind = 'refund'), sum(delivery_fee))
               || jsonb_build_object('voids', count(*) filter (where is_void),
                                     'pos_orders', count(*) filter (where kind = 'sale' and is_pos),
                                     'online_orders', count(*) filter (where kind = 'sale' and not is_pos))
               || (select jsonb_build_object('units', coalesce(sum(units), 0), 'refunded_units', coalesce(sum(refunded_units), 0),
                                             'net_units', coalesce(sum(units), 0) - coalesce(sum(refunded_units), 0)) from l)
        from f),
      'pending_refunds', (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0)) from pr),
      'by_day', (
        select coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'units', coalesce(u.units, 0),
                                                     'refunded_units', coalesce(u.refunded_units, 0),
                                                     'net_units', coalesce(u.units, 0) - coalesce(u.refunded_units, 0))
                 || public._sales_money_json(s.n, s.g, s.d, s.r, s.rn, s.fee) order by d.day), '[]'::jsonb)
        from (select (v_from + g)::date as day from generate_series(0, v_to - v_from) g) d
        left join (
          select event_date, count(*) filter (where kind = 'sale') as n, sum(gross) as g, sum(discount) as d,
                 sum(refund) as r, count(*) filter (where kind = 'refund') as rn, sum(delivery_fee) as fee
          from f group by event_date) s on s.event_date = d.day
        left join (select event_date, sum(units)::int as units, sum(refunded_units)::int as refunded_units
                   from l group by event_date) u on u.event_date = d.day),
      'by_channel', (
        select coalesce(jsonb_agg(jsonb_build_object('channel', c.channel)
                 || public._sales_money_json(c.n, c.g, c.d, c.r, c.rn, c.fee) order by c.channel), '[]'::jsonb)
        from (
          select case when is_pos then 'pos' when is_delivery then 'delivery' else 'pickup' end as channel,
                 count(*) filter (where kind = 'sale') as n, sum(gross) as g, sum(discount) as d,
                 sum(refund) as r, count(*) filter (where kind = 'refund') as rn, sum(delivery_fee) as fee
          from f group by 1) c),
      'by_branch', (
        select coalesce(jsonb_agg(jsonb_build_object('branch_id', coalesce(sb.id, a.branch_id), 'branch', sb.name)
                 || public._sales_money_json(a.n, a.g, a.d, a.r, a.rn, a.fee)
                 || jsonb_build_object('voids', coalesce(a.voids, 0),
                                       'pending_refund_count', coalesce(pb.n, 0),
                                       'pending_refund_amount', coalesce(pb.amount, 0))
                 order by sb.name nulls last), '[]'::jsonb)
        from scope_branches sb
        full join agg_branch a on a.branch_id = sb.id
        left join pend_branch pb on pb.branch_id = coalesce(sb.id, a.branch_id)),
      'kept_downpayments', (
        select jsonb_build_object('count', count(*), 'amount', coalesce(sum(d.amount), 0))
        from public.order_downpayments d join public.orders o on o.id = d.order_id
        where d.status = 'forfeited' and d.forfeited_at >= v_start and d.forfeited_at < v_end
          and (v_branches is null or o.branch_id = any (v_branches))),
      'by_method', (
        select coalesce(jsonb_agg(jsonb_build_object('method', m.payment_method, 'amount_paid', m.paid)
                 || public._sales_money_json(m.n, m.g, m.d, m.r, m.rn, m.fee) order by m.g desc nulls last), '[]'::jsonb)
        from (
          select f.payment_method, count(*) filter (where kind = 'sale') as n, sum(gross) as g,
                 sum(discount) as d, sum(refund) as r, count(*) filter (where kind = 'refund') as rn,
                 sum(delivery_fee) as fee, coalesce(sum(gross - discount + delivery_fee) filter (where kind = 'sale'), 0) + coalesce(sum(paid_adjust), 0) as paid
          from f group by f.payment_method) m),
      'by_staff', case when v_detail then (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'staff_uid', s.staff_uid,
                 'staff_name', case when s.staff_uid is null then null else coalesce(nullif(sm.full_name, ''), s.staff_uid) end,
                 'channel', case when s.staff_uid is null then 'online' else 'pos' end)
                 || public._sales_money_json(s.n, s.g, s.d, s.r, s.rn, s.fee)
                 || jsonb_build_object('voids', s.voids)
                 order by (s.staff_uid is null), sm.full_name), '[]'::jsonb)
        from (
          select f.staff_uid, count(*) filter (where kind = 'sale') as n, sum(gross) as g, sum(discount) as d,
                 sum(refund) as r, count(*) filter (where kind = 'refund') as rn, sum(delivery_fee) as fee,
                 count(*) filter (where is_void) as voids
          from f group by f.staff_uid) s
        left join public.staff_members sm on sm.firebase_uid = s.staff_uid) end,
      -- Products: every staff member of the branch (the website's Overview shows top sellers).
      'by_product', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'product', p.product_name, 'variant', p.variant_label, 'variant_id', p.variant_id,
                 'units', p.units, 'refunded_units', p.refunded_units, 'net_units', p.units - p.refunded_units)
                 || public._sales_money_json(p.n, p.g, p.d, p.r, p.rn, 0)
                 order by round(p.g, 2) - round(p.d, 2) - round(p.r, 2) desc, p.product_name nulls last), '[]'::jsonb)
        from (
          select l.product_name, l.variant_label, (array_agg(l.variant_id) filter (where l.variant_id is not null))[1] as variant_id,
                 sum(l.units)::int as units, sum(l.refunded_units)::int as refunded_units,
                 count(distinct l.order_id) filter (where l.kind = 'sale') as n,
                 sum(l.gross) as g, sum(l.discount) as d, sum(l.refund) as r,
                 count(distinct l.refund_id) as rn
          from l
          group by l.product_name, l.variant_label) p)
    )
  );
end;
$$;

create or replace function public.analytics_report(
  p_from date,
  p_to date,
  p_branch_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_from date := coalesce(p_from, (now() at time zone 'Asia/Manila')::date - 29);
  v_to date := coalesce(p_to, (now() at time zone 'Asia/Manila')::date);
  v_start timestamptz;
  v_end timestamptz;
  v_branches uuid[];
  v_summary jsonb;
begin
  v_staff := public._require_reports(p_branch_id);
  if v_to < v_from then raise exception 'The end date is before the start date.'; end if;
  if v_to - v_from > 400 then raise exception 'Date range is too long (maximum 400 days).'; end if;
  v_start := v_from::timestamp at time zone 'Asia/Manila';
  v_end := (v_to + 1)::timestamp at time zone 'Asia/Manila';
  v_branches := case when p_branch_id is null then null else array[p_branch_id] end;

  create temp table if not exists _ar_facts on commit drop as
    select * from public._sales_facts(null, null, null) limit 0;
  truncate _ar_facts;
  insert into _ar_facts select * from public._sales_facts(v_start, v_end, v_branches);

  create temp table if not exists _ar_lines on commit drop as
    select * from public._sales_line_facts(null, null, null) limit 0;
  truncate _ar_lines;
  insert into _ar_lines select * from public._sales_line_facts(v_start, v_end, v_branches);

  select public._sales_money_json(count(*) filter (where kind = 'sale'), sum(gross), sum(discount),
                                  sum(refund), count(*) filter (where kind = 'refund'), sum(delivery_fee))
         || jsonb_build_object(
              'verified_orders', count(*) filter (where kind = 'sale'),
              'pos_orders', count(*) filter (where kind = 'sale' and is_pos),
              'online_orders', count(*) filter (where kind = 'sale' and not is_pos),
              'voids', count(*) filter (where is_void))
    into v_summary
  from _ar_facts;

  v_summary := v_summary || jsonb_build_object(
    'pending_refunds', (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0))
                        from public._pending_refund_facts(v_branches)),
    'kept_downpayments', (
      select jsonb_build_object('count', count(*), 'amount', coalesce(sum(d.amount), 0))
      from public.order_downpayments d join public.orders o on o.id = d.order_id
      where d.status = 'forfeited' and d.forfeited_at >= v_start and d.forfeited_at < v_end
        and (v_branches is null or o.branch_id = any (v_branches))),
    'pending_payments', (
      select jsonb_build_object('count', count(*), 'amount', coalesce(sum(o.total), 0))
      from public.orders o join public.payments p on p.order_id = o.id
      where p.status in ('pending', 'processing') and o.status not in ('cancelled', 'awaitingDownpayment')
        and o.created_at >= v_start and o.created_at < v_end
        and (p_branch_id is null or o.branch_id = p_branch_id)),
    'cancelled_orders', (
      select count(*) from public.orders o
      where o.status = 'cancelled' and o.created_at >= v_start and o.created_at < v_end
        and (p_branch_id is null or o.branch_id = p_branch_id)),
    'completed_deliveries', (
      select count(*) from public.delivery_stops ds join public.deliveries d on d.id = ds.delivery_id
      join public.orders o on o.id = ds.order_id
      where ds.status = 'delivered' and o.status = 'completed'
        and coalesce(ds.delivered_at, ds.updated_at) >= v_start and coalesce(ds.delivered_at, ds.updated_at) < v_end
        and (p_branch_id is null or d.branch_id = p_branch_id)),
    'failed_deliveries', (
      select count(*) from public.delivery_stops ds join public.deliveries d on d.id = ds.delivery_id
      where ds.status = 'failed' and ds.failed_at >= v_start and ds.failed_at < v_end
        and (p_branch_id is null or d.branch_id = p_branch_id)));

  return jsonb_build_object(
    'from', v_from, 'to', v_to, 'branch_id', p_branch_id,
    'definitions', jsonb_build_object(
      'gross_sales', 'Subtotal of orders with a verified payment (before discounts, without delivery fee), by order date',
      'refunds', 'Completed refunds (partial refunds included), by completion date',
      'net_sales', 'Gross sales - discounts - refunds',
      'refund_rate', 'Refunds / (gross sales - discounts)',
      'revenue', 'Net sales + delivery fees',
      'pending_refunds', 'Refunds requested / approved / processing right now (not deducted)',
      'kept_downpayments', 'Downpayments kept because the order was not picked up in time (not counted as sales)',
      'pending_payments', 'Orders not cancelled whose payment is not verified yet (not counted as sales)',
      'units', 'Units sold on verified orders minus units refunded (completed refunds, by completion date)'),
    'summary', v_summary,

    'by_day', (
      select coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'units', coalesce(u.units, 0),
                                                   'refunded_units', coalesce(u.refunded_units, 0),
                                                   'net_units', coalesce(u.units, 0) - coalesce(u.refunded_units, 0))
               || public._sales_money_json(s.n, s.g, s.d, s.r, s.rn, s.fee) order by d.day), '[]'::jsonb)
      from (select (v_from + g)::date as day from generate_series(0, v_to - v_from) g) d
      left join (select event_date, count(*) filter (where kind = 'sale') n, sum(gross) g, sum(discount) d,
                        sum(refund) r, count(*) filter (where kind = 'refund') rn, sum(delivery_fee) fee
                 from _ar_facts group by event_date) s on s.event_date = d.day
      left join (select event_date, sum(units)::int as units, sum(refunded_units)::int as refunded_units
                 from _ar_lines group by event_date) u on u.event_date = d.day),

    'by_branch', (
      select coalesce(jsonb_agg(jsonb_build_object('branch_id', coalesce(b.id, s.branch_id), 'branch', b.name)
               || public._sales_money_json(s.n, s.g, s.d, s.r, s.rn, s.fee)
               || jsonb_build_object('pending_refund_count', coalesce(pd.n, 0), 'pending_refund_amount', coalesce(pd.amount, 0))
               order by b.name nulls last), '[]'::jsonb)
      from (select * from public.branches where p_branch_id is null or id = p_branch_id) b
      full join (select branch_id, count(*) filter (where kind = 'sale') n, sum(gross) g, sum(discount) d,
                        sum(refund) r, count(*) filter (where kind = 'refund') rn, sum(delivery_fee) fee
                 from _ar_facts group by branch_id) s on s.branch_id = b.id
      left join (select branch_id, count(*) n, sum(amount) amount from public._pending_refund_facts(v_branches)
                 group by branch_id) pd on pd.branch_id = coalesce(b.id, s.branch_id)),

    'by_payment_method', (
      select coalesce(jsonb_agg(jsonb_build_object('method', payment_method, 'orders', n, 'amount', coalesce(paid, 0))
               || public._sales_money_json(n, g, d, r, rn, fee) order by g desc nulls last), '[]'::jsonb)
      from (select payment_method, count(*) filter (where kind = 'sale') n, sum(gross) g, sum(discount) d,
                   sum(refund) r, count(*) filter (where kind = 'refund') rn, sum(delivery_fee) fee,
                   coalesce(sum(gross - discount + delivery_fee) filter (where kind = 'sale'), 0) + coalesce(sum(paid_adjust), 0) paid
            from _ar_facts group by payment_method) t),

    'by_category', (
      select coalesce(jsonb_agg(jsonb_build_object('category', category, 'units', units - refunded_units,
                                                   'gross_units', units, 'refunded_units', refunded_units)
               || public._sales_money_json(n, g, d, r, rn, 0) order by g desc), '[]'::jsonb)
      from (
        select coalesce(pc.label, 'Uncategorised') as category, sum(l.units)::int as units,
               sum(l.refunded_units)::int as refunded_units, count(distinct l.order_id) filter (where l.kind = 'sale') n,
               sum(l.gross) g, sum(l.discount) d, sum(l.refund) r, count(distinct l.refund_id) rn
        from _ar_lines l
        left join public.products p on p.id = l.product_id
        left join public.product_categories pc on pc.id = p.category_id
        group by 1) t),

    'by_product', (
      select coalesce(jsonb_agg(jsonb_build_object('product', product_name, 'variant', variant_label, 'variant_id', variant_id,
                                                   'units', units - refunded_units, 'gross_units', units,
                                                   'refunded_units', refunded_units)
               || public._sales_money_json(n, g, d, r, rn, 0)
               order by round(g, 2) - round(d, 2) - round(r, 2) desc, product_name nulls last), '[]'::jsonb)
      from (
        select l.product_name, l.variant_label, (array_agg(l.variant_id) filter (where l.variant_id is not null))[1] as variant_id,
               sum(l.units)::int as units, sum(l.refunded_units)::int as refunded_units,
               count(distinct l.order_id) filter (where l.kind = 'sale') n,
               sum(l.gross) g, sum(l.discount) d, sum(l.refund) r, count(distinct l.refund_id) rn
        from _ar_lines l group by l.product_name, l.variant_label) t),

    'top_products', (
      select coalesce(jsonb_agg(jsonb_build_object('product', product_name, 'variant', variant_label, 'variant_id', variant_id,
                                                   'units', units - refunded_units, 'gross_units', units,
                                                   'refunded_units', refunded_units,
                                                   'gross_sales', round(g, 2), 'refunds', round(r, 2),
                                                   'net_sales', round(g, 2) - round(d, 2) - round(r, 2))
               order by round(g, 2) - round(d, 2) - round(r, 2) desc), '[]'::jsonb)
      from (
        select l.product_name, l.variant_label, (array_agg(l.variant_id) filter (where l.variant_id is not null))[1] as variant_id,
               sum(l.units)::int as units, sum(l.refunded_units)::int as refunded_units,
               sum(l.gross) g, sum(l.discount) d, sum(l.refund) r
        from _ar_lines l where l.product_name is not null
        group by l.product_name, l.variant_label
        order by round(sum(l.gross), 2) - round(sum(l.discount), 2) - round(sum(l.refund), 2) desc
        limit 15) t),

    'by_staff', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'staff_uid', s.staff_uid,
               'staff_name', case when s.staff_uid is null then null else coalesce(nullif(sm.full_name, ''), s.staff_uid) end,
               'channel', case when s.staff_uid is null then 'online' else 'pos' end)
               || public._sales_money_json(s.n, s.g, s.d, s.r, s.rn, s.fee) || jsonb_build_object('voids', s.voids)
               order by (s.staff_uid is null), sm.full_name), '[]'::jsonb)
      from (select staff_uid, count(*) filter (where kind = 'sale') n, sum(gross) g, sum(discount) d,
                   sum(refund) r, count(*) filter (where kind = 'refund') rn, sum(delivery_fee) fee,
                   count(*) filter (where is_void) voids
            from _ar_facts group by staff_uid) s
      left join public.staff_members sm on sm.firebase_uid = s.staff_uid),

    -- Active products that are in stock but sold least (net of refunds, including zero).
    'slow_movers', (
      select coalesce(jsonb_agg(jsonb_build_object('product', product, 'variant', variant, 'variant_id', variant_id,
                                                   'in_stock', stock, 'units_sold', units) order by units, stock desc), '[]'::jsonb)
      from (
        select p.name as product, pv.label as variant, pv.id as variant_id, sum(bi.quantity)::int as stock,
               coalesce((select sum(l.units - l.refunded_units) from _ar_lines l where l.variant_id = pv.id), 0)::int as units
        from public.product_variants pv
        join public.products p on p.id = pv.product_id and p.is_active
        join public.branch_inventory bi on bi.variant_id = pv.id and (p_branch_id is null or bi.branch_id = p_branch_id)
        group by p.name, pv.label, pv.id
        having sum(bi.quantity) > 0
        order by units, stock desc limit 15) t),

    'customers', (
      select jsonb_build_object(
        'new_customers', (select count(*) from public.customer_profiles c
                          where c.firebase_uid <> 'walk-in' and c.created_at >= v_start and c.created_at < v_end),
        'active_customers', count(distinct firebase_uid),
        'repeat_customers', count(*) filter (where n >= 2),
        'repeat_rate', case when count(*) > 0 then round(count(*) filter (where n >= 2)::numeric / count(*), 4) end)
      from (select o.firebase_uid, count(*) n from _ar_facts f join public.orders o on o.id = f.order_id
            where f.kind = 'sale' and o.firebase_uid <> 'walk-in' group by o.firebase_uid) t),

    -- Points reversed by refunds are shown apart from points customers redeemed.
    'loyalty', (
      select jsonb_build_object(
        'points_earned', coalesce(sum(points) filter (where points > 0 and coalesce(source, 'order_earn') <> 'admin_adjust'), 0),
        'points_redeemed', coalesce(-sum(points) filter (where points < 0 and coalesce(source, 'order_redeem') = 'order_redeem'), 0),
        'points_reversed', coalesce(-sum(points) filter (where source = 'order_clawback'), 0),
        'points_adjusted', coalesce(sum(points) filter (where source = 'admin_adjust'), 0),
        'members_active', count(distinct firebase_uid))
      from public.loyalty_transactions lt
      where lt.created_at >= v_start and lt.created_at < v_end
        and (p_branch_id is null or exists (select 1 from public.orders o where o.id = lt.order_id and o.branch_id = p_branch_id))),

    'drivers', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'driver_uid', t.driver_uid, 'driver', t.full_name, 'runs', t.runs, 'delivered', t.delivered,
               'failed', t.failed,
               'success_rate', case when t.delivered + t.failed > 0 then round(t.delivered::numeric / (t.delivered + t.failed), 4) end,
               'avg_minutes_pickup_to_delivered', t.avg_minutes) order by t.delivered desc), '[]'::jsonb)
      from (
        select dr.firebase_uid as driver_uid, dr.full_name,
               count(distinct d.id) as runs,
               count(*) filter (where ds.status = 'delivered') as delivered,
               count(*) filter (where ds.status = 'failed') as failed,
               round(avg(extract(epoch from ds.delivered_at - d.picked_up_at) / 60)
                       filter (where ds.status = 'delivered' and d.picked_up_at is not null)::numeric, 1) as avg_minutes
        from public.drivers dr
        join public.deliveries d on d.driver_uid = dr.firebase_uid
        join public.delivery_stops ds on ds.delivery_id = d.id
        where d.created_at >= v_start and d.created_at < v_end
          and (p_branch_id is null or d.branch_id = p_branch_id)
        group by dr.firebase_uid, dr.full_name) t),

    'inventory', (
      select jsonb_build_object(
        'units_on_hand', coalesce(sum(bi.quantity), 0),
        'stock_value_at_cost', sum(bi.quantity * c.cost_price),
        'variants_without_cost', count(*) filter (where c.cost_price is null and bi.quantity > 0),
        'out_of_stock', count(*) filter (where bi.quantity = 0),
        'low_stock', count(*) filter (where bi.quantity > 0 and bi.quantity <= coalesce(st.restock_threshold, public._default_restock_threshold())))
      from public.branch_inventory bi
      join public.products p on p.id = bi.product_id and p.is_active
      left join public.product_variant_costs c on c.variant_id = bi.variant_id
      left join public.stock_thresholds st on st.branch_id = bi.branch_id and st.variant_id = bi.variant_id
      where bi.is_carried and (p_branch_id is null or bi.branch_id = p_branch_id))
  );
end;
$$;


commit;
