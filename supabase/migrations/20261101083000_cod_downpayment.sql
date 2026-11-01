-- =============================================================================
-- Melai Nuts — Migration 20261101083000: required downpayment for Cash on Delivery
-- =============================================================================
-- Run after 20261031064602_refund_payment_on_cancelled_order.sql. Idempotent.
--
-- A Cash on Delivery order can require part of its total to be paid online through
-- HitPay before staff ever see it. The rest is collected in cash on delivery.
--
-- OFF UNTIL THE OWNER SETS IT. Nothing changes while cod_downpayment_type, _value or
-- _expiry_minutes is Not set, or while online payment is switched off: Cash on
-- Delivery then stays full cash, exactly as before.
--
-- RELEASE ORDER. Older app builds cannot read the new order status. Apply this
-- migration, deploy hitpay-create-payment and hitpay-webhook, schedule
-- expire_unpaid_cod_downpayments() every minute, release the app, and only then let
-- the owner enter the settings.
--
--   select cron.schedule('melai-cod-downpayment-expiry', '* * * * *',
--                        $$ select public.expire_unpaid_cod_downpayments() $$);
--
-- HOW IT FITS TOGETHER
--  * order_downpayments holds the online part, one row per order.
--  * payments stays one row per order and holds the CASH BALANCE, so the rider's
--    exact-cash check and "completed needs a confirmed payment" work unchanged.
--  * Status awaitingDownpayment: stock is held, staff cannot see the order. It moves
--    to pending when paid, or to cancelled when unpaid after the time limit.
--  * Cancelled after paying, or paid after being cancelled: a refund request for the
--    downpayment opens in the normal queue. A sale that never completed is not a sale,
--    so that refund is left out of the sales figures.
-- =============================================================================
begin;

-- 1. Settings ------------------------------------------------------------------
alter table public.business_settings add column if not exists cod_downpayment_type text;
alter table public.business_settings add column if not exists cod_downpayment_value numeric(10, 2);
alter table public.business_settings add column if not exists cod_downpayment_min_order numeric(10, 2);
alter table public.business_settings add column if not exists cod_downpayment_expiry_minutes int;
alter table public.business_settings drop constraint if exists business_settings_cod_downpayment_check;
alter table public.business_settings add constraint business_settings_cod_downpayment_check check (
  (cod_downpayment_type is null or cod_downpayment_type in ('percent', 'fixed'))
  and (cod_downpayment_value is null or cod_downpayment_value > 0)
  and (cod_downpayment_type is distinct from 'percent' or cod_downpayment_value is null or cod_downpayment_value < 100)
  and (cod_downpayment_min_order is null or cod_downpayment_min_order > 0)
  and (cod_downpayment_expiry_minutes is null or cod_downpayment_expiry_minutes between 5 and 1440));

-- 2. Order status --------------------------------------------------------------
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in (
    'awaitingDownpayment', 'pending', 'confirmed', 'preparing', 'readyForPickup', 'outForDelivery',
    'completed', 'cancelled', 'refundRequested', 'refunded'
  ));

-- 3. The online part of a Cash on Delivery order -------------------------------
create table if not exists public.order_downpayments (
  order_id text primary key references public.orders(id) on delete cascade,
  firebase_uid text not null references public.customer_profiles(firebase_uid),
  amount numeric(10, 2) not null check (amount > 0),
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'success', 'failed', 'expired', 'refunded')),
  method text not null default 'online' check (method in (
    'gcash', 'maya', 'card',
    'qrph', 'grabpay', 'shopeepay', 'spaylater', 'billease', 'wechat',
    'unionbank', 'instapay', 'pesonet', 'bayad', 'ecpay', 'palawan',
    'online'
  )),
  gateway text,
  gateway_payment_id text,
  gateway_checkout_url text,
  gateway_checkout_created_at timestamptz,
  checkout_started_at timestamptz,
  expires_at timestamptz not null,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists order_downpayments_open_idx on public.order_downpayments (expires_at)
  where status in ('pending', 'processing', 'failed');
drop trigger if exists order_downpayments_set_updated_at on public.order_downpayments;
create trigger order_downpayments_set_updated_at before update on public.order_downpayments
  for each row execute function public.set_updated_at();

alter table public.order_downpayments enable row level security;
revoke all on public.order_downpayments from anon, authenticated;
grant select on public.order_downpayments to authenticated;
drop policy if exists "customer: read own downpayments" on public.order_downpayments;
create policy "customer: read own downpayments" on public.order_downpayments for select to authenticated
  using (firebase_uid = public.current_firebase_uid());
drop policy if exists "staff: read branch downpayments" on public.order_downpayments;
create policy "staff: read branch downpayments" on public.order_downpayments for select to authenticated
  using (exists (select 1 from public.orders o
                 where o.id = order_id and public.staff_can_see_branch(o.branch_id)));

-- Staff do not see an order until its downpayment is paid.
drop policy if exists "staff: read branch orders" on public.orders;
create policy "staff: read branch orders" on public.orders for select to authenticated
  using (public.staff_can_see_branch(branch_id) and status <> 'awaitingDownpayment');

-- 4. What an order would have to pay ------------------------------------------
-- NULL = no downpayment. Online payment switched off also means none.
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
     or s.cod_downpayment_expiry_minutes is null then
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
revoke all on function public._cod_downpayment_amount(numeric) from public, anon, authenticated;

-- The checkout preview. place_order works the amount out again for itself.
create or replace function public.cod_downpayment_quote(p_total numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v numeric := public._cod_downpayment_amount(p_total);
begin
  if v is null then
    return jsonb_build_object('required', false, 'amount', 0, 'balance', coalesce(p_total, 0), 'expiry_minutes', null);
  end if;
  return jsonb_build_object('required', true, 'amount', v, 'balance', p_total - v,
    'expiry_minutes', (select cod_downpayment_expiry_minutes from public.business_settings where id = 'default'));
end;
$$;
revoke all on function public.cod_downpayment_quote(numeric) from public, anon;
grant execute on function public.cod_downpayment_quote(numeric) to authenticated;

-- 5. Settings functions ---------------------------------------------------------

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
                          'cod_downpayment_min_order', 'cod_downpayment_expiry_minutes'];
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
  if (v_new.cod_downpayment_type is null) <> (v_new.cod_downpayment_value is null)
     or (v_new.cod_downpayment_type is not null and v_new.cod_downpayment_expiry_minutes is null) then
    raise exception 'To require a downpayment, enter its type, its amount and the time limit together.';
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
      carried_over = false,
      updated_at = now(),
      updated_by = v_owner.firebase_uid
    where id = 'default';
  exception when check_violation then
    raise exception 'A setting is out of range (ratios: low must be below plenty / high; margin 1-99%%; threshold 0-100,000; targets above 0; expiry alerts 1-365 days; "only N left" 1-1,000; downpayment above 0, a percent below 100, time limit 5-1,440 minutes).';
  end;

  perform public._write_audit(v_owner.firebase_uid, null, 'business.settings_updated', 'business_settings', 'default',
    jsonb_build_object('before', to_jsonb(v_old) - 'updated_at' - 'updated_by',
                       'after', p_settings));
  return public.get_business_settings();
end;
$$;


-- 6. Placing an order -----------------------------------------------------------

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

  if p_payment_method = 'Cash on Delivery' then
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
    insert into public.order_downpayments (order_id, firebase_uid, amount, expires_at)
    select v_order_id, v_uid, v_downpayment, now() + make_interval(mins => s.cod_downpayment_expiry_minutes)
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

create or replace function public.check_order_integrity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
  v_items numeric;
begin
  select count(*), coalesce(sum(quantity * unit_price), 0)
  into v_count, v_items
  from public.order_items where order_id = new.id;

  if v_count = 0 then
    raise exception 'Order % must have at least one item.', new.id;
  end if;
  if v_items <> new.subtotal then
    raise exception 'Order % subtotal (%) does not match its items (%).', new.id, new.subtotal, v_items;
  end if;
  if not exists (select 1 from public.payments p
                 where p.order_id = new.id
                   and p.amount + coalesce((select d.amount from public.order_downpayments d where d.order_id = new.id), 0) = new.total) then
    raise exception 'Order % must have a payment record for exactly its total (%).', new.id, new.total;
  end if;
  return null;
end;
$$;

create or replace function public.enforce_order_transition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old int;
  v_new int;
begin
  if new.status = old.status then return new; end if;

  if old.status in ('cancelled', 'refunded') then
    raise exception 'Order % is % and can no longer change status.', old.id, old.status;
  end if;

  if old.status = 'awaitingDownpayment' then
    if new.status = 'cancelled' then return new; end if;
    if new.status = 'pending' and coalesce(current_setting('app.cod_downpayment_release', true), '') = 'on' then
      return new;
    end if;
    raise exception 'Order % is waiting for its downpayment.', old.id;
  end if;
  if new.status = 'awaitingDownpayment' then
    raise exception 'An order cannot go back to waiting for its downpayment.';
  end if;

  if old.status = 'completed' then
    if new.status <> 'refundRequested' then
      raise exception 'A completed order can only move to refundRequested (not %).', new.status;
    end if;
    return new;
  end if;

  if old.status = 'refundRequested' then
    if new.status not in ('refunded', 'completed') then
      raise exception 'A refund-requested order can only become refunded or return to completed (not %).', new.status;
    end if;
    return new;
  end if;

  -- From here `old` is an active (unfulfilled) status.
  if new.status in ('refundRequested', 'refunded') then
    raise exception 'Only a completed order can be refunded.';
  end if;
  if new.status = 'cancelled' then return new; end if;

  -- A delivery dispatch was cancelled: the order returns to the kitchen
  -- queue so staff can redispatch it on a new delivery. The only backward
  -- edge in this state machine, and only this one.
  if old.status = 'outForDelivery' and new.status = 'confirmed' then
    return new;
  end if;

  if new.status = 'readyForPickup' and new.is_delivery then
    raise exception 'A delivery order cannot be ready for pickup.';
  end if;
  if new.status = 'outForDelivery' and not new.is_delivery then
    raise exception 'A pickup order cannot be out for delivery.';
  end if;

  v_old := case old.status when 'pending' then 1 when 'confirmed' then 2 when 'preparing' then 3
                           when 'readyForPickup' then 4 when 'outForDelivery' then 4 end;
  v_new := case new.status when 'pending' then 1 when 'confirmed' then 2 when 'preparing' then 3
                           when 'readyForPickup' then 4 when 'outForDelivery' then 4 when 'completed' then 5 end;
  if v_new is null or v_new <= v_old then
    raise exception 'Order status cannot move from % to %.', old.status, new.status;
  end if;

  if new.status = 'completed' and new.total > 0 and not exists (
       select 1 from public.payments p where p.order_id = new.id and p.status = 'success') then
    raise exception 'Order % cannot be completed until its payment is confirmed.', new.id;
  end if;

  return new;
end;
$$;

create or replace function public._trg_staff_notify_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    -- A Cash on Delivery order awaiting its downpayment is announced when it is paid.
    if coalesce(current_setting('app.pos_sale', true), '') <> '1' and new.status <> 'awaitingDownpayment' then
      perform public._notify_staff(new.branch_id, 'order',
        'New ' || case when new.is_delivery then 'delivery' else 'pickup' end || ' order ' || new.id,
        'Total ₱' || to_char(new.total, 'FM999,999,990.00') || ' • ' || new.payment_method,
        new.id);
    end if;
  exception when others then
    raise warning 'staff order notification for % failed: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;


-- 7. HitPay ---------------------------------------------------------------------
-- Every HitPay event of an order with a downpayment row is about the downpayment:
-- its balance is only ever cash.
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
  if p_dp.status in ('success', 'refunded') then return p_dp.status; end if;
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
        || '. The rest is paid in cash on delivery.');
    begin
      perform public._notify_staff(p_order.branch_id, 'order', 'New delivery order ' || p_order.id,
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
revoke all on function public._cod_downpayment_apply(public.orders, public.order_downpayments, text, text, text, text) from public, anon, authenticated;

create or replace function public._cod_downpayment_open_refund(p_order public.orders, p_amount numeric, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.refund_requests (order_id, firebase_uid, reason, notes, amount, payment_method)
  values (p_order.id, p_order.firebase_uid, p_reason, 'Opened automatically for the downpayment.',
          p_amount, p_order.payment_method)
  on conflict (order_id) where status <> 'rejected' do nothing;

  perform public.notify_customer(p_order.firebase_uid, 'refund', 'Your downpayment will be refunded',
    'Order ' || p_order.id || ' was cancelled. We will refund your ₱'
      || to_char(p_amount, 'FM999,999,990.00') || ' downpayment.');
end;
$$;
revoke all on function public._cod_downpayment_open_refund(public.orders, numeric, text) from public, anon, authenticated;

-- Staff cancelled an order, or the time limit ran out.
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
    perform public._cod_downpayment_open_refund(new, v_dp.amount, 'Order cancelled after the downpayment was paid');
  elsif v_dp.status in ('pending', 'processing', 'failed') then
    update public.order_downpayments
    set status = 'expired', gateway_checkout_url = null, gateway_checkout_created_at = null, checkout_started_at = null
    where order_id = new.id;
  end if;
  return new;
end;
$$;
revoke all on function public._trg_cod_downpayment_on_cancel() from public, anon, authenticated;
drop trigger if exists orders_cod_downpayment_on_cancel on public.orders;
create trigger orders_cod_downpayment_on_cancel after update of status on public.orders
  for each row when (new.status = 'cancelled' and old.status is distinct from new.status)
  execute function public._trg_cod_downpayment_on_cancel();

-- Run every minute. Cancelling returns the stock, points and voucher (reverse_order_on_cancel).
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
  return n;
end;
$$;
revoke all on function public.expire_unpaid_cod_downpayments() from public, anon, authenticated;
grant execute on function public.expire_unpaid_cod_downpayments() to service_role;


create or replace function public.hitpay_claim_checkout(p_order_id text, p_max_age_minutes int default 60)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay public.payments;
  v_max_age interval := make_interval(mins => greatest(coalesce(p_max_age_minutes, 60), 1));
  v_dp public.order_downpayments;
begin
  select * into v_dp from public.order_downpayments where order_id = p_order_id for update;
  if found then
    if v_dp.status not in ('pending', 'processing', 'failed') then
      return jsonb_build_object('action', 'closed', 'status', v_dp.status);
    end if;
    if v_dp.expires_at <= now() then return jsonb_build_object('action', 'expired'); end if;
    if v_dp.status <> 'failed'
       and v_dp.gateway_checkout_url is not null and v_dp.gateway_payment_id is not null
       and v_dp.gateway_checkout_created_at is not null
       and v_dp.gateway_checkout_created_at > now() - v_max_age then
      return jsonb_build_object('action', 'reuse', 'checkout_url', v_dp.gateway_checkout_url,
                                'payment_request_id', v_dp.gateway_payment_id);
    end if;
    if v_dp.checkout_started_at is not null and v_dp.checkout_started_at > now() - interval '60 seconds' then
      return jsonb_build_object('action', 'busy');
    end if;
    update public.order_downpayments set checkout_started_at = now() where order_id = p_order_id;
    return jsonb_build_object('action', 'create');
  end if;

  select * into v_pay from public.payments where order_id = p_order_id for update;
  if not found then raise exception 'Order % has no payment record.', p_order_id; end if;
  if v_pay.status not in ('pending', 'processing', 'failed') then
    return jsonb_build_object('action', 'closed', 'status', v_pay.status);
  end if;
  if v_pay.status <> 'failed'
     and v_pay.gateway_checkout_url is not null and v_pay.gateway_payment_id is not null
     and v_pay.gateway_checkout_created_at is not null
     and v_pay.gateway_checkout_created_at > now() - v_max_age then
    return jsonb_build_object('action', 'reuse', 'checkout_url', v_pay.gateway_checkout_url,
                              'payment_request_id', v_pay.gateway_payment_id);
  end if;
  if v_pay.checkout_started_at is not null and v_pay.checkout_started_at > now() - interval '60 seconds' then
    return jsonb_build_object('action', 'busy');
  end if;
  update public.payments set checkout_started_at = now() where id = v_pay.id;
  return jsonb_build_object('action', 'create');
end;
$$;

create or replace function public.hitpay_release_checkout(p_order_id text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.payments set checkout_started_at = null where order_id = p_order_id;
  update public.order_downpayments set checkout_started_at = null where order_id = p_order_id;
$$;

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
  v_dp public.order_downpayments;
begin
  select * into v_dp from public.order_downpayments where order_id = p_order_id for update;
  if found then
    update public.order_downpayments
    set gateway = 'hitpay',
        gateway_payment_id = nullif(trim(coalesce(p_payment_id, '')), ''),
        gateway_checkout_url = nullif(trim(coalesce(p_url, '')), ''),
        gateway_checkout_created_at = now(),
        checkout_started_at = null,
        status = case when status in ('pending', 'failed') then 'processing' else status end
    where order_id = p_order_id;
    return;
  end if;

  select * into v_pay from public.payments where order_id = p_order_id for update;
  if not found then raise exception 'Order % has no payment record.', p_order_id; end if;

  update public.payments
  set gateway = 'hitpay',
      gateway_payment_id = nullif(trim(coalesce(p_payment_id, '')), ''),
      gateway_checkout_url = nullif(trim(coalesce(p_url, '')), ''),
      gateway_checkout_created_at = now(),
      checkout_started_at = null
  where id = v_pay.id;

  if v_pay.status in ('pending', 'failed') then
    update public.payments set status = 'processing' where id = v_pay.id;
  end if;
end;
$$;

create or replace function public.hitpay_expire_checkout(p_order_id text, p_payment_request_id text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay public.payments;
  v_dp public.order_downpayments;
begin
  select * into v_dp from public.order_downpayments where order_id = p_order_id for update;
  if found then
    if v_dp.status <> 'processing'
       or v_dp.gateway_payment_id is distinct from nullif(trim(coalesce(p_payment_request_id, '')), '') then
      return v_dp.status;
    end if;
    update public.order_downpayments
       set status = 'failed', gateway_checkout_url = null, gateway_checkout_created_at = null, checkout_started_at = null
     where order_id = p_order_id;
    return 'failed';
  end if;

  select * into v_pay from public.payments where order_id = p_order_id for update;
  if not found then return null; end if;
  if v_pay.status <> 'processing'
     or v_pay.gateway_payment_id is distinct from nullif(trim(coalesce(p_payment_request_id, '')), '') then
    return v_pay.status;
  end if;
  update public.payments
     set status = 'failed', gateway_checkout_url = null, gateway_checkout_created_at = null, checkout_started_at = null
   where id = v_pay.id;
  return 'failed';
end;
$$;

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
  v_dp public.order_downpayments;
begin
  if p_status is null or p_status not in ('success', 'failed') then
    return null;
  end if;

  -- The order first, so a cancel running right now is seen here or sees this payment.
  select * into v_order from public.orders where id = p_order_id for update;
  select * into v_dp from public.order_downpayments where order_id = p_order_id for update;
  if found then
    return public._cod_downpayment_apply(v_order, v_dp, p_status, v_method, v_gateway_payment_id, v_request_id);
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


-- 8. Staff ----------------------------------------------------------------------

create or replace function public.staff_update_order_status(
  p_order_id text,
  p_status text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.orders;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'That order could not be found.'; end if;
  perform public._require_staff(o.branch_id);
  if o.status = 'awaitingDownpayment' then raise exception 'That order could not be found.'; end if;
  if p_status not in ('confirmed', 'preparing', 'readyForPickup', 'outForDelivery', 'completed', 'cancelled') then
    raise exception 'Staff cannot set an order to that status.';
  end if;
  -- The state machine trigger (enforce_order_transition) validates the move,
  -- including "completed needs a confirmed payment".
  update public.orders set status = p_status where id = p_order_id;
  if nullif(trim(coalesce(p_note, '')), '') is not null then
    update public.order_status_events set note = left(trim(p_note), 300)
    where id = (select id from public.order_status_events
                where order_id = p_order_id and status = p_status
                order by created_at desc limit 1);
  end if;
end;
$$;

create or replace function public.staff_confirm_payment(p_order_id text, p_reference text default null)
returns void
language plpgsql
security definer
set search_path = public
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
  if pay.method <> 'cash' and (v_ref is null or length(v_ref) < 4) then
    raise exception 'Enter the payment reference number to confirm this payment.';
  end if;
  update public.payments
  set status = 'success', reference_number = coalesce(v_ref, reference_number)
  where id = pay.id;
  perform public.notify_customer(o.firebase_uid, 'payment', 'Payment received',
    'We received your payment for order ' || o.id || '.');
end;
$$;

create or replace function public.staff_list_orders(
  p_branch_id uuid default null,
  p_statuses text[] default null,
  p_since timestamptz default null,
  p_limit int default 100,
  p_order_id text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branch uuid;
begin
  v_staff := public._require_staff();
  v_branch := case when v_staff.role = 'owner' then p_branch_id else v_staff.branch_id end;
  if v_branch is null then raise exception 'Please choose a branch first.'; end if;

  return (
    select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb)
    from (
      select o.created_at,
        jsonb_build_object(
          'id', o.id, 'created_at', o.created_at, 'status', o.status,
          'branch_id', o.branch_id, 'branch_name', o.branch_name, 'is_delivery', o.is_delivery,
          'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', o.total,
          'payment_method', o.payment_method, 'points_earned', o.points_earned,
          'customer_notes', o.customer_notes, 'contact_phone', o.contact_phone,
          'delivery_address_text', o.delivery_address_text,
          'rider_name', o.rider_name, 'eta_label', o.eta_label,
          'customer_name', case when o.firebase_uid = 'walk-in' then null else nullif(cp.full_name, '') end,
          'is_pos', (ps.order_id is not null),
          'cashier_name', nullif(ps.staff_name, ''),
          'cash_received', ps.cash_received, 'change_given', ps.change_given,
          'items', (select coalesce(jsonb_agg(jsonb_build_object(
                      'variant_id', i.variant_id, 'product_id', i.product_id,
                      'product_name', i.product_name, 'variant_label', i.variant_label,
                      'quantity', i.quantity, 'unit_price', i.unit_price)), '[]'::jsonb)
                    from public.order_items i where i.order_id = o.id),
          'downpayment', (select jsonb_build_object('amount', dpx.amount, 'status', dpx.status, 'method', dpx.method, 'paid_at', dpx.paid_at)
                          from public.order_downpayments dpx where dpx.order_id = o.id),
          'payment', (select jsonb_build_object('id', pay.id, 'method', pay.method, 'status', pay.status,
                                                'reference_number', pay.reference_number, 'amount', pay.amount)
                      from public.payments pay where pay.order_id = o.id limit 1),
          'refund_summary', public._order_refund_json(o.id)
        ) as j
      from public.orders o
      left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
      left join public.pos_sales ps on ps.order_id = o.id
      where o.branch_id = v_branch
        and o.status <> 'awaitingDownpayment'
        and (p_statuses is null or o.status = any(p_statuses))
        and (p_since is null or o.created_at >= p_since)
        and (p_order_id is null or o.id = p_order_id)
      order by o.created_at desc
      limit least(greatest(coalesce(p_limit, 100), 1), 300)
    ) x
  );
end;
$$;

create or replace function public.staff_get_dashboard(p_branch_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branch uuid;
  v_day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Manila') at time zone 'Asia/Manila';
  v_today date := (now() at time zone 'Asia/Manila')::date;
  b record;
  o record;
  v_money jsonb;
  v_low int;
  v_out int;
  v_expiring int;
  v_await_approval int;
  v_await_receipt int;
  v_refunds int;
  v_refund_amount numeric;
  v_unread int;
begin
  v_staff := public._require_staff();
  v_branch := case when v_staff.role = 'owner' then p_branch_id else v_staff.branch_id end;
  if v_branch is null then raise exception 'Please choose a branch first.'; end if;
  select * into b from public.branches where id = v_branch;
  if not found then raise exception 'That branch could not be found.'; end if;

  select
    count(*) filter (where created_at >= v_day_start) as orders_today,
    count(*) filter (where status in ('pending', 'confirmed')) as pending_orders,
    count(*) filter (where status = 'preparing') as preparing_orders,
    count(*) filter (where status in ('readyForPickup', 'outForDelivery')) as ready_orders,
    count(*) filter (where created_at >= v_day_start and status = 'completed') as completed_today,
    count(*) filter (where created_at >= v_day_start and status = 'cancelled') as cancelled_today
  into o
  from public.orders where branch_id = v_branch and status <> 'awaitingDownpayment';

  select public._sales_money_json(count(*) filter (where kind = 'sale'), sum(gross), sum(discount),
                                  sum(refund), count(*) filter (where kind = 'refund'), sum(delivery_fee))
    into v_money
  from public._sales_facts(v_day_start, null, array[v_branch]);

  with items as (
    select bi.quantity,
           coalesce(th.restock_threshold, public._default_restock_threshold()) as thr
    from public.branch_inventory bi
    join public.products p on p.id = bi.product_id and p.is_active
    left join public.stock_thresholds th on th.branch_id = bi.branch_id and th.variant_id = bi.variant_id
    where bi.branch_id = v_branch and bi.variant_id is not null and bi.is_carried
  )
  select count(*) filter (where quantity = 0), count(*) filter (where quantity > 0 and quantity <= thr)
  into v_out, v_low from items;

  select count(*) into v_expiring from public.inventory_batches
  where branch_id = v_branch and quantity > 0 and expiration_date <= v_today + 15;

  select count(*) into v_await_approval from public.stock_transfers
  where from_branch_id = v_branch and status = 'requested';
  select count(*) into v_await_receipt from public.stock_transfers
  where to_branch_id = v_branch and status = 'in_transit';

  if v_staff.role = 'owner' or v_staff.can_review_refunds then
    select count(*), coalesce(sum(amount), 0) into v_refunds, v_refund_amount
    from public._pending_refund_facts(array[v_branch]);
  end if;

  select count(*) into v_unread from public.staff_notifications
  where recipient_uid = v_staff.firebase_uid and not read;

  return jsonb_build_object(
    'branch', jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address, 'contact_phone', b.contact_phone,
      'operating_hours', b.operating_hours, 'is_active', b.is_active,
      'supports_delivery', b.supports_delivery, 'supports_pickup', b.supports_pickup),
    'sales_today', v_money -> 'net_sales',          -- net sales today (gross - discounts - refunds)
    'net_sales_today', v_money -> 'net_sales',
    'gross_sales_today', v_money -> 'gross_sales',
    'discounts_today', v_money -> 'discounts',
    'refunds_today', v_money -> 'refunds',
    'refund_count_today', v_money -> 'refund_count',
    'refund_rate_today', v_money -> 'refund_rate',
    'paid_orders_today', v_money -> 'orders',
    'orders_today', o.orders_today,
    'pending_orders', o.pending_orders,
    'preparing_orders', o.preparing_orders,
    'ready_orders', o.ready_orders,
    'completed_today', o.completed_today,
    'cancelled_today', o.cancelled_today,
    'low_stock_count', v_low,
    'out_of_stock_count', v_out,
    'expiring_soon_count', v_expiring,
    'transfers_awaiting_approval', v_await_approval,
    'transfers_awaiting_receipt', v_await_receipt,
    'pending_refunds', v_refunds,                -- null when the caller may not review refunds
    'pending_refund_amount', v_refund_amount,    -- null when the caller may not review refunds
    'unread_notifications', v_unread,
    'generated_at', now()
  );
end;
$$;

create or replace function public._delivery_to_jsonb(p_delivery_id text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', d.id,
    'branch', d.branch_name,
    'branch_id', d.branch_id,
    'vehicle', d.vehicle,
    'rider_name', d.rider_name,
    'status', d.status,
    'created_at', d.created_at,
    'driver_uid', d.driver_uid,
    'driver_status', d.driver_status,
    'driver_phone', dr.phone,
    'assigned_at', d.assigned_at,
    'accepted_at', d.accepted_at,
    'picked_up_at', d.picked_up_at,
    'completed_at', d.completed_at,
    'tracking_active', d.tracking_active,
    'branch_latitude', b.latitude,
    'branch_longitude', b.longitude,
    'stops', (
      select coalesce(jsonb_agg(to_jsonb(s) order by s.sequence_index), '[]'::jsonb)
      from (
        select
          ds.id,
          o.id as order_id,
          coalesce(nullif(cp.full_name, ''), 'Customer') as customer_name,
          coalesce(o.delivery_address_text, 'Address not provided') as address,
          case when o.delivery_latitude is not null then o.delivery_latitude
               when ca.latitude = 0 and ca.longitude = 0 then null else ca.latitude end as latitude,
          case when o.delivery_latitude is not null then o.delivery_longitude
               when ca.latitude = 0 and ca.longitude = 0 then null else ca.longitude end as longitude,
          o.contact_phone,
          o.customer_notes,
          o.total as order_total,
          case when p.method = 'cash' and p.status <> 'success' then p.amount end as cash_due,
          (select dpx.amount from public.order_downpayments dpx where dpx.order_id = o.id and dpx.status = 'success') as downpayment_paid,
          p.method as payment_method,
          p.status as payment_status,
          ds.sequence_index,
          ds.distance_from_previous_km,
          ds.travel_minutes_from_previous,
          ds.eta_label as eta,
          ds.status,
          ds.issue_reason,
          ds.proof_note,
          ds.proof_photo_path,
          ds.recipient_name,
          ds.delivered_at,
          ds.failed_at,
          (select coalesce(jsonb_agg(
                     oi.quantity::text || 'x ' || oi.product_name ||
                     case when oi.variant_label is null or oi.variant_label = '' or oi.variant_label = 'Regular'
                          then '' else ' (' || oi.variant_label || ')' end
                   ), '[]'::jsonb)
           from public.order_items oi where oi.order_id = o.id) as items
        from public.delivery_stops ds
        join public.orders o on o.id = ds.order_id
        left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
        left join public.customer_addresses ca on ca.id = o.delivery_address_id and ca.firebase_uid = o.firebase_uid
        left join public.payments p on p.order_id = o.id
        where ds.delivery_id = d.id
      ) s
    )
  )
  from public.deliveries d
  join public.branches b on b.id = d.branch_id
  left join public.drivers dr on dr.firebase_uid = d.driver_uid
  where d.id = p_delivery_id
$$;

create or replace function public.staff_list_refunds(
  p_branch_id uuid default null,
  p_statuses text[] default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branch uuid;
begin
  v_staff := public._require_staff(null, 'refunds');
  v_branch := case when v_staff.role = 'owner' then p_branch_id else v_staff.branch_id end;
  if v_branch is null then raise exception 'Please choose a branch first.'; end if;
  return (
    select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb)
    from (
      select r.created_at,
        jsonb_build_object(
          'id', r.id, 'order_id', r.order_id, 'status', r.status, 'reason', r.reason, 'notes', r.notes,
          'amount', r.amount, 'payment_method', r.payment_method,
          'downpayment_amount', (select dpx.amount from public.order_downpayments dpx where dpx.order_id = r.order_id), 'created_at', r.created_at,
          'completed_at', (select max(e.created_at) from public.refund_status_events e
                           where e.refund_request_id = r.id and e.status = 'completed'),
          'customer_name', nullif(cp.full_name, ''),
          'order_total', o.total,
          'is_pos', exists (select 1 from public.pos_sales ps where ps.order_id = o.id),
          'is_partial', r.amount < greatest(o.subtotal - o.discount, 0) - 0.005,
          'order_refund', public._order_refund_json(o.id),
          'items', (select coalesce(jsonb_agg(jsonb_build_object(
                      'product_name', ri.product_name, 'variant_label', ri.variant_label,
                      'quantity', ri.quantity, 'unit_price', ri.unit_price)), '[]'::jsonb)
                    from public.refund_items ri where ri.refund_request_id = r.id),
          'returned', (select coalesce(jsonb_agg(jsonb_build_object(
                         'product_name', rr.product_name, 'variant_label', rr.variant_label,
                         'quantity', rr.quantity, 'condition', rr.condition, 'received_at', rr.created_at)
                         order by rr.created_at), '[]'::jsonb)
                       from public.refund_returned_items rr where rr.refund_id = r.id)
        ) as j
      from public.refund_requests r
      join public.orders o on o.id = r.order_id
      left join public.customer_profiles cp on cp.firebase_uid = r.firebase_uid
      where o.branch_id = v_branch and (p_statuses is null or r.status = any(p_statuses))
      order by r.created_at desc
      limit 200
    ) x
  );
end;
$$;


-- 9. Refunds --------------------------------------------------------------------

create or replace function public._validate_refund_against_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paid numeric;
  v_has_payment boolean;
  v_total numeric;
  v_done numeric;
begin
  if tg_op = 'UPDATE' and new.amount = old.amount
     and not (new.status = 'completed' and old.status is distinct from 'completed') then
    return new;
  end if;
  select o.total into v_total from public.orders o where o.id = new.order_id;
  select coalesce(sum(p.amount) filter (where p.status in ('success', 'refunded')), 0), count(*) > 0
    into v_paid, v_has_payment
  from public.payments p where p.order_id = new.order_id;
  -- Orders from before payments were recorded fall back to the order total.
  if not v_has_payment then v_paid := coalesce(v_total, 0); end if;
  v_paid := v_paid + coalesce((select d.amount from public.order_downpayments d
                               where d.order_id = new.order_id and d.status in ('success', 'refunded')), 0);
  select coalesce(sum(r.amount), 0) into v_done
  from public.refund_requests r
  where r.order_id = new.order_id and r.status = 'completed' and r.id <> new.id;
  if new.amount > v_paid - v_done + 0.004 then
    raise exception 'Refund amount (₱%) is more than what is left to refund on this order (₱%).',
      new.amount, greatest(v_paid - v_done, 0);
  end if;
  return new;
end;
$$;

create or replace function public._order_refund_json(p_order_id text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'state', case
               when coalesce(c.amount, 0) > 0
                    and c.amount >= greatest(o.subtotal - o.discount, 0) - 0.005 then 'full'
               when coalesce(c.amount, 0) > 0 then 'partial'
               when coalesce(pd.amount, 0) > 0 then 'pending'
               else 'none' end,
    'refunded_amount', coalesce(c.amount, 0),
    'refund_count', coalesce(c.n, 0),
    'refunded_units', coalesce(c.units, 0),
    'refunded_at', c.done_at,
    'pending_amount', coalesce(pd.amount, 0),
    'pending_status', pd.status,
    'points_reversed', coalesce(lp.reversed, 0),
    'refundable_amount', greatest(coalesce(nullif(coalesce(pay.paid, 0) + coalesce(dpx.paid, 0), 0), o.total) - coalesce(c.amount, 0), 0))
  from public.orders o
  left join lateral (
    select sum(r.amount) as amount, count(*) as n,
           (select coalesce(sum(ri.quantity), 0) from public.refund_items ri
              join public.refund_requests r2 on r2.id = ri.refund_request_id
             where r2.order_id = o.id and r2.status = 'completed') as units,
           max((select coalesce(max(e.created_at), r.updated_at) from public.refund_status_events e
                where e.refund_request_id = r.id and e.status = 'completed')) as done_at
    from public.refund_requests r where r.order_id = o.id and r.status = 'completed'
  ) c on true
  left join lateral (
    select sum(r.amount) as amount, max(r.status) as status
    from public.refund_requests r
    where r.order_id = o.id and r.status in ('pending', 'approved', 'processing')
  ) pd on true
  left join lateral (
    select sum(p.amount) as paid from public.payments p
    where p.order_id = o.id and p.status in ('success', 'refunded')
  ) pay on true
  left join lateral (
    select d.amount as paid from public.order_downpayments d
    where d.order_id = o.id and d.status in ('success', 'refunded')
  ) dpx on true
  left join lateral (
    select -sum(lt.points)::int as reversed from public.loyalty_transactions lt
    where lt.order_id = o.id and lt.source = 'order_clawback'
  ) lp on true
  where o.id = p_order_id
$$;

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
      update public.order_downpayments set status = 'refunded'
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

create or replace function public.finalize_order_refund()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_earned int;
  v_refunded numeric;
  v_base numeric;
  v_target int;
  v_done int;
  v_take int;
begin
  select coalesce(sum(points), 0) into v_earned
  from public.loyalty_transactions
  where order_id = new.id and source = 'order_earn';

  select coalesce(sum(amount), 0) into v_refunded
  from public.refund_requests where order_id = new.id and status = 'completed';
  v_base := greatest(new.subtotal - new.discount, 0);

  if v_earned > 0 and v_refunded > 0 then
    v_target := case when v_base <= 0 or v_refunded >= v_base then v_earned
                     else least(v_earned, round(v_earned * v_refunded / v_base)::int) end;
    select coalesce(-sum(points), 0) into v_done
    from public.loyalty_transactions where order_id = new.id and source = 'order_clawback';

    if v_target - v_done > 0 then
      select least(points_balance, v_target - v_done) into v_take
      from public.loyalty_accounts where firebase_uid = new.firebase_uid for update;

      if coalesce(v_take, 0) > 0 then
        update public.loyalty_accounts
        set points_balance = points_balance - v_take
        where firebase_uid = new.firebase_uid;

        insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
        values (new.firebase_uid, 'redeem', -v_take,
                'Points reversed - order ' || new.id || ' refunded'
                  || case when v_refunded < v_base then ' (partial)' else '' end,
                new.id, 'order_clawback');
      end if;
    end if;
  end if;

  update public.payments set status = 'refunded'
  where order_id = new.id and status = 'success';
  update public.order_downpayments set status = 'refunded'
  where order_id = new.id and status = 'success';

  return new;
end;
$$;

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
  v_dp public.order_downpayments;
  v_send numeric;
begin
  select * into r from public.refund_requests where id = p_refund_id for update;
  if r.id is null then raise exception 'That refund request could not be found.'; end if;
  select branch_id into v_branch from public.orders where id = r.order_id;
  v_staff := public._require_staff(v_branch, 'refunds');

  -- 'processing' = the app's "Start processing" step; still nothing has been paid back.
  if r.status not in ('approved', 'processing') then
    raise exception 'Only an approved refund can be sent to HitPay (this one is %).', r.status;
  end if;
  -- With a downpayment, only that part can go back through HitPay. Any rest was paid in cash.
  select * into v_dp from public.order_downpayments where order_id = r.order_id for update;
  if found then
    v_pay.id := v_dp.order_id;
    v_pay.method := v_dp.method;
    v_pay.status := v_dp.status;
    v_pay.amount := v_dp.amount;
    v_pay.gateway := v_dp.gateway;
    v_pay.gateway_payment_id := v_dp.gateway_payment_id;
    v_send := least(r.amount, v_dp.amount);
  else
    select * into v_pay from public.payments where order_id = r.order_id order by created_at desc limit 1 for update;
    v_send := r.amount;
  end if;
  if v_pay.id is null or v_pay.method = 'cash' then
    raise exception 'This order was not paid online. Refund the cash and mark it completed instead.';
  end if;
  if v_pay.status <> 'success' then
    raise exception 'The online payment for this order is %, so there is nothing to send back through HitPay.', v_pay.status;
  end if;
  if coalesce(v_pay.gateway, '') <> 'hitpay' or v_pay.gateway_payment_id is null then
    raise exception 'This payment has no HitPay payment id. Send the refund from the HitPay dashboard and mark it completed by hand.';
  end if;
  if v_send <= 0 or v_send > v_pay.amount then
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
  values (r.id, r.order_id, v_pay.gateway_payment_id, v_send, v_staff.firebase_uid)
  returning * into a;
  perform public._write_audit(v_staff.firebase_uid, v_branch, 'refund.gateway_send', 'refund_request', r.id,
    jsonb_build_object('attempt_id', a.id, 'amount', a.amount, 'order_id', r.order_id));
  return public._gateway_attempt_json(a) || jsonb_build_object('cash_remainder', r.amount - v_send);
end;
$$;

create or replace function public.admin_portal_review_refund(
  p_refund_id text,
  p_action text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.refund_requests;
  v_staff public.staff_members;
  v_branch uuid;
  v_pay_method text;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into r from public.refund_requests where id = p_refund_id for update;
  if not found then raise exception 'That refund request could not be found.'; end if;
  select o.branch_id, coalesce((select d.method from public.order_downpayments d where d.order_id = o.id),
                (select pay.method from public.payments pay where pay.order_id = o.id order by pay.created_at desc limit 1))
    into v_branch, v_pay_method
  from public.orders o where o.id = r.order_id;
  v_staff := public._require_staff(v_branch, 'refunds');
  perform set_config('app.refund_audit', 'caller', true);

  if p_action = 'approve' then
    perform public.staff_review_refund(r.id, 'approve');
  elsif p_action = 'approve_cash' then
    if v_pay_method is distinct from 'cash' then
      raise exception 'Only cash payments can be refunded in one step. Approve it, refund through the payment provider, then mark it completed.';
    end if;
    perform public.staff_review_refund(r.id, 'approve');
    perform public.staff_review_refund(r.id, 'complete');
  elsif p_action = 'complete' then
    if v_note is null or char_length(v_note) < 4 or char_length(v_note) > 120 then
      raise exception 'Enter the refund reference from the payment provider (4 to 120 characters).';
    end if;
    perform public.staff_review_refund(r.id, 'complete');
  elsif p_action = 'reject' then
    if v_note is null or char_length(v_note) < 5 or char_length(v_note) > 500 then
      raise exception 'A written reason (5 to 500 characters) is required to reject a refund.';
    end if;
    perform public.staff_review_refund(r.id, 'reject');
    perform public.notify_customer(r.firebase_uid, 'refund', 'Refund request not approved',
      'Request ' || r.id || ' for order ' || r.order_id || ': ' || v_note);
  else
    perform set_config('app.refund_audit', '', true);
    raise exception 'Unsupported refund action.';
  end if;
  perform set_config('app.refund_audit', '', true);

  perform public._write_audit(v_staff.firebase_uid, v_branch, 'refund.' || p_action, 'refund_request', r.id,
    jsonb_build_object('order_id', r.order_id, 'amount', r.amount, 'payment_method', v_pay_method,
                       'note', v_note, 'via', 'admin_portal'));

  return (select jsonb_build_object('id', id, 'status', status, 'order_id', order_id)
          from public.refund_requests where id = r.id);
end;
$$;


-- 10. Reports -------------------------------------------------------------------
-- paid_adjust moves the downpayment from the cash line to its online method in the
-- per-method "amount paid". Every other figure ignores it. A refund on an order that
-- was cancelled before delivery undoes no sale, so it is left out.
drop function if exists public._sales_facts(timestamptz, timestamptz, uuid[]);

create or replace function public._sales_facts(
  p_start timestamptz,
  p_end timestamptz,
  p_branch_ids uuid[] default null
)
returns table (
  kind text,
  order_id text,
  refund_id text,
  branch_id uuid,
  staff_uid text,
  event_at timestamptz,
  event_date date,
  is_pos boolean,
  is_void boolean,
  is_delivery boolean,
  payment_method text,
  gross numeric,
  discount numeric,
  delivery_fee numeric,
  refund numeric,
  paid_adjust numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select 'sale'::text, o.id, null::text, o.branch_id, ps.staff_uid, o.created_at,
         (o.created_at at time zone 'Asia/Manila')::date,
         ps.order_id is not null, false, o.is_delivery, pay.method,
         o.subtotal, o.discount, o.delivery_fee, 0::numeric,
         -coalesce((select d.amount from public.order_downpayments d where d.order_id = o.id and d.status in ('success', 'refunded')), 0)
  from public.orders o
  join lateral (
    select p.method from public.payments p
    where p.order_id = o.id and p.status in ('success', 'refunded')
    order by p.created_at desc limit 1
  ) pay on true
  left join public.pos_sales ps on ps.order_id = o.id
  where (p_start is null or o.created_at >= p_start)
    and (p_end is null or o.created_at < p_end)
    and (p_branch_ids is null or o.branch_id = any (p_branch_ids))
  union all
  select 'cod_downpayment'::text, o.id, null::text, o.branch_id, null::text, o.created_at,
         (o.created_at at time zone 'Asia/Manila')::date,
         false, false, o.is_delivery, dpx.method,
         0::numeric, 0::numeric, 0::numeric, 0::numeric, dpx.amount
  from public.orders o
  join public.order_downpayments dpx on dpx.order_id = o.id and dpx.status in ('success', 'refunded')
  where exists (select 1 from public.payments p where p.order_id = o.id and p.status in ('success', 'refunded'))
    and (p_start is null or o.created_at >= p_start)
    and (p_end is null or o.created_at < p_end)
    and (p_branch_ids is null or o.branch_id = any (p_branch_ids))
  union all
  select 'refund'::text, r.order_id, r.id, o.branch_id, ps.staff_uid, d.done_at,
         (d.done_at at time zone 'Asia/Manila')::date,
         ps.order_id is not null,
         exists (select 1 from public.pos_voids v where v.refund_id = r.id),
         o.is_delivery,
         coalesce((select p.method from public.payments p where p.order_id = o.id
                   order by p.created_at desc limit 1), r.payment_method),
         0::numeric, 0::numeric, 0::numeric, r.amount, 0::numeric
  from public.refund_requests r
  join public.orders o on o.id = r.order_id
  left join public.pos_sales ps on ps.order_id = r.order_id
  cross join lateral (
    -- refund_status_events is written by a trigger on every status change; a
    -- completed refund is final, so updated_at is the fallback for rows that
    -- pre-date that trigger.
    select coalesce(max(e.created_at), r.updated_at) as done_at
    from public.refund_status_events e
    where e.refund_request_id = r.id and e.status = 'completed'
  ) d
  where r.status = 'completed'
    and not (o.status = 'cancelled' and exists (select 1 from public.order_downpayments dpx where dpx.order_id = o.id))
    and (p_start is null or d.done_at >= p_start)
    and (p_end is null or d.done_at < p_end)
    and (p_branch_ids is null or o.branch_id = any (p_branch_ids))
$$;

revoke all on function public._sales_facts(timestamptz, timestamptz, uuid[]) from public, anon, authenticated;


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

create or replace function public.owner_all_users(
  p_search text default null,
  p_limit int default 50,
  p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := nullif(lower(trim(coalesce(p_search, ''))), '');
  -- 0917… typed by a person, +63917… stored: search both forms.
  v_q_phone text := case when nullif(lower(trim(coalesce(p_search, ''))), '') ~ '^0?9[0-9]*$'
                         then '+63' || regexp_replace(lower(trim(p_search)), '^0', '') end;
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 2000);
  v_offset int := least(greatest(coalesce(p_offset, 0), 0), 1000000);
begin
  perform public._require_owner();

  return jsonb_build_object(
    'staff', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'firebase_uid', s.firebase_uid, 'full_name', s.full_name, 'email', s.email,
               'role', s.role, 'branch_id', s.branch_id, 'branch_name', b.name,
               'is_active', s.is_active, 'account_status', s.account_status,
               'can_manage_inventory', s.can_manage_inventory, 'can_review_refunds', s.can_review_refunds,
               'created_at', s.created_at)
             order by s.role desc, s.full_name, s.firebase_uid), '[]'::jsonb)
      from public.staff_members s
      left join public.branches b on b.id = s.branch_id
    ),
    'drivers', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'firebase_uid', d.firebase_uid, 'full_name', d.full_name, 'email', d.email, 'phone', d.phone,
               'branch_id', d.branch_id, 'branch_name', b.name, 'vehicle', d.vehicle,
               'account_status', d.account_status, 'is_available', d.is_available, 'created_at', d.created_at,
               'active_runs', (select count(*) from public.deliveries x
                               where x.driver_uid = d.firebase_uid and x.status not in ('completed', 'cancelled')))
             order by d.full_name, d.firebase_uid), '[]'::jsonb)
      from public.drivers d
      left join public.branches b on b.id = d.branch_id
    ),
    'customers', (
      select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc, c.firebase_uid), '[]'::jsonb)
      from (
        select cp.firebase_uid,
               coalesce(nullif(cp.full_name, ''), 'Customer') as full_name,
               cp.email, nullif(cp.phone, '') as phone, cp.rfid_card_number as card_number,
               cp.default_branch_id as branch_id, b.name as branch_name, cp.created_at,
               coalesce(o.orders, 0) as orders, coalesce(o.paid_total, 0) as paid_total, o.last_order_at,
               la.points_balance as points_balance
        from public.customer_profiles cp
        left join public.branches b on b.id = cp.default_branch_id
        left join public.loyalty_accounts la on la.firebase_uid = cp.firebase_uid
        left join lateral (
          select count(*) filter (where ord.status not in ('cancelled', 'awaitingDownpayment')) as orders,
                 sum(ord.total) filter (where exists (select 1 from public.payments p
                                                      where p.order_id = ord.id and p.status in ('success', 'refunded'))) as paid_total,
                 max(ord.created_at) as last_order_at
          from public.orders ord
          where ord.firebase_uid = cp.firebase_uid
        ) o on true
        where cp.firebase_uid <> 'walk-in'
          and (v_q is null
               or lower(cp.full_name) like '%' || v_q || '%'
               or lower(cp.email) like '%' || v_q || '%'
               or lower(cp.phone) like '%' || v_q || '%'
               or (v_q_phone is not null and cp.phone like v_q_phone || '%')
               or lower(coalesce(cp.rfid_card_number, '')) like '%' || v_q || '%')
        order by cp.created_at desc, cp.firebase_uid
        limit v_limit offset v_offset
      ) c
    ),
    'customers_total', (
      select count(*)
      from public.customer_profiles cp
      where cp.firebase_uid <> 'walk-in'
        and (v_q is null
             or lower(cp.full_name) like '%' || v_q || '%'
             or lower(cp.email) like '%' || v_q || '%'
             or lower(cp.phone) like '%' || v_q || '%'
             or (v_q_phone is not null and cp.phone like v_q_phone || '%')
             or lower(coalesce(cp.rfid_card_number, '')) like '%' || v_q || '%')
    ),
    'limit', v_limit,
    'offset', v_offset
  );
end;
$$;


-- 11. Admin website -------------------------------------------------------------

create or replace function public.admin_portal_orders(
  p_from timestamptz,
  p_to timestamptz,
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
  v_branches uuid[];
  v_refunds boolean;
begin
  v_staff := public._require_staff();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Choose a valid date range.';
  end if;
  if p_to - p_from > interval '400 days' then
    raise exception 'Date range is too long (maximum 400 days).';
  end if;
  v_branches := public.staff_authorized_branch_ids();
  if p_branch_id is not null then
    if not (p_branch_id = any (v_branches)) then
      raise exception 'You can only work in your assigned branch.';
    end if;
    v_branches := array[p_branch_id];
  end if;
  v_refunds := public.staff_has_permission('refunds');

  return (
    select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb)
    from (
      select o.created_at,
        jsonb_build_object(
          'id', o.id, 'created_at', o.created_at, 'updated_at', o.updated_at, 'status', o.status,
          'branch_id', o.branch_id, 'branch_name', o.branch_name, 'is_delivery', o.is_delivery,
          'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', o.total,
          'payment_label', o.payment_method, 'points_earned', o.points_earned,
          'customer_uid', case when o.firebase_uid = 'walk-in' then null else o.firebase_uid end,
          'customer_name', case when o.firebase_uid = 'walk-in' then 'Walk-in' else nullif(cp.full_name, '') end,
          'is_pos', exists (select 1 from public.pos_sales ps where ps.order_id = o.id),
          'items', (select coalesce(jsonb_agg(jsonb_build_object(
                      'product_name', i.product_name, 'variant_label', i.variant_label,
                      'quantity', i.quantity, 'unit_price', i.unit_price)), '[]'::jsonb)
                    from public.order_items i where i.order_id = o.id),
          'downpayment', (select jsonb_build_object('amount', dpx.amount, 'status', dpx.status, 'method', dpx.method, 'paid_at', dpx.paid_at)
                          from public.order_downpayments dpx where dpx.order_id = o.id),
          'payment', (select jsonb_build_object('id', pay.id, 'method', pay.method, 'status', pay.status,
                                                'reference_number', pay.reference_number, 'amount', pay.amount,
                                                'updated_at', pay.updated_at)
                      from public.payments pay where pay.order_id = o.id
                      order by pay.created_at desc limit 1),
          -- Amounts only (they are part of the order's money); details stay behind 'refunds'.
          'refund_summary', public._order_refund_json(o.id),
          'refund', case when v_refunds then (
                      select jsonb_build_object('id', r.id, 'status', r.status, 'amount', r.amount,
                                                'reason', r.reason, 'notes', r.notes,
                                                'payment_method', r.payment_method,
                                                'created_at', r.created_at, 'updated_at', r.updated_at,
                                                'completed_at', (select max(e.created_at) from public.refund_status_events e
                                                                 where e.refund_request_id = r.id and e.status = 'completed'))
                      from public.refund_requests r where r.order_id = o.id
                      order by r.created_at desc limit 1) end
        ) as j
      from public.orders o
      left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
      where o.branch_id = any (v_branches)
        and o.created_at >= p_from and o.created_at <= p_to
      order by o.created_at desc
      limit 5000
    ) x
  );
end;
$$;

create or replace function public.admin_portal_orders_page(
  p_from timestamptz,
  p_to timestamptz,
  p_branch_id uuid default null,
  p_search text default null,
  p_status text default null,
  p_payment_method text default null,
  p_sort text default 'created_at',
  p_dir text default 'desc',
  p_limit int default 25,
  p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_branches uuid[];
  v_refunds boolean;
  v_q text := nullif(lower(trim(coalesce(p_search, ''))), '');
  v_limit int := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset int := least(greatest(coalesce(p_offset, 0), 0), 1000000);
  v_sort text := case when p_sort in ('created_at', 'total', 'id', 'status') then p_sort else 'created_at' end;
  v_desc boolean := lower(coalesce(p_dir, 'desc')) <> 'asc';
  v_total bigint;
  v_rows jsonb;
begin
  perform public._require_staff();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Choose a valid date range.';
  end if;
  if p_to - p_from > interval '400 days' then
    raise exception 'Date range is too long (maximum 400 days).';
  end if;
  v_branches := public.staff_authorized_branch_ids();
  if p_branch_id is not null then
    if not (p_branch_id = any (v_branches)) then
      raise exception 'You can only work in your assigned branch.';
    end if;
    v_branches := array[p_branch_id];
  end if;
  v_refunds := public.staff_has_permission('refunds');

  select count(*) into v_total
    from public.orders o
    left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
   where o.branch_id = any (v_branches)
     and o.created_at >= p_from and o.created_at <= p_to
     and (p_status is null or o.status = p_status)
     and (p_payment_method is null or o.payment_method = p_payment_method)
     and (v_q is null
          or lower(o.id) like '%' || v_q || '%'
          or lower(coalesce(cp.full_name, '')) like '%' || v_q || '%'
          or lower(coalesce(o.branch_name, '')) like '%' || v_q || '%');

  select coalesce(jsonb_agg(x.j order by x.rn), '[]'::jsonb) into v_rows
  from (
    select pg.rn,
      jsonb_build_object(
        'id', o.id, 'created_at', o.created_at, 'updated_at', o.updated_at, 'status', o.status,
        'branch_id', o.branch_id, 'branch_name', o.branch_name, 'is_delivery', o.is_delivery,
        'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', o.total,
        'payment_label', o.payment_method, 'points_earned', o.points_earned,
        'customer_uid', case when o.firebase_uid = 'walk-in' then null else o.firebase_uid end,
        'customer_name', case when o.firebase_uid = 'walk-in' then 'Walk-in' else nullif(cp.full_name, '') end,
        'is_pos', exists (select 1 from public.pos_sales ps where ps.order_id = o.id),
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'product_name', i.product_name, 'variant_label', i.variant_label,
                    'quantity', i.quantity, 'unit_price', i.unit_price)), '[]'::jsonb)
                  from public.order_items i where i.order_id = o.id),
        'downpayment', (select jsonb_build_object('amount', dpx.amount, 'status', dpx.status, 'method', dpx.method, 'paid_at', dpx.paid_at)
                          from public.order_downpayments dpx where dpx.order_id = o.id),
        'payment', (select jsonb_build_object('id', pay.id, 'method', pay.method, 'status', pay.status,
                                              'reference_number', pay.reference_number, 'amount', pay.amount,
                                              'updated_at', pay.updated_at)
                    from public.payments pay where pay.order_id = o.id
                    order by pay.created_at desc limit 1),
        'refund_summary', public._order_refund_json(o.id),
        'refund', case when v_refunds then (
                    select jsonb_build_object('id', r.id, 'status', r.status, 'amount', r.amount,
                                              'reason', r.reason, 'notes', r.notes,
                                              'payment_method', r.payment_method,
                                              'created_at', r.created_at, 'updated_at', r.updated_at)
                    from public.refund_requests r where r.order_id = o.id
                    order by r.created_at desc limit 1) end
      ) as j
    from (
      select o2.id, row_number() over (
               order by
                 case when v_sort = 'created_at' and v_desc then o2.created_at end desc nulls last,
                 case when v_sort = 'created_at' and not v_desc then o2.created_at end asc nulls last,
                 case when v_sort = 'total' and v_desc then o2.total end desc nulls last,
                 case when v_sort = 'total' and not v_desc then o2.total end asc nulls last,
                 case when v_sort = 'status' and v_desc then o2.status end desc nulls last,
                 case when v_sort = 'status' and not v_desc then o2.status end asc nulls last,
                 case when v_desc then o2.id end desc,
                 case when not v_desc then o2.id end asc) as rn
        from public.orders o2
        left join public.customer_profiles cp2 on cp2.firebase_uid = o2.firebase_uid
       where o2.branch_id = any (v_branches)
         and o2.created_at >= p_from and o2.created_at <= p_to
         and (p_status is null or o2.status = p_status)
         and (p_payment_method is null or o2.payment_method = p_payment_method)
         and (v_q is null
              or lower(o2.id) like '%' || v_q || '%'
              or lower(coalesce(cp2.full_name, '')) like '%' || v_q || '%'
              or lower(coalesce(o2.branch_name, '')) like '%' || v_q || '%')
       order by rn
       limit v_limit offset v_offset
    ) pg
    join public.orders o on o.id = pg.id
    left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
  ) x;

  return jsonb_build_object('rows', v_rows, 'total', v_total, 'limit', v_limit, 'offset', v_offset,
                            'sort', v_sort, 'dir', case when v_desc then 'desc' else 'asc' end);
end;
$$;


commit;
