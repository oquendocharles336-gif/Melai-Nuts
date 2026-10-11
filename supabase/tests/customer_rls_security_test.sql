-- =============================================================================
-- Melai Nuts — customer RLS / security test suite
-- =============================================================================
-- Attacks the database the way a malicious customer with a modified app would:
-- by sending requests as the `anon` / `authenticated` Postgres roles with a
-- forged-but-validly-shaped Firebase JWT (`request.jwt.claims`).
--
-- HOW TO RUN (against a DEV / staging database, never production):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/customer_rls_security_test.sql
-- or paste it into the Supabase SQL Editor of a dev project.
--
-- It is fully self-contained: it creates its own test branch / product /
-- customers / voucher inside ONE transaction and ROLLS EVERYTHING BACK at the
-- end, so no data is left behind (sequence counters do advance — harmless).
-- Prerequisites: supabase/schema.sql, then BOTH files in supabase/migrations/
-- (20260928000000_customer_security_hardening.sql, 20260928010000_order_integrity.sql).
-- Companion suites: order_integrity_test.sql and concurrency_test.sh.
--
-- Output: one PASS/FAIL row per attack. The script ends by raising an error if
-- ANY check failed, so it can gate a CI pipeline.
-- =============================================================================

begin;

create temp table results (
  id serial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
create temp table fx (k text primary key, v text);

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------

-- Switches this session to a customer (or anon when p_uid is null).
create function pg_temp.act_as(p_uid text, p_verified boolean default true, p_email text default null)
returns void language plpgsql as $$
begin
  if p_uid is null then
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
  else
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', p_uid,
      'role', 'authenticated',
      'email', coalesce(p_email, p_uid || '@test.local'),
      'email_verified', p_verified)::text, true);
    execute 'set local role authenticated';
  end if;
end $$;

create function pg_temp.back_to_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Called while the session is switched to a customer role, so it needs an explicit
-- grant now that new functions are private by default (fail-closed).
grant execute on function pg_temp.back_to_admin() to public;

-- Runs p_sql as p_uid and records whether it behaved as expected.
--   'error' : must raise (permission denied / RLS violation / business rule)
--   'deny'  : must raise OR touch/return zero rows
--   'ok'    : must succeed
--   'ok1'   : must succeed AND touch/return at least one row
--   'int:N' : a `select ...` returning a single integer equal to N
create function pg_temp.chk(p_name text, p_uid text, p_sql text, p_expect text,
                            p_verified boolean default true, p_email text default null)
returns void language plpgsql as $$
declare
  v_err text;
  v_n bigint;
begin
  perform pg_temp.act_as(p_uid, p_verified, p_email);
  begin
    if lower(ltrim(p_sql)) like 'select%' then
      execute p_sql into v_n;
    else
      execute p_sql;
      get diagnostics v_n = row_count;
    end if;
  exception when others then
    v_err := sqlerrm;
  end;
  perform pg_temp.back_to_admin();

  insert into results(name, passed, detail) values (
    p_name,
    case
      when p_expect = 'error' then v_err is not null
      when p_expect = 'deny'  then v_err is not null or coalesce(v_n, 0) = 0
      when p_expect = 'ok'    then v_err is null
      when p_expect = 'ok1'   then v_err is null and coalesce(v_n, 0) >= 1
      when p_expect like 'int:%' then v_err is null and v_n = substr(p_expect, 5)::bigint
      else false end,
    'expected ' || p_expect || ' -> ' ||
      coalesce('error: ' || v_err, 'n=' || coalesce(v_n::text, 'null')));
end $$;

-- Runs p_sql as p_uid and returns the scalar text result (errors propagate).
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

-- true/false, or NULL when the function does not exist (a missing function must FAIL, not abort).
create function pg_temp.can_exec(p_role text, p_sig text) returns boolean language plpgsql as $$
begin
  return has_function_privilege(p_role, p_sig, 'execute');
exception when others then
  return null;
end $$;

create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '')
returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (created as the table owner; rolled back at the end)
-- ---------------------------------------------------------------------------

insert into public.branches (name, address, supports_delivery, supports_pickup, delivery_fee)
values ('RLS-TEST Branch', 'test', true, true, 30);
insert into public.product_categories (label) values ('RLS-TEST Category');
insert into public.products (category_id, name, price, unit)
select id, 'RLS-TEST Nut', 100, 'pack' from public.product_categories where label = 'RLS-TEST Category';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'RLS-TEST Nut';
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select b.id, v.product_id, v.id, 10
from public.branches b, public.product_variants v
where b.name = 'RLS-TEST Branch' and v.product_id = (select id from public.products where name = 'RLS-TEST Nut');

insert into fx select 'branch',  id::text from public.branches where name = 'RLS-TEST Branch';
insert into fx select 'product', id::text from public.products where name = 'RLS-TEST Nut';
insert into fx select 'variant', id::text from public.product_variants
  where product_id = (select id from public.products where name = 'RLS-TEST Nut');

insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('uid_rls_a', 'Alice Test', 'uid_rls_a@test.local', '09170000001'),
  ('uid_rls_b', 'Bob Test',   'uid_rls_b@test.local', '09170000002');
insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city)
values ('uid_rls_a', 'Alice Test', '09170000001', '1 Test St', 'Calamba'),
       ('uid_rls_b', 'Bob Test',   '09170000002', '2 Test St', 'Calamba');
insert into fx select 'addr_a', id::text from public.customer_addresses where firebase_uid = 'uid_rls_a';

insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point)
values ('default', 1, 50, 50)
  on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;

insert into public.vouchers (code, discount_type, discount_value)
values ('RLSTEST10', 'percent', 10);
insert into public.rewards (title, points_required) values ('RLS-TEST Reward', 100);
insert into fx select 'reward', id::text from public.rewards where title = 'RLS-TEST Reward';

insert into public.notifications (firebase_uid, category, title, body)
values ('uid_rls_a', 'system', 'A note', 'for A'),
       ('uid_rls_b', 'system', 'B note', 'for B');
insert into fx select 'ntf_b', id from public.notifications where firebase_uid = 'uid_rls_b';
insert into fx select 'ntf_a', id from public.notifications where firebase_uid = 'uid_rls_a';

-- ===========================================================================
-- 1. Anonymous callers see nothing private
-- ===========================================================================
select pg_temp.chk('anon cannot read customer_profiles', null, 'select count(*) from public.customer_profiles', 'deny');
select pg_temp.chk('anon cannot read orders',            null, 'select count(*) from public.orders', 'deny');
select pg_temp.chk('anon cannot read payments',          null, 'select count(*) from public.payments', 'deny');
select pg_temp.chk('anon cannot read carts',             null, 'select count(*) from public.carts', 'deny');
select pg_temp.chk('anon cannot read notifications',     null, 'select count(*) from public.notifications', 'deny');
select pg_temp.chk('anon cannot read loyalty_accounts',  null, 'select count(*) from public.loyalty_accounts', 'deny');
select pg_temp.chk('anon cannot read vouchers',          null, 'select count(*) from public.vouchers', 'deny');
select pg_temp.chk('anon CAN read the public catalog',   null, 'select count(*) from public.products where is_active', 'ok1');

-- ===========================================================================
-- 2. Cross-customer isolation (Alice attacking Bob)
-- ===========================================================================
select pg_temp.chk('A cannot read B profile',       'uid_rls_a', $$select count(*) from public.customer_profiles where firebase_uid = 'uid_rls_b'$$, 'deny');
select pg_temp.chk('A cannot read B addresses',     'uid_rls_a', $$select count(*) from public.customer_addresses where firebase_uid = 'uid_rls_b'$$, 'deny');
select pg_temp.chk('A cannot read B notifications', 'uid_rls_a', $$select count(*) from public.notifications where firebase_uid = 'uid_rls_b'$$, 'deny');
select pg_temp.chk('A can read own profile',        'uid_rls_a', $$select count(*) from public.customer_profiles where firebase_uid = 'uid_rls_a'$$, 'ok1');
select pg_temp.chk('A cannot update B profile',     'uid_rls_a', $$update public.customer_profiles set full_name = 'pwned' where firebase_uid = 'uid_rls_b'$$, 'deny');
select pg_temp.chk('A cannot insert a profile as B','uid_rls_a', $$insert into public.customer_profiles(firebase_uid, full_name, email) values ('uid_rls_x', 'x', 'uid_rls_a@test.local')$$, 'error');
select pg_temp.chk('A cannot delete B address',     'uid_rls_a', $$delete from public.customer_addresses where firebase_uid = 'uid_rls_b'$$, 'deny');
select pg_temp.chk('A cannot re-point own address at B',
  'uid_rls_a', $$update public.customer_addresses set firebase_uid = 'uid_rls_b' where firebase_uid = 'uid_rls_a'$$, 'error');
select pg_temp.chk('A cannot change own firebase_uid on profile',
  'uid_rls_a', $$update public.customer_profiles set firebase_uid = 'uid_rls_b' where firebase_uid = 'uid_rls_a'$$, 'error');

-- ===========================================================================
-- 3. Profile creation requires a VERIFIED email that matches the token
-- ===========================================================================
select pg_temp.chk('unverified email cannot create a profile', 'uid_rls_c',
  $$insert into public.customer_profiles(firebase_uid, full_name, email) values ('uid_rls_c', 'C', 'uid_rls_c@test.local')$$, 'error', false);
select pg_temp.chk('verified but mismatched email cannot create a profile', 'uid_rls_d',
  $$insert into public.customer_profiles(firebase_uid, full_name, email) values ('uid_rls_d', 'D', 'someone.else@test.local')$$, 'error', true);
select pg_temp.chk('verified + matching email CAN create own profile', 'uid_rls_e',
  $$insert into public.customer_profiles(firebase_uid, full_name, email) values ('uid_rls_e', 'E', 'uid_rls_e@test.local')$$, 'ok');

-- ===========================================================================
-- 4. Role / privileged-field escalation on the profile
-- ===========================================================================
select pg_temp.chk('customer cannot set own RFID card number', 'uid_rls_a',
  $$update public.customer_profiles set rfid_card_number = 'STOLEN-CARD' where firebase_uid = 'uid_rls_a'$$, 'error');
select pg_temp.chk('customer cannot change own email on profile', 'uid_rls_a',
  $$update public.customer_profiles set email = 'ceo@evil.test' where firebase_uid = 'uid_rls_a'$$, 'error');
select pg_temp.chk('customer CAN update own name/phone', 'uid_rls_a',
  $$update public.customer_profiles set full_name = 'Alice Renamed', phone = '09171111111' where firebase_uid = 'uid_rls_a'$$, 'ok1');

-- ===========================================================================
-- 5. Catalog / pricing / inventory are read-only for customers
-- ===========================================================================
select pg_temp.chk('customer cannot change product price', 'uid_rls_a', $$update public.products set price = 1$$, 'deny');
select pg_temp.chk('customer cannot change variant price', 'uid_rls_a', $$update public.product_variants set price = 1$$, 'deny');
select pg_temp.chk('customer cannot change inventory',     'uid_rls_a', $$update public.branch_inventory set quantity = 9999$$, 'deny');
select pg_temp.chk('customer cannot insert a product',     'uid_rls_a', $$insert into public.products(name, price) values ('free stuff', 0)$$, 'error');
select pg_temp.chk('customer cannot delete a product',     'uid_rls_a', $$delete from public.products$$, 'deny');
select pg_temp.chk('customer cannot edit rewards',         'uid_rls_a', $$update public.rewards set points_required = 1$$, 'deny');
select pg_temp.chk('customer cannot read voucher table',   'uid_rls_a', 'select count(*) from public.vouchers', 'deny');
select pg_temp.chk('customer cannot edit vouchers',        'uid_rls_a', $$update public.vouchers set discount_value = 100$$, 'deny');
select pg_temp.chk('customer cannot edit loyalty settings','uid_rls_a', $$update public.loyalty_cart_settings set points_per_peso = 0.01$$, 'deny');
select pg_temp.chk('anon cannot read product cost (COGS) table', null, 'select count(*) from public.product_variant_costs', 'deny');
select pg_temp.chk('customer cannot read product cost (COGS) table', 'uid_rls_a', 'select count(*) from public.product_variant_costs', 'deny');
select pg_temp.chk_true('product_variants no longer exposes cost_price',
  not exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'product_variants' and column_name = 'cost_price'));

-- ===========================================================================
-- 6. Cart integrity: only the sync RPC can write; prices come from the server
-- ===========================================================================
select pg_temp.chk('customer cannot insert cart directly', 'uid_rls_a',
  format($$insert into public.carts(firebase_uid, branch_id) values ('uid_rls_a', %L)$$, (select v from fx where k = 'branch')), 'error');

do $$
declare v_cart text;
begin
  -- Bob builds a real cart through the RPC (quantity 2 @ 100 = 200).
  v_cart := pg_temp.call_as('uid_rls_b', format(
    $q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
         'product_id', %L, 'variant_id', %L, 'quantity', 2)), null, false)->>'cart_id'$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'variant')));
  insert into fx values ('cart_b', v_cart);
end $$;

select pg_temp.chk('A cannot read B cart', 'uid_rls_a', $$select count(*) from public.carts where firebase_uid = 'uid_rls_b'$$, 'deny');
select pg_temp.chk('A cannot read B cart items', 'uid_rls_a', 'select count(*) from public.cart_items', 'deny');
select pg_temp.chk('A cannot price/read B cart via RPC', 'uid_rls_a',
  format($$select get_cart_pricing(%L::uuid, false)::text$$, (select v from fx where k = 'cart_b')), 'error');
select pg_temp.chk('A cannot check out B cart', 'uid_rls_a',
  format($$select place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'k1')$$, (select v from fx where k = 'cart_b')), 'error');
select pg_temp.chk('cart sync rejects quantity above real stock', 'uid_rls_a',
  format($q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
      'product_id', %L, 'variant_id', %L, 'quantity', 999)), null, false)$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'variant')), 'error');
select pg_temp.chk('cart sync rejects negative quantity', 'uid_rls_a',
  format($q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
      'product_id', %L, 'variant_id', %L, 'quantity', -5)), null, false)$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'variant')), 'error');
select pg_temp.chk('anon cannot call cart RPCs', null,
  format($$select get_customer_cart(%L::uuid)::text$$, (select v from fx where k = 'branch')), 'error');

-- ===========================================================================
-- 7. Orders: server-computed totals; no direct writes; points NOT farmable
-- ===========================================================================
select pg_temp.chk('customer cannot insert an order directly', 'uid_rls_a',
  $$insert into public.orders(firebase_uid, branch_name, subtotal, total, payment_method) values ('uid_rls_a', 'x', 100, 0.01, 'cash')$$, 'error');
select pg_temp.chk('customer cannot insert order_items directly', 'uid_rls_a',
  $$insert into public.order_items(order_id, product_name, quantity, unit_price) values ('ORD-1', 'x', 1, 0)$$, 'error');
select pg_temp.chk('place_order rejects unknown payment method', 'uid_rls_b',
  format($$select place_order(%L::uuid, false, null, 'Free Money', '', 'k0')$$, (select v from fx where k = 'cart_b')), 'error');

do $$
declare v_order text;
begin
  v_order := pg_temp.call_as('uid_rls_b', format(
    $q$select place_order(%L::uuid, false, null, 'Cash on Counter Pickup', 'notes', 'idem-1')$q$,
    (select v from fx where k = 'cart_b')));
  insert into fx values ('order_b', v_order);
end $$;

select pg_temp.chk_true('order total is computed server-side (2 x 100 = 200)',
  (select total from public.orders where id = (select v from fx where k = 'order_b')) = 200,
  'total=' || (select total::text from public.orders where id = (select v from fx where k = 'order_b')));
select pg_temp.chk_true('placing an order creates exactly one pending payment',
  (select count(*) from public.payments where order_id = (select v from fx where k = 'order_b') and status = 'pending') = 1);
select pg_temp.chk_true('stock was deducted atomically (10 -> 8)',
  (select quantity from public.branch_inventory where variant_id = (select v from fx where k = 'variant')::uuid) = 8);
select pg_temp.chk_true('replaying the same idempotency key returns the same order (no double order)',
  pg_temp.call_as('uid_rls_b', format($q$select place_order(%L::uuid, false, null, 'Cash on Counter Pickup', 'notes', 'idem-1')$q$,
    (select v from fx where k = 'cart_b'))) = (select v from fx where k = 'order_b'));
select pg_temp.chk_true('loyalty points are NOT awarded when an unpaid order is merely placed',
  coalesce((select points_balance from public.loyalty_accounts where firebase_uid = 'uid_rls_b'), 0) = 0,
  'balance=' || coalesce((select points_balance::text from public.loyalty_accounts where firebase_uid = 'uid_rls_b'), '0'));

-- Destructive tamper attempts run AFTER the legitimate checkout so a hole here
-- cannot corrupt the rest of the run.
select pg_temp.chk('customer cannot re-open a checked-out cart', 'uid_rls_b',
  $$update public.carts set status = 'open' where status = 'checked_out'$$, 'error');
do $$
begin
  perform pg_temp.call_as('uid_rls_b', format(
    $q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
         'product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false)::text$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'variant')));
end $$;
select pg_temp.chk('customer cannot tamper with cart item price', 'uid_rls_b',
  $$update public.cart_items set current_price = 0.01$$, 'error');
select pg_temp.chk('customer cannot tamper with cart item quantity directly', 'uid_rls_b',
  $$update public.cart_items set quantity = 500$$, 'error');
select pg_temp.chk('customer cannot add a cart item directly', 'uid_rls_b',
  $$insert into public.cart_items(cart_id, product_id, variant_label, quantity, current_price)
    select c.id, ci.product_id, 'Hacked', 1, 0.01 from public.carts c join public.cart_items ci on ci.cart_id = c.id where c.status = 'open' limit 1$$, 'error');

select pg_temp.chk('A cannot read B order', 'uid_rls_a', $$select count(*) from public.orders where firebase_uid = 'uid_rls_b'$$, 'deny');
select pg_temp.chk('A cannot read B order items', 'uid_rls_a', 'select count(*) from public.order_items', 'deny');
select pg_temp.chk('A cannot read B order status history', 'uid_rls_a', 'select count(*) from public.order_status_events', 'deny');
select pg_temp.chk('B can read own order', 'uid_rls_b', 'select count(*) from public.orders', 'ok1');
select pg_temp.chk('B cannot lower own order total', 'uid_rls_b', $$update public.orders set total = 0.01$$, 'error');
select pg_temp.chk('B cannot mark own order completed', 'uid_rls_b', $$update public.orders set status = 'completed'$$, 'error');
select pg_temp.chk('B cannot cancel/alter own order items', 'uid_rls_b', $$update public.order_items set unit_price = 0$$, 'error');
select pg_temp.chk('B cannot delete own order', 'uid_rls_b', 'delete from public.orders', 'error');

-- ===========================================================================
-- 8. Payments: customers can read their own, never write
-- ===========================================================================
select pg_temp.chk('B can read own payment', 'uid_rls_b', 'select count(*) from public.payments', 'ok1');
select pg_temp.chk('A cannot read B payment', 'uid_rls_a', $$select count(*) from public.payments where firebase_uid = 'uid_rls_b'$$, 'deny');
select pg_temp.chk('B cannot mark own payment as paid', 'uid_rls_b', $$update public.payments set status = 'success'$$, 'error');
select pg_temp.chk('A cannot inject a payment onto B order', 'uid_rls_a',
  format($$insert into public.payments(order_id, firebase_uid, method, status, amount, reference_number) values (%L, 'uid_rls_a', 'cash', 'pending', 1, 'x')$$,
         (select v from fx where k = 'order_b')), 'error');
select pg_temp.chk('B cannot insert a fake "success" payment', 'uid_rls_b',
  format($$insert into public.payments(order_id, firebase_uid, method, status, amount, reference_number) values (%L, 'uid_rls_b', 'cash', 'success', 200, 'x')$$,
         (select v from fx where k = 'order_b')), 'error');
select pg_temp.chk('B cannot delete own payment record', 'uid_rls_b', 'delete from public.payments', 'error');

-- ===========================================================================
-- 9. Loyalty: read-only balance; points only move via server logic
-- ===========================================================================
insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points)
values ('uid_rls_a', 500, 500)
on conflict (firebase_uid) do update set points_balance = 500, lifetime_points = 500;

select pg_temp.chk('A can read own loyalty balance', 'uid_rls_a', 'select count(*) from public.loyalty_accounts', 'ok1');
select pg_temp.chk('A cannot read B loyalty balance', 'uid_rls_a', $$select count(*) from public.loyalty_accounts where firebase_uid = 'uid_rls_b'$$, 'deny');
select pg_temp.chk('customer cannot raise own balance', 'uid_rls_a', $$update public.loyalty_accounts set points_balance = 999999$$, 'error');
select pg_temp.chk('customer cannot insert loyalty account', 'uid_rls_e', $$insert into public.loyalty_accounts(firebase_uid, points_balance) values ('uid_rls_e', 999999)$$, 'error');
select pg_temp.chk('customer cannot forge loyalty transactions', 'uid_rls_a',
  $$insert into public.loyalty_transactions(firebase_uid, type, points, description) values ('uid_rls_a', 'earn', 99999, 'free')$$, 'error');
select pg_temp.chk('customer cannot forge a reward redemption', 'uid_rls_a',
  format($$insert into public.reward_redemptions(firebase_uid, reward_id, points_spent) values ('uid_rls_a', %L::uuid, 0)$$, (select v from fx where k = 'reward')), 'error');
select pg_temp.chk('anon cannot redeem a reward', null,
  format($$select redeem_reward(%L::uuid)$$, (select v from fx where k = 'reward')), 'error');
select pg_temp.chk('customer with too few points cannot redeem', 'uid_rls_b',
  format($$select redeem_reward(%L::uuid)$$, (select v from fx where k = 'reward')), 'error');
select pg_temp.chk('customer with enough points CAN redeem (atomic)', 'uid_rls_a',
  format($$select redeem_reward(%L::uuid)$$, (select v from fx where k = 'reward')), 'ok');
select pg_temp.chk_true('redemption deducted exactly the reward cost (500 -> 400)',
  (select points_balance from public.loyalty_accounts where firebase_uid = 'uid_rls_a') = 400);

-- Staff confirms the cash payment, then completes Bob's order (simulated as the table
-- owner, i.e. a trusted server path). An unpaid order cannot be completed.
update public.payments set status = 'success' where order_id = (select v from fx where k = 'order_b');
update public.orders set status = 'completed' where id = (select v from fx where k = 'order_b');
select pg_temp.chk_true('points ARE awarded once the order completes (200 / 50 = 4)',
  coalesce((select points_balance from public.loyalty_accounts where firebase_uid = 'uid_rls_b'), 0) = 4,
  'balance=' || coalesce((select points_balance::text from public.loyalty_accounts where firebase_uid = 'uid_rls_b'), '0'));
update public.orders set status = 'refundRequested' where id = (select v from fx where k = 'order_b');
update public.orders set status = 'completed' where id = (select v from fx where k = 'order_b');
select pg_temp.chk_true('re-completing an order never double-awards points',
  (select points_balance from public.loyalty_accounts where firebase_uid = 'uid_rls_b') = 4);

-- ===========================================================================
-- 10. Notifications: no forging, no tampering, no cross-customer access
-- ===========================================================================
select pg_temp.chk('customer cannot call notify_customer() for someone else', 'uid_rls_a',
  $$select public.notify_customer('uid_rls_b', 'system', 'Your account is compromised', 'click evil.test')$$, 'error');
select pg_temp.chk('anon cannot call notify_customer()', null,
  $$select public.notify_customer('uid_rls_b', 'system', 'x', 'y')$$, 'error');
select pg_temp.chk('customer cannot insert a notification directly', 'uid_rls_a',
  $$insert into public.notifications(firebase_uid, category, title, body) values ('uid_rls_b', 'system', 'x', 'y')$$, 'error');
select pg_temp.chk('customer cannot rewrite own notification text', 'uid_rls_a',
  $$update public.notifications set title = 'You won a prize'$$, 'error');
select pg_temp.chk('customer CAN mark own notification read', 'uid_rls_a',
  format($$update public.notifications set read = true where id = %L$$, (select v from fx where k = 'ntf_a')), 'ok1');
select pg_temp.chk('A cannot mark B notification read', 'uid_rls_a',
  format($$update public.notifications set read = true where id = %L$$, (select v from fx where k = 'ntf_b')), 'deny');
select pg_temp.chk('A cannot delete B notification', 'uid_rls_a',
  format($$delete from public.notifications where id = %L$$, (select v from fx where k = 'ntf_b')), 'deny');
select pg_temp.chk('customer CAN delete own notification', 'uid_rls_a',
  format($$delete from public.notifications where id = %L$$, (select v from fx where k = 'ntf_a')), 'ok1');

-- ===========================================================================
-- 11. Refunds: server decides eligibility, amount and status
-- ===========================================================================
select pg_temp.chk('customer cannot insert a refund row directly', 'uid_rls_b',
  format($$insert into public.refund_requests(order_id, firebase_uid, status, reason, amount, payment_method) values (%L, 'uid_rls_b', 'completed', 'x', 200, 'cash')$$,
         (select v from fx where k = 'order_b')), 'error');
select pg_temp.chk('customer cannot insert refund_items directly', 'uid_rls_b',
  $$insert into public.refund_items(refund_request_id, product_name, quantity, unit_price) values ('RFD-1', 'x', 1, 9999)$$, 'error');
select pg_temp.chk('A cannot request a refund on B order', 'uid_rls_a',
  format($q$select request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','RLS-TEST Nut','variant_label','Regular','quantity',1)))$q$,
         (select v from fx where k = 'order_b')), 'error');
select pg_temp.chk('refund with no items is rejected', 'uid_rls_b',
  format($q$select request_refund(%L, 'Damaged', '', '[]'::jsonb)$q$, (select v from fx where k = 'order_b')), 'error');
select pg_temp.chk('refund of more units than ordered is rejected', 'uid_rls_b',
  format($q$select request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','RLS-TEST Nut','variant_label','Regular','quantity',3)))$q$,
         (select v from fx where k = 'order_b')), 'error');
select pg_temp.chk('refund of an item not on the order is rejected', 'uid_rls_b',
  format($q$select request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','Gold Bar','variant_label','Regular','quantity',1)))$q$,
         (select v from fx where k = 'order_b')), 'error');

do $$
declare v_refund text;
begin
  -- Bob legitimately refunds 1 of his 2 units. He (a modified client) cannot dictate the amount.
  v_refund := pg_temp.call_as('uid_rls_b', format(
    $q$select request_refund(%L, 'Damaged / Spoiled Product', 'seal was broken',
         jsonb_build_array(jsonb_build_object('product_name','RLS-TEST Nut','variant_label','Regular','quantity',1,'unit_price',0.01,'amount',9999)))$q$,
    (select v from fx where k = 'order_b')));
  insert into fx values ('refund_b', v_refund);
end $$;

select pg_temp.chk_true('refund amount is computed server-side (1 x 100 = 100), ignoring client-sent amount/price',
  (select amount from public.refund_requests where id = (select v from fx where k = 'refund_b')) = 100,
  'amount=' || (select amount::text from public.refund_requests where id = (select v from fx where k = 'refund_b')));
select pg_temp.chk_true('new refunds always start as pending',
  (select status from public.refund_requests where id = (select v from fx where k = 'refund_b')) = 'pending');
select pg_temp.chk_true('refund line price came from the order, not the client',
  (select unit_price from public.refund_items where refund_request_id = (select v from fx where k = 'refund_b')) = 100);
select pg_temp.chk_true('refund request moved the order to refundRequested',
  (select status from public.orders where id = (select v from fx where k = 'order_b')) = 'refundRequested');
select pg_temp.chk('duplicate open refund on same order is rejected', 'uid_rls_b',
  format($q$select request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','RLS-TEST Nut','variant_label','Regular','quantity',1)))$q$,
         (select v from fx where k = 'order_b')), 'error');
select pg_temp.chk('B can read own refund', 'uid_rls_b', 'select count(*) from public.refund_requests', 'ok1');
select pg_temp.chk('A cannot read B refund', 'uid_rls_a', 'select count(*) from public.refund_requests', 'deny');
select pg_temp.chk('A cannot read B refund items', 'uid_rls_a', 'select count(*) from public.refund_items', 'deny');
select pg_temp.chk('A cannot read B refund history', 'uid_rls_a', 'select count(*) from public.refund_status_events', 'deny');
select pg_temp.chk('B cannot approve own refund', 'uid_rls_b', $$update public.refund_requests set status = 'completed'$$, 'error');
select pg_temp.chk('B cannot inflate own refund amount', 'uid_rls_b', $$update public.refund_requests set amount = 9999$$, 'error');
select pg_temp.chk('customer cannot edit refund lines', 'uid_rls_b', $$update public.refund_items set unit_price = 9999$$, 'error');

-- Staff rejects, then completes a refund on a fresh completed order — order/payment/points follow.
update public.refund_requests set status = 'rejected' where id = (select v from fx where k = 'refund_b');
select pg_temp.chk_true('rejected refund returns the order to completed',
  (select status from public.orders where id = (select v from fx where k = 'order_b')) = 'completed');
-- A rejected refund is final; the customer files a new one, which staff approve and complete.
do $$
begin
  insert into fx values ('refund_b2', pg_temp.call_as('uid_rls_b', format(
    $q$select request_refund(%L, 'Damaged again', '',
         jsonb_build_array(jsonb_build_object('product_name','RLS-TEST Nut','variant_label','Regular','quantity',1)))$q$,
    (select v from fx where k = 'order_b'))));
end $$;
update public.refund_requests set status = 'approved'  where id = (select v from fx where k = 'refund_b2');
update public.refund_requests set status = 'completed' where id = (select v from fx where k = 'refund_b2');
select pg_temp.chk_true('completed refund marks the order refunded',
  (select status from public.orders where id = (select v from fx where k = 'order_b')) = 'refunded');
-- 1 of 2 units refunded: half of the 4 points earned are reversed (20261015000000: proportional
-- clawback; before, a partial refund took back every point).
select pg_temp.chk_true('completed partial refund claws back points in proportion (4 -> 2)',
  (select points_balance from public.loyalty_accounts where firebase_uid = 'uid_rls_b') = 2,
  'balance=' || (select points_balance::text from public.loyalty_accounts where firebase_uid = 'uid_rls_b'));

-- ===========================================================================
-- 12. Cancelling an order returns stock, redeemed points and the voucher
-- ===========================================================================
update public.loyalty_accounts set points_balance = 60, lifetime_points = 60 where firebase_uid = 'uid_rls_b';
do $$
declare v_cart text; v_order text; v_pricing jsonb;
begin
  v_pricing := pg_temp.call_as('uid_rls_b', format(
    $q$select sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object(
         'product_id', %L, 'variant_id', %L, 'quantity', 1)), 'rlstest10', true)::text$q$,
    (select v from fx where k = 'branch'), (select v from fx where k = 'product'), (select v from fx where k = 'variant')))::jsonb;
  v_cart := v_pricing->>'cart_id';
  insert into fx values ('cart_b2', v_cart);
  insert into fx values ('pricing_b2', v_pricing::text);
  v_order := pg_temp.call_as('uid_rls_b', format(
    $q$select place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'idem-2')$q$, v_cart));
  insert into fx values ('order_b2', v_order);
end $$;

select pg_temp.chk_true('voucher (10%) + points are applied server-side: 100 - 10 - 50 (points capped at 50% of subtotal) = 40',
  (select total from public.orders where id = (select v from fx where k = 'order_b2')) = 40,
  'total=' || (select total::text from public.orders where id = (select v from fx where k = 'order_b2')));
select pg_temp.chk_true('voucher usage row was recorded',
  (select count(*) from public.voucher_usage where order_id = (select v from fx where k = 'order_b2')) = 1);
select pg_temp.chk_true('voucher used_count incremented',
  (select used_count from public.vouchers where code = 'RLSTEST10') = 1);
select pg_temp.chk('B can read own voucher usage', 'uid_rls_b', 'select count(*) from public.voucher_usage', 'ok1');
select pg_temp.chk('A cannot read B voucher usage', 'uid_rls_a', 'select count(*) from public.voucher_usage', 'deny');
select pg_temp.chk('customer cannot forge voucher usage', 'uid_rls_a',
  $$insert into public.voucher_usage(voucher_id, firebase_uid, order_id, discount_amount) select id, 'uid_rls_a', 'ORD-1', 0 from public.vouchers limit 1$$, 'error');

update public.orders set status = 'cancelled' where id = (select v from fx where k = 'order_b2');
select pg_temp.chk_true('cancel restored stock (8 -> 7 -> 8)',
  (select quantity from public.branch_inventory where variant_id = (select v from fx where k = 'variant')::uuid) = 8,
  'qty=' || (select quantity::text from public.branch_inventory where variant_id = (select v from fx where k = 'variant')::uuid));
select pg_temp.chk_true('cancel returned the redeemed loyalty points',
  (select points_balance from public.loyalty_accounts where firebase_uid = 'uid_rls_b') = 60,
  'balance=' || (select points_balance::text from public.loyalty_accounts where firebase_uid = 'uid_rls_b'));
select pg_temp.chk_true('cancel released the voucher',
  (select used_count from public.vouchers where code = 'RLSTEST10') = 0
  and not exists (select 1 from public.voucher_usage where order_id = (select v from fx where k = 'order_b2')));

-- ===========================================================================
-- 13. Function exposure (SECURITY DEFINER surface)
-- ===========================================================================
select pg_temp.chk_true('anon cannot execute notify_customer',
  not pg_temp.can_exec('anon', 'public.notify_customer(text,text,text,text)'));
select pg_temp.chk_true('authenticated cannot execute notify_customer',
  not pg_temp.can_exec('authenticated', 'public.notify_customer(text,text,text,text)'));
select pg_temp.chk_true('authenticated cannot execute the 5-arg place_order (idempotency bypass)',
  not pg_temp.can_exec('authenticated', 'public.place_order(uuid,boolean,uuid,text,text)'));
select pg_temp.chk_true('anon cannot execute place_order',
  not pg_temp.can_exec('anon', 'public.place_order(uuid,boolean,uuid,text,text,text)'));
select pg_temp.chk_true('authenticated CAN execute the 6-arg place_order',
  pg_temp.can_exec('authenticated', 'public.place_order(uuid,boolean,uuid,text,text,text)'));
select pg_temp.chk_true('anon cannot execute redeem_reward',
  not pg_temp.can_exec('anon', 'public.redeem_reward(uuid)'));
select pg_temp.chk_true('anon cannot execute request_refund',
  not pg_temp.can_exec('anon', 'public.request_refund(text,text,text,jsonb)'));
select pg_temp.chk_true('anon cannot execute the internal pricing function',
  not pg_temp.can_exec('anon', 'public._calculate_cart_pricing(uuid,boolean)')
  and not pg_temp.can_exec('authenticated', 'public._calculate_cart_pricing(uuid,boolean)'));
select pg_temp.chk_true('popular-products aggregate stays public (storefront needs it)',
  pg_temp.can_exec('anon', 'public.get_popular_products(int)'));
select pg_temp.chk_true('every SECURITY DEFINER function pins search_path',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.prosecdef
                and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')));

-- ===========================================================================
-- 14. Structural guarantees
-- ===========================================================================
select pg_temp.chk_true('RLS is enabled on every public table',
  not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  coalesce((select string_agg(c.relname, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), 'all enabled'));
select pg_temp.chk_true('no policy is granted to the catch-all PUBLIC role',
  not exists (select 1 from pg_policies where schemaname = 'public' and 'public' = any(roles)),
  coalesce((select string_agg(tablename || '.' || policyname, ', ') from pg_policies
            where schemaname = 'public' and 'public' = any(roles)), 'none'));
select pg_temp.chk_true('anon has no privilege on any customer-owned table',
  not exists (select 1 from information_schema.role_table_grants
              where grantee = 'anon' and table_schema = 'public'
                and table_name in ('customer_profiles','customer_addresses','notification_preferences','carts','cart_items',
                                   'orders','order_items','order_status_events','payments','refund_requests','refund_items',
                                   'refund_status_events','loyalty_accounts','loyalty_transactions','reward_redemptions',
                                   'notifications','voucher_usage','vouchers','loyalty_cart_settings','product_variant_costs')));
select pg_temp.chk_true('one payment per order is enforced by a unique index',
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'payments'
          and indexdef ilike '%unique%' and indexdef ilike '%(order_id)%'));

select pg_temp.chk_true('required indexes exist (customer uid, order, branch, product, category, status, created_at)',
  (select count(*) from pg_indexes where schemaname = 'public' and indexname in (
     'customer_addresses_uid_idx', 'carts_uid_status_idx', 'carts_branch_idx', 'cart_items_cart_idx', 'cart_items_product_idx',
     'orders_uid_created_idx', 'orders_branch_idx', 'orders_status_idx', 'orders_created_idx',
     'order_items_order_idx', 'order_items_product_idx', 'order_status_events_order_idx',
     'payments_uid_created_idx', 'payments_status_idx',
     'refund_requests_uid_created_idx', 'refund_requests_order_idx', 'refund_requests_status_idx',
     'loyalty_tx_uid_created_idx', 'reward_redemptions_uid_idx', 'notifications_uid_created_idx',
     'products_category_idx', 'products_active_idx', 'products_created_idx', 'product_variants_product_idx',
     'branch_inventory_product_idx', 'branch_inventory_variant_idx', 'voucher_usage_uid_idx', 'voucher_usage_voucher_idx'
   )) = 28,
  'found ' || (select count(*) from pg_indexes where schemaname = 'public' and indexname in (
     'customer_addresses_uid_idx', 'carts_uid_status_idx', 'carts_branch_idx', 'cart_items_cart_idx', 'cart_items_product_idx',
     'orders_uid_created_idx', 'orders_branch_idx', 'orders_status_idx', 'orders_created_idx',
     'order_items_order_idx', 'order_items_product_idx', 'order_status_events_order_idx',
     'payments_uid_created_idx', 'payments_status_idx',
     'refund_requests_uid_created_idx', 'refund_requests_order_idx', 'refund_requests_status_idx',
     'loyalty_tx_uid_created_idx', 'reward_redemptions_uid_idx', 'notifications_uid_created_idx',
     'products_category_idx', 'products_active_idx', 'products_created_idx', 'product_variants_product_idx',
     'branch_inventory_product_idx', 'branch_inventory_variant_idx', 'voucher_usage_uid_idx', 'voucher_usage_voucher_idx'
   )) || ' of 28');

-- ===========================================================================
-- Report
-- ===========================================================================
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail
from results order by id;

select count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed,
       count(*) as total
from results;

do $$
declare v_failed int;
begin
  select count(*) into v_failed from results where not passed;
  if v_failed > 0 then
    raise exception '% security check(s) FAILED — see the report above.', v_failed;
  end if;
end $$;

rollback;
