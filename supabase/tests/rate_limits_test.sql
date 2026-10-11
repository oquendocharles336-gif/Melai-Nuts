-- =============================================================================
-- Melai Nuts — rate limits for voucher codes and orders (migration 20261019000000_rate_limits.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rate_limits_test.sql
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
create function pg_temp.err_of(p_uid text, p_sql text) returns text language plpgsql as $$
declare v_err text;
begin
  perform pg_temp.act_as(p_uid);
  begin execute p_sql; exception when others then v_err := sqlerrm; end;
  perform pg_temp.back_to_admin();
  return v_err;
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
insert into public.branches (name, address, delivery_fee) values ('RL-TEST A', 'a', 0);
insert into fx select 'ba', id::text from public.branches where name = 'RL-TEST A';
insert into public.product_categories (label) values ('RL-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'RL-TEST Nut', 100, 'pack' from public.product_categories where label = 'RL-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'RL-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'RL-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 1000);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('rl-sa', 'Staff A', 'rl-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active');
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('rl-c1', 'RL Customer', 'rl-c1@test.local', '09170000041'),
  ('rl-c2', 'RL Customer 2', 'rl-c2@test.local', '09170000042');
insert into public.vouchers (code, description, discount_type, discount_value)
values ('RLTEST10', 'test fixture', 'fixed', 10);

create function pg_temp.sync(p_uid text, p_code text) returns text language sql as $$
  select pg_temp.call_as(p_uid, format($q$select (public.sync_customer_cart(%L::uuid,
    jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), %L, false) ->> 'cart_id')$q$,
    pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var'), p_code))
$$;

-- 0. Database-owner SQL (repairs, this test without the switch) is not limited ----------
select pg_temp.chk('owner SQL: a cart may use a voucher without registering it', 'rl-c2',
  format($q$select public.sync_customer_cart(%L::uuid, '[]'::jsonb, 'RLTEST10', false)$q$, pg_temp.f('ba')), 'ok');

-- From here on the limits are on, as for requests from the app.
select set_config('melai.force_rate_limits', 'on', true);

-- 1. Voucher codes --------------------------------------------------------------------
select pg_temp.chk('anon cannot register a voucher attempt', null, $q$select public.register_voucher_attempt('X')$q$, 'error');
select pg_temp.chk('an unregistered code is refused by the cart', 'rl-c1',
  format($q$select public.sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), 'RLTEST10', false)$q$, pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var')), 'error');
select pg_temp.chk_true('... with a clear message',
  pg_temp.err_of('rl-c1', format($q$select public.sync_customer_cart(%L::uuid, '[]'::jsonb, 'RLTEST10', false)$q$, pg_temp.f('ba')))
  = 'Please enter the voucher code again.');
select pg_temp.chk('registering the code', 'rl-c1', $q$select public.register_voucher_attempt(' rltest10 ')$q$, 'ok');
select pg_temp.chk('the registered code is accepted (case and spaces ignored)', 'rl-c1',
  format($q$select public.sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), 'RLtest10', false)$q$, pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var')), 'ok');
select pg_temp.chk('re-syncing the same cart with the same code needs no new registration', 'rl-c1',
  format($q$select public.sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), 'RLTEST10', false)$q$, pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var')), 'ok');
do $$ begin
  for i in 2..10 loop
    perform pg_temp.call_as('rl-c1', format($q$select public.register_voucher_attempt('GUESS%s')::text$q$, i));
  end loop;
end $$;
select pg_temp.chk('the 11th code within 15 minutes is refused', 'rl-c1', $q$select public.register_voucher_attempt('GUESS11')$q$, 'error');
select pg_temp.chk_true('... and says to wait',
  pg_temp.err_of('rl-c1', $q$select public.register_voucher_attempt('GUESS12')$q$) like 'Too many voucher attempts.%');
select pg_temp.chk('another customer is not affected', 'rl-c2', $q$select public.register_voucher_attempt('RLTEST10')$q$, 'ok');
select pg_temp.chk('clients cannot read or write the attempts table', 'rl-c1', 'select count(*) from public.rate_limit_events', 'error');
select pg_temp.chk('clients cannot delete their attempts', 'rl-c1', 'delete from public.rate_limit_events', 'error');
-- A registration older than 24 hours no longer counts.
update public.rate_limit_events set created_at = now() - interval '25 hours' where firebase_uid = 'rl-c2';
select pg_temp.sync('rl-c2', null);   -- remove the code from the cart first (re-sending the same code is not checked)
select pg_temp.chk('an expired registration is refused', 'rl-c2', format($q$select public.sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), 'RLTEST10', false)$q$, pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var')), 'error');

-- 2. Orders ------------------------------------------------------------------------------
do $$ begin
  for i in 1..5 loop
    perform pg_temp.call_as('rl-c2', format($q$select (public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', %L))::text$q$,
      pg_temp.sync('rl-c2', null), 'rl-key-' || i));
  end loop;
end $$;
select pg_temp.chk_true('5 orders in a row are accepted', (select count(*) = 5 from public.orders where firebase_uid = 'rl-c2'));
select pg_temp.chk('replaying an idempotency key is not a new order and is allowed', 'rl-c2',
  format($q$select public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'rl-key-5')$q$, pg_temp.sync('rl-c2', null)), 'ok');
select pg_temp.chk('the 6th new order within 10 minutes is refused', 'rl-c2',
  format($q$select public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'rl-key-6')$q$, pg_temp.sync('rl-c2', null)), 'error');
select pg_temp.chk_true('... no 6th order was stored', (select count(*) = 5 from public.orders where firebase_uid = 'rl-c2'));
select pg_temp.chk('POS sales are not limited', 'rl-sa',
  format($q$select public.staff_create_pos_sale(%L::uuid, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'cash', null, 500)$q$,
    pg_temp.f('ba'), pg_temp.f('var')), 'ok');
update public.orders set created_at = now() - interval '11 minutes' where firebase_uid = 'rl-c2';
select pg_temp.chk('after the window, ordering works again', 'rl-c2',
  format($q$select public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'rl-key-7')$q$, pg_temp.sync('rl-c2', null)), 'ok');

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% rate limit check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
