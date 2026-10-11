-- =============================================================================
-- Melai Nuts — Migration 20261023000000: customer features
-- =============================================================================
-- Run after 20261022000000_warehouse.sql. Idempotent, one transaction.
--
--   1. "Only N left": business_settings.low_stock_badge_qty (owner setting; Not set =
--      never shown). Customers read it through get_storefront_settings(); the count
--      itself is the real branch_inventory quantity the catalogue already reads.
--   2. Favourites: customer_favorites, only through toggle_favorite / get_my_favorites
--      (a customer sees and changes only their own).
--   3. Order-ready alerts: notify_on_order_status() now writes a clear message per
--      status ("ready for pickup", ...). Each notification is pushed by the outbox
--      from 20261021000000, so the customer's phone gets it.
--   (Reorder needs no new SQL: order_items already carry product_id / variant_id,
--    readable only by the customer who placed the order; the app matches on them.)
-- =============================================================================
begin;

-- 1. ---------------------------------------------------------------------------
alter table public.business_settings add column if not exists low_stock_badge_qty int;
alter table public.business_settings drop constraint if exists business_settings_low_stock_badge_qty_check;
alter table public.business_settings add constraint business_settings_low_stock_badge_qty_check
  check (low_stock_badge_qty is null or low_stock_badge_qty between 1 and 1000);

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
revoke all on function public.get_business_settings() from public, anon;
grant execute on function public.get_business_settings() to authenticated;

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
                          'low_stock_badge_qty'];
begin
  v_owner := public._require_owner();
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then
    raise exception 'Settings must be an object.';
  end if;
  for k in select jsonb_object_keys(p_settings) loop
    if not (k = any(allowed)) then raise exception 'Unknown setting: %', k; end if;
    if jsonb_typeof(p_settings -> k) not in ('number', 'null') then raise exception 'Setting % must be a number or empty.', k; end if;
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
      carried_over = false,
      updated_at = now(),
      updated_by = v_owner.firebase_uid
    where id = 'default';
  exception when check_violation then
    raise exception 'A setting is out of range (ratios: low must be below plenty / high; margin 1-99%%; threshold 0-100,000; targets above 0; expiry alerts 1-365 days; "only N left" 1-1,000).';
  end;

  perform public._write_audit(v_owner.firebase_uid, null, 'business.settings_updated', 'business_settings', 'default',
    jsonb_build_object('before', to_jsonb(v_old) - 'updated_at' - 'updated_by',
                       'after', p_settings));
  return public.get_business_settings();
end;
$$;
revoke all on function public.owner_update_business_settings(jsonb) from public, anon;
grant execute on function public.owner_update_business_settings(jsonb) to authenticated;

-- Public, non-sensitive storefront switches (also for signed-out browsing).
create or replace function public.get_storefront_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('low_stock_badge_qty',
           (select low_stock_badge_qty from public.business_settings where id = 'default'))
$$;
revoke all on function public.get_storefront_settings() from public;
grant execute on function public.get_storefront_settings() to anon, authenticated;

-- 2. ---------------------------------------------------------------------------
create table if not exists public.customer_favorites (
  firebase_uid text not null references public.customer_profiles(firebase_uid) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (firebase_uid, product_id)
);
alter table public.customer_favorites enable row level security;
revoke all on public.customer_favorites from anon, authenticated;

-- Returns true when the product is now a favourite, false when it was removed.
create or replace function public.toggle_favorite(p_product_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
begin
  if v_uid is null then raise exception 'Please sign in to save favourites.'; end if;
  if not exists (select 1 from public.customer_profiles where firebase_uid = v_uid) then
    raise exception 'Please finish setting up your profile first.';
  end if;
  delete from public.customer_favorites where firebase_uid = v_uid and product_id = p_product_id;
  if found then return false; end if;
  if not exists (select 1 from public.products where id = p_product_id and is_active) then
    raise exception 'This product is no longer available.';
  end if;
  if (select count(*) from public.customer_favorites where firebase_uid = v_uid) >= 500 then
    raise exception 'You can save up to 500 favourites.';
  end if;
  insert into public.customer_favorites (firebase_uid, product_id) values (v_uid, p_product_id);
  return true;
end;
$$;
revoke all on function public.toggle_favorite(uuid) from public, anon;
grant execute on function public.toggle_favorite(uuid) to authenticated;

create or replace function public.get_my_favorites()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(f.product_id order by f.created_at desc), '[]'::jsonb)
    from public.customer_favorites f
    join public.products p on p.id = f.product_id and p.is_active
   where f.firebase_uid = public.current_firebase_uid()
$$;
revoke all on function public.get_my_favorites() from public, anon;
grant execute on function public.get_my_favorites() to authenticated;

-- 3. ---------------------------------------------------------------------------
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
          v_body := 'You can pick it up now' || coalesce(' at ' || v_branch, '') || '.';
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
revoke all on function public.notify_on_order_status() from public, anon, authenticated;

commit;
