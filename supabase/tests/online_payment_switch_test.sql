-- =============================================================================
-- Melai Nuts — online payment switch (migration 20261017000000_online_payment_switch.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/online_payment_switch_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
-- =============================================================================
begin;

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
      'email', p_uid || '@test.local', 'email_verified', true)::text, true);
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

-- Fixtures ---------------------------------------------------------------------
insert into public.branches (name, address, delivery_fee) values ('PAY-TEST A', 'a', 0);
insert into fx select 'ba', id::text from public.branches where name = 'PAY-TEST A';
insert into public.product_categories (label) values ('PAY-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'PAY-TEST Nut', 100, 'pack' from public.product_categories where label = 'PAY-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'PAY-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'PAY-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 100);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('pay-sa', 'Staff A', 'pay-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active');
insert into public.customer_profiles (firebase_uid, full_name, email, phone)
values ('pay-c1', 'Pay Customer', 'pay-c1@test.local', '09170000021');
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent)
values ('default', 1, 50) on conflict (id) do nothing;

create function pg_temp.cart() returns text language sql as $$
  select pg_temp.call_as('pay-c1', format($q$select (public.sync_customer_cart(%L::uuid,
    jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false) ->> 'cart_id')$q$,
    pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var')))
$$;

-- 1. Off by default -------------------------------------------------------------
select pg_temp.chk_true('online payment is off by default', not public.online_payment_enabled());
select pg_temp.chk_true('customers can read the switch',
  pg_temp.call_as('pay-c1', 'select online_payment_enabled::text from public.payment_settings') = 'false');
select pg_temp.chk_true('anon can read the switch',
  pg_temp.call_as(null, 'select public.online_payment_enabled()::text') = 'false');
select pg_temp.chk('a customer cannot turn it on', 'pay-c1',
  $q$update public.payment_settings set online_payment_enabled = true$q$, 'error');
select pg_temp.chk('staff cannot turn it on', 'pay-sa',
  $q$update public.payment_settings set online_payment_enabled = true$q$, 'error');
select pg_temp.chk_true('the switch is still off', not public.online_payment_enabled());

-- 2. Online orders refused, cash orders fine --------------------------------------
select pg_temp.chk('online payment order is refused', 'pay-c1',
  format($q$select public.place_order(%L::uuid, false, null, 'Online Payment (GCash, Maya, Card)', '', 'pay-key-1')$q$, pg_temp.cart()), 'error');
select pg_temp.chk('older app label GCash E-Wallet is refused too', 'pay-c1',
  format($q$select public.place_order(%L::uuid, false, null, 'GCash E-Wallet', '', 'pay-key-2')$q$, pg_temp.cart()), 'error');
select pg_temp.chk('older app label Maya / Credit Card is refused too', 'pay-c1',
  format($q$select public.place_order(%L::uuid, false, null, 'Maya / Credit Card', '', 'pay-key-3')$q$, pg_temp.cart()), 'error');
select pg_temp.chk_true('no online order or payment was left behind',
  (select count(*) = 0 from public.orders where firebase_uid = 'pay-c1'));
select pg_temp.chk('cash on counter pickup still works', 'pay-c1',
  format($q$select public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'pay-key-4')$q$, pg_temp.cart()), 'ok');
select pg_temp.chk('in-store GCash sale at the POS is not affected', 'pay-sa',
  format($q$select public.staff_create_pos_sale(%L::uuid, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'gcash', 'REF-1')$q$,
    pg_temp.f('ba'), pg_temp.f('var')), 'ok');

-- 3. Turned back on by the owner of the database -----------------------------------
update public.payment_settings set online_payment_enabled = true where id = 'default';
select pg_temp.chk('with the switch on, an online order is accepted again', 'pay-c1',
  format($q$select public.place_order(%L::uuid, false, null, 'Online Payment (GCash, Maya, Card)', '', 'pay-key-5')$q$, pg_temp.cart()), 'ok');

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% online payment switch check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
