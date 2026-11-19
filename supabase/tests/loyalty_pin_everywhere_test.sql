-- =============================================================================
-- Melai Nuts — the loyalty PIN is needed wherever points are spent
-- (migration 20261120020000_loyalty_pin_for_every_redemption.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/loyalty_pin_everywhere_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
-- =============================================================================
begin;

-- Every order is paid online first (migration 20261119080000).
\ir online_first_setup.sql

set local timezone = 'Asia/Manila';

create temp table results (id serial primary key, name text not null, passed boolean not null, detail text);
create temp table fx (k text primary key, v text);
grant select on fx to public;

create function pg_temp.act_as(p_uid text) returns void language plpgsql as $$
begin
  if p_uid is null then
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
  else
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', p_uid, 'role', 'authenticated',
      'email', p_uid || '@test.local', 'email_verified', true, 'phone_number', '+639' || lpad((abs(hashtext(p_uid)) % 1000000000)::text, 9, '0'))::text, true);
    execute 'set local role authenticated';
  end if;
end $$;
create function pg_temp.back_to_admin() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on function pg_temp.back_to_admin() to public;
create function pg_temp.chk(p_name text, p_uid text, p_sql text, p_expect text) returns void language plpgsql as $$
declare v_err text;
begin
  perform pg_temp.act_as(p_uid);
  begin execute p_sql; exception when others then v_err := sqlerrm; end;
  perform pg_temp.back_to_admin();
  insert into results(name, passed, detail) values (p_name,
    case p_expect when 'error' then v_err is not null else v_err is null end,
    'expected ' || p_expect || ' -> ' || coalesce('error: ' || v_err, 'no error'));
end $$;
create function pg_temp.call_as(p_uid text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.act_as(p_uid);
  begin execute p_sql into v;
  exception when others then perform pg_temp.back_to_admin(); raise; end;
  perform pg_temp.back_to_admin();
  return v;
end $$;
create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;
create function pg_temp.f(p_k text) returns text language sql as $$ select v from fx where k = p_k $$;
grant execute on function pg_temp.f(text) to public;
create function pg_temp.j(p_uid text, p_sql text) returns jsonb language sql as $$
  select pg_temp.call_as(p_uid, 'select (' || p_sql || ')::text')::jsonb $$;
create function pg_temp.balance(p_uid text) returns int language sql as $$
  select points_balance from public.loyalty_accounts where firebase_uid = p_uid $$;

-- Fixtures: one unit costs 100. 1 point = PHP 1, at most 50% of the subtotal. -------------
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point)
values ('default', 1, 50, 50)
  on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;
insert into public.branches (name, address, delivery_fee) values ('PIN-TEST A', 'a', 0);
insert into fx select 'ba', id::text from public.branches where name = 'PIN-TEST A';
insert into public.product_categories (label) values ('PIN-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'PIN-TEST Nut', 100, 'pack' from public.product_categories where label = 'PIN-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'PIN-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'PIN-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 0);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('pn-sa', 'Cashier', 'pn-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active'),
       ('pn-own', 'Owner', 'pn-own@test.local', 'owner', null, 'active');
-- pn-pin set a PIN; pn-free did not. Both are returning customers with 300 points.
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('pn-pin', 'Pin Holder', 'pn-pin@test.local', '09173330001'),
  ('pn-free', 'No Pin', 'pn-free@test.local', '09173330002');
update public.customer_profiles set first_paid_order_at = now() - interval '30 days' where firebase_uid in ('pn-pin', 'pn-free');
insert into public.loyalty_accounts (firebase_uid, points_balance) values ('pn-pin', 300), ('pn-free', 300)
  on conflict (firebase_uid) do update set points_balance = excluded.points_balance;
insert into public.rewards (title, points_required) values ('PIN-TEST Reward', 50);
insert into fx select 'reward', id::text from public.rewards where title = 'PIN-TEST Reward';
select pg_temp.call_as('pn-own', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'PIN-A1', 50, current_date + 90)::text$q$,
  pg_temp.f('ba'), pg_temp.f('var')));
select set_config('app.inventory_managed', '', true);

select pg_temp.call_as('pn-pin', $q$select public.customer_set_loyalty_pin('4321')::text$q$);

-- An open cart of 2 units with "use points" on, and an online order from it.
create function pg_temp.cart(p_uid text) returns text language sql as $$
  select pg_temp.call_as(p_uid, format($q$select (public.sync_customer_cart(%L::uuid,
    jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 2)), null, true) ->> 'cart_id')$q$,
    pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var'))) $$;
create function pg_temp.order_sql(p_cart text, p_key text) returns text language sql as $$
  select format($q$select public.place_order(%L::uuid, false, null, 'Online Payment (GCash, QR Ph, Card)', '', %L)$q$, p_cart, p_key) $$;

-- 1. No PIN: exactly as before ----------------------------------------------------------------
select pg_temp.chk_true('no PIN: verify says so and gives no pass',
  pg_temp.j('pn-free', $q$public.verify_my_loyalty_pin(null)$q$) ->> 'reason' = 'no_pin'
  and not exists (select 1 from public.loyalty_pin_passes where firebase_uid = 'pn-free'));
insert into fx select 'cart_free', pg_temp.cart('pn-free');
select pg_temp.chk('no PIN: an online order with points works without a PIN', 'pn-free',
  pg_temp.order_sql(pg_temp.f('cart_free'), 'pin-free-1'), 'ok');
select pg_temp.chk_true('no PIN: the points were used (100 of 300)', pg_temp.balance('pn-free') = 200);
select pg_temp.chk('no PIN: a reward works without a PIN', 'pn-free',
  format($q$select public.redeem_reward(%L::uuid)$q$, pg_temp.f('reward')), 'ok');
select pg_temp.chk_true('no PIN: reward paid', pg_temp.balance('pn-free') = 150);

-- 2. PIN holder, online order: refused without the PIN, even by a direct RPC call ---------------
insert into fx select 'cart_pin', pg_temp.cart('pn-pin');
select pg_temp.chk('PIN: an order with points WITHOUT the PIN is refused (direct place_order RPC)', 'pn-pin',
  pg_temp.order_sql(pg_temp.f('cart_pin'), 'pin-1'), 'error');
select pg_temp.chk_true('PIN: nothing was spent and no order exists',
  pg_temp.balance('pn-pin') = 300 and not exists (select 1 from public.orders where idempotency_key = 'pin-1'));
insert into fx select 'wrong1', pg_temp.j('pn-pin', $q$public.verify_my_loyalty_pin('9999')$q$)::text;
select pg_temp.chk_true('PIN: a wrong PIN is refused, counted, and gives no pass',
  pg_temp.f('wrong1')::jsonb ->> 'reason' = 'wrong' and (pg_temp.f('wrong1')::jsonb ->> 'attempts_left')::int = 4
  and (select failed_attempts = 1 from public.loyalty_pins where firebase_uid = 'pn-pin')
  and not exists (select 1 from public.loyalty_pin_passes where firebase_uid = 'pn-pin'));
select pg_temp.chk('PIN: after a wrong PIN the order is still refused', 'pn-pin',
  pg_temp.order_sql(pg_temp.f('cart_pin'), 'pin-2'), 'error');
select pg_temp.chk('PIN: a customer cannot write a pass for themselves', 'pn-pin',
  $q$insert into public.loyalty_pin_passes values ('pn-pin', now() + interval '1 day')$q$, 'error');
select pg_temp.chk('PIN: a customer cannot read the PIN check directly', 'pn-pin',
  $q$select public._check_loyalty_pin('pn-pin', '4321')$q$, 'error');
insert into fx select 'right1', pg_temp.j('pn-pin', $q$public.verify_my_loyalty_pin('4321')$q$)::text;
select pg_temp.chk_true('PIN: the right PIN gives a pass and resets the counter',
  (pg_temp.f('right1')::jsonb ->> 'ok')::boolean
  and (select failed_attempts = 0 from public.loyalty_pins where firebase_uid = 'pn-pin')
  and exists (select 1 from public.loyalty_pin_passes where firebase_uid = 'pn-pin' and valid_until > now()));
select pg_temp.chk('PIN: with the pass the order with points is placed', 'pn-pin',
  pg_temp.order_sql(pg_temp.f('cart_pin'), 'pin-3'), 'ok');
select pg_temp.chk_true('PIN: points used once and the pass is used up',
  pg_temp.balance('pn-pin') = 200 and not exists (select 1 from public.loyalty_pin_passes where firebase_uid = 'pn-pin'));

-- 3. PIN holder, rewards ----------------------------------------------------------------------
select pg_temp.chk('PIN: a reward WITHOUT the PIN is refused (direct redeem_reward RPC)', 'pn-pin',
  format($q$select public.redeem_reward(%L::uuid)$q$, pg_temp.f('reward')), 'error');
select pg_temp.chk_true('PIN: the refused reward spent nothing', pg_temp.balance('pn-pin') = 200);
select pg_temp.call_as('pn-pin', $q$select public.verify_my_loyalty_pin('4321')::text$q$);
select pg_temp.chk('PIN: with the pass the reward works', 'pn-pin',
  format($q$select public.redeem_reward(%L::uuid)$q$, pg_temp.f('reward')), 'ok');
select pg_temp.chk('PIN: one pass is one spend', 'pn-pin',
  format($q$select public.redeem_reward(%L::uuid)$q$, pg_temp.f('reward')), 'error');
select pg_temp.chk_true('PIN: exactly one reward paid', pg_temp.balance('pn-pin') = 150);
update public.loyalty_pin_passes set valid_until = now() - interval '1 second' where firebase_uid = 'pn-pin';
select pg_temp.call_as('pn-pin', $q$select public.verify_my_loyalty_pin('4321')::text$q$);
update public.loyalty_pin_passes set valid_until = now() - interval '1 second' where firebase_uid = 'pn-pin';
select pg_temp.chk('PIN: an expired pass does not count', 'pn-pin',
  format($q$select public.redeem_reward(%L::uuid)$q$, pg_temp.f('reward')), 'error');

-- 4. Lock: 5 wrong tries = 15 minutes, even with the right PIN ---------------------------------
select pg_temp.call_as('pn-pin', $q$select public.verify_my_loyalty_pin('0000')::text$q$) from generate_series(1, 4);
insert into fx select 'lock5', pg_temp.j('pn-pin', $q$public.verify_my_loyalty_pin('0000')$q$)::text;
select pg_temp.chk_true('PIN: the 5th wrong try locks it',
  pg_temp.f('lock5')::jsonb ->> 'reason' = 'locked'
  and (select locked_until > now() + interval '14 minutes' from public.loyalty_pins where firebase_uid = 'pn-pin'));
select pg_temp.chk_true('PIN: while locked the right PIN gives no pass',
  pg_temp.j('pn-pin', $q$public.verify_my_loyalty_pin('4321')$q$) ->> 'reason' = 'locked'
  and not exists (select 1 from public.loyalty_pin_passes where firebase_uid = 'pn-pin' and valid_until > now()));
select pg_temp.chk('PIN: while locked a reward is refused', 'pn-pin',
  format($q$select public.redeem_reward(%L::uuid)$q$, pg_temp.f('reward')), 'error');
select pg_temp.chk_true('PIN: the locked attempts spent nothing', pg_temp.balance('pn-pin') = 150);
update public.loyalty_pins set locked_until = null, failed_attempts = 0 where firebase_uid = 'pn-pin';

-- 5. Counter (POS): still checked by staff_create_pos_sale, and the new rule does not get in the way
create function pg_temp.items(p_qty int) returns text language sql as $$
  select jsonb_build_array(jsonb_build_object('variant_id', pg_temp.f('var'), 'quantity', p_qty))::text $$;
grant execute on function pg_temp.items(int) to public;
insert into fx select 'pos_wrong', pg_temp.j('pn-sa', format(
  $q$public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 200, 'pn-pin', 'pin-pos-1', true, '1111', true)$q$,
  pg_temp.f('ba'), pg_temp.items(2)))::text;
select pg_temp.chk_true('POS: a wrong PIN sells nothing and spends nothing (direct RPC)',
  pg_temp.f('pos_wrong')::jsonb ->> 'error' = 'pin_wrong' and pg_temp.balance('pn-pin') = 150
  and not exists (select 1 from public.pos_sales where idempotency_key = 'pin-pos-1'));
select pg_temp.chk_true('POS: a missing PIN is refused too',
  pg_temp.j('pn-sa', format(
    $q$public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 200, 'pn-pin', 'pin-pos-2', true, null, true)$q$,
    pg_temp.f('ba'), pg_temp.items(2))) ->> 'error' = 'pin_wrong');
select pg_temp.chk('POS: the right PIN redeems at the counter (no app pass needed)', 'pn-sa',
  format($q$select public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 200, 'pn-pin', 'pin-pos-3', true, '4321', true)$q$,
    pg_temp.f('ba'), pg_temp.items(2)), 'ok');
select pg_temp.chk_true('POS: points used at the counter', pg_temp.balance('pn-pin') < 150);
select pg_temp.chk('POS: a customer without a PIN redeems with confirmation only', 'pn-sa',
  format($q$select public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 200, 'pn-free', 'pin-pos-4', true, null, true)$q$,
    pg_temp.f('ba'), pg_temp.items(2)), 'ok');

-- 6. Never needed for earning or owner adjustments -----------------------------------------------
select pg_temp.chk('the owner can still adjust a PIN holder''s points', 'pn-own',
  $q$select public.owner_adjust_loyalty_points('pn-pin', -1, 'PIN-TEST correction', 'pin-adj-1')$q$, 'ok');
select pg_temp.chk('anon cannot verify a PIN', null, $q$select public.verify_my_loyalty_pin('4321')$q$, 'error');

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% loyalty PIN check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
