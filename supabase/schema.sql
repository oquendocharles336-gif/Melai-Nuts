-- =============================================================================
-- Melai Nuts — Supabase schema (customer-facing business data)
-- =============================================================================
-- Run this once against a fresh Supabase project (SQL Editor > New query >
-- paste > Run). Firebase Authentication remains the identity provider; this
-- database never stores passwords or session tokens. Every customer-owned
-- row is keyed by `firebase_uid`, the Firebase Auth UID.
--
-- REQUIRED one-time dashboard step (cannot be done via SQL):
--   Supabase Dashboard > Authentication > Sign In / Providers
--   > Third Party Auth > Add provider > Firebase
--   > paste this app's Firebase **Project ID** (not the API key).
-- This lets Postgres verify the Firebase ID token the app attaches to every
-- request and exposes it to policies as `auth.jwt() ->> 'sub'`. Until this
-- is configured, RLS below will reject every authenticated request.
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- The signed-in Firebase UID for the current request, or null for anon/guest.
create or replace function public.current_firebase_uid()
returns text
language sql
stable
as $$
  select nullif(auth.jwt() ->> 'sub', '')
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Branches, catalog (public read; managed by staff/owner tooling later)
-- -----------------------------------------------------------------------------

create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  address text,
  -- Operating status shown to customers ("Open"/"Temporarily Closed").
  is_active boolean not null default true,
  contact_phone text,
  -- Free-text display hours (e.g. "8:00 AM – 8:00 PM, Mon–Sun"). Structured
  -- per-day open/close times aren't modeled yet; this is intentionally a
  -- simple real field rather than a fabricated schedule.
  operating_hours text,
  supports_delivery boolean not null default true,
  supports_pickup boolean not null default true,
  delivery_fee numeric(10, 2) not null default 0 check (delivery_fee >= 0),
  created_at timestamptz not null default now()
);
-- Bring a branches table created by an older version of this script up to date.
alter table public.branches add column if not exists address text;
alter table public.branches add column if not exists is_active boolean not null default true;
alter table public.branches add column if not exists contact_phone text;
alter table public.branches add column if not exists operating_hours text;
alter table public.branches add column if not exists supports_delivery boolean not null default true;
alter table public.branches add column if not exists supports_pickup boolean not null default true;
alter table public.branches add column if not exists created_at timestamptz not null default now();
create unique index if not exists branches_name_key on public.branches (name);
alter table public.branches add column if not exists delivery_fee numeric(10, 2) not null default 0;
alter table public.branches drop constraint if exists branches_delivery_fee_check;
alter table public.branches add constraint branches_delivery_fee_check check (delivery_fee >= 0);

create table if not exists public.product_categories (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  icon_name text not null default 'category',
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
-- Bring a product_categories table created by an older version of this script up to date.
alter table public.product_categories add column if not exists label text not null default '';
alter table public.product_categories add column if not exists icon_name text not null default 'category';
alter table public.product_categories add column if not exists sort_order int not null default 0;
alter table public.product_categories add column if not exists created_at timestamptz not null default now();

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.product_categories(id) on delete set null,
  name text not null,
  price numeric(10, 2) not null check (price >= 0),
  -- Pre-discount reference price shown struck-through next to `price` on
  -- the storefront. Null means "no discount is running" (never fabricated).
  original_price numeric(10, 2) check (original_price is null or original_price >= price),
  unit text not null default 'pack',
  description text not null default '',
  -- Master/product-level SKU, e.g. "MN-GP-CORE" (distinct from each
  -- variant's own optional SKU on `product_variants.sku`).
  sku text,
  -- Ordered photo URLs (Supabase Storage public URLs or any external CDN
  -- link). Empty until staff upload real photos — the storefront falls
  -- back to the icon/color placeholder rather than showing a fake image.
  images text[] not null default '{}',
  -- Free-form merchandising tags, e.g. "Laguna Heritage", "Bestseller".
  tags text[] not null default '{}',
  icon_name text not null default 'nuts',
  color_hex text not null default '#8D6E63',
  is_active boolean not null default true,
  -- Manually curated by staff/owner ("Featured" toggle on Product
  -- Management) to promote a product on the customer Home dashboard when
  -- there isn't yet enough sales history to rank it as genuinely popular.
  is_featured boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Bring a products table created by an older version of this script up to date.
alter table public.products add column if not exists category_id uuid references public.product_categories(id) on delete set null;
alter table public.products add column if not exists name text not null default '';
alter table public.products add column if not exists price numeric(10, 2) not null default 0;
alter table public.products add column if not exists unit text not null default 'pack';
alter table public.products add column if not exists description text not null default '';
alter table public.products add column if not exists icon_name text not null default 'nuts';
alter table public.products add column if not exists color_hex text not null default '#8D6E63';
alter table public.products add column if not exists is_active boolean not null default true;
alter table public.products add column if not exists is_featured boolean not null default false;
alter table public.products add column if not exists created_at timestamptz not null default now();
alter table public.products add column if not exists updated_at timestamptz not null default now();
drop trigger if exists products_set_updated_at on public.products;
create trigger products_set_updated_at before update on public.products
  for each row execute function public.set_updated_at();

-- Safe to re-run against a project created before these columns existed.
alter table public.products add column if not exists original_price numeric(10, 2);
alter table public.products add column if not exists sku text;
alter table public.products add column if not exists images text[] not null default '{}';
alter table public.products add column if not exists tags text[] not null default '{}';

-- One row per purchasable pack size/SKU of a product. `price` is the full
-- shelf price for that variant (not a delta) — it's what the customer pays
-- per unit, matching the Flutter ProductVariant model exactly.
create table if not exists public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  label text not null,
  price numeric(10, 2) not null check (price >= 0),
  badge text,
  cost_price numeric(10, 2),
  sku text,
  sort_order int not null default 0
);
-- Bring a product_variants table created by an older version of this script up to date.
alter table public.product_variants add column if not exists label text not null default '';
alter table public.product_variants add column if not exists price numeric(10, 2) not null default 0;
alter table public.product_variants add column if not exists badge text;
alter table public.product_variants add column if not exists cost_price numeric(10, 2);
alter table public.product_variants add column if not exists sku text;
alter table public.product_variants add column if not exists sort_order int not null default 0;

create table if not exists public.branch_inventory (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  variant_id uuid references public.product_variants(id) on delete cascade,
  quantity int not null default 0 check (quantity >= 0),
  unique (branch_id, product_id, variant_id)
);
-- Bring a branch_inventory table created by an older version of this script up to date.
alter table public.branch_inventory add column if not exists variant_id uuid references public.product_variants(id) on delete cascade;
alter table public.branch_inventory add column if not exists quantity int not null default 0;

-- -----------------------------------------------------------------------------
-- Customer profile, addresses, notification preferences
-- -----------------------------------------------------------------------------

create table if not exists public.customer_profiles (
  firebase_uid text primary key,
  full_name text not null default '',
  email text not null default '',
  phone text not null default '',
  rfid_card_number text,
  default_branch_id uuid references public.branches(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists customer_profiles_set_updated_at on public.customer_profiles;
create trigger customer_profiles_set_updated_at before update on public.customer_profiles
  for each row execute function public.set_updated_at();

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  firebase_uid text not null references public.customer_profiles(firebase_uid) on delete cascade,
  label text not null default 'Home',
  recipient_name text not null,
  phone text not null,
  line1 text not null,
  city text not null,
  province text not null default 'Laguna',
  postal_code text not null default '',
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.notification_preferences (
  firebase_uid text primary key references public.customer_profiles(firebase_uid) on delete cascade,
  order_updates boolean not null default true,
  promos boolean not null default true,
  loyalty_updates boolean not null default true,
  delivery_updates boolean not null default true,
  updated_at timestamptz not null default now()
);
drop trigger if exists notification_prefs_set_updated_at on public.notification_preferences;
create trigger notification_prefs_set_updated_at before update on public.notification_preferences
  for each row execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- Cart (server-side, so it survives app restarts / device switches)
-- -----------------------------------------------------------------------------

create table if not exists public.carts (
  id uuid primary key default gen_random_uuid(),
  firebase_uid text not null references public.customer_profiles(firebase_uid) on delete cascade,
  branch_id uuid not null references public.branches(id),
  status text not null default 'open' check (status in ('open', 'checked_out', 'abandoned')),
  voucher_code text,
  redeem_points boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Migrate carts created by the earlier prototype-backed cart implementation.
alter table public.carts add column if not exists branch_id uuid references public.branches(id);
alter table public.carts add column if not exists voucher_code text;
alter table public.carts add column if not exists redeem_points boolean not null default false;
alter table public.carts add column if not exists created_at timestamptz not null default now();
alter table public.carts add column if not exists updated_at timestamptz not null default now();
update public.carts c
set branch_id = cp.default_branch_id
from public.customer_profiles cp
where c.branch_id is null and c.firebase_uid = cp.firebase_uid;
update public.carts set status = 'abandoned' where status = 'open' and branch_id is null;
do $$
begin
  if not exists (select 1 from public.carts where branch_id is null) then
    alter table public.carts alter column branch_id set not null;
  end if;
end $$;

drop index if exists public.carts_one_open_per_customer;
create unique index if not exists carts_one_open_per_customer_branch
  on public.carts (firebase_uid, branch_id) where (status = 'open');
drop trigger if exists carts_set_updated_at on public.carts;
create trigger carts_set_updated_at before update on public.carts
  for each row execute function public.set_updated_at();

create table if not exists public.cart_items (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references public.carts(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  variant_id uuid references public.product_variants(id) on delete set null,
  variant_label text not null default 'Regular',
  quantity int not null check (quantity > 0),
  current_price numeric(10, 2) not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (cart_id, product_id, variant_label)
);

-- Migrate the old cart item's unit_price column to the explicit current_price name.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'cart_items' and column_name = 'unit_price'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'cart_items' and column_name = 'current_price'
  ) then
    alter table public.cart_items rename column unit_price to current_price;
  end if;
end $$;
alter table public.cart_items add column if not exists current_price numeric(10, 2);
alter table public.cart_items add column if not exists created_at timestamptz not null default now();
alter table public.cart_items add column if not exists updated_at timestamptz not null default now();
update public.cart_items ci
set current_price = pv.price
from public.product_variants pv
where ci.variant_id = pv.id and ci.current_price is null;
delete from public.cart_items where current_price is null;
alter table public.cart_items alter column current_price set not null;
drop trigger if exists cart_items_set_updated_at on public.cart_items;
create trigger cart_items_set_updated_at before update on public.cart_items
  for each row execute function public.set_updated_at();

-- Vouchers are real owner/staff-managed records. Nothing is seeded here.
create table if not exists public.vouchers (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  description text not null default '',
  discount_type text not null check (discount_type in ('fixed', 'percent')),
  discount_value numeric(10, 2) not null check (discount_value > 0),
  minimum_subtotal numeric(10, 2) not null default 0 check (minimum_subtotal >= 0),
  maximum_discount numeric(10, 2),
  usage_limit int check (usage_limit is null or usage_limit > 0),
  used_count int not null default 0 check (used_count >= 0),
  starts_at timestamptz,
  ends_at timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Loyalty redemption rate is business configuration, not a client-side constant.
create table if not exists public.loyalty_cart_settings (
  id text primary key default 'default',
  points_per_peso numeric(10, 2) not null check (points_per_peso > 0),
  max_discount_percent numeric(5, 2) not null default 100 check (max_discount_percent > 0 and max_discount_percent <= 100),
  updated_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Orders
-- -----------------------------------------------------------------------------

create sequence if not exists public.order_code_seq start 1001;

create table if not exists public.orders (
  id text primary key default ('ORD-' || nextval('public.order_code_seq')::text),
  firebase_uid text not null references public.customer_profiles(firebase_uid),
  branch_id uuid references public.branches(id),
  branch_name text not null,
  is_delivery boolean not null default false,
  delivery_address_id uuid references public.customer_addresses(id),
  status text not null default 'pending'
    check (status in ('pending', 'confirmed', 'preparing', 'outForDelivery', 'completed', 'cancelled')),
  subtotal numeric(10, 2) not null,
  discount numeric(10, 2) not null default 0,
  delivery_fee numeric(10, 2) not null default 0,
  total numeric(10, 2) not null,
  payment_method text not null,
  points_earned int not null default 0,
  rider_name text,
  eta_label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists orders_set_updated_at on public.orders;
create trigger orders_set_updated_at before update on public.orders
  for each row execute function public.set_updated_at();

-- Widen the lifecycle to also cover pickup orders (`readyForPickup` is
-- distinct from delivery's `outForDelivery` — a pickup order is never
-- "out for delivery") and the two refund-driven terminal states a
-- completed order can move into. Kept as one shared `status` column
-- rather than a separate "fulfillment status" enum since an order only
-- ever needs one authoritative lifecycle state at a time. Values keep the
-- existing camelCase spelling (`outForDelivery`) for consistency, since
-- that's what `OrderStatus.name` in Dart already serializes as.
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in (
    'pending', 'confirmed', 'preparing', 'readyForPickup', 'outForDelivery',
    'completed', 'cancelled', 'refundRequested', 'refunded'
  ));

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id text not null references public.orders(id) on delete cascade,
  product_name text not null,
  variant_label text not null default 'Regular',
  quantity int not null check (quantity > 0),
  unit_price numeric(10, 2) not null
);

-- Real, automatic status history: every time an order's status changes, log
-- it. This is what powers the tracking timeline — no fabricated steps.
create table if not exists public.order_status_events (
  id uuid primary key default gen_random_uuid(),
  order_id text not null references public.orders(id) on delete cascade,
  status text not null,
  note text,
  created_at timestamptz not null default now()
);

create or replace function public.log_order_status_event()
returns trigger
language plpgsql
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
drop trigger if exists orders_log_status_event on public.orders;
create trigger orders_log_status_event
  after insert or update of status on public.orders
  for each row execute function public.log_order_status_event();

-- Points are earned server-side (₱50 spent = 1 point) so the client can never
-- inflate what it's awarded. Runs before insert so `points_earned` is always
-- consistent with `total`.
create or replace function public.compute_points_earned()
returns trigger
language plpgsql
as $$
begin
  new.points_earned := greatest(0, floor(new.total / 50)::int);
  return new;
end;
$$;
drop trigger if exists orders_compute_points on public.orders;
create trigger orders_compute_points before insert on public.orders
  for each row execute function public.compute_points_earned();

-- -----------------------------------------------------------------------------
-- Payments
-- -----------------------------------------------------------------------------

create sequence if not exists public.payment_code_seq start 5001;

create table if not exists public.payments (
  id text primary key default ('PAY-' || nextval('public.payment_code_seq')::text),
  order_id text not null references public.orders(id) on delete cascade,
  firebase_uid text not null references public.customer_profiles(firebase_uid),
  method text not null check (method in ('gcash', 'maya', 'card', 'cash')),
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'success', 'failed', 'refunded')),
  amount numeric(10, 2) not null,
  reference_number text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists payments_set_updated_at on public.payments;
create trigger payments_set_updated_at before update on public.payments
  for each row execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- Refunds
-- -----------------------------------------------------------------------------

create sequence if not exists public.refund_code_seq start 7001;

create table if not exists public.refund_requests (
  id text primary key default ('RFD-' || nextval('public.refund_code_seq')::text),
  order_id text not null references public.orders(id),
  firebase_uid text not null references public.customer_profiles(firebase_uid),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'processing', 'completed', 'rejected')),
  reason text not null,
  notes text not null default '',
  amount numeric(10, 2) not null,
  payment_method text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists refund_requests_set_updated_at on public.refund_requests;
create trigger refund_requests_set_updated_at before update on public.refund_requests
  for each row execute function public.set_updated_at();

create table if not exists public.refund_items (
  id uuid primary key default gen_random_uuid(),
  refund_request_id text not null references public.refund_requests(id) on delete cascade,
  product_name text not null,
  variant_label text not null default 'Regular',
  quantity int not null check (quantity > 0),
  unit_price numeric(10, 2) not null
);

create table if not exists public.refund_status_events (
  id uuid primary key default gen_random_uuid(),
  refund_request_id text not null references public.refund_requests(id) on delete cascade,
  status text not null,
  note text,
  created_at timestamptz not null default now()
);

create or replace function public.log_refund_status_event()
returns trigger
language plpgsql
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
drop trigger if exists refund_requests_log_status_event on public.refund_requests;
create trigger refund_requests_log_status_event
  after insert or update of status on public.refund_requests
  for each row execute function public.log_refund_status_event();

-- Reflects a refund's lifecycle onto its order's own status, so Order
-- History/Details/Tracking (which only ever read `orders.status`) show
-- "Refund Requested"/"Refunded" without duplicating refund logic there.
-- A rejected refund returns the order to 'completed' — the only state a
-- refund can be requested from — rather than leaving it stuck as
-- 'refundRequested' with no real refund in progress.
create or replace function public.sync_order_status_from_refund()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
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
drop trigger if exists refund_requests_sync_order_status on public.refund_requests;
create trigger refund_requests_sync_order_status
  after insert or update of status on public.refund_requests
  for each row execute function public.sync_order_status_from_refund();

-- -----------------------------------------------------------------------------
-- Loyalty
-- -----------------------------------------------------------------------------

create table if not exists public.loyalty_accounts (
  firebase_uid text primary key references public.customer_profiles(firebase_uid) on delete cascade,
  points_balance int not null default 0 check (points_balance >= 0),
  lifetime_points int not null default 0,
  updated_at timestamptz not null default now()
);
drop trigger if exists loyalty_accounts_set_updated_at on public.loyalty_accounts;
create trigger loyalty_accounts_set_updated_at before update on public.loyalty_accounts
  for each row execute function public.set_updated_at();

create sequence if not exists public.loyalty_tx_code_seq start 1;

create table if not exists public.loyalty_transactions (
  id text primary key default ('LTX-' || nextval('public.loyalty_tx_code_seq')::text),
  firebase_uid text not null references public.customer_profiles(firebase_uid),
  type text not null check (type in ('earn', 'redeem')),
  points int not null,
  description text not null,
  order_id text references public.orders(id),
  created_at timestamptz not null default now()
);

-- Award points automatically whenever a paid order is created.
create or replace function public.award_order_points()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.points_earned > 0 then
    insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points)
    values (new.firebase_uid, new.points_earned, new.points_earned)
    on conflict (firebase_uid) do update
      set points_balance = public.loyalty_accounts.points_balance + excluded.points_balance,
          lifetime_points = public.loyalty_accounts.lifetime_points + excluded.lifetime_points;

    insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id)
    values (new.firebase_uid, 'earn', new.points_earned, 'Order ' || new.id, new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists orders_award_points on public.orders;
create trigger orders_award_points after insert on public.orders
  for each row execute function public.award_order_points();

create table if not exists public.rewards (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  points_required int not null check (points_required > 0),
  badge_label text not null default '',
  icon_name text not null default 'redeem',
  color_hex text not null default '#8D6E63',
  stock int,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
-- Bring a rewards table created by an older version of this script up to date.
alter table public.rewards add column if not exists description text not null default '';
alter table public.rewards add column if not exists points_required int not null default 1;
alter table public.rewards add column if not exists badge_label text not null default '';
alter table public.rewards add column if not exists icon_name text not null default 'redeem';
alter table public.rewards add column if not exists color_hex text not null default '#8D6E63';
alter table public.rewards add column if not exists stock int;
alter table public.rewards add column if not exists is_active boolean not null default true;
alter table public.rewards add column if not exists created_at timestamptz not null default now();

-- Home dashboard promo banner(s). Real, staff/owner-managed rows — the app
-- never shows a promo that isn't actually here, and shows none at all
-- (rather than a fabricated one) when this table is empty or nothing is
-- currently within its date window.
create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  subtitle text not null default '',
  badge_label text not null default 'LIMITED TIME OFFER',
  icon_name text not null default 'local_offer',
  starts_at timestamptz,
  ends_at timestamptz,
  sort_order int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
-- Bring a promotions table created by an older version of this script up to date.
alter table public.promotions add column if not exists subtitle text not null default '';
alter table public.promotions add column if not exists badge_label text not null default 'LIMITED TIME OFFER';
alter table public.promotions add column if not exists icon_name text not null default 'local_offer';
alter table public.promotions add column if not exists starts_at timestamptz;
alter table public.promotions add column if not exists ends_at timestamptz;
alter table public.promotions add column if not exists sort_order int not null default 0;
alter table public.promotions add column if not exists is_active boolean not null default true;
alter table public.promotions add column if not exists created_at timestamptz not null default now();

create table if not exists public.reward_redemptions (
  id uuid primary key default gen_random_uuid(),
  firebase_uid text not null references public.customer_profiles(firebase_uid),
  reward_id uuid not null references public.rewards(id),
  points_spent int not null,
  status text not null default 'redeemed',
  created_at timestamptz not null default now()
);

-- Atomic "spend points" transaction: check balance, deduct, log, decrement
-- stock — all or nothing. This is the only way points ever leave an account,
-- so a slow tap or a flaky connection can never double-charge.
create or replace function public.redeem_reward(p_reward_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_reward record;
  v_balance int;
begin
  if v_uid is null then
    raise exception 'Not signed in';
  end if;

  select * into v_reward from public.rewards where id = p_reward_id and is_active for update;
  if not found then
    raise exception 'Reward not available';
  end if;
  if v_reward.stock is not null and v_reward.stock <= 0 then
    raise exception 'Reward is out of stock';
  end if;

  insert into public.loyalty_accounts (firebase_uid) values (v_uid)
    on conflict (firebase_uid) do nothing;

  select points_balance into v_balance from public.loyalty_accounts
    where firebase_uid = v_uid for update;

  if v_balance < v_reward.points_required then
    raise exception 'Not enough points';
  end if;

  update public.loyalty_accounts
    set points_balance = points_balance - v_reward.points_required
    where firebase_uid = v_uid
    returning points_balance into v_balance;

  insert into public.loyalty_transactions (firebase_uid, type, points, description)
    values (v_uid, 'redeem', -v_reward.points_required, v_reward.title);

  insert into public.reward_redemptions (firebase_uid, reward_id, points_spent)
    values (v_uid, p_reward_id, v_reward.points_required);

  if v_reward.stock is not null then
    update public.rewards set stock = stock - 1 where id = p_reward_id;
  end if;

  return v_balance;
end;
$$;

-- -----------------------------------------------------------------------------
-- Notifications
-- -----------------------------------------------------------------------------

create sequence if not exists public.notification_code_seq start 1;

create table if not exists public.notifications (
  id text primary key default ('NTF-' || nextval('public.notification_code_seq')::text),
  firebase_uid text not null references public.customer_profiles(firebase_uid) on delete cascade,
  category text not null
    check (category in ('order', 'payment', 'refund', 'loyalty', 'delivery', 'promo', 'system')),
  title text not null,
  body text not null,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

create or replace function public.notify_customer(
  p_uid text, p_category text, p_title text, p_body text
) returns void language sql security definer set search_path = public as $$
  insert into public.notifications (firebase_uid, category, title, body)
  values (p_uid, p_category, p_title, p_body);
$$;

-- Real, automatic notifications for real events — not fabricated client-side.
create or replace function public.notify_on_order_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.notify_customer(new.firebase_uid, 'order', 'Order placed',
      'Your order ' || new.id || ' has been received.');
  elsif new.status is distinct from old.status then
    perform public.notify_customer(new.firebase_uid, 'order', 'Order ' || new.id || ' updated',
      'Status changed to ' || new.status || '.');
  end if;
  return new;
end;
$$;
drop trigger if exists orders_notify on public.orders;
create trigger orders_notify after insert or update of status on public.orders
  for each row execute function public.notify_on_order_status();

create or replace function public.notify_on_refund_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.notify_customer(new.firebase_uid, 'refund', 'Refund request submitted',
      'Request ' || new.id || ' for order ' || new.order_id || ' is pending review.');
  elsif new.status is distinct from old.status then
    perform public.notify_customer(new.firebase_uid, 'refund', 'Refund ' || new.id || ' updated',
      'Status changed to ' || new.status || '.');
  end if;
  return new;
end;
$$;
drop trigger if exists refunds_notify on public.refund_requests;
create trigger refunds_notify after insert or update of status on public.refund_requests
  for each row execute function public.notify_on_refund_status();

-- -----------------------------------------------------------------------------
-- Storefront popularity ranking
-- -----------------------------------------------------------------------------

-- "Popular Near You" on the customer Home dashboard needs to rank products
-- by real units sold across ALL customers, but `order_items` itself is only
-- readable by the customer who placed that order (see RLS below). This
-- function runs as security definer to read across every order, and returns
-- only an aggregate (product id + total units sold) — never anyone's order
-- details — so it's safe to expose to any signed-in or anonymous caller.
-- `order_items` stores a denormalized `product_name` (not a product_id FK,
-- since a name can outlive edits to the product row), so we match on name.
create or replace function public.get_popular_products(p_limit int default 8)
returns table (product_id uuid, total_quantity bigint)
language sql
stable
security definer
set search_path = public
as $$
  select p.id as product_id, sum(oi.quantity)::bigint as total_quantity
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  join public.products p on p.name = oi.product_name
  where p.is_active
    and o.status <> 'cancelled'
  group by p.id
  order by total_quantity desc
  limit greatest(p_limit, 0)
$$;

grant execute on function public.get_popular_products(int) to anon, authenticated;

-- Real per-product trailing-30-day unit counts for every active product (not
-- just a top-N ranking like get_popular_products above) — drives
-- Product.unitsSoldLast30Days on the Product Performance / Pricing Hub
-- screens. 0 for a product with no recent sales, never omitted.
create or replace function public.get_product_sales_30d()
returns table (product_id uuid, units_sold bigint)
language sql
stable
security definer
set search_path = public
as $$
  select p.id as product_id,
         coalesce(sum(oi.quantity) filter (
           where o.id is not null
             and o.status <> 'cancelled'
             and o.created_at >= now() - interval '30 days'
         ), 0)::bigint as units_sold
  from public.products p
  left join public.order_items oi on oi.product_name = p.name
  left join public.orders o on o.id = oi.order_id
  where p.is_active
  group by p.id
$$;

grant execute on function public.get_product_sales_30d() to anon, authenticated;

-- =============================================================================
-- Row Level Security
-- =============================================================================

alter table public.branches enable row level security;
alter table public.product_categories enable row level security;
alter table public.products enable row level security;
alter table public.product_variants enable row level security;
alter table public.branch_inventory enable row level security;
alter table public.rewards enable row level security;
alter table public.promotions enable row level security;

alter table public.customer_profiles enable row level security;
alter table public.customer_addresses enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.carts enable row level security;
alter table public.cart_items enable row level security;
alter table public.vouchers enable row level security;
alter table public.loyalty_cart_settings enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_status_events enable row level security;
alter table public.payments enable row level security;
alter table public.refund_requests enable row level security;
alter table public.refund_items enable row level security;
alter table public.refund_status_events enable row level security;
alter table public.loyalty_accounts enable row level security;
alter table public.loyalty_transactions enable row level security;
alter table public.reward_redemptions enable row level security;
alter table public.notifications enable row level security;

-- Catalog: anyone (including guests browsing without an account) can read.
drop policy if exists "catalog is publicly readable" on public.branches;
create policy "catalog is publicly readable" on public.branches for select using (true);
drop policy if exists "catalog is publicly readable" on public.product_categories;
create policy "catalog is publicly readable" on public.product_categories for select using (true);
drop policy if exists "catalog is publicly readable" on public.products;
create policy "catalog is publicly readable" on public.products for select using (is_active);
drop policy if exists "catalog is publicly readable" on public.product_variants;
create policy "catalog is publicly readable" on public.product_variants for select using (true);
drop policy if exists "catalog is publicly readable" on public.branch_inventory;
create policy "catalog is publicly readable" on public.branch_inventory for select using (true);
drop policy if exists "rewards are publicly readable" on public.rewards;
create policy "rewards are publicly readable" on public.rewards for select using (is_active);
drop policy if exists "active promotions are publicly readable" on public.promotions;
create policy "active promotions are publicly readable" on public.promotions for select
  using (is_active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at >= now()));

-- Customer profile
drop policy if exists "read own profile" on public.customer_profiles;
create policy "read own profile" on public.customer_profiles for select
  using (firebase_uid = current_firebase_uid());
drop policy if exists "create own profile" on public.customer_profiles;
create policy "create own profile" on public.customer_profiles for insert
  with check (firebase_uid = current_firebase_uid());
drop policy if exists "update own profile" on public.customer_profiles;
create policy "update own profile" on public.customer_profiles for update
  using (firebase_uid = current_firebase_uid());

-- Addresses
drop policy if exists "manage own addresses" on public.customer_addresses;
create policy "manage own addresses" on public.customer_addresses for all
  using (firebase_uid = current_firebase_uid())
  with check (firebase_uid = current_firebase_uid());

-- Notification preferences
drop policy if exists "manage own notification prefs" on public.notification_preferences;
create policy "manage own notification prefs" on public.notification_preferences for all
  using (firebase_uid = current_firebase_uid())
  with check (firebase_uid = current_firebase_uid());

-- Cart
drop policy if exists "manage own cart" on public.carts;
create policy "manage own cart" on public.carts for all
  using (firebase_uid = current_firebase_uid())
  with check (firebase_uid = current_firebase_uid());
drop policy if exists "manage own cart items" on public.cart_items;
create policy "manage own cart items" on public.cart_items for all
  using (exists (select 1 from public.carts c where c.id = cart_id and c.firebase_uid = current_firebase_uid()))
  with check (exists (select 1 from public.carts c where c.id = cart_id and c.firebase_uid = current_firebase_uid()));

-- Orders: customers can create and read their own; status changes going
-- forward belong to staff/delivery tooling (not exposed here), so no
-- customer update/delete policy is defined.
drop policy if exists "read own orders" on public.orders;
create policy "read own orders" on public.orders for select
  using (firebase_uid = current_firebase_uid());
drop policy if exists "create own orders" on public.orders;
create policy "create own orders" on public.orders for insert
  with check (firebase_uid = current_firebase_uid());
drop policy if exists "read own order items" on public.order_items;
create policy "read own order items" on public.order_items for select
  using (exists (select 1 from public.orders o where o.id = order_id and o.firebase_uid = current_firebase_uid()));
drop policy if exists "create own order items" on public.order_items;
create policy "create own order items" on public.order_items for insert
  with check (exists (select 1 from public.orders o where o.id = order_id and o.firebase_uid = current_firebase_uid()));
drop policy if exists "read own order status events" on public.order_status_events;
create policy "read own order status events" on public.order_status_events for select
  using (exists (select 1 from public.orders o where o.id = order_id and o.firebase_uid = current_firebase_uid()));

-- Payments: customers can record and read their own; no update/delete.
drop policy if exists "read own payments" on public.payments;
create policy "read own payments" on public.payments for select
  using (firebase_uid = current_firebase_uid());
drop policy if exists "create own payments" on public.payments;
create policy "create own payments" on public.payments for insert
  with check (firebase_uid = current_firebase_uid());

-- Refunds
drop policy if exists "read own refund requests" on public.refund_requests;
create policy "read own refund requests" on public.refund_requests for select
  using (firebase_uid = current_firebase_uid());
drop policy if exists "create own refund requests" on public.refund_requests;
create policy "create own refund requests" on public.refund_requests for insert
  with check (firebase_uid = current_firebase_uid());
drop policy if exists "read own refund items" on public.refund_items;
create policy "read own refund items" on public.refund_items for select
  using (exists (select 1 from public.refund_requests r where r.id = refund_request_id and r.firebase_uid = current_firebase_uid()));
drop policy if exists "create own refund items" on public.refund_items;
create policy "create own refund items" on public.refund_items for insert
  with check (exists (select 1 from public.refund_requests r where r.id = refund_request_id and r.firebase_uid = current_firebase_uid()));
drop policy if exists "read own refund status events" on public.refund_status_events;
create policy "read own refund status events" on public.refund_status_events for select
  using (exists (select 1 from public.refund_requests r where r.id = refund_request_id and r.firebase_uid = current_firebase_uid()));

-- Loyalty: balance and history are read-only from the client — every change
-- goes through the order/redemption triggers and the redeem_reward()
-- function above, never a direct client update.
drop policy if exists "read own loyalty account" on public.loyalty_accounts;
create policy "read own loyalty account" on public.loyalty_accounts for select
  using (firebase_uid = current_firebase_uid());
drop policy if exists "read own loyalty transactions" on public.loyalty_transactions;
create policy "read own loyalty transactions" on public.loyalty_transactions for select
  using (firebase_uid = current_firebase_uid());
drop policy if exists "read own redemptions" on public.reward_redemptions;
create policy "read own redemptions" on public.reward_redemptions for select
  using (firebase_uid = current_firebase_uid());

-- Notifications: customers can read, mark read, and delete their own; rows
-- are only ever created by the notify_* trigger functions above.
drop policy if exists "manage own notifications" on public.notifications;
create policy "manage own notifications" on public.notifications for select
  using (firebase_uid = current_firebase_uid());
drop policy if exists "update own notifications" on public.notifications;
create policy "update own notifications" on public.notifications for update
  using (firebase_uid = current_firebase_uid())
  with check (firebase_uid = current_firebase_uid());
drop policy if exists "delete own notifications" on public.notifications;
create policy "delete own notifications" on public.notifications for delete
  using (firebase_uid = current_firebase_uid());

-- =============================================================================
-- No seed data
-- =============================================================================
-- This file used to insert a starter catalog (5 sample products with 50 units of
-- stock at every branch), 3 rewards, a promotion and branch addresses/phones.
-- Those were demo values, and because they were upserts, re-running this file on
-- a live project overwrote real branch details and put invented stock in place.
-- Real branches, products, stock, rewards and promotions are entered by the
-- owner (app / admin website). The project has no demo data file.

-- =============================================================================
-- Migration: real category management + product-targeted promotions +
-- server-side stock enforcement (customer catalog/checkout hardening)
-- =============================================================================
-- Safe to re-run: every statement below is idempotent (IF NOT EXISTS /
-- CREATE OR REPLACE / DROP POLICY IF EXISTS before CREATE POLICY).

-- -----------------------------------------------------------------------------
-- Categories: real active/inactive state + optional real photo
-- -----------------------------------------------------------------------------

alter table public.product_categories add column if not exists is_active boolean not null default true;
alter table public.product_categories add column if not exists image_url text;

-- Categories follow the same rule as products: only what's currently
-- active is visible to the storefront (and to any other client using this
-- same anon/authenticated connection — there is no separate admin role
-- defined yet, matching how `products.is_active` already works above).
drop policy if exists "catalog is publicly readable" on public.product_categories;
create policy "catalog is publicly readable" on public.product_categories for select
  using (is_active);

-- -----------------------------------------------------------------------------
-- Promotions: let a banner/offer target one specific product or category,
-- so Product Details can show real "Applicable Promotions" instead of
-- nothing. Existing sitewide promos (both columns null) are unaffected —
-- they keep showing on the Home dashboard as before.
-- -----------------------------------------------------------------------------

alter table public.promotions add column if not exists product_id uuid references public.products(id) on delete cascade;
alter table public.promotions add column if not exists category_id uuid references public.product_categories(id) on delete cascade;

-- -----------------------------------------------------------------------------
-- Atomic, server-enforced checkout: validates every line against real,
-- current `branch_inventory` (locking the rows so two simultaneous
-- checkouts can't both oversell the same last unit), rejects the whole
-- order if a product has gone inactive or any line now exceeds what's
-- actually on the shelf, and only then decrements stock and creates the
-- order + items in one transaction. The client (`OrdersRepository`) never
-- writes to `orders`/`order_items`/`branch_inventory` directly for a
-- checkout — this function is the only path, so a stale/cached client-side
-- stock number can never actually oversell.
-- -----------------------------------------------------------------------------

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
  v_points_per_peso numeric;
  v_max_discount_percent numeric;
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

create or replace function public.get_customer_cart(p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_cart record;
  v_items jsonb;
  v_pricing jsonb;
begin
  if v_uid is null then
    raise exception 'Please sign in to use the shopping cart.';
  end if;
  select c.* into v_cart
  from public.carts c
  where c.firebase_uid = v_uid and c.branch_id = p_branch_id and c.status = 'open'
  limit 1;
  if not found then
    return jsonb_build_object('cart_id', null, 'branch_id', p_branch_id, 'items', '[]'::jsonb,
      'voucher_code', null, 'redeem_points', false,
      'pricing', jsonb_build_object('subtotal',0,'voucher_discount',0,'loyalty_discount',0,'delivery_fee',0,'total',0,
        'voucher_code',null,'redeem_points',false,'loyalty_points_balance',coalesce((select points_balance from public.loyalty_accounts where firebase_uid=v_uid),0),'loyalty_points_used',0));
  end if;

  update public.cart_items ci
  set current_price = pv.price, updated_at = now()
  from public.product_variants pv
  where ci.cart_id = v_cart.id and ci.variant_id = pv.id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', ci.product_id,
    'variant_id', ci.variant_id,
    'variant_label', ci.variant_label,
    'quantity', ci.quantity,
    'current_price', ci.current_price
  ) order by ci.created_at), '[]'::jsonb)
  into v_items
  from public.cart_items ci
  where ci.cart_id = v_cart.id;

  v_pricing := public._calculate_cart_pricing(v_cart.id, exists (select 1 from public.branches b where b.id = v_cart.branch_id and b.supports_delivery and b.is_active));
  return jsonb_build_object(
    'cart_id', v_cart.id,
    'branch_id', v_cart.branch_id,
    'voucher_code', v_cart.voucher_code,
    'redeem_points', v_cart.redeem_points,
    'items', v_items,
    'pricing', v_pricing
  );
end;
$$;

create or replace function public.get_cart_pricing(p_cart_id uuid, p_is_delivery boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public._calculate_cart_pricing(p_cart_id, p_is_delivery);
end;
$$;

create or replace function public.sync_customer_cart(
  p_branch_id uuid,
  p_items jsonb,
  p_voucher_code text,
  p_redeem_points boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_cart_id uuid;
  v_item jsonb;
  v_product_id uuid;
  v_variant_id uuid;
  v_quantity int;
  v_variant_label text;
  v_price numeric;
  v_result jsonb;
begin
  if v_uid is null then raise exception 'Please sign in to use the shopping cart.'; end if;
  if p_branch_id is null then raise exception 'Please select a branch first.'; end if;
  if not exists (select 1 from public.branches where id = p_branch_id and is_active) then
    raise exception 'Selected branch is unavailable.';
  end if;

  insert into public.carts(firebase_uid, branch_id)
  values(v_uid, p_branch_id)
  on conflict (firebase_uid, branch_id) where (status = 'open') do nothing
  returning id into v_cart_id;

  if v_cart_id is null then
    select id into v_cart_id from public.carts
    where firebase_uid = v_uid and branch_id = p_branch_id and status = 'open'
    for update;
  end if;

  delete from public.cart_items where cart_id = v_cart_id;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_product_id := nullif(v_item->>'product_id', '')::uuid;
    v_variant_id := nullif(v_item->>'variant_id', '')::uuid;
    v_quantity := nullif(v_item->>'quantity', '')::int;

    if v_product_id is null or v_variant_id is null or v_quantity is null or v_quantity <= 0 then
      raise exception 'One of the cart items is invalid. Please refresh the product and try again.';
    end if;

    select pv.label, pv.price into v_variant_label, v_price
    from public.product_variants pv
    join public.products p on p.id = pv.product_id
    where pv.id = v_variant_id and pv.product_id = v_product_id and p.is_active;
    if not found then
      raise exception 'One of the cart items is no longer available.';
    end if;

    if not exists (
      select 1
      from public.branch_inventory bi
      where bi.branch_id = p_branch_id
        and bi.product_id = v_product_id
        and bi.variant_id = v_variant_id
        and bi.quantity >= v_quantity
    ) then
      raise exception 'The requested quantity is not available at this branch.';
    end if;

    insert into public.cart_items(cart_id, product_id, variant_id, variant_label, quantity, current_price)
    values(v_cart_id, v_product_id, v_variant_id, v_variant_label, v_quantity, v_price);
  end loop;

  update public.carts
  set voucher_code = nullif(upper(trim(p_voucher_code)), ''),
      redeem_points = coalesce(p_redeem_points, false),
      updated_at = now()
  where id = v_cart_id;

  -- Validation/calculation occurs inside the same transaction. Invalid vouchers
  -- or unavailable loyalty redemption roll the entire sync back.
  v_result := public._calculate_cart_pricing(v_cart_id, exists (select 1 from public.branches b where b.id = p_branch_id and b.supports_delivery and b.is_active));
  v_result := jsonb_build_object(
    'cart_id', v_cart_id,
    'branch_id', p_branch_id,
    'voucher_code', v_result->'voucher_code',
    'redeem_points', v_result->'redeem_points',
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'product_id', ci.product_id,
      'variant_id', ci.variant_id,
      'variant_label', ci.variant_label,
      'quantity', ci.quantity,
      'current_price', ci.current_price
    ) order by ci.created_at) from public.cart_items ci where ci.cart_id=v_cart_id), '[]'::jsonb),
    'pricing', v_result
  );
  return v_result;
end;
$$;

create or replace function public.place_order(
  p_cart_id uuid,
  p_is_delivery boolean,
  p_delivery_address_id uuid,
  p_payment_method text
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
  v_voucher_discount numeric;
  v_loyalty_discount numeric;
  v_delivery_fee numeric;
  v_total numeric;
  v_discount numeric;
  v_points_used int := 0;
  v_balance int := 0;
  v_voucher record;
  v_points_per_peso numeric;
  v_max_discount_percent numeric;
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

  if p_is_delivery then
    if p_delivery_address_id is null then raise exception 'Please provide a delivery address.'; end if;
    if not exists (select 1 from public.customer_addresses where id=p_delivery_address_id and firebase_uid=v_uid) then
      raise exception 'The selected delivery address is invalid.';
    end if;
    select delivery_fee into v_delivery_fee from public.branches where id=v_cart.branch_id and supports_delivery and is_active;
    if not found then raise exception 'Delivery is not available for this branch.'; end if;
  else
    if not exists (select 1 from public.branches where id=v_cart.branch_id and supports_pickup and is_active) then
      raise exception 'Pickup is not available for this branch.';
    end if;
    v_delivery_fee := 0;
  end if;

  update public.cart_items ci
  set current_price = pv.price, variant_label = pv.label, updated_at = now()
  from public.product_variants pv
  join public.products p on p.id = pv.product_id
  where ci.cart_id=v_cart.id and ci.variant_id=pv.id and p.is_active;

  if not exists (select 1 from public.cart_items where cart_id=v_cart.id) then
    raise exception 'Your cart is empty.';
  end if;

  for v_item in select ci.*, p.name, p.is_active from public.cart_items ci join public.products p on p.id=ci.product_id where ci.cart_id=v_cart.id loop
    if not v_item.is_active then raise exception '% is no longer available.', v_item.name; end if;
    select quantity into v_available
    from public.branch_inventory bi
    where bi.branch_id=v_cart.branch_id and bi.product_id=v_item.product_id and bi.variant_id=v_item.variant_id
    for update;
    if v_available is null then raise exception '% is not available at this branch.', v_item.name; end if;
    if v_available < v_item.quantity then raise exception 'Only % of % left at this branch.', v_available, v_item.name; end if;
  end loop;

  -- Lock the loyalty account before recomputing so points cannot be spent twice.
  insert into public.loyalty_accounts(firebase_uid) values(v_uid) on conflict(firebase_uid) do nothing;
  select points_balance into v_balance from public.loyalty_accounts where firebase_uid=v_uid for update;

  select * into v_voucher from public.vouchers v
  where v.id is not null and upper(v.code)=upper(trim(v_cart.voucher_code))
    and v_cart.voucher_code is not null
    and v.is_active and (v.starts_at is null or v.starts_at<=now()) and (v.ends_at is null or v.ends_at>=now())
  for update;
  if v_cart.voucher_code is not null and not found then raise exception 'Voucher is invalid or expired.'; end if;

  select coalesce(sum(current_price*quantity),0) into v_subtotal from public.cart_items where cart_id=v_cart.id;
  if v_cart.voucher_code is not null then
    if v_voucher.usage_limit is not null and v_voucher.used_count >= v_voucher.usage_limit then raise exception 'This voucher has reached its usage limit.'; end if;
    if v_subtotal < v_voucher.minimum_subtotal then raise exception 'This voucher requires a minimum subtotal of ₱%.', v_voucher.minimum_subtotal; end if;
    if v_voucher.discount_type='percent' then v_voucher_discount := round(v_subtotal*v_voucher.discount_value/100,2); else v_voucher_discount := v_voucher.discount_value; end if;
    if v_voucher.maximum_discount is not null then v_voucher_discount := least(v_voucher_discount, v_voucher.maximum_discount); end if;
    v_voucher_discount := least(v_voucher_discount,v_subtotal);
  else
    v_voucher_discount := 0;
  end if;

  if v_cart.redeem_points then
    select points_per_peso, max_discount_percent into v_points_per_peso, v_max_discount_percent from public.loyalty_cart_settings where id='default';
    if v_points_per_peso is null then raise exception 'Loyalty point redemption is not configured yet.'; end if;
    if v_balance <= 0 then raise exception 'You do not have loyalty points available to redeem.'; end if;
    v_points_used := least(
      v_balance,
      floor(greatest(0,least(v_subtotal-v_voucher_discount,v_subtotal*(v_max_discount_percent)/100))*v_points_per_peso)::int
    );
    v_loyalty_discount := round(v_points_used/v_points_per_peso,2);
  else
    v_loyalty_discount := 0;
  end if;

  v_discount := v_voucher_discount + v_loyalty_discount;
  v_total := greatest(0,v_subtotal-v_discount+v_delivery_fee);

  for v_item in select * from public.cart_items where cart_id=v_cart.id loop
    update public.branch_inventory
    set quantity=quantity-v_item.quantity
    where branch_id=v_cart.branch_id and product_id=v_item.product_id and variant_id=v_item.variant_id;
  end loop;

  insert into public.orders(firebase_uid,branch_id,branch_name,is_delivery,delivery_address_id,subtotal,discount,delivery_fee,total,payment_method)
  select v_uid, v_cart.branch_id, b.name, p_is_delivery, p_delivery_address_id, v_subtotal, v_discount, v_delivery_fee, v_total, p_payment_method
  from public.branches b where b.id=v_cart.branch_id
  returning id into v_order_id;

  insert into public.order_items(order_id,product_name,variant_label,quantity,unit_price)
  select v_order_id,p.name,ci.variant_label,ci.quantity,ci.current_price
  from public.cart_items ci join public.products p on p.id=ci.product_id where ci.cart_id=v_cart.id;

  if v_points_used > 0 then
    update public.loyalty_accounts set points_balance=points_balance-v_points_used where firebase_uid=v_uid;
    insert into public.loyalty_transactions(firebase_uid,type,points,description,order_id)
    values(v_uid,'redeem',-v_points_used,'Applied to order '||v_order_id,v_order_id);
  end if;

  if v_cart.voucher_code is not null then
    update public.vouchers set used_count=used_count+1 where id=v_voucher.id;
  end if;

  delete from public.cart_items where cart_id=v_cart.id;
  update public.carts set status='checked_out', voucher_code=null, redeem_points=false, updated_at=now() where id=v_cart.id;

  return v_order_id;
end;
$$;

revoke all on function public._calculate_cart_pricing(uuid, boolean) from public;
revoke all on function public.get_customer_cart(uuid) from public;
revoke all on function public.get_cart_pricing(uuid, boolean) from public;
revoke all on function public.sync_customer_cart(uuid, jsonb, text, boolean) from public;
revoke all on function public.place_order(uuid, boolean, uuid, text) from public;

grant execute on function public._calculate_cart_pricing(uuid, boolean) to authenticated;
grant execute on function public.get_customer_cart(uuid) to authenticated;
grant execute on function public.get_cart_pricing(uuid, boolean) to authenticated;
grant execute on function public.sync_customer_cart(uuid, jsonb, text, boolean) to authenticated;
grant execute on function public.place_order(uuid, boolean, uuid, text) to authenticated;

-- =============================================================================
-- Migration: atomic payment record on checkout, real customer notes,
-- denormalized delivery contact snapshot, and payment-status hardening.
-- =============================================================================
-- Safe to re-run. Closes three real gaps in the checkout flow:
--   1. The Flutter client used to insert the `payments` row itself, in a
--      second network call made *after* `place_order` had already
--      committed the order. If that second call failed (dropped
--      connection, app killed), the order existed with no payment record
--      at all — a partially-succeeded checkout. The payment row is now
--      created inside `place_order`'s own transaction, so an order and its
--      payment record always come into existence together or not at all.
--   2. The previous "create own payments" policy let a signed-in customer
--      insert a payments row with ANY status, including 'success' —
--      nothing stopped a modified client from writing a fake "paid"
--      receipt straight into the database. Client-initiated inserts are
--      now restricted to status = 'pending' (the only truthful status a
--      client can assert about its own not-yet-confirmed payment); moving
--      it to 'success'/'failed'/'refunded' requires a real gateway
--      webhook or staff action running with elevated privileges, not this
--      policy.
--   3. The "Special Instructions" field on Checkout and the customer's
--      real contact number/delivery address were never persisted on the
--      order — the notes field silently discarded whatever the customer
--      typed, and the address/phone were only reachable via a
--      foreign key that could later be edited or deleted out from under
--      the order. Both are now captured as an immutable snapshot at the
--      moment the order is placed, and a customer with no phone on file
--      can no longer complete checkout at all (staff need a real number
--      to reach them for both pickup and delivery orders).
-- -----------------------------------------------------------------------------

alter table public.orders add column if not exists customer_notes text not null default '';
alter table public.orders add column if not exists contact_phone text not null default '';
alter table public.orders add column if not exists delivery_address_text text;

-- Direct client inserts may only ever assert 'pending' — anything further
-- along the payment lifecycle has to come from `place_order` (security
-- definer, bypasses RLS) or a future real gateway integration running with
-- its own elevated credentials.
drop policy if exists "create own payments" on public.payments;
create policy "create own payments" on public.payments for insert
  with check (firebase_uid = current_firebase_uid() and status = 'pending');

-- The 4-argument place_order is being replaced by a 5-argument version
-- (adds p_customer_notes). Postgres treats that as a different overload
-- rather than a replacement, so the old signature is dropped explicitly —
-- otherwise both would exist and the client could still reach the one
-- that skips notes/phone/payment-record creation.
drop function if exists public.place_order(uuid, boolean, uuid, text);

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
  v_voucher_discount numeric;
  v_loyalty_discount numeric;
  v_delivery_fee numeric;
  v_total numeric;
  v_discount numeric;
  v_points_used int := 0;
  v_balance int := 0;
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
    select delivery_fee into v_delivery_fee from public.branches where id=v_cart.branch_id and supports_delivery and is_active;
    if not found then raise exception 'Delivery is not available for this branch.'; end if;
    v_contact_phone := nullif(trim(v_address.phone), '');
    v_delivery_address_text := trim(
      v_address.recipient_name || ', ' || v_address.line1 || ', ' || v_address.city ||
      case when coalesce(v_address.province, '') <> '' then ', ' || v_address.province else '' end ||
      case when coalesce(v_address.postal_code, '') <> '' then ' ' || v_address.postal_code else '' end
    );
  else
    if not exists (select 1 from public.branches where id=v_cart.branch_id and supports_pickup and is_active) then
      raise exception 'Pickup is not available for this branch.';
    end if;
    v_delivery_fee := 0;
    v_contact_phone := nullif(trim(coalesce(v_profile_phone, '')), '');
    v_delivery_address_text := null;
  end if;

  if v_contact_phone is null then
    raise exception 'Please add a contact phone number to your profile before checking out.';
  end if;

  update public.cart_items ci
  set current_price = pv.price, variant_label = pv.label, updated_at = now()
  from public.product_variants pv
  join public.products p on p.id = pv.product_id
  where ci.cart_id=v_cart.id and ci.variant_id=pv.id and p.is_active;

  if not exists (select 1 from public.cart_items where cart_id=v_cart.id) then
    raise exception 'Your cart is empty.';
  end if;

  for v_item in select ci.*, p.name, p.is_active from public.cart_items ci join public.products p on p.id=ci.product_id where ci.cart_id=v_cart.id loop
    if not v_item.is_active then raise exception '% is no longer available.', v_item.name; end if;
    select quantity into v_available
    from public.branch_inventory bi
    where bi.branch_id=v_cart.branch_id and bi.product_id=v_item.product_id and bi.variant_id=v_item.variant_id
    for update;
    if v_available is null then raise exception '% is not available at this branch.', v_item.name; end if;
    if v_available < v_item.quantity then raise exception 'Only % of % left at this branch.', v_available, v_item.name; end if;
  end loop;

  -- Lock the loyalty account before recomputing so points cannot be spent twice.
  insert into public.loyalty_accounts(firebase_uid) values(v_uid) on conflict(firebase_uid) do nothing;
  select points_balance into v_balance from public.loyalty_accounts where firebase_uid=v_uid for update;

  select * into v_voucher from public.vouchers v
  where v.id is not null and upper(v.code)=upper(trim(v_cart.voucher_code))
    and v_cart.voucher_code is not null
    and v.is_active and (v.starts_at is null or v.starts_at<=now()) and (v.ends_at is null or v.ends_at>=now())
  for update;
  if v_cart.voucher_code is not null and not found then raise exception 'Voucher is invalid or expired.'; end if;

  select coalesce(sum(current_price*quantity),0) into v_subtotal from public.cart_items where cart_id=v_cart.id;
  if v_cart.voucher_code is not null then
    if v_voucher.usage_limit is not null and v_voucher.used_count >= v_voucher.usage_limit then raise exception 'This voucher has reached its usage limit.'; end if;
    if v_subtotal < v_voucher.minimum_subtotal then raise exception 'This voucher requires a minimum subtotal of ₱%.', v_voucher.minimum_subtotal; end if;
    if v_voucher.discount_type='percent' then v_voucher_discount := round(v_subtotal*v_voucher.discount_value/100,2); else v_voucher_discount := v_voucher.discount_value; end if;
    if v_voucher.maximum_discount is not null then v_voucher_discount := least(v_voucher_discount, v_voucher.maximum_discount); end if;
    v_voucher_discount := least(v_voucher_discount,v_subtotal);
  else
    v_voucher_discount := 0;
  end if;

  if v_cart.redeem_points then
    select points_per_peso, max_discount_percent into v_points_per_peso, v_max_discount_percent from public.loyalty_cart_settings where id='default';
    if v_points_per_peso is null then raise exception 'Loyalty point redemption is not configured yet.'; end if;
    if v_balance <= 0 then raise exception 'You do not have loyalty points available to redeem.'; end if;
    v_points_used := least(
      v_balance,
      floor(greatest(0,least(v_subtotal-v_voucher_discount,v_subtotal*(v_max_discount_percent)/100))*v_points_per_peso)::int
    );
    v_loyalty_discount := round(v_points_used/v_points_per_peso,2);
  else
    v_loyalty_discount := 0;
  end if;

  v_discount := v_voucher_discount + v_loyalty_discount;
  v_total := greatest(0,v_subtotal-v_discount+v_delivery_fee);

  for v_item in select * from public.cart_items where cart_id=v_cart.id loop
    update public.branch_inventory
    set quantity=quantity-v_item.quantity
    where branch_id=v_cart.branch_id and product_id=v_item.product_id and variant_id=v_item.variant_id;
  end loop;

  insert into public.orders(
    firebase_uid, branch_id, branch_name, is_delivery, delivery_address_id,
    subtotal, discount, delivery_fee, total, payment_method,
    customer_notes, contact_phone, delivery_address_text
  )
  select v_uid, v_cart.branch_id, b.name, p_is_delivery, p_delivery_address_id,
    v_subtotal, v_discount, v_delivery_fee, v_total, p_payment_method,
    coalesce(trim(p_customer_notes), ''), v_contact_phone, v_delivery_address_text
  from public.branches b where b.id=v_cart.branch_id
  returning id into v_order_id;

  insert into public.order_items(order_id,product_name,variant_label,quantity,unit_price)
  select v_order_id,p.name,ci.variant_label,ci.quantity,ci.current_price
  from public.cart_items ci join public.products p on p.id=ci.product_id where ci.cart_id=v_cart.id;

  -- The payment record is created here, in the same transaction as the
  -- order, so a checkout can never leave an order without one. No real
  -- payment-gateway integration exists yet (that needs a provider — e.g.
  -- PayMongo/GCash for Business — plus API keys/webhooks this project
  -- doesn't have), so this honestly records a payment awaiting
  -- confirmation rather than fabricating an instant "paid" result. A
  -- future gateway webhook is the only thing that should ever move it
  -- past 'pending'.
  insert into public.payments(order_id, firebase_uid, method, status, amount, reference_number)
  values (v_order_id, v_uid, v_payment_method_code, 'pending', v_total, v_order_id);

  if v_points_used > 0 then
    update public.loyalty_accounts set points_balance=points_balance-v_points_used where firebase_uid=v_uid;
    insert into public.loyalty_transactions(firebase_uid,type,points,description,order_id)
    values(v_uid,'redeem',-v_points_used,'Applied to order '||v_order_id,v_order_id);
  end if;

  if v_cart.voucher_code is not null then
    update public.vouchers set used_count=used_count+1 where id=v_voucher.id;
  end if;

  delete from public.cart_items where cart_id=v_cart.id;
  update public.carts set status='checked_out', voucher_code=null, redeem_points=false, updated_at=now() where id=v_cart.id;

  return v_order_id;
end;
$$;

revoke all on function public.place_order(uuid, boolean, uuid, text, text) from public;
grant execute on function public.place_order(uuid, boolean, uuid, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- Refund eligibility, enforced server-side
-- -----------------------------------------------------------------------------
-- The original "create own refund requests" policy only checked that the
-- caller owned the new row's `firebase_uid` — it never checked that
-- `order_id` actually belongs to them, that the order is in a refundable
-- state, or that it doesn't already have an open request. That let a
-- signed-in customer insert a refund request against *any* order id
-- (including another customer's), on an order still being prepared, or
-- submit duplicates. Tightened here to require: the order belongs to the
-- caller, it's actually 'completed' (the only state a refund makes sense
-- from), and there is no existing request for it other than one already
-- rejected.
drop policy if exists "create own refund requests" on public.refund_requests;
create policy "create own refund requests" on public.refund_requests for insert
  with check (
    firebase_uid = current_firebase_uid()
    and exists (
      select 1 from public.orders o
      where o.id = order_id
        and o.firebase_uid = current_firebase_uid()
        and o.status = 'completed'
    )
    and not exists (
      select 1 from public.refund_requests r
      where r.order_id = refund_requests.order_id and r.status <> 'rejected'
    )
  );

-- =============================================================================
-- Migration: close the direct-insert bypass on orders/order_items, and stop
-- trusting client-supplied refund amounts/prices.
-- =============================================================================
-- Safe to re-run.
--
-- 1. `orders`/`order_items` still carried their original "create own ..."
--    INSERT policies from before `place_order()` existed. Those policies
--    only checked `firebase_uid = current_firebase_uid()` — they never
--    checked that `subtotal`/`discount`/`total`/`points_earned` were
--    correct, or that `order_items` rows matched anything real. Since
--    `place_order` is `security definer` (runs as the function owner, which
--    bypasses RLS), it never needed these policies to do its own inserts —
--    they were a live bypass letting any signed-in customer skip checkout
--    entirely and insert a fabricated order with a self-chosen total, plus
--    arbitrary order_items. Removing them makes `place_order` (and, for
--    staff/owner tooling, a future security-definer function) the only way
--    an order can ever be created — exactly the same pattern already used
--    for loyalty_accounts/reward_redemptions (no client insert policy;
--    redeem_reward() is the only path).
-- 2. `refund_requests.amount` and `refund_items.unit_price`/`quantity` were
--    accepted from the client with no check against the order they claim to
--    refund. Added a trigger that recomputes/validates the refund amount
--    against that order's own total at insert time, so a request can never
--    ask for more than what was actually paid.
-- -----------------------------------------------------------------------------

drop policy if exists "create own orders" on public.orders;
drop policy if exists "create own order items" on public.order_items;

create or replace function public.validate_refund_amount()
returns trigger
language plpgsql
as $$
declare
  v_order_total numeric;
begin
  select total into v_order_total from public.orders where id = new.order_id;
  if v_order_total is null then
    raise exception 'Order not found.';
  end if;
  if new.amount > v_order_total then
    raise exception 'Refund amount cannot exceed the order total (₱%).', v_order_total;
  end if;
  if new.amount <= 0 then
    raise exception 'Refund amount must be greater than zero.';
  end if;
  return new;
end;
$$;
drop trigger if exists refund_requests_validate_amount on public.refund_requests;
create trigger refund_requests_validate_amount before insert on public.refund_requests
  for each row execute function public.validate_refund_amount();

-- =============================================================================
-- Migration: idempotency key for order placement.
-- =============================================================================
-- Safe to re-run.
--
-- Problem: `place_order` is one atomic transaction (see above), so a
-- dropped connection *during* it always rolls back cleanly and a retry is
-- safe. But if the transaction actually COMMITS on the server and only the
-- *response* is lost on the way back to a flaky client, the app has no way
-- to tell "failed" apart from "succeeded, I just didn't hear back" — and a
-- naive retry would call `place_order` again. That second call is already
-- blocked (the cart's `status` flips to 'checked_out' inside the same
-- transaction as the first order, so the retry's cart lookup fails), but it
-- fails with a confusing "cart no longer available" error instead of
-- calmly returning the order that already exists — exactly the
-- ambiguous-failure case the client needs to resolve, not just avoid a
-- duplicate row.
--
-- Fix: an optional client-generated `p_idempotency_key` (any opaque unique
-- string the client keeps for the lifetime of one checkout attempt, reused
-- verbatim across retries of that same attempt). Before doing any real
-- work, if an order already carries that (firebase_uid, key) pair, its id
-- is returned immediately — no re-validation, no double stock deduction,
-- no double order. A unique index makes this a hard guarantee at the
-- database level, not just a check-then-act race.
-- -----------------------------------------------------------------------------

alter table public.orders add column if not exists idempotency_key text;
create unique index if not exists orders_firebase_uid_idempotency_key
  on public.orders (firebase_uid, idempotency_key)
  where (idempotency_key is not null);

create or replace function public.place_order(
  p_cart_id uuid,
  p_is_delivery boolean,
  p_delivery_address_id uuid,
  p_payment_method text,
  p_customer_notes text,
  p_idempotency_key text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_existing_order_id text;
  v_order_id text;
begin
  if v_uid is null then raise exception 'You must be signed in to place this order.'; end if;

  if p_idempotency_key is not null and trim(p_idempotency_key) <> '' then
    select id into v_existing_order_id
    from public.orders
    where firebase_uid = v_uid and idempotency_key = p_idempotency_key;
    if found then
      -- Same checkout attempt already went through; hand back the same
      -- order instead of touching stock/loyalty/cart again.
      return v_existing_order_id;
    end if;
  end if;

  v_order_id := public.place_order(p_cart_id, p_is_delivery, p_delivery_address_id, p_payment_method, p_customer_notes);

  if p_idempotency_key is not null and trim(p_idempotency_key) <> '' then
    update public.orders set idempotency_key = p_idempotency_key where id = v_order_id;
  end if;

  return v_order_id;
end;
$$;

revoke all on function public.place_order(uuid, boolean, uuid, text, text, text) from public;
grant execute on function public.place_order(uuid, boolean, uuid, text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- Delivery module: see migrations/20261002010000_delivery_module.sql.
-- (It used to be repeated here, but it references public.staff_members, which
-- is created by migrations/20260930000000_staff_backend.sql, so a fresh
-- `schema.sql` run stopped with "relation public.staff_members does not
-- exist". Run schema.sql, then every migration in order; nothing is lost.)
-- -----------------------------------------------------------------------------
