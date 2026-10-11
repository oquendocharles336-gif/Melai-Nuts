-- =============================================================================
-- Melai Nuts — order / payment / loyalty INTEGRITY test suite
-- =============================================================================
-- Proves that checkout is all-or-nothing and that the data can never become
-- inconsistent, even through paths the app does not use today.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/order_integrity_test.sql
--
-- DEV / STAGING ONLY. Everything runs in one transaction that is rolled back.
-- Prerequisites: schema.sql, then BOTH migrations in supabase/migrations/.
-- Ends by raising an error if any check failed (CI-friendly).
--
-- Concurrency (two sessions racing) cannot be tested inside one transaction;
-- see supabase/tests/concurrency_test.sh for that.
-- =============================================================================

begin;

-- These checks cover online-paid orders: switch online payment on inside this
-- rolled-back transaction (it is off by default, migration 20261017000000).
do $$ begin
  if to_regclass('public.payment_settings') is not null then
    update public.payment_settings set online_payment_enabled = true where id = 'default';
  end if;
end $$;

create temp table results (id serial primary key, name text not null, passed boolean not null, detail text);
create temp table fx (k text primary key, v text);

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_uid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated',
    'email', p_uid || '@test.local', 'email_verified', true)::text, true);
  execute 'set local role authenticated';
end $$;

create function pg_temp.back_to_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
grant execute on function pg_temp.back_to_admin() to public;

-- Runs p_sql (as customer p_uid, or as the trusted owner when p_uid = '__admin__').
-- p_expect: 'ok' | 'error' | 'like:<pattern>' (must fail with a message matching the pattern)
create function pg_temp.chk(p_name text, p_uid text, p_sql text, p_expect text) returns void language plpgsql as $$
declare v_err text;
begin
  if p_uid <> '__admin__' then perform pg_temp.act_as(p_uid); end if;
  begin
    execute p_sql;
  exception when others then
    v_err := sqlerrm;
  end;
  perform pg_temp.back_to_admin();
  insert into results(name, passed, detail) values (
    p_name,
    case when p_expect = 'ok' then v_err is null
         when p_expect = 'error' then v_err is not null
         when p_expect like 'like:%' then coalesce(v_err ilike '%' || substr(p_expect, 6) || '%', false)
         else false end,
    'expected ' || p_expect || ' -> ' || coalesce('error: ' || v_err, 'no error'));
end $$;

create function pg_temp.call_as(p_uid text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.act_as(p_uid);
  begin
    execute p_sql into v;
  exception when others then
    perform pg_temp.back_to_admin();
    raise;
  end;
  perform pg_temp.back_to_admin();
  return v;
end $$;

create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into public.branches (name, address, supports_delivery, supports_pickup, delivery_fee)
values ('INT-TEST Branch', 'test', true, true, 30);
insert into public.product_categories (label) values ('INT-TEST Category');
insert into public.products (category_id, name, price, unit)
select id, p.n, 100, 'pack' from public.product_categories, (values ('INT-TEST Nut'), ('INT-TEST Other')) p(n)
where label = 'INT-TEST Category';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name in ('INT-TEST Nut', 'INT-TEST Other');
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select b.id, v.product_id, v.id, 10
from public.branches b, public.product_variants v
where b.name = 'INT-TEST Branch' and v.product_id = (select id from public.products where name = 'INT-TEST Nut');

insert into fx select 'branch', id::text from public.branches where name = 'INT-TEST Branch';
insert into fx select 'product', id::text from public.products where name = 'INT-TEST Nut';
insert into fx select 'variant', id::text from public.product_variants
  where product_id = (select id from public.products where name = 'INT-TEST Nut');
insert into fx select 'other_variant', id::text from public.product_variants
  where product_id = (select id from public.products where name = 'INT-TEST Other');

insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('i_a', 'Ann', 'i_a@test.local', '09170000001'),
  ('i_b', 'Ben', 'i_b@test.local', '09170000002');
insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city)
values ('i_b', 'Ben', '09170000002', '2 Test St', 'Calamba');
insert into fx select 'addr_b', id::text from public.customer_addresses where firebase_uid = 'i_b';

insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point)
values ('default', 1, 50, 50)
  on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;

-- Ann starts with 60 points, recorded in the ledger so balance == ledger.
insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points) values ('i_a', 60, 60);
insert into public.loyalty_transactions (firebase_uid, type, points, description) values ('i_a', 'earn', 60, 'seed');

insert into public.vouchers (code, discount_type, discount_value, per_customer_limit) values
  ('INTTEST10', 'percent', 10, 1),
  ('INTFREE', 'percent', 100, null);

-- State snapshot used to prove "nothing changed".
create function pg_temp.snap() returns jsonb language sql as $$
  select jsonb_build_object(
    'stock',        (select quantity from public.branch_inventory where variant_id = (select v from fx where k = 'variant')::uuid),
    'orders',       (select count(*) from public.orders where firebase_uid = 'i_a'),
    'order_items',  (select count(*) from public.order_items oi join public.orders o on o.id = oi.order_id where o.firebase_uid = 'i_a'),
    'payments',     (select count(*) from public.payments where firebase_uid = 'i_a'),
    'points',       (select points_balance from public.loyalty_accounts where firebase_uid = 'i_a'),
    'ledger',       (select count(*) from public.loyalty_transactions where firebase_uid = 'i_a'),
    'voucher_used', (select used_count from public.vouchers where code = 'INTTEST10'),
    'voucher_rows', (select count(*) from public.voucher_usage where firebase_uid = 'i_a'),
    'cart_status',  (select string_agg(status, ',' order by status) from public.carts where firebase_uid = 'i_a'),
    'cart_items',   (select count(*) from public.cart_items ci join public.carts c on c.id = ci.cart_id where c.firebase_uid = 'i_a'),
    'status_events',(select count(*) from public.order_status_events e join public.orders o on o.id = e.order_id where o.firebase_uid = 'i_a')
  )
$$;

-- ===========================================================================
-- 1. CHECKOUT IS ALL-OR-NOTHING: force each step to fail, prove nothing leaks
-- ===========================================================================
-- Ann's cart uses everything at once: 2 units, a voucher AND loyalty points, so
-- every write in place_order() (stock, order, lines, payment, points ledger,
-- voucher usage, cart conversion) is exercised.
do $$
declare v_pricing jsonb;
begin
  v_pricing := pg_temp.call_as('i_a', format(
    $q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
         'product_id', %L, 'variant_id', %L, 'quantity', 2)), 'inttest10', true)::text$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'variant')))::jsonb;
  insert into fx values ('cart_a', v_pricing ->> 'cart_id');
end $$;

select pg_temp.chk_true('cart preview matches what checkout will charge: 200 - 20 voucher - 60 points = 120',
  (pg_temp.call_as('i_a', format($q$select get_cart_pricing(%L::uuid, false)::text$q$, (select v from fx where k = 'cart_a')))::jsonb ->> 'total')::numeric = 120,
  pg_temp.call_as('i_a', format($q$select get_cart_pricing(%L::uuid, false)::text$q$, (select v from fx where k = 'cart_a'))));

create function public.zz_fail() returns trigger language plpgsql as $$
begin
  raise exception 'INJECTED FAILURE on % %', tg_table_name, tg_op;
end $$;

do $$
declare
  inj record;
  v_before jsonb;
  v_after jsonb;
  v_errored boolean;
  v_msg text;
begin
  v_before := pg_temp.snap();
  for inj in
    select * from (values
      ('branches',             'update'),   -- (never touched: control, must NOT fail checkout... see below)
      ('branch_inventory',     'update'),   -- step 12: stock deduction
      ('orders',               'insert'),   -- step 10: order row
      ('order_items',          'insert'),   -- step 11: order lines
      ('payments',             'insert'),   -- step 13: payment record
      ('loyalty_transactions', 'insert'),   -- step 14: loyalty ledger
      ('loyalty_accounts',     'update'),   -- step 14: loyalty balance
      ('voucher_usage',        'insert'),   -- step  7: voucher accounting
      ('vouchers',             'update'),   -- step  7: voucher counter
      ('order_status_events',  'insert'),   -- order history
      ('carts',                'update')    -- step 15: cart conversion
    ) t(tbl, ev)
  loop
    continue when inj.tbl = 'branches';
    execute format('create trigger zz_fail before %s on public.%I for each row execute function public.zz_fail()', inj.ev, inj.tbl);
    v_errored := false; v_msg := null;
    begin
      perform pg_temp.call_as('i_a', format(
        $q$select place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', %L)$q$,
        (select v from fx where k = 'cart_a'), 'inj-' || inj.tbl || '-' || inj.ev));
    exception when others then
      v_errored := true; v_msg := sqlerrm;
    end;
    execute format('drop trigger zz_fail on public.%I', inj.tbl);
    v_after := pg_temp.snap();
    insert into results(name, passed, detail) values (
      format('checkout aborts and leaves NOTHING behind when the %s %s step fails', inj.tbl, inj.ev),
      v_errored and v_after = v_before and (v_msg like 'INJECTED FAILURE%'),
      case when v_after = v_before then 'state identical to before; ' else 'STATE CHANGED: ' || v_after::text || ' vs ' || v_before::text || '; ' end || coalesce(v_msg, 'NO ERROR RAISED'));
  end loop;
end $$;

select pg_temp.chk_true('after all injected failures the cart is still open with its items (customer loses nothing)',
  (select count(*) from public.carts where firebase_uid = 'i_a' and status = 'open') = 1
  and (select count(*) from public.cart_items where cart_id = (select v from fx where k = 'cart_a')::uuid) = 1);

-- Notifications are NOT critical: a broken notification must never cost the customer an order.
create trigger zz_fail before insert on public.notifications for each row execute function public.zz_fail();
do $$
begin
  insert into fx values ('order_a', pg_temp.call_as('i_a', format(
    $q$select place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'idem-a')$q$, (select v from fx where k = 'cart_a'))));
end $$;
drop trigger zz_fail on public.notifications;
drop function public.zz_fail();

select pg_temp.chk_true('a failing notification does NOT roll back a successful checkout',
  exists (select 1 from public.orders where id = (select v from fx where k = 'order_a')));

-- The successful order: every one of the 16 steps landed together.
select pg_temp.chk_true('order total = 200 - 20 voucher - 60 points = 120',
  (select total from public.orders where id = (select v from fx where k = 'order_a')) = 120,
  'total=' || (select total::text from public.orders where id = (select v from fx where k = 'order_a')));
select pg_temp.chk_true('order lines saved with product and variant ids',
  (select count(*) from public.order_items where order_id = (select v from fx where k = 'order_a')
     and product_id is not null and variant_id is not null and quantity = 2 and unit_price = 100) = 1);
select pg_temp.chk_true('stock deducted 10 -> 8',
  (select quantity from public.branch_inventory where variant_id = (select v from fx where k = 'variant')::uuid) = 8);
select pg_temp.chk_true('exactly one payment for exactly the order total',
  (select count(*) from public.payments where order_id = (select v from fx where k = 'order_a') and amount = 120 and status = 'pending') = 1);
select pg_temp.chk_true('loyalty points debited (60 -> 0) with a matching ledger row',
  (select points_balance from public.loyalty_accounts where firebase_uid = 'i_a') = 0
  and exists (select 1 from public.loyalty_transactions where order_id = (select v from fx where k = 'order_a') and points = -60 and source = 'order_redeem'));
select pg_temp.chk_true('voucher use recorded once (counter and per-customer row)',
  (select used_count from public.vouchers where code = 'INTTEST10') = 1
  and (select count(*) from public.voucher_usage where order_id = (select v from fx where k = 'order_a')) = 1);
select pg_temp.chk_true('cart converted (checked out, emptied, voucher and points cleared)',
  (select status from public.carts where id = (select v from fx where k = 'cart_a')::uuid) = 'checked_out'
  and not exists (select 1 from public.cart_items where cart_id = (select v from fx where k = 'cart_a')::uuid));
select pg_temp.chk_true('replaying the same checkout key returns the same order and changes nothing',
  pg_temp.call_as('i_a', format($q$select place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'idem-a')$q$,
    (select v from fx where k = 'cart_a'))) = (select v from fx where k = 'order_a')
  and (select count(*) from public.orders where firebase_uid = 'i_a') = 1
  and (select quantity from public.branch_inventory where variant_id = (select v from fx where k = 'variant')::uuid) = 8);

-- ===========================================================================
-- 2. Validation steps reject bad input WITHOUT side effects
-- ===========================================================================
select pg_temp.chk('customer without a profile is refused with a clear message', 'i_ghost',
  format($q$select place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'g1')$q$, (select v from fx where k = 'cart_a')),
  'like:profile is not set up');
select pg_temp.chk('the same voucher cannot be used twice by one customer (per-customer limit)', 'i_a',
  format($q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
      'product_id', %L, 'variant_id', %L, 'quantity', 1)), 'INTTEST10', false)$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'variant')),
  'like:already used this voucher');
select pg_temp.chk('an unknown voucher is rejected', 'i_b',
  format($q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
      'product_id', %L, 'variant_id', %L, 'quantity', 1)), 'NOPE', false)$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'variant')),
  'like:invalid or expired');
select pg_temp.chk('a variant that belongs to another product is rejected', 'i_b',
  format($q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
      'product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false)$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'other_variant')),
  'error');
select pg_temp.chk('Ann cannot use the loyalty ledger she no longer has (0 points, redeem flag)', 'i_a',
  format($q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
      'product_id', %L, 'variant_id', %L, 'quantity', 1)), null, true)$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'variant')),
  'like:do not have loyalty points');

-- ===========================================================================
-- 3. Order state machine (applies to EVERY writer, here the trusted owner)
-- ===========================================================================
select pg_temp.chk('unpaid order cannot be completed', '__admin__',
  format($$update public.orders set status = 'completed' where id = %L$$, (select v from fx where k = 'order_a')),
  'like:payment is confirmed');
select pg_temp.chk('pickup order cannot go out for delivery', '__admin__',
  format($$update public.orders set status = 'outForDelivery' where id = %L$$, (select v from fx where k = 'order_a')), 'error');
select pg_temp.chk('pending order cannot jump straight to refunded', '__admin__',
  format($$update public.orders set status = 'refunded' where id = %L$$, (select v from fx where k = 'order_a')), 'error');
select pg_temp.chk('pending -> confirmed is allowed', '__admin__',
  format($$update public.orders set status = 'confirmed' where id = %L$$, (select v from fx where k = 'order_a')), 'ok');
select pg_temp.chk('status cannot move backwards (confirmed -> pending)', '__admin__',
  format($$update public.orders set status = 'pending' where id = %L$$, (select v from fx where k = 'order_a')), 'error');

-- Payment state machine + immutability
select pg_temp.chk('payment amount cannot be edited', '__admin__',
  format($$update public.payments set amount = 1 where order_id = %L$$, (select v from fx where k = 'order_a')), 'like:cannot be changed');
select pg_temp.chk('payment method cannot be edited', '__admin__',
  format($$update public.payments set method = 'gcash' where order_id = %L$$, (select v from fx where k = 'order_a')), 'like:cannot be changed');
select pg_temp.chk('payment cannot jump pending -> refunded', '__admin__',
  format($$update public.payments set status = 'refunded' where order_id = %L$$, (select v from fx where k = 'order_a')), 'error');
select pg_temp.chk('payment pending -> success is allowed (trusted path)', '__admin__',
  format($$update public.payments set status = 'success' where order_id = %L$$, (select v from fx where k = 'order_a')), 'ok');
select pg_temp.chk('a successful payment cannot be un-paid', '__admin__',
  format($$update public.payments set status = 'pending' where order_id = %L$$, (select v from fx where k = 'order_a')), 'error');

select pg_temp.chk('confirmed -> readyForPickup', '__admin__',
  format($$update public.orders set status = 'readyForPickup' where id = %L$$, (select v from fx where k = 'order_a')), 'ok');
select pg_temp.chk('paid order can now be completed', '__admin__',
  format($$update public.orders set status = 'completed' where id = %L$$, (select v from fx where k = 'order_a')), 'ok');
select pg_temp.chk_true('completion awarded points from the amount actually paid (120/50 = 2)',
  (select points_balance from public.loyalty_accounts where firebase_uid = 'i_a') = 2,
  'balance=' || (select points_balance::text from public.loyalty_accounts where firebase_uid = 'i_a'));
select pg_temp.chk('completed order cannot be cancelled', '__admin__',
  format($$update public.orders set status = 'cancelled' where id = %L$$, (select v from fx where k = 'order_a')), 'error');
select pg_temp.chk('completed order cannot be reset to pending', '__admin__',
  format($$update public.orders set status = 'pending' where id = %L$$, (select v from fx where k = 'order_a')), 'error');
select pg_temp.chk('completed order cannot skip the refund flow (completed -> refunded)', '__admin__',
  format($$update public.orders set status = 'refunded' where id = %L$$, (select v from fx where k = 'order_a')), 'error');

-- Immutability of financial facts
select pg_temp.chk('order total cannot be edited after placement', '__admin__',
  format($$update public.orders set total = 1 where id = %L$$, (select v from fx where k = 'order_a')), 'like:cannot be changed');
select pg_temp.chk('order discount cannot be edited', '__admin__',
  format($$update public.orders set discount = 0 where id = %L$$, (select v from fx where k = 'order_a')), 'error');
select pg_temp.chk('order owner cannot be reassigned', '__admin__',
  format($$update public.orders set firebase_uid = 'i_b' where id = %L$$, (select v from fx where k = 'order_a')), 'error');
select pg_temp.chk('order line price cannot be edited', '__admin__',
  format($$update public.order_items set unit_price = 1 where order_id = %L$$, (select v from fx where k = 'order_a')), 'like:cannot be edited');
select pg_temp.chk('order line quantity cannot be edited', '__admin__',
  format($$update public.order_items set quantity = 99 where order_id = %L$$, (select v from fx where k = 'order_a')), 'error');
select pg_temp.chk('deleting a product may still detach the order line (ON DELETE SET NULL keeps working)', '__admin__',
  format($$update public.order_items set product_id = null where order_id = %L$$, (select v from fx where k = 'order_a')), 'ok');

-- Loyalty ledger is append-only
select pg_temp.chk('loyalty ledger rows cannot be edited', '__admin__',
  $$update public.loyalty_transactions set points = 99999 where firebase_uid = 'i_a'$$, 'like:append-only');
select pg_temp.chk('loyalty ledger rows cannot be deleted', '__admin__',
  $$delete from public.loyalty_transactions where firebase_uid = 'i_a'$$, 'like:append-only');

-- Refund state machine
do $$
begin
  insert into fx values ('refund_a', pg_temp.call_as('i_a', format(
    $q$select request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','INT-TEST Nut','variant_label','Regular','quantity',1)))$q$,
    (select v from fx where k = 'order_a'))));
end $$;
select pg_temp.chk('refund amount cannot be edited (even by staff)', '__admin__',
  format($$update public.refund_requests set amount = 999 where id = %L$$, (select v from fx where k = 'refund_a')), 'like:cannot be changed');
select pg_temp.chk('refund cannot be completed without approval (pending -> completed)', '__admin__',
  format($$update public.refund_requests set status = 'completed' where id = %L$$, (select v from fx where k = 'refund_a')), 'error');
select pg_temp.chk('refund pending -> approved', '__admin__',
  format($$update public.refund_requests set status = 'approved' where id = %L$$, (select v from fx where k = 'refund_a')), 'ok');
select pg_temp.chk('refund approved -> completed', '__admin__',
  format($$update public.refund_requests set status = 'completed' where id = %L$$, (select v from fx where k = 'refund_a')), 'ok');
select pg_temp.chk('a completed refund is final', '__admin__',
  format($$update public.refund_requests set status = 'pending' where id = %L$$, (select v from fx where k = 'refund_a')), 'error');
-- 1 of 2 units refunded (60 of the 120 paid for goods): half of the 2 points earned are reversed
-- (20261015000000: proportional clawback; before, a partial refund took back every point).
select pg_temp.chk_true('refund finished: order refunded, payment refunded, earned points reversed in proportion (2 -> 1)',
  (select status from public.orders where id = (select v from fx where k = 'order_a')) = 'refunded'
  and (select status from public.payments where order_id = (select v from fx where k = 'order_a')) = 'refunded'
  and (select points_balance from public.loyalty_accounts where firebase_uid = 'i_a') = 1,
  'balance=' || (select points_balance::text from public.loyalty_accounts where firebase_uid = 'i_a'));
select pg_temp.chk('a refunded order is final', '__admin__',
  format($$update public.orders set status = 'completed' where id = %L$$, (select v from fx where k = 'order_a')), 'error');

-- Ledger reconciliation: after all of the above, balance == sum(ledger) for Ann.
select pg_temp.chk_true('loyalty balance equals the sum of its ledger after buy/redeem/earn/refund',
  not exists (select 1 from public.loyalty_ledger_drift where firebase_uid = 'i_a'),
  coalesce((select 'drift=' || drift from public.loyalty_ledger_drift where firebase_uid = 'i_a'), 'no drift'));
select pg_temp.chk('customers cannot read the reconciliation view', 'i_a', 'select count(*) from public.loyalty_ledger_drift', 'error');

-- ---------------------------------------------------------------------------
-- Delivery orders, cancellation and zero-total orders (Ben)
-- ---------------------------------------------------------------------------
do $$
declare v_cart text;
begin
  v_cart := pg_temp.call_as('i_b', format(
    $q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
         'product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false)->>'cart_id'$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'variant')));
  insert into fx values ('order_b_delivery', pg_temp.call_as('i_b', format(
    $q$select place_order(%L::uuid, true, %L::uuid, 'GCash E-Wallet', '', 'idem-b1')$q$, v_cart, (select v from fx where k = 'addr_b'))));
end $$;

select pg_temp.chk_true('delivery order total includes the branch fee (100 + 30)',
  (select total from public.orders where id = (select v from fx where k = 'order_b_delivery')) = 130);
select pg_temp.chk('delivery order cannot be "ready for pickup"', '__admin__',
  format($$update public.orders set status = 'readyForPickup' where id = %L$$, (select v from fx where k = 'order_b_delivery')), 'error');
select pg_temp.chk('payment pending -> failed', '__admin__',
  format($$update public.payments set status = 'failed' where order_id = %L$$, (select v from fx where k = 'order_b_delivery')), 'ok');
select pg_temp.chk('failed payment may be retried (failed -> pending)', '__admin__',
  format($$update public.payments set status = 'pending' where order_id = %L$$, (select v from fx where k = 'order_b_delivery')), 'ok');
select pg_temp.chk('cancelling an active order is allowed', '__admin__',
  format($$update public.orders set status = 'cancelled' where id = %L$$, (select v from fx where k = 'order_b_delivery')), 'ok');
select pg_temp.chk('a cancelled order is final', '__admin__',
  format($$update public.orders set status = 'completed' where id = %L$$, (select v from fx where k = 'order_b_delivery')), 'error');
select pg_temp.chk_true('cancel gave the unit back (stock 8 -> 7 -> 8)',
  (select quantity from public.branch_inventory where variant_id = (select v from fx where k = 'variant')::uuid) = 8);

do $$
declare v_cart text;
begin
  v_cart := pg_temp.call_as('i_b', format(
    $q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
         'product_id', %L, 'variant_id', %L, 'quantity', 1)), 'INTFREE', false)->>'cart_id'$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'variant')));
  insert into fx values ('order_b_free', pg_temp.call_as('i_b', format(
    $q$select place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'idem-b2')$q$, v_cart)));
end $$;
select pg_temp.chk_true('a fully discounted order has total 0 and still has an item and a 0 payment',
  (select total from public.orders where id = (select v from fx where k = 'order_b_free')) = 0
  and (select count(*) from public.payments where order_id = (select v from fx where k = 'order_b_free') and amount = 0) = 1);
select pg_temp.chk('a zero-total order can be completed without a payment step', '__admin__',
  format($$update public.orders set status = 'completed' where id = %L$$, (select v from fx where k = 'order_b_free')), 'ok');

-- ===========================================================================
-- 4. An order can never exist half-created (deferred constraint, checked at COMMIT;
--    forced here with SET CONSTRAINTS IMMEDIATE)
-- ===========================================================================
select pg_temp.chk('an order with no items cannot commit', '__admin__',
  $$insert into public.orders(firebase_uid, branch_name, subtotal, total, payment_method)
    values ('i_b', 'x', 100, 100, 'Cash on Counter Pickup');
    set constraints orders_integrity_check immediate$$, 'like:at least one item');

select pg_temp.chk('an order whose items do not add up to its subtotal cannot commit', '__admin__',
  $$with o as (insert into public.orders(id, firebase_uid, branch_name, subtotal, total, payment_method)
                values ('ORD-X1', 'i_b', 'x', 100, 100, 'Cash on Counter Pickup') returning id),
         i as (insert into public.order_items(order_id, product_name, variant_label, quantity, unit_price)
               select id, 'x', 'Regular', 1, 50 from o returning 1)
    insert into public.payments(order_id, firebase_uid, method, status, amount, reference_number)
    select id, 'i_b', 'cash', 'pending', 100, 'r' from o;
    set constraints orders_integrity_check immediate$$, 'like:does not match its items');

select pg_temp.chk('an order with no payment cannot commit', '__admin__',
  $$with o as (insert into public.orders(id, firebase_uid, branch_name, subtotal, total, payment_method)
                values ('ORD-X2', 'i_b', 'x', 100, 100, 'Cash on Counter Pickup') returning id)
    insert into public.order_items(order_id, product_name, variant_label, quantity, unit_price)
    select id, 'x', 'Regular', 1, 100 from o;
    set constraints orders_integrity_check immediate$$, 'like:payment record');

select pg_temp.chk('an order whose payment differs from its total cannot commit', '__admin__',
  $$with o as (insert into public.orders(id, firebase_uid, branch_name, subtotal, total, payment_method)
                values ('ORD-X3', 'i_b', 'x', 100, 100, 'Cash on Counter Pickup') returning id),
         i as (insert into public.order_items(order_id, product_name, variant_label, quantity, unit_price)
               select id, 'x', 'Regular', 1, 100 from o returning 1)
    insert into public.payments(order_id, firebase_uid, method, status, amount, reference_number)
    select id, 'i_b', 'cash', 'pending', 1, 'r' from o;
    set constraints orders_integrity_check immediate$$, 'like:exactly its total');

select pg_temp.chk('a fully consistent order (items + payment) commits fine', '__admin__',
  $$with o as (insert into public.orders(id, firebase_uid, branch_name, subtotal, total, payment_method)
                values ('ORD-X4', 'i_b', 'x', 100, 100, 'Cash on Counter Pickup') returning id),
         i as (insert into public.order_items(order_id, product_name, variant_label, quantity, unit_price)
               select id, 'x', 'Regular', 1, 100 from o returning 1)
    insert into public.payments(order_id, firebase_uid, method, status, amount, reference_number)
    select id, 'i_b', 'cash', 'pending', 100, 'r' from o;
    set constraints orders_integrity_check immediate$$, 'ok');

-- Money arithmetic CHECKs (constraint fires immediately, independent of the deferred trigger)
select pg_temp.chk('order total must equal subtotal - discount + delivery fee', '__admin__',
  $$insert into public.orders(firebase_uid, branch_name, subtotal, discount, delivery_fee, total, payment_method)
    values ('i_b', 'x', 100, 10, 30, 1, 'Cash on Counter Pickup')$$, 'like:orders_total_consistent');
select pg_temp.chk('discount cannot exceed the subtotal', '__admin__',
  $$insert into public.orders(firebase_uid, branch_name, subtotal, discount, total, payment_method)
    values ('i_b', 'x', 100, 150, 0, 'Cash on Counter Pickup')$$, 'like:orders_discount_within_subtotal');
select pg_temp.chk('negative amounts are rejected', '__admin__',
  $$insert into public.orders(firebase_uid, branch_name, subtotal, total, payment_method)
    values ('i_b', 'x', -5, 0, 'Cash on Counter Pickup')$$, 'error');
select pg_temp.chk('a voucher cannot be used beyond its limit', '__admin__',
  $$update public.vouchers set usage_limit = 1, used_count = 5 where code = 'INTFREE'$$, 'like:vouchers_used_within_limit');

-- Variant <-> product pairing
select pg_temp.chk('inventory cannot pair a product with another product''s variant', '__admin__',
  format($$insert into public.branch_inventory(branch_id, product_id, variant_id, quantity) values (%L, %L, %L, 5)$$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'other_variant')),
  'like:foreign key');
select pg_temp.chk('stock can never go negative', '__admin__',
  $$update public.branch_inventory set quantity = -1$$, 'error');

-- ===========================================================================
-- 5. Fail-closed privileges for functions added in the future
-- ===========================================================================
create function public.zz_future_function() returns int language sql as $$ select 1 $$;
select pg_temp.chk_true('a newly created function is NOT executable by anon',
  not has_function_privilege('anon', 'public.zz_future_function()', 'execute'));
select pg_temp.chk_true('a newly created function is NOT executable by authenticated',
  not has_function_privilege('authenticated', 'public.zz_future_function()', 'execute'));
drop function public.zz_future_function();

select pg_temp.chk_true('integrity trigger functions are not callable by client roles',
  not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('check_order_integrity','enforce_order_transition','enforce_payment_transition',
                                'enforce_refund_transition','forbid_financial_edits','forbid_ledger_rewrite')
              and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))));

-- ===========================================================================
-- Report
-- ===========================================================================
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;

select count(*) filter (where passed) as passed, count(*) filter (where not passed) as failed, count(*) as total from results;

do $$
declare v_failed int;
begin
  select count(*) into v_failed from results where not passed;
  if v_failed > 0 then
    raise exception '% integrity check(s) FAILED — see the report above.', v_failed;
  end if;
end $$;

rollback;
