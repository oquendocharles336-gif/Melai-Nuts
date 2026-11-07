-- =============================================================================
-- Melai Nuts — Migration 20261107120000: a time limit on customer refund requests
-- =============================================================================
-- Run after 20261102090000_owner_only_online_paid.sql. Idempotent.
--
-- The owner approved "customers can request a refund within 7 days after pickup"
-- (Terms section 4, docs/owner-approval.md). Like every business value, the number
-- is typed by the owner on the admin website (Business settings > "Customers can
-- request a refund within (days)"). Not set = no limit, exactly as before.
--
-- PICKUP is the FIRST time the order became Completed (order_status_events). A
-- rejected refund puts the order back to Completed; that must not restart the
-- window, so the first time is used. An order with no Completed event (older than
-- the history table) counts from when it was placed.
--
-- A rejected request can be sent again, but only inside the same window.
-- Staff counter returns (POS) are not limited: this is only the customer's own
-- request in the app.
-- =============================================================================
begin;

-- 1. The setting --------------------------------------------------------------------
alter table public.business_settings add column if not exists refund_request_days int;
alter table public.business_settings drop constraint if exists business_settings_refund_request_days_check;
alter table public.business_settings add constraint business_settings_refund_request_days_check
  check (refund_request_days is null or refund_request_days between 1 and 365);

-- 2. When an order was picked up, and until when it can be refunded -------------------
create or replace function public._order_picked_up_at(p_order_id text)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select min(e.created_at) from public.order_status_events e
      where e.order_id = p_order_id and e.status = 'completed'),
    (select o.created_at from public.orders o where o.id = p_order_id));
$$;
revoke all on function public._order_picked_up_at(text) from public, anon, authenticated;

-- The app reads this to hide "Request Refund" once the window has passed.
-- request_refund checks it again on the server.
create or replace function public.refund_request_days()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select s.refund_request_days from public.business_settings s where s.id = 'default';
$$;
revoke all on function public.refund_request_days() from public, anon;
grant execute on function public.refund_request_days() to authenticated;

-- 3. request_refund: unchanged except the window check after the status check ---------
create or replace function public.request_refund(
  p_order_id text,
  p_reason text,
  p_notes text default '',
  p_items jsonb default '[]'::jsonb
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_order record;
  v_req record;
  v_line record;
  v_refund_id text;
  v_items_total numeric := 0;
  v_ratio numeric := 1;
  v_amount numeric;
  v_days int;
  v_picked_up timestamptz;
begin
  if v_uid is null then raise exception 'Please sign in to request a refund.'; end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'Please choose a reason for the refund.'; end if;
  if length(p_reason) > 200 or length(coalesce(p_notes, '')) > 1000 then
    raise exception 'The reason or notes are too long.';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Select at least one item to refund.';
  end if;

  -- "Not found" is deliberately identical for missing and other people's orders.
  select * into v_order from public.orders
  where id = p_order_id and firebase_uid = v_uid
  for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.status <> 'completed' then raise exception 'Only completed orders can be refunded.'; end if;

  v_days := public.refund_request_days();
  if v_days is not null then
    v_picked_up := public._order_picked_up_at(v_order.id);
    if now() > v_picked_up + make_interval(days => v_days) then
      raise exception 'Refunds can only be requested within % days after pickup. This order was picked up on %.',
        v_days, to_char(v_picked_up at time zone 'Asia/Manila', 'FMMonth FMDD, YYYY');
    end if;
  end if;

  if exists (select 1 from public.refund_requests r where r.order_id = v_order.id and r.status <> 'rejected') then
    raise exception 'A refund request already exists for this order.';
  end if;

  for v_req in
    select trim(e ->> 'product_name') as product_name,
           coalesce(nullif(trim(e ->> 'variant_label'), ''), 'Regular') as variant_label,
           sum((e ->> 'quantity')::int)::int as quantity
    from jsonb_array_elements(p_items) e
    group by 1, 2
  loop
    if v_req.quantity is null or v_req.quantity <= 0 then
      raise exception 'Refund quantities must be greater than zero.';
    end if;

    select sum(oi.quantity)::int as qty, max(oi.unit_price) as unit_price into v_line
    from public.order_items oi
    where oi.order_id = v_order.id
      and oi.product_name = v_req.product_name
      and oi.variant_label = v_req.variant_label;

    if v_line.qty is null then
      raise exception '% is not part of this order.', v_req.product_name;
    end if;
    if v_req.quantity > v_line.qty then
      raise exception 'You can refund at most % of %.', v_line.qty, v_req.product_name;
    end if;
    v_items_total := v_items_total + v_req.quantity * v_line.unit_price;
  end loop;

  if v_order.subtotal > 0 then
    v_ratio := greatest(0, v_order.subtotal - v_order.discount) / v_order.subtotal;
  end if;
  v_amount := least(round(v_items_total * v_ratio, 2), v_order.total);
  if v_amount <= 0 then raise exception 'This order has nothing left to refund.'; end if;

  insert into public.refund_requests (order_id, firebase_uid, reason, notes, amount, payment_method)
  values (v_order.id, v_uid, trim(p_reason), coalesce(trim(p_notes), ''), v_amount, v_order.payment_method)
  returning id into v_refund_id;

  insert into public.refund_items (refund_request_id, product_name, variant_label, quantity, unit_price)
  select v_refund_id, r.product_name, r.variant_label, r.quantity,
         (select max(oi.unit_price) from public.order_items oi
          where oi.order_id = v_order.id
            and oi.product_name = r.product_name
            and oi.variant_label = r.variant_label)
  from (
    select trim(e ->> 'product_name') as product_name,
           coalesce(nullif(trim(e ->> 'variant_label'), ''), 'Regular') as variant_label,
           sum((e ->> 'quantity')::int)::int as quantity
    from jsonb_array_elements(p_items) e
    group by 1, 2
  ) r;

  return v_refund_id;
end;
$$;
-- create or replace keeps the existing grant (authenticated only).

-- 4. Business settings: read and save the new value ------------------------------------
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
    'refund_request_days', s.refund_request_days,
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
                          'cod_downpayment_min_order', 'cod_downpayment_expiry_minutes', 'cod_downpayment_pickup_days',
                          'refund_request_days'];
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
  if p_settings ? 'refund_request_days' then
    v_new.refund_request_days := (p_settings ->> 'refund_request_days')::numeric::int; end if;
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
      refund_request_days = v_new.refund_request_days,
      carried_over = false,
      updated_at = now(),
      updated_by = v_owner.firebase_uid
    where id = 'default';
  exception when check_violation then
    raise exception 'A setting is out of range (ratios: low must be below plenty / high; margin 1-99%%; threshold 0-100,000; targets above 0; expiry alerts 1-365 days; "only N left" 1-1,000; downpayment above 0, a percent below 100, time limit 5-1,440 minutes; pickup 1-30 days; refund requests 1-365 days).';
  end;

  perform public._write_audit(v_owner.firebase_uid, null, 'business.settings_updated', 'business_settings', 'default',
    jsonb_build_object('before', to_jsonb(v_old) - 'updated_at' - 'updated_by',
                       'after', p_settings));
  return public.get_business_settings();
end;
$$;

notify pgrst, 'reload schema';

commit;
