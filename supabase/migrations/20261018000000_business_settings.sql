-- =============================================================================
-- Melai Nuts — Migration 20261018000000: owner-editable business settings
-- =============================================================================
-- Run after 20261017000000_online_payment_switch.sql. Idempotent, one transaction.
--
-- WHY
--   Several business rules were constants in code: the restock threshold
--   fallback (20, in _default_restock_threshold()), the loyalty earn-rate
--   fallback (1 pt per PHP 50), stock-health and sales-rating ratios and daily
--   sales targets (admin config/melai.php), the "healthy margin" line (50 %,
--   app product screens) and the online-payment "unavailable" text. They are
--   now settings the owner edits (admin website > Settings > Business settings)
--   and that nobody else can change.
--
-- RULES
--   * A setting that was never entered is NULL and is shown as "Not set". No
--     value is invented: without an earn rate no points are earned, without a
--     restock threshold no "low stock" warning is raised (out-of-stock still is),
--     without a target a branch shows "No target set".
--   * On a NEW, empty project this migration creates structure only.
--   * On an EXISTING project that already holds stock (i.e. it ran with the old
--     built-in values), the old values are carried over ONCE, flagged
--     `carried_over = true`, so behaviour does not change silently; the admin
--     page asks the owner to confirm or change them. Re-running never
--     overwrites a value the owner saved.
--   * branches.delivery_fee loses its default of 0: a new branch must be given
--     its real delivery fee (0 only if delivery really is free).
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1. Settings table (single row 'default'; every value nullable = "Not set")
-- -----------------------------------------------------------------------------
create table if not exists public.business_settings (
  id text primary key default 'default' check (id = 'default'),
  restock_threshold_default int check (restock_threshold_default is null or restock_threshold_default between 0 and 100000),
  stock_low_ratio numeric(4, 3) check (stock_low_ratio is null or (stock_low_ratio > 0 and stock_low_ratio < 1)),
  stock_plenty_ratio numeric(4, 3) check (stock_plenty_ratio is null or (stock_plenty_ratio > 0 and stock_plenty_ratio <= 1)),
  sales_low_ratio numeric(5, 3) check (sales_low_ratio is null or (sales_low_ratio > 0 and sales_low_ratio <= 10)),
  sales_high_ratio numeric(5, 3) check (sales_high_ratio is null or (sales_high_ratio > 0 and sales_high_ratio <= 10)),
  default_daily_sales_target numeric(12, 2) check (default_daily_sales_target is null or default_daily_sales_target > 0),
  healthy_margin_percent numeric(5, 2) check (healthy_margin_percent is null or (healthy_margin_percent > 0 and healthy_margin_percent < 100)),
  expiry_alert_days int check (expiry_alert_days is null or expiry_alert_days between 1 and 365),
  carried_over boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by text,
  constraint business_settings_stock_order check (stock_low_ratio is null or stock_plenty_ratio is null or stock_low_ratio < stock_plenty_ratio),
  constraint business_settings_sales_order check (sales_low_ratio is null or sales_high_ratio is null or sales_low_ratio <= sales_high_ratio)
);
alter table public.business_settings enable row level security;
-- No direct table access for the API roles: reads and writes go through the functions below.
revoke all on public.business_settings from anon, authenticated;

-- Per-branch daily sales target (null = use the default target, or "No target set").
alter table public.branches add column if not exists daily_sales_target numeric(12, 2);
alter table public.branches drop constraint if exists branches_daily_sales_target_check;
alter table public.branches add constraint branches_daily_sales_target_check
  check (daily_sales_target is null or daily_sales_target > 0);

-- A branch's delivery fee must be entered, never assumed to be 0.
alter table public.branches alter column delivery_fee drop default;

-- Online payment "unavailable" text lives in the database (the app and the
-- order trigger read it), so it is changed in one place.
alter table public.payment_settings add column if not exists online_payment_disabled_message text;
update public.payment_settings
   set online_payment_disabled_message = 'Online payment is temporarily unavailable. Please choose Cash on Delivery or Cash on Counter Pickup.'
 where id = 'default' and online_payment_disabled_message is null;

-- Carry the old built-in values over ONCE, only on a database that already ran with them.
insert into public.business_settings
  (id, restock_threshold_default, stock_low_ratio, stock_plenty_ratio, sales_low_ratio, sales_high_ratio,
   healthy_margin_percent, carried_over)
select 'default', 20, 0.4, 0.8, 0.7, 1.0, 50, true
where exists (select 1 from public.branch_inventory)
on conflict (id) do nothing;

-- -----------------------------------------------------------------------------
-- 2. Loyalty earn rate: no invented fallback
-- -----------------------------------------------------------------------------
alter table public.loyalty_cart_settings alter column earn_pesos_per_point drop not null;
alter table public.loyalty_cart_settings alter column earn_pesos_per_point drop default;

-- Points earned on an order: floor(total / earn rate). No rate set = 0 points.
create or replace function public.compute_points_earned()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rate numeric;
begin
  select earn_pesos_per_point into v_rate from public.loyalty_cart_settings where id = 'default';
  if v_rate is null or v_rate < 1 then
    new.points_earned := 0;
  else
    new.points_earned := greatest(0, floor(new.total / v_rate)::int);
  end if;
  return new;
end;
$$;

-- NULL when the owner has not set an earn rate (the app shows "Not set").
create or replace function public.get_loyalty_earn_rate()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select earn_pesos_per_point from public.loyalty_cart_settings where id = 'default'
$$;
revoke all on function public.get_loyalty_earn_rate() from public;
grant execute on function public.get_loyalty_earn_rate() to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. Restock threshold fallback reads the setting (NULL = not set)
-- -----------------------------------------------------------------------------
create or replace function public._default_restock_threshold()
returns int
language sql
stable
security definer
set search_path = public
as $$ select restock_threshold_default from public.business_settings where id = 'default' $$;

-- -----------------------------------------------------------------------------
-- 4. Online payment trigger uses the database text
-- -----------------------------------------------------------------------------
create or replace function public.online_payment_disabled_message()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(trim((select online_payment_disabled_message from public.payment_settings where id = 'default')), ''),
                  'Online payment is unavailable.')
$$;
revoke all on function public.online_payment_disabled_message() from public;
grant execute on function public.online_payment_disabled_message() to anon, authenticated, service_role;

create or replace function public._trg_orders_online_payment_switch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.payment_method in ('Online Payment (GCash, Maya, Card)', 'GCash E-Wallet', 'Maya / Credit Card')
     and not public.online_payment_enabled() then
    raise exception '%', public.online_payment_disabled_message();
  end if;
  return new;
end;
$$;
revoke all on function public._trg_orders_online_payment_switch() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5. Read: settings + branches (staff: their own branch; owner: all)
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 6. Owner-only writes (audited)
-- -----------------------------------------------------------------------------
-- p_settings keys (all optional; a key present with JSON null clears the value):
--   restock_threshold_default, stock_low_ratio, stock_plenty_ratio, sales_low_ratio,
--   sales_high_ratio, default_daily_sales_target, healthy_margin_percent, expiry_alert_days
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
                          'sales_high_ratio', 'default_daily_sales_target', 'healthy_margin_percent', 'expiry_alert_days'];
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
      carried_over = false,
      updated_at = now(),
      updated_by = v_owner.firebase_uid
    where id = 'default';
  exception when check_violation then
    raise exception 'A setting is out of range (ratios: low must be below plenty / high; margin 1-99%%; threshold 0-100,000; targets above 0; expiry alerts 1-365 days).';
  end;

  perform public._write_audit(v_owner.firebase_uid, null, 'business.settings_updated', 'business_settings', 'default',
    jsonb_build_object('before', to_jsonb(v_old) - 'updated_at' - 'updated_by',
                       'after', p_settings));
  return public.get_business_settings();
end;
$$;
revoke all on function public.owner_update_business_settings(jsonb) from public, anon;
grant execute on function public.owner_update_business_settings(jsonb) to authenticated;

-- Create (p_branch_id null) or update a branch's customer-facing details.
create or replace function public.owner_save_branch(
  p_branch_id uuid,
  p_name text,
  p_address text,
  p_contact_phone text,
  p_operating_hours text,
  p_delivery_fee numeric,
  p_daily_sales_target numeric,
  p_supports_delivery boolean,
  p_supports_pickup boolean,
  p_is_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
  v_id uuid := p_branch_id;
  v_name text := trim(coalesce(p_name, ''));
  v_before jsonb;
begin
  v_owner := public._require_owner();
  if v_name = '' or length(v_name) > 80 then raise exception 'Enter the branch name (up to 80 characters).'; end if;
  if p_delivery_fee is null then raise exception 'Enter the delivery fee (0 if delivery is free).'; end if;
  if p_delivery_fee < 0 or p_delivery_fee > 100000 then raise exception 'Delivery fee must be between 0 and 100,000.'; end if;
  if p_daily_sales_target is not null and p_daily_sales_target <= 0 then
    raise exception 'A daily sales target must be more than 0 (leave it empty for none).';
  end if;
  if length(coalesce(p_address, '')) > 300 or length(coalesce(p_contact_phone, '')) > 40
     or length(coalesce(p_operating_hours, '')) > 200 then
    raise exception 'Address, phone or hours is too long.';
  end if;

  if v_id is null then
    insert into public.branches (name, address, contact_phone, operating_hours, delivery_fee, daily_sales_target,
                                 supports_delivery, supports_pickup, is_active)
    values (v_name, nullif(trim(coalesce(p_address, '')), ''), nullif(trim(coalesce(p_contact_phone, '')), ''),
            nullif(trim(coalesce(p_operating_hours, '')), ''), p_delivery_fee, p_daily_sales_target,
            coalesce(p_supports_delivery, false), coalesce(p_supports_pickup, false), coalesce(p_is_active, true))
    returning id into v_id;
  else
    select to_jsonb(b) into v_before from public.branches b where id = v_id for update;
    if v_before is null then raise exception 'That branch could not be found.'; end if;
    update public.branches set
      name = v_name,
      address = nullif(trim(coalesce(p_address, '')), ''),
      contact_phone = nullif(trim(coalesce(p_contact_phone, '')), ''),
      operating_hours = nullif(trim(coalesce(p_operating_hours, '')), ''),
      delivery_fee = p_delivery_fee,
      daily_sales_target = p_daily_sales_target,
      supports_delivery = coalesce(p_supports_delivery, supports_delivery),
      supports_pickup = coalesce(p_supports_pickup, supports_pickup),
      is_active = coalesce(p_is_active, is_active)
    where id = v_id;
  end if;

  perform public._write_audit(v_owner.firebase_uid, v_id, case when p_branch_id is null then 'branch.created' else 'branch.updated' end,
    'branch', v_id::text, jsonb_build_object('before', v_before,
      'after', (select to_jsonb(b) from public.branches b where b.id = v_id)));
  return jsonb_build_object('id', v_id);
exception
  when unique_violation then
    raise exception 'Another branch already has the name %.', v_name;
  when check_violation then
    raise exception 'A warehouse cannot take deliveries or pickups (or a value is out of range).';
end;
$$;
revoke all on function public.owner_save_branch(uuid, text, text, text, text, numeric, numeric, boolean, boolean, boolean) from public, anon;
grant execute on function public.owner_save_branch(uuid, text, text, text, text, numeric, numeric, boolean, boolean, boolean) to authenticated;

commit;
