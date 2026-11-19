-- =============================================================================
-- Melai Nuts — Migration 20261119000000: no SMS check of the mobile number; the first order
-- is still paid online first (50% or 100%), with a phone-match safeguard
-- =============================================================================
-- Run after 20261118070000_staff_offline_sync.sql. Idempotent, one transaction.
-- Replaces the verified-number part of 20261118040000 (the phone-number verification step is
-- gone from the app and the website). The mobile number is an ordinary profile / contact field
-- again, checked for its format only (09XXXXXXXXX).
--
-- FIRST ORDER (unchanged rule, decided on the server only):
--   * Keyed on the ACCOUNT: customer_profiles.first_paid_order_at (Firebase UID). NULL = the
--     next order is paid online first, 50% or 100%.
--   * Set ONLY by the HitPay webhook (hitpay_apply_payment -> _mark_first_paid_order). The guard
--     trigger of 20261118040000 still refuses every other writer, so the client and the owner's
--     manual payment confirmation (owner_confirm_online_payment) never use it up.
--
-- PHONE-MATCH SAFEGUARD (new). Without an SMS check, a number proves nothing, so it can only
-- ever ADD the prepayment, never remove it:
--   * first_order_phones now holds (normalized number, account) for every account that paid an
--     online order with that number on its profile (written by the webhook; backfilled below
--     for every customer who already paid, so nobody who paid is penalized).
--   * _is_first_order(uid) is TRUE (prepay) when the account has no first_paid_order_at, OR when
--     its profile number matches a number another account already paid with and this account
--     never paid with that number itself. Signing up is never refused for this reason.
--   * Numbers are compared normalized with the existing normalize_ph_mobile() (20261025000000):
--     0917 123 4567, 639171234567 and +639171234567 are the same number.
--
-- CLEAN-UP: claim_verified_phone(), _claim_verified_phone(), _require_verified_phone(),
-- _phone_status(), jwt_verified_phone() and the columns customer_profiles.verified_phone /
-- phone_verified_at are dropped. A verified number is first copied into customer_profiles.phone
-- when that is empty, and into first_order_phones, so existing accounts keep their number and
-- their returning-customer status. first_order_quote no longer returns phone_* fields.
-- =============================================================================
begin;

-- 1. Keep what the verified number gave existing accounts ---------------------------------
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'customer_profiles' and column_name = 'verified_phone') then
    -- The verified number becomes the profile number when the profile has none.
    execute $q$update public.customer_profiles
                  set phone = verified_phone
                where verified_phone is not null and coalesce(trim(phone), '') = ''$q$;
  end if;
end $$;

-- first_order_phones: one row per (number, account) instead of one per number, so two accounts
-- that both paid with a shared family number are both returning customers.
create table if not exists public.first_order_phones (
  phone text not null check (phone ~ '^\+639[0-9]{9}$'),
  firebase_uid text not null,
  first_paid_at timestamptz not null default now()
);
do $$
declare v_cols text;
begin
  select string_agg(a.attname, ',' order by a.attname) into v_cols
  from pg_constraint c
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
  where c.conrelid = 'public.first_order_phones'::regclass and c.contype = 'p';
  if v_cols is distinct from 'firebase_uid,phone' then
    if v_cols is not null then
      execute (select format('alter table public.first_order_phones drop constraint %I', conname)
               from pg_constraint where conrelid = 'public.first_order_phones'::regclass and contype = 'p');
    end if;
    alter table public.first_order_phones add primary key (phone, firebase_uid);
  end if;
end $$;
create index if not exists first_order_phones_uid_idx on public.first_order_phones (firebase_uid);
alter table public.first_order_phones enable row level security;
revoke all on public.first_order_phones from public, anon, authenticated;
grant select, insert, update, delete on public.first_order_phones to service_role;

-- Every customer who already paid: their current profile number counts as paid with.
insert into public.first_order_phones (phone, firebase_uid, first_paid_at)
select public.normalize_ph_mobile(cp.phone), cp.firebase_uid, cp.first_paid_order_at
from public.customer_profiles cp
where cp.first_paid_order_at is not null and public.normalize_ph_mobile(cp.phone) ~ '^\+639[0-9]{9}$'
on conflict (phone, firebase_uid) do nothing;

-- 2. First order: the account, plus the phone-match safeguard -------------------------------
create or replace function public._is_first_order(p_uid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_uid is null
    or not exists (select 1 from public.customer_profiles cp
                   where cp.firebase_uid = p_uid and cp.first_paid_order_at is not null)
    or exists (
      select 1
      from public.customer_profiles cp
      join public.first_order_phones f on f.phone = public.normalize_ph_mobile(cp.phone)
      where cp.firebase_uid = p_uid
        and f.firebase_uid <> p_uid
        and not exists (select 1 from public.first_order_phones own
                        where own.phone = f.phone and own.firebase_uid = p_uid))
$$;
revoke all on function public._is_first_order(text) from public, anon, authenticated;

-- Called only from hitpay_apply_payment (the HitPay webhook). Sets first_paid_order_at once
-- (only while still NULL: the only writer the guard trigger lets through) and records the
-- profile number the order was paid with. Never called by owner_confirm_online_payment.
create or replace function public._mark_first_paid_order(p_order_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text;
  v_phone text;
begin
  select o.firebase_uid, public.normalize_ph_mobile(cp.phone) into v_uid, v_phone
  from public.orders o
  join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
  where o.id = p_order_id
    and o.status <> 'cancelled'
    and not exists (select 1 from public.pos_sales ps where ps.order_id = o.id);
  if v_uid is null then return; end if;

  perform set_config('app.first_order_mark', 'on', true);
  update public.customer_profiles
     set first_paid_order_at = now()
   where firebase_uid = v_uid and first_paid_order_at is null;
  perform set_config('app.first_order_mark', 'off', true);

  if v_phone ~ '^\+639[0-9]{9}$' then
    insert into public.first_order_phones (phone, firebase_uid, first_paid_at)
    values (v_phone, v_uid, now())
    on conflict (phone, firebase_uid) do nothing;
  end if;
end;
$$;
revoke all on function public._mark_first_paid_order(text) from public, anon, authenticated;

-- 3. place_order: the body of 20261118040000 without the verified number --------------------
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
      raise exception 'Your first order is paid online: choose to pay 50%% or 100%% now. Cash payment is available from your next order.';
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
  elsif p_payment_method = 'Cash on Counter Pickup' then
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

revoke all on function public._place_order_core(uuid, boolean, uuid, text, text, text) from public, anon, authenticated;

-- 4. Checkout preview: no phone_* fields -------------------------------------------------------
create or replace function public.first_order_quote(p_cart_id uuid, p_is_delivery boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_total numeric;
  v_half numeric;
  v_pending text;
  v_expiry int;
begin
  if v_uid is null then raise exception 'Please sign in to check out.'; end if;
  if not public._is_first_order(v_uid) then
    return jsonb_build_object('first_order', false);
  end if;
  v_total := round(coalesce((public._calculate_cart_pricing(p_cart_id, coalesce(p_is_delivery, false)) ->> 'total')::numeric, 0), 2);
  if v_total <= 0 then
    return jsonb_build_object('first_order', false);
  end if;
  v_half := round(v_total * 0.5, 2);
  select o.id into v_pending
  from public.orders o join public.order_downpayments d on d.order_id = o.id
  where o.firebase_uid = v_uid and o.status = 'awaitingDownpayment' and d.kind = 'first_order'
  order by o.created_at limit 1;
  select cod_downpayment_expiry_minutes into v_expiry from public.business_settings where id = 'default';
  return jsonb_build_object(
    'first_order', true,
    'total', v_total,
    'half_amount', v_half,
    'half_balance', v_total - v_half,
    'full_amount', v_total,
    'expiry_minutes', coalesce(v_expiry, 30),
    'pending_order_id', v_pending,
    'online_payment_enabled', public.online_payment_enabled());
end;
$$;
revoke all on function public.first_order_quote(uuid, boolean) from public, anon;
grant execute on function public.first_order_quote(uuid, boolean) to authenticated;

-- 5. Remove the verified-number pieces -----------------------------------------------------
drop function if exists public.claim_verified_phone();
drop function if exists public._claim_verified_phone(text, text);
drop function if exists public._require_verified_phone(text);
drop function if exists public._phone_status(text);
drop function if exists public.jwt_verified_phone();
drop index if exists public.customer_profiles_verified_phone_key;
alter table public.customer_profiles drop constraint if exists customer_profiles_verified_phone_format;
alter table public.customer_profiles drop column if exists verified_phone;
alter table public.customer_profiles drop column if exists phone_verified_at;
comment on table public.first_order_phones is
  'Mobile numbers (normalized, +639XXXXXXXXX) each account had on its profile when the HitPay webhook confirmed one of its online payments. A profile number paid with by ANOTHER account (and never by this one) keeps the first-order prepayment on (_is_first_order).';

commit;
