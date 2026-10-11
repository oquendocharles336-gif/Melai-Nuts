-- =============================================================================
-- Melai Nuts — Migration 20260928000000
-- Customer-side security hardening, integrity fixes and indexes
-- =============================================================================
-- RUN ORDER:  supabase/schema.sql  ->  this file  ->  supabase/tests/*.sql
-- Safe to re-run (idempotent) and atomic (one transaction: all or nothing).
--
-- This builds ON the existing schema (no duplicate tables). What it fixes:
--
--  SECURITY
--   1. Customers could WRITE payment / refund / cart rows straight through the
--      Data API. Every money- or points-affecting write now goes through a
--      server-side function; the customer roles get read-only table access.
--   2. notify_customer() (SECURITY DEFINER) was executable by anyone, letting
--      any caller inject notifications into any customer's inbox. All function
--      EXECUTE grants are now explicit allow-lists.
--   3. Profile creation now requires a *verified* email that matches the token
--      (enforces at the database what the Firestore rules already enforce).
--   4. Product cost price (COGS) was publicly readable; moved to a private table.
--   5. Column-level privileges: customers can edit only name/phone/default
--      branch on their profile, and only `read` on a notification.
--   6. Policies are scoped `TO authenticated` (fail-closed) instead of PUBLIC.
--
--  INTEGRITY
--   7. Refund submission was BROKEN (a trigger wrote to a table with no INSERT
--      policy). Replaced by request_refund(): the server checks ownership,
--      eligibility and computes the amount; the client cannot choose it.
--   8. Loyalty points were awarded when an order was merely PLACED, so a
--      customer could farm points with cash orders they never collect. Points
--      are now awarded when the order is COMPLETED, returned when a redeemed
--      order is cancelled, and clawed back when an order is refunded.
--   9. Cancelling an order now restores stock, redeemed points and the voucher.
--  10. One payment per order (unique index); duplicates made the Flutter
--      `.maybeSingle()` payment lookup throw.
--  11. voucher_usage + per_customer_limit: per-customer voucher accounting.
--  12. orders/refund_requests added to the realtime publication (the app
--      streams both; without this live tracking never updates).
--
--  PERFORMANCE
--  13. Indexes for firebase_uid, order/branch/product/category ids, status and
--      created_at (none existed apart from primary/unique keys).
--
-- NOTE: after this migration new tables are NOT auto-exposed to the Data API
-- (default privileges are revoked below, fail-closed). When you add a table the
-- app must read, `grant` it explicitly and add a policy.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 0. Helpers
-- -----------------------------------------------------------------------------

-- True only when the Firebase ID token says the email address was verified.
-- Firebase sets `email_verified`; a client cannot forge it.
create or replace function public.jwt_email_verified()
returns boolean
language sql
stable
as $$
  select coalesce(nullif(auth.jwt() ->> 'email_verified', '')::boolean, false)
$$;

-- -----------------------------------------------------------------------------
-- 1. New structures
-- -----------------------------------------------------------------------------

-- 1a. Cost of goods sold, moved out of the publicly-readable product_variants.
--     RLS is enabled with NO policy: only the service role / table owner (future
--     staff & owner tooling on a trusted backend) can read or write it.
create table if not exists public.product_variant_costs (
  variant_id uuid primary key references public.product_variants(id) on delete cascade,
  cost_price numeric(10, 2) not null check (cost_price >= 0),
  updated_at timestamptz not null default now()
);
alter table public.product_variant_costs enable row level security;

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'product_variants' and column_name = 'cost_price') then
    insert into public.product_variant_costs (variant_id, cost_price)
    select id, cost_price from public.product_variants
    where cost_price is not null and cost_price >= 0
    on conflict (variant_id) do nothing;
    alter table public.product_variants drop column cost_price;
  end if;
end $$;

-- 1b. Order lines remember which product/variant they came from, so a cancelled
--     order can put stock back (previously only the display name was kept).
alter table public.order_items
  add column if not exists product_id uuid references public.products(id) on delete set null;
alter table public.order_items
  add column if not exists variant_id uuid references public.product_variants(id) on delete set null;

-- Best-effort backfill for orders placed before this migration (exact matches only).
update public.order_items oi
set product_id = p.id
from public.products p
where oi.product_id is null and p.name = oi.product_name;

update public.order_items oi
set variant_id = v.id
from public.product_variants v
where oi.variant_id is null and oi.product_id = v.product_id and v.label = oi.variant_label;

-- 1c. Loyalty ledger: say WHY a row exists so triggers can be idempotent.
alter table public.loyalty_transactions add column if not exists source text;
alter table public.loyalty_transactions drop constraint if exists loyalty_transactions_source_check;
alter table public.loyalty_transactions add constraint loyalty_transactions_source_check
  check (source is null or source in ('order_earn', 'order_redeem', 'order_return', 'order_clawback'));

update public.loyalty_transactions set source = 'order_earn'
where source is null and type = 'earn' and order_id is not null;
update public.loyalty_transactions set source = 'order_redeem'
where source is null and type = 'redeem' and order_id is not null;

create unique index if not exists loyalty_tx_one_earn_per_order
  on public.loyalty_transactions (order_id) where source = 'order_earn';

-- 1d. Per-customer voucher accounting. `per_customer_limit` NULL = unlimited
--     (preserves current behaviour); set it (e.g. 1) on welcome/one-time codes.
alter table public.vouchers
  add column if not exists per_customer_limit int
  check (per_customer_limit is null or per_customer_limit > 0);

create table if not exists public.voucher_usage (
  id uuid primary key default gen_random_uuid(),
  voucher_id uuid not null references public.vouchers(id),
  firebase_uid text not null references public.customer_profiles(firebase_uid),
  order_id text not null references public.orders(id) on delete cascade,
  discount_amount numeric(10, 2) not null check (discount_amount >= 0),
  created_at timestamptz not null default now(),
  unique (order_id)
);
alter table public.voucher_usage enable row level security;

-- -----------------------------------------------------------------------------
-- 2. Integrity constraints
-- -----------------------------------------------------------------------------

-- Duplicate PENDING payments (created by the old client-side insert on top of
-- the one place_order already makes) are removed, keeping the earliest.
delete from public.payments p
using public.payments keep
where p.order_id = keep.order_id
  and p.id <> keep.id
  and p.status = 'pending'
  and (keep.created_at < p.created_at or (keep.created_at = p.created_at and keep.id < p.id));

do $$
begin
  create unique index if not exists payments_one_per_order on public.payments (order_id);
exception when unique_violation then
  raise warning 'payments_one_per_order NOT created: some order still has several non-pending payments. Resolve them manually and re-run.';
end $$;

do $$
begin
  create unique index if not exists refund_requests_one_open_per_order
    on public.refund_requests (order_id) where (status <> 'rejected');
exception when unique_violation then
  raise warning 'refund_requests_one_open_per_order NOT created: an order has several open refunds. Resolve manually and re-run.';
end $$;

do $$
begin
  create unique index if not exists customer_profiles_rfid_key
    on public.customer_profiles (rfid_card_number) where (rfid_card_number is not null);
exception when unique_violation then
  raise warning 'customer_profiles_rfid_key NOT created: an RFID card is linked to several customers. Resolve manually and re-run.';
end $$;

do $$
begin
  create unique index if not exists vouchers_code_upper_key on public.vouchers (upper(code));
exception when unique_violation then
  raise warning 'vouchers_code_upper_key NOT created: voucher codes differ only by letter case.';
end $$;

-- -----------------------------------------------------------------------------
-- 3. Indexes  (customer/firebase uid, order, branch, product, category,
--              status, created_at). Primary/unique keys already cover their
--              own columns; these cover the app's real access paths.
-- -----------------------------------------------------------------------------

-- customers
create index if not exists customer_profiles_default_branch_idx on public.customer_profiles (default_branch_id);
create index if not exists customer_addresses_uid_idx           on public.customer_addresses (firebase_uid);

-- catalog
create index if not exists product_categories_active_sort_idx   on public.product_categories (sort_order) where is_active;
create index if not exists products_category_idx                on public.products (category_id);
create index if not exists products_active_idx                  on public.products (name) where is_active;
create index if not exists products_featured_idx                on public.products (name) where is_active and is_featured;
create index if not exists products_created_idx                 on public.products (created_at desc);
create index if not exists products_name_idx                    on public.products (name);      -- get_popular_products joins on name
create index if not exists product_variants_product_idx         on public.product_variants (product_id, sort_order);
create index if not exists branch_inventory_product_idx         on public.branch_inventory (product_id);
create index if not exists branch_inventory_variant_idx         on public.branch_inventory (variant_id);
create index if not exists rewards_active_idx                   on public.rewards (points_required) where is_active;
create index if not exists promotions_active_idx                on public.promotions (sort_order) where is_active;

-- carts
create index if not exists carts_uid_status_idx                 on public.carts (firebase_uid, status);
create index if not exists carts_branch_idx                     on public.carts (branch_id);
create index if not exists cart_items_cart_idx                  on public.cart_items (cart_id);
create index if not exists cart_items_product_idx               on public.cart_items (product_id);
create index if not exists cart_items_variant_idx               on public.cart_items (variant_id);

-- orders
create index if not exists orders_uid_created_idx               on public.orders (firebase_uid, created_at desc);
create index if not exists orders_branch_idx                    on public.orders (branch_id);
create index if not exists orders_status_idx                    on public.orders (status);
create index if not exists orders_created_idx                   on public.orders (created_at desc);
create index if not exists orders_delivery_address_idx          on public.orders (delivery_address_id);
create index if not exists order_items_order_idx                on public.order_items (order_id);
create index if not exists order_items_product_idx              on public.order_items (product_id);
create index if not exists order_items_variant_idx              on public.order_items (variant_id);
create index if not exists order_status_events_order_idx        on public.order_status_events (order_id, created_at);

-- payments
create index if not exists payments_uid_created_idx             on public.payments (firebase_uid, created_at desc);
create index if not exists payments_status_idx                  on public.payments (status);

-- refunds
create index if not exists refund_requests_uid_created_idx      on public.refund_requests (firebase_uid, created_at desc);
create index if not exists refund_requests_order_idx            on public.refund_requests (order_id);
create index if not exists refund_requests_status_idx           on public.refund_requests (status);
create index if not exists refund_items_refund_idx              on public.refund_items (refund_request_id);
create index if not exists refund_status_events_refund_idx      on public.refund_status_events (refund_request_id, created_at);

-- loyalty
create index if not exists loyalty_tx_uid_created_idx           on public.loyalty_transactions (firebase_uid, created_at desc);
create index if not exists loyalty_tx_order_idx                 on public.loyalty_transactions (order_id);
create index if not exists reward_redemptions_uid_idx           on public.reward_redemptions (firebase_uid, created_at desc);
create index if not exists reward_redemptions_reward_idx        on public.reward_redemptions (reward_id);

-- vouchers
create index if not exists vouchers_active_idx                  on public.vouchers (is_active);
create index if not exists voucher_usage_uid_idx                on public.voucher_usage (firebase_uid);
create index if not exists voucher_usage_voucher_idx            on public.voucher_usage (voucher_id, firebase_uid);

-- notifications
create index if not exists notifications_uid_created_idx        on public.notifications (firebase_uid, created_at desc);
create index if not exists notifications_unread_idx             on public.notifications (firebase_uid) where not read;

-- -----------------------------------------------------------------------------
-- 4. Trigger / lifecycle fixes
-- -----------------------------------------------------------------------------

-- 4a. These two history triggers fired as the CALLING customer and wrote to
--     tables that (correctly) have no customer INSERT policy, which made every
--     refund request fail. History rows are system-written: run as owner.
create or replace function public.log_order_status_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'INSERT') then
    insert into public.order_status_events (order_id, status, note)
    values (new.id, new.status, 'Order placed');
  elsif (new.status is distinct from old.status) then
    insert into public.order_status_events (order_id, status, note)
    values (new.id, new.status, null);
  end if;
  return new;
end;
$$;

create or replace function public.log_refund_status_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'INSERT') then
    insert into public.refund_status_events (refund_request_id, status, note)
    values (new.id, new.status, 'Request submitted');
  elsif (new.status is distinct from old.status) then
    insert into public.refund_status_events (refund_request_id, status, note)
    values (new.id, new.status, null);
  end if;
  return new;
end;
$$;

-- 4b. Points are earned when the order is COMPLETED (fulfilled), not when it is
--     placed. Idempotent: the ledger's unique index allows one 'order_earn' per order.
drop trigger if exists orders_award_points on public.orders;
drop function if exists public.award_order_points();

create or replace function public.award_points_on_completion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.points_earned > 0 and not exists (
       select 1 from public.loyalty_transactions t
       where t.order_id = new.id and t.source = 'order_earn') then
    insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points)
    values (new.firebase_uid, new.points_earned, new.points_earned)
    on conflict (firebase_uid) do update
      set points_balance  = public.loyalty_accounts.points_balance  + excluded.points_balance,
          lifetime_points = public.loyalty_accounts.lifetime_points + excluded.lifetime_points;

    insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
    values (new.firebase_uid, 'earn', new.points_earned, 'Order ' || new.id, new.id, 'order_earn');
  end if;
  return new;
end;
$$;

drop trigger if exists orders_award_points_on_completion on public.orders;
create trigger orders_award_points_on_completion
  after update of status on public.orders
  for each row
  when (new.status = 'completed' and old.status is distinct from new.status)
  execute function public.award_points_on_completion();

-- 4c. Cancelling an order that was never fulfilled puts everything back.
create or replace function public.reverse_order_on_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line record;
  v_points int;
  v_voucher_id uuid;
begin
  -- Only undo orders that never reached the customer.
  if old.status in ('completed', 'refundRequested', 'refunded') then
    return new;
  end if;

  if new.branch_id is not null then
    for v_line in
      select product_id, variant_id, quantity from public.order_items
      where order_id = new.id and product_id is not null and variant_id is not null
    loop
      update public.branch_inventory
      set quantity = quantity + v_line.quantity
      where branch_id = new.branch_id
        and product_id = v_line.product_id
        and variant_id = v_line.variant_id;
    end loop;
  end if;

  select coalesce(-sum(points), 0) into v_points
  from public.loyalty_transactions
  where order_id = new.id and source = 'order_redeem';

  if v_points > 0 and not exists (
       select 1 from public.loyalty_transactions t
       where t.order_id = new.id and t.source = 'order_return') then
    insert into public.loyalty_accounts (firebase_uid, points_balance)
    values (new.firebase_uid, v_points)
    on conflict (firebase_uid) do update
      set points_balance = public.loyalty_accounts.points_balance + excluded.points_balance;

    insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
    values (new.firebase_uid, 'earn', v_points,
            'Points returned - order ' || new.id || ' cancelled', new.id, 'order_return');
  end if;

  delete from public.voucher_usage where order_id = new.id returning voucher_id into v_voucher_id;
  if v_voucher_id is not null then
    update public.vouchers set used_count = greatest(used_count - 1, 0) where id = v_voucher_id;
  end if;

  return new;
end;
$$;

drop trigger if exists orders_reverse_on_cancel on public.orders;
create trigger orders_reverse_on_cancel
  after update of status on public.orders
  for each row
  when (new.status = 'cancelled' and old.status is distinct from new.status)
  execute function public.reverse_order_on_cancel();

-- 4d. A completed refund reverses the points that order earned (never below 0)
--     and marks a successful payment as refunded.
create or replace function public.finalize_order_refund()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_earned int;
  v_take int;
begin
  select coalesce(sum(points), 0) into v_earned
  from public.loyalty_transactions
  where order_id = new.id and source = 'order_earn';

  if v_earned > 0 and not exists (
       select 1 from public.loyalty_transactions t
       where t.order_id = new.id and t.source = 'order_clawback') then
    select least(points_balance, v_earned) into v_take
    from public.loyalty_accounts where firebase_uid = new.firebase_uid for update;

    if coalesce(v_take, 0) > 0 then
      update public.loyalty_accounts
      set points_balance = points_balance - v_take
      where firebase_uid = new.firebase_uid;

      insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
      values (new.firebase_uid, 'redeem', -v_take,
              'Points reversed - order ' || new.id || ' refunded', new.id, 'order_clawback');
    end if;
  end if;

  update public.payments set status = 'refunded'
  where order_id = new.id and status = 'success';

  return new;
end;
$$;

drop trigger if exists orders_finalize_refund on public.orders;
create trigger orders_finalize_refund
  after update of status on public.orders
  for each row
  when (new.status = 'refunded' and old.status is distinct from new.status)
  execute function public.finalize_order_refund();

-- -----------------------------------------------------------------------------
-- 5. Server-side pricing & checkout (replaces the previous definitions)
-- -----------------------------------------------------------------------------

-- Adds the per-customer voucher limit to the price preview so what the customer
-- sees is exactly what place_order() will enforce.
create or replace function public._calculate_cart_pricing(
  p_cart_id uuid,
  p_is_delivery boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_cart record;
  v_subtotal numeric := 0;
  v_voucher_discount numeric := 0;
  v_loyalty_discount numeric := 0;
  v_delivery_fee numeric := 0;
  v_total numeric := 0;
  v_balance int := 0;
  v_points_used int := 0;
  v_voucher record;
  v_settings record;
begin
  if v_uid is null then
    raise exception 'Please sign in to use the shopping cart.';
  end if;

  select c.* into v_cart
  from public.carts c
  where c.id = p_cart_id and c.firebase_uid = v_uid and c.status = 'open';
  if not found then
    raise exception 'Cart not found.';
  end if;

  update public.cart_items ci
  set current_price = pv.price, updated_at = now()
  from public.product_variants pv
  where ci.cart_id = p_cart_id and ci.variant_id = pv.id;

  select coalesce(sum(ci.current_price * ci.quantity), 0)
  into v_subtotal
  from public.cart_items ci
  where ci.cart_id = p_cart_id;

  if v_cart.voucher_code is not null and trim(v_cart.voucher_code) <> '' then
    select * into v_voucher
    from public.vouchers v
    where upper(v.code) = upper(trim(v_cart.voucher_code))
      and v.is_active
      and (v.starts_at is null or v.starts_at <= now())
      and (v.ends_at is null or v.ends_at >= now())
    for update;

    if not found then
      raise exception 'Voucher is invalid or expired.';
    end if;
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

  select points_balance into v_balance
  from public.loyalty_accounts
  where firebase_uid = v_uid;
  v_balance := coalesce(v_balance, 0);

  if v_cart.redeem_points then
    select * into v_settings from public.loyalty_cart_settings where id = 'default';
    if not found then
      raise exception 'Loyalty point redemption is not configured yet.';
    end if;
    if v_balance <= 0 then
      raise exception 'You do not have loyalty points available to redeem.';
    end if;

    v_points_used := least(
      v_balance,
      floor(
        greatest(0, least(
          v_subtotal - v_voucher_discount,
          v_subtotal * v_settings.max_discount_percent / 100
        )) * v_settings.points_per_peso
      )::int
    );
    v_loyalty_discount := round(v_points_used / v_settings.points_per_peso, 2);
  end if;

  if p_is_delivery then
    select delivery_fee into v_delivery_fee
    from public.branches
    where id = v_cart.branch_id and supports_delivery and is_active;
    if not found then
      raise exception 'Delivery is not available for this branch.';
    end if;
  end if;

  v_total := greatest(0, v_subtotal - v_voucher_discount - v_loyalty_discount + v_delivery_fee);

  return jsonb_build_object(
    'cart_id', v_cart.id,
    'branch_id', v_cart.branch_id,
    'voucher_code', v_cart.voucher_code,
    'redeem_points', v_cart.redeem_points,
    'loyalty_points_balance', v_balance,
    'loyalty_points_used', v_points_used,
    'subtotal', round(v_subtotal, 2),
    'voucher_discount', round(v_voucher_discount, 2),
    'loyalty_discount', round(v_loyalty_discount, 2),
    'delivery_fee', round(v_delivery_fee, 2),
    'total', round(v_total, 2)
  );
end;
$$;

-- Checkout. Same contract as before (this is the 5-argument core; the public
-- entry point is the 6-argument idempotent wrapper defined in schema.sql).
-- Changes: rows locked in a fixed order (no deadlocks between two carts),
-- order lines keep product/variant ids, per-customer voucher limit +
-- voucher_usage row, and every loyalty ledger row states its source.
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

  if p_payment_method not in ('GCash E-Wallet', 'Maya / Credit Card', 'Cash on Counter Pickup') then
    raise exception 'Unsupported payment method.';
  end if;
  v_payment_method_code := case p_payment_method
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
-- 6. Server-side refund request
-- -----------------------------------------------------------------------------
-- The client says WHICH order, WHICH lines/quantities and WHY. Ownership,
-- eligibility, unit prices, amount, payment method and initial status are all
-- decided here. Any amount/price/status the client sends is ignored.
--
-- Amount = value of the selected lines, scaled by the share of the order the
-- customer actually paid (so a discounted order is never over-refunded), and
-- never more than the order total. Delivery fees are not refunded here.
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

-- -----------------------------------------------------------------------------
-- 7. Privileges — deny by default, then allow-list
-- -----------------------------------------------------------------------------
-- Supabase auto-grants ALL on every new public table/function to anon and
-- authenticated and relies on RLS alone. Grants are a second, independent gate
-- (defence in depth): even a mistake in a policy cannot let a customer write to
-- a table they were never granted write access to.

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;

do $$
declare r record;
begin
  -- Every function we own, except extension members.
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- Public storefront data (guests may browse).
grant select on
  public.branches, public.product_categories, public.products, public.product_variants,
  public.branch_inventory, public.rewards, public.promotions
to anon, authenticated;

-- A customer's own data. Read-only unless stated: money, stock, points and
-- statuses are only ever changed by server-side functions/triggers.
grant select on
  public.customer_profiles, public.carts, public.cart_items,
  public.orders, public.order_items, public.order_status_events,
  public.payments, public.refund_requests, public.refund_items, public.refund_status_events,
  public.loyalty_accounts, public.loyalty_transactions, public.reward_redemptions,
  public.voucher_usage, public.customer_addresses, public.notification_preferences,
  public.notifications
to authenticated;

grant insert (firebase_uid, full_name, email, phone, default_branch_id) on public.customer_profiles to authenticated;
grant update (full_name, phone, default_branch_id)                      on public.customer_profiles to authenticated;
grant insert, update, delete on public.customer_addresses      to authenticated;
grant insert, update         on public.notification_preferences to authenticated;
grant update (read)          on public.notifications            to authenticated;
grant delete                 on public.notifications            to authenticated;
-- vouchers, loyalty_cart_settings, product_variant_costs: no client access at all.

-- Functions: explicit allow-list. Everything else (notify_customer, the 5-arg
-- place_order, _calculate_cart_pricing, all trigger functions) is internal.
grant execute on function public.current_firebase_uid() to authenticated;
grant execute on function public.jwt_email_verified()   to authenticated;
grant execute on function public.get_customer_cart(uuid)                                    to authenticated;
grant execute on function public.get_cart_pricing(uuid, boolean)                            to authenticated;
grant execute on function public.sync_customer_cart(uuid, jsonb, text, boolean)             to authenticated;
grant execute on function public.place_order(uuid, boolean, uuid, text, text, text)         to authenticated;
grant execute on function public.redeem_reward(uuid)                                        to authenticated;
grant execute on function public.request_refund(text, text, text, jsonb)                    to authenticated;
grant execute on function public.get_popular_products(int)                                  to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 8. Row Level Security policies (rebuilt from scratch, all TO a named role)
-- -----------------------------------------------------------------------------
-- Every policy on the tables managed here is dropped first so a stale permissive
-- policy from an earlier migration can never survive. If you have added
-- custom policies to these tables in the dashboard, re-create them afterwards.

do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
    where schemaname = 'public'
      and tablename in (
        'branches','product_categories','products','product_variants','branch_inventory',
        'rewards','promotions','customer_profiles','customer_addresses','notification_preferences',
        'carts','cart_items','vouchers','loyalty_cart_settings','orders','order_items',
        'order_status_events','payments','refund_requests','refund_items','refund_status_events',
        'loyalty_accounts','loyalty_transactions','reward_redemptions','notifications',
        'voucher_usage','product_variant_costs')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.branches                enable row level security;
alter table public.product_categories      enable row level security;
alter table public.products                enable row level security;
alter table public.product_variants        enable row level security;
alter table public.branch_inventory        enable row level security;
alter table public.rewards                 enable row level security;
alter table public.promotions              enable row level security;
alter table public.customer_profiles       enable row level security;
alter table public.customer_addresses      enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.carts                   enable row level security;
alter table public.cart_items              enable row level security;
alter table public.vouchers                enable row level security;
alter table public.loyalty_cart_settings   enable row level security;
alter table public.orders                  enable row level security;
alter table public.order_items             enable row level security;
alter table public.order_status_events     enable row level security;
alter table public.payments                enable row level security;
alter table public.refund_requests         enable row level security;
alter table public.refund_items            enable row level security;
alter table public.refund_status_events    enable row level security;
alter table public.loyalty_accounts        enable row level security;
alter table public.loyalty_transactions    enable row level security;
alter table public.reward_redemptions      enable row level security;
alter table public.notifications           enable row level security;
alter table public.voucher_usage           enable row level security;
alter table public.product_variant_costs   enable row level security;

-- Storefront (guests + customers). Inactive products/categories stay hidden.
create policy "storefront: branches"    on public.branches           for select to anon, authenticated using (true);
create policy "storefront: categories"  on public.product_categories for select to anon, authenticated using (is_active);
create policy "storefront: products"    on public.products           for select to anon, authenticated using (is_active);
create policy "storefront: variants"    on public.product_variants   for select to anon, authenticated
  using (exists (select 1 from public.products p where p.id = product_id and p.is_active));
create policy "storefront: stock"       on public.branch_inventory   for select to anon, authenticated
  using (exists (select 1 from public.products p where p.id = product_id and p.is_active));
create policy "storefront: rewards"     on public.rewards            for select to anon, authenticated using (is_active);
create policy "storefront: promotions"  on public.promotions         for select to anon, authenticated
  using (is_active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at >= now()));

-- Profile: a customer may create ONLY their own row, and only with a verified
-- email that matches their Firebase identity.
create policy "customer: read own profile"   on public.customer_profiles for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));
create policy "customer: create own profile" on public.customer_profiles for insert to authenticated
  with check (
    firebase_uid = (select public.current_firebase_uid())
    and (select public.jwt_email_verified())
    and lower(email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  );
create policy "customer: update own profile" on public.customer_profiles for update to authenticated
  using (firebase_uid = (select public.current_firebase_uid()))
  with check (firebase_uid = (select public.current_firebase_uid()));

create policy "customer: own addresses" on public.customer_addresses for all to authenticated
  using (firebase_uid = (select public.current_firebase_uid()))
  with check (firebase_uid = (select public.current_firebase_uid()));

create policy "customer: own notification prefs" on public.notification_preferences for all to authenticated
  using (firebase_uid = (select public.current_firebase_uid()))
  with check (firebase_uid = (select public.current_firebase_uid()));

-- Read-only own records (all writes happen in server-side functions).
create policy "customer: read own carts"        on public.carts for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));
create policy "customer: read own cart items"   on public.cart_items for select to authenticated
  using (exists (select 1 from public.carts c where c.id = cart_id and c.firebase_uid = (select public.current_firebase_uid())));
create policy "customer: read own orders"       on public.orders for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));
create policy "customer: read own order items"  on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and o.firebase_uid = (select public.current_firebase_uid())));
create policy "customer: read own order history" on public.order_status_events for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and o.firebase_uid = (select public.current_firebase_uid())));
create policy "customer: read own payments"     on public.payments for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));
create policy "customer: read own refunds"      on public.refund_requests for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));
create policy "customer: read own refund items" on public.refund_items for select to authenticated
  using (exists (select 1 from public.refund_requests r where r.id = refund_request_id and r.firebase_uid = (select public.current_firebase_uid())));
create policy "customer: read own refund history" on public.refund_status_events for select to authenticated
  using (exists (select 1 from public.refund_requests r where r.id = refund_request_id and r.firebase_uid = (select public.current_firebase_uid())));
create policy "customer: read own loyalty account" on public.loyalty_accounts for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));
create policy "customer: read own loyalty history" on public.loyalty_transactions for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));
create policy "customer: read own redemptions"  on public.reward_redemptions for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));
create policy "customer: read own voucher usage" on public.voucher_usage for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));

-- Notifications: read, mark-read (column-limited by grant), delete own.
create policy "customer: read own notifications"   on public.notifications for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));
create policy "customer: update own notifications" on public.notifications for update to authenticated
  using (firebase_uid = (select public.current_firebase_uid()))
  with check (firebase_uid = (select public.current_firebase_uid()));
create policy "customer: delete own notifications" on public.notifications for delete to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));

-- vouchers, loyalty_cart_settings, product_variant_costs intentionally have NO
-- policy: RLS is on, so no client role can read or write them.

-- -----------------------------------------------------------------------------
-- 9. Realtime: the app streams these two tables (OrdersRepository.watchOrder,
--    RefundsRepository.watchRequest). Realtime enforces the RLS above per
--    subscriber, so a customer only ever receives their own rows.
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['orders', 'refund_requests'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

commit;
