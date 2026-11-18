-- =============================================================================
-- Melai Nuts — Migration 20261118040000: verified mobile number + first-order rule keyed on it
-- =============================================================================
-- Run after 20261118033157_staff_two_factor_totp.sql. Idempotent, one transaction.
-- The place_order core, first_order_quote, _cod_downpayment_apply and hitpay_apply_payment bodies
-- below are the ones of 20261118015010 (live) with only the lines marked VERIFIED PHONE /
-- REMAINING BALANCE added. Details: docs/PHONE_VERIFICATION.md.
--
-- WHY. The first online order must be paid online first (50% or 100%). A new account must not
-- be able to pass itself off as a paying customer by typing that customer's phone number. So:
--
-- 1. VERIFIED NUMBER. customer_profiles.verified_phone holds the account's mobile number ONLY
--    once Firebase has verified it with an SMS code: the value is taken from the Firebase ID
--    token's `phone_number` claim (Firebase sets it after phone sign-in / linking a phone; a
--    client cannot forge it), never from anything the app or website sends. Customers cannot
--    write the column (no grant). E.164, Philippine mobile (+639XXXXXXXXX).
--      * UNIQUE: one verified number = one account (partial unique index). Firebase also refuses
--        to link a number that is on another Firebase account.
--      * claim_verified_phone()   the app/website call it right after the SMS step.
--      * place_order() requires it on EVERY checkout and checks it against THIS request's token
--        (_require_verified_phone), and claims it there when not claimed yet (phone sign-in).
--      * A typed `phone` (profile / address) is only a contact number; it never counts.
--
-- 2. FIRST ORDER, keyed on account AND verified number. A customer is a returning customer
--    (no prepayment) only when ALL of these hold:
--      * the account has first_paid_order_at (set only by the HitPay webhook, 20261118015010);
--      * the account has a verified number;
--      * that number is not recorded for a DIFFERENT account in first_order_phones
--        (the number a first order was paid with, written in the same webhook transaction).
--    A new account therefore always prepays, whatever number it uses, and a number that earned
--    an exemption for one account can never be the basis of another account's exemption.
--    Legacy customers (paid before this migration, no verified number yet) prepay nothing once
--    they verify a number that no other account has paid with.
--
-- 3. ONLY THE WEBHOOK sets first_paid_order_at. A guard trigger refuses any change made by an
--    API caller (app, website, owner functions, service role) unless it comes from
--    _mark_first_paid_order(), which hitpay_apply_payment calls. owner_confirm_online_payment
--    does not call it, so an owner's manual confirmation releases the order but leaves the
--    flag untouched: the customer sees the 50% / 100% step again on the next order.
--
-- 4. REMAINING BALANCE ONLINE. For a first order paid 50% online, the other 50% (payments row)
--    can now be paid online too, when online payment is on: hitpay_claim_checkout /
--    hitpay_set_checkout open the checkout on the payments row once the downpayment is paid,
--    and hitpay_apply_payment routes that request's event to it. Cash at pickup / on delivery
--    still works; paid both ways = the owner is told to refund the online part.
--
-- 5. Live-project fixes found while reconciling the migration history:
--      * "staff: read loyalty accounts" / "staff: read loyalty history" (20261118032730) let
--        EVERY active staff member read every customer's points and history. Owners only now
--        (customers still read their own rows through their own policies).
--      * Storage: four extra product-images policies created outside the migrations
--        ("Admins can insert/update/delete product images", "Product images are publicly
--        accessible") bypassed the folder check of 20261117000000. Dropped; the 20261117000000
--        policies remain.
-- =============================================================================
begin;

-- 1. Columns -----------------------------------------------------------------------------
alter table public.customer_profiles add column if not exists verified_phone text;
alter table public.customer_profiles add column if not exists phone_verified_at timestamptz;
comment on column public.customer_profiles.verified_phone is
  'Mobile number verified by Firebase with an SMS code (E.164), taken from the ID token phone_number claim. Unique. Only this number counts for checkout and the first-order rule.';
alter table public.customer_profiles drop constraint if exists customer_profiles_verified_phone_format;
alter table public.customer_profiles add constraint customer_profiles_verified_phone_format
  check (verified_phone is null or verified_phone ~ '^\+639[0-9]{9}$');
create unique index if not exists customer_profiles_verified_phone_key
  on public.customer_profiles (verified_phone) where verified_phone is not null;
revoke insert (verified_phone, phone_verified_at), update (verified_phone, phone_verified_at)
  on public.customer_profiles from anon, authenticated;

-- The verified number each first order was paid with (one row per number).
create table if not exists public.first_order_phones (
  phone text primary key check (phone ~ '^\+639[0-9]{9}$'),
  firebase_uid text not null,
  first_paid_at timestamptz not null default now()
);
create index if not exists first_order_phones_uid_idx on public.first_order_phones (firebase_uid);
alter table public.first_order_phones enable row level security;
revoke all on public.first_order_phones from public, anon, authenticated;
grant select, insert, update, delete on public.first_order_phones to service_role;

-- 2. The number in this request's token --------------------------------------------------
-- Firebase puts phone_number (E.164) in the ID token only for a verified number.
create or replace function public.jwt_verified_phone()
returns text
language sql
stable
as $$
  select case when auth.jwt() ->> 'phone_number' ~ '^\+[1-9][0-9]{7,14}$' then auth.jwt() ->> 'phone_number' end
$$;
revoke all on function public.jwt_verified_phone() from public, anon;
grant execute on function public.jwt_verified_phone() to authenticated, service_role;

create or replace function public._claim_verified_phone(p_uid text, p_phone text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.customer_profiles;
begin
  if p_uid is null then raise exception 'Please sign in again.'; end if;
  if p_phone is null then
    raise exception 'Please verify your mobile number with the SMS code first.';
  end if;
  if p_phone !~ '^\+639[0-9]{9}$' then
    raise exception 'Please verify a Philippine mobile number (09XX XXX XXXX).';
  end if;
  -- One claim per number at a time, so two accounts cannot take it at the same moment.
  perform pg_advisory_xact_lock(hashtextextended('melai:verified-phone:' || p_phone, 0));
  select * into v_profile from public.customer_profiles where firebase_uid = p_uid for update;
  if not found then raise exception 'Your customer profile is not set up yet. Please sign in again.'; end if;
  if exists (select 1 from public.customer_profiles
             where verified_phone = p_phone and firebase_uid <> p_uid) then
    raise exception 'This mobile number is already verified on another Melai Nuts account. Sign in to that account, or verify a different number.';
  end if;
  if v_profile.verified_phone is distinct from p_phone then
    update public.customer_profiles
       set verified_phone = p_phone, phone_verified_at = now(), phone = p_phone
     where firebase_uid = p_uid;
  end if;
  -- Paid before numbers were verified: this number becomes the one that customer paid with,
  -- unless another account already paid with it.
  if v_profile.first_paid_order_at is not null then
    insert into public.first_order_phones (phone, firebase_uid, first_paid_at)
    values (p_phone, p_uid, v_profile.first_paid_order_at)
    on conflict (phone) do nothing;
  end if;
  return p_phone;
end;
$$;
revoke all on function public._claim_verified_phone(text, text) from public, anon, authenticated;

-- The app / website call this right after the SMS step (with a refreshed ID token).
create or replace function public.claim_verified_phone()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_phone text;
begin
  v_phone := public._claim_verified_phone(v_uid, public.jwt_verified_phone());
  return jsonb_build_object('verified_phone', v_phone, 'first_order', public._is_first_order(v_uid));
end;
$$;
revoke all on function public.claim_verified_phone() from public, anon;
grant execute on function public.claim_verified_phone() to authenticated;

-- Used by place_order: the verified number of the account, proven by this request's token.
create or replace function public._require_verified_phone(p_uid text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token_phone text := public.jwt_verified_phone();
  v_stored text;
begin
  select verified_phone into v_stored from public.customer_profiles where firebase_uid = p_uid;
  if v_token_phone is null then
    raise exception 'Please verify your mobile number with an SMS code before checking out.';
  end if;
  if v_stored is distinct from v_token_phone then
    -- First time, or the account's Firebase number changed: claim it (refused when taken).
    v_stored := public._claim_verified_phone(p_uid, v_token_phone);
  end if;
  return v_stored;
end;
$$;
revoke all on function public._require_verified_phone(text) from public, anon, authenticated;

-- {phone_verified, verified_phone, phone_claimable} for the checkout preview (no writes).
create or replace function public._phone_status(p_uid text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'phone_verified', coalesce(cp.verified_phone is not null and cp.verified_phone = public.jwt_verified_phone(), false),
    'verified_phone', case when cp.verified_phone = public.jwt_verified_phone() then cp.verified_phone end,
    'phone_claimable', coalesce(public.jwt_verified_phone() is not null
      and cp.verified_phone is distinct from public.jwt_verified_phone()
      and public.jwt_verified_phone() ~ '^\+639[0-9]{9}$'
      and not exists (select 1 from public.customer_profiles o
                      where o.verified_phone = public.jwt_verified_phone() and o.firebase_uid <> p_uid), false))
  from (select (select verified_phone from public.customer_profiles where firebase_uid = p_uid) as verified_phone) cp
$$;
revoke all on function public._phone_status(text) from public, anon, authenticated;

-- 3. First order: account AND verified number ------------------------------------------------
create or replace function public._is_first_order(p_uid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_uid is not null and not exists (
    select 1 from public.customer_profiles cp
    where cp.firebase_uid = p_uid
      and cp.first_paid_order_at is not null
      and cp.verified_phone is not null
      and not exists (select 1 from public.first_order_phones f
                      where f.phone = cp.verified_phone and f.firebase_uid <> cp.firebase_uid))
$$;
revoke all on function public._is_first_order(text) from public, anon, authenticated;

-- Called only from hitpay_apply_payment. Conditional (only while still NULL), and the only
-- writer the guard below lets through. Records the verified number the order was paid with;
-- a number whose earlier owner no longer has it verified (a recycled number) moves over.
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
  perform set_config('app.first_order_mark', 'on', true);
  update public.customer_profiles cp
     set first_paid_order_at = now()
    from public.orders o
   where o.id = p_order_id
     and cp.firebase_uid = o.firebase_uid
     and cp.first_paid_order_at is null
     and o.status <> 'cancelled'
     and not exists (select 1 from public.pos_sales ps where ps.order_id = o.id)
  returning cp.firebase_uid, cp.verified_phone into v_uid, v_phone;
  perform set_config('app.first_order_mark', 'off', true);

  if v_uid is not null and v_phone is not null then
    insert into public.first_order_phones as f (phone, firebase_uid, first_paid_at)
    values (v_phone, v_uid, now())
    on conflict (phone) do update
      set firebase_uid = excluded.firebase_uid, first_paid_at = excluded.first_paid_at
      where not exists (select 1 from public.customer_profiles x
                        where x.firebase_uid = f.firebase_uid and x.verified_phone = f.phone);
  end if;
end;
$$;
revoke all on function public._mark_first_paid_order(text) from public, anon, authenticated;

-- 4. Guard: only the webhook path changes first_paid_order_at ---------------------------------
-- Any API caller (role claim authenticated / anon / service_role, which includes every
-- security-definer function they call, such as owner_confirm_online_payment) is refused unless
-- the change runs inside _mark_first_paid_order. The SQL editor / migrations (no API role)
-- are not affected.
create or replace function public._guard_first_paid_order_at()
returns trigger
language plpgsql
as $$
begin
  if new.first_paid_order_at is distinct from old.first_paid_order_at
     and coalesce(current_setting('app.first_order_mark', true), '') <> 'on'
     and coalesce(auth.jwt() ->> 'role', '') in ('authenticated', 'anon', 'service_role') then
    raise exception 'first_paid_order_at is set only by the HitPay payment webhook.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function public._guard_first_paid_order_at() from public, anon, authenticated;
drop trigger if exists customer_profiles_guard_first_paid on public.customer_profiles;
create trigger customer_profiles_guard_first_paid
  before update of first_paid_order_at on public.customer_profiles
  for each row execute function public._guard_first_paid_order_at();

-- 5. Remaining balance online: checkout on the payments row once the downpayment is paid ------
-- Same as 20261027000000 / 20261101083000, plus the REMAINING BALANCE branch.
create or replace function public._first_order_balance_open(p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.order_downpayments d
    join public.orders o on o.id = d.order_id
    join public.payments p on p.order_id = d.order_id
    where d.order_id = p_order_id
      and d.kind = 'first_order' and d.status = 'success'
      and o.status not in ('awaitingDownpayment', 'cancelled', 'refundRequested', 'refunded', 'completed')
      and p.amount > 0)
$$;
revoke all on function public._first_order_balance_open(text) from public, anon, authenticated;

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
  if found and v_dp.kind = 'first_order' and v_dp.status = 'success' then
    -- REMAINING BALANCE: the payments row below, while the order is still open.
    if not public._first_order_balance_open(p_order_id) then
      return jsonb_build_object('action', 'closed', 'status', 'success');
    end if;
  elsif found then
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
revoke all on function public.hitpay_claim_checkout(text, int) from public, anon, authenticated;
grant execute on function public.hitpay_claim_checkout(text, int) to service_role;

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
  if found and not (v_dp.kind = 'first_order' and v_dp.status = 'success') then
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
revoke all on function public.hitpay_set_checkout(text, text, text) from public, anon, authenticated;
grant execute on function public.hitpay_set_checkout(text, text, text) to service_role;

-- 6. place_order: the body of 20261118015010, plus the verified phone (marked VERIFIED PHONE)
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
  v_verified_phone text;
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
  -- VERIFIED PHONE (20261118040000). Every checkout needs the account's verified mobile
  -- number, proven by THIS request's Firebase ID token (phone_number claim, set by Firebase
  -- only after an SMS code). Claimed here when the account has not claimed one yet.
  v_verified_phone := public._require_verified_phone(v_uid);

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
    v_contact_phone := v_verified_phone;   -- pickup: the verified number, never a typed one
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
  -- (migration 20261118000000). Nothing to pay (a fully discounted order) = no rule.
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

-- 7. Checkout preview: + phone_verified / verified_phone / phone_claimable
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
  v_phone jsonb;
begin
  if v_uid is null then raise exception 'Please sign in to check out.'; end if;
  -- Whether this request can check out at all (verified mobile number), see phone_status().
  v_phone := public._phone_status(v_uid);
  if not public._is_first_order(v_uid) then
    return jsonb_build_object('first_order', false) || v_phone;
  end if;
  v_total := round(coalesce((public._calculate_cart_pricing(p_cart_id, coalesce(p_is_delivery, false)) ->> 'total')::numeric, 0), 2);
  if v_total <= 0 then
    return jsonb_build_object('first_order', false) || v_phone;
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
    'online_payment_enabled', public.online_payment_enabled()) || v_phone;
end;
$$;
revoke all on function public.first_order_quote(uuid, boolean) from public, anon;
grant execute on function public.first_order_quote(uuid, boolean) to authenticated;

-- 8. Downpayment paid: the customer is told the balance can be paid online
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

    if p_dp.kind = 'first_order' and p_dp.amount >= p_order.total then
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

revoke all on function public._cod_downpayment_apply(public.orders, public.order_downpayments, text, text, text, text) from public, anon, authenticated;

-- 9. Webhook: the remaining balance of a 50% first order can be paid online
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
  v_result text;
  v_balance boolean := false;
  v_balance_request text;
begin
  if p_status is null or p_status not in ('success', 'failed') then
    return null;
  end if;

  -- The order first, so a cancel running right now is seen here or sees this payment.
  select * into v_order from public.orders where id = p_order_id for update;
  select * into v_dp from public.order_downpayments where order_id = p_order_id for update;
  -- REMAINING BALANCE (20261118040000): a first order paid 50% online whose downpayment is
  -- already paid. The event of the balance checkout goes to the payments row below, never to
  -- the downpayment.
  -- Routed by the payment request the balance checkout stored on the payments row, so a
  -- repeated event of the downpayment can never be taken for the balance.
  if found and v_dp.kind = 'first_order' and v_dp.status = 'success' and v_request_id is not null then
    select gateway_payment_id into v_balance_request from public.payments where order_id = p_order_id;
    v_balance := v_balance_request is not distinct from v_request_id;
  end if;
  if v_dp.order_id is not null and not v_balance then
    v_result := public._cod_downpayment_apply(v_order, v_dp, p_status, v_method, v_gateway_payment_id, v_request_id);
    -- Paid now (not before), for an order that was not cancelled first: the customer's
    -- first paid online order is used up, in this same transaction.
    if v_result = 'success' and v_dp.status not in ('success', 'refunded', 'forfeited')
       and v_order.status is distinct from 'cancelled' then
      perform public._mark_first_paid_order(v_order.id);
    end if;
    return v_result;
  end if;
  select * into v_pay from public.payments where order_id = p_order_id for update;
  if not found then return null; end if;

  if v_pay.status = 'success' or v_pay.status = 'refunded' then
    -- The balance was collected in cash while its online checkout was still open, and the
    -- customer paid online too: the owner is told to send the online part back (HitPay
    -- dashboard). The order itself goes on; no refund request, which would stop it.
    if v_balance and p_status = 'success' and v_pay.status = 'success' and v_pay.method = 'cash'
       and v_pay.gateway_payment_id is not distinct from v_request_id and v_pay.amount > 0 then
      insert into public.staff_notifications (recipient_uid, branch_id, category, title, body, reference)
      select s.firebase_uid, v_order.branch_id, 'refund', 'Refund needed: balance paid twice',
             'Order ' || v_order.id || ' • ₱' || to_char(v_pay.amount, 'FM999,999,990.00')
               || ' paid online (HitPay ' || coalesce(v_gateway_payment_id, v_request_id) || ') after it was paid in cash. Refund it in HitPay.',
             v_order.id
      from public.staff_members s
      where s.is_active and s.role = 'owner';
      perform public.notify_customer(v_order.firebase_uid, 'refund', 'Balance paid twice',
        'We received ₱' || to_char(v_pay.amount, 'FM999,999,990.00') || ' online for order ' || v_order.id
          || ', but the balance was already paid in cash. We will refund the online payment.');
    end if;
    return v_pay.status;
  end if;
  if p_status = 'failed' and v_pay.status = 'failed' then
    return v_pay.status;
  end if;
  -- A "failed" event from an older link never touches the current one.
  if p_status = 'failed' and v_pay.gateway_payment_id is distinct from v_request_id then
    return v_pay.status;
  end if;

  -- REMAINING BALANCE: a failed online attempt leaves the balance open (pending), so it can
  -- still be paid online again or in cash at the counter / on delivery.
  if v_balance and p_status = 'failed' then
    update public.payments set status = 'failed' where id = v_pay.id and status = 'processing';
    update public.payments
       set status = 'pending', gateway_checkout_url = null, gateway_checkout_created_at = null, checkout_started_at = null
     where id = v_pay.id and status in ('pending', 'failed');
    return 'failed';
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

  if p_status = 'success' and v_order.status is distinct from 'cancelled' then
    perform public._mark_first_paid_order(v_order.id);
  end if;

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

revoke all on function public.hitpay_apply_payment(text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.hitpay_apply_payment(text, text, text, text, text, text) to service_role;

-- 10. Live-project fixes ---------------------------------------------------------------------
create or replace function public.is_active_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.staff_members s
                 where s.firebase_uid = public.current_firebase_uid()
                   and s.account_status = 'active' and s.role = 'owner')
$$;
revoke all on function public.is_active_owner() from public, anon;
grant execute on function public.is_active_owner() to authenticated;

-- Customers' points and history are personal data: owners only (not every staff member).
drop policy if exists "staff: read loyalty accounts" on public.loyalty_accounts;
create policy "staff: read loyalty accounts" on public.loyalty_accounts
  for select to authenticated using (public.is_active_owner());
drop policy if exists "staff: read loyalty history" on public.loyalty_transactions;
create policy "staff: read loyalty history" on public.loyalty_transactions
  for select to authenticated using (public.is_active_owner());

-- Product photos: only the policies of 20261117000000 (folder of an existing product, active
-- owner via security-definer helpers). The extra ones below were added outside the migrations
-- and let an owner write any path in the bucket.
do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'objects') then
    execute $p$drop policy if exists "Admins can insert product images" on storage.objects$p$;
    execute $p$drop policy if exists "Admins can update product images" on storage.objects$p$;
    execute $p$drop policy if exists "Admins can delete product images" on storage.objects$p$;
    execute $p$drop policy if exists "Product images are publicly accessible" on storage.objects$p$;
  end if;
end
$do$;

commit;

notify pgrst, 'reload schema';
