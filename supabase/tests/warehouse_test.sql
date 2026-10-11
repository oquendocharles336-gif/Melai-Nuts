-- =============================================================================
-- Melai Nuts — warehouse as a branch (migration 20261022000000_warehouse.sql)
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/warehouse_test.sql
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

insert into public.branches (name, address, delivery_fee) values ('WH-TEST Shop', 'a', 0), ('WH-TEST Warehouse', 'w', 0);
insert into fx select 'shop', id::text from public.branches where name = 'WH-TEST Shop';
insert into fx select 'wh', id::text from public.branches where name = 'WH-TEST Warehouse';
insert into public.product_categories (label) values ('WH-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'WH-TEST Nut', 100, 'pack' from public.product_categories where label = 'WH-TEST Cat';
insert into public.product_variants (product_id, label, price) select id, 'Regular', 100 from public.products where name = 'WH-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'WH-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity) values
  (pg_temp.f('shop')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 0);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory) values
  ('wh-own', 'Owner', 'wh-own@test.local', 'owner', null, 'active', true),
  ('wh-ws', 'Warehouse staff', 'wh-ws@test.local', 'staff', pg_temp.f('wh')::uuid, 'active', true),
  ('wh-ss', 'Shop staff', 'wh-ss@test.local', 'staff', pg_temp.f('shop')::uuid, 'active', true);
-- The warehouse receives a real batch of 100 (Receive Stock).
select pg_temp.call_as('wh-ws', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'WH-B1', 100, current_date + 180)::text$q$,
  pg_temp.f('wh'), pg_temp.f('var')));
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values ('wh-c1', 'WH Customer', 'wh-c1@test.local', '09170000061');

select pg_temp.chk('staff cannot mark a warehouse', 'wh-ws', format($q$select public.owner_set_branch_warehouse(%L::uuid, true)$q$, pg_temp.f('wh')), 'error');
select pg_temp.chk('the owner marks the warehouse', 'wh-own', format($q$select public.owner_set_branch_warehouse(%L::uuid, true)$q$, pg_temp.f('wh')), 'ok');
select pg_temp.chk_true('a warehouse supports neither delivery nor pickup',
  (select is_warehouse and not supports_delivery and not supports_pickup from public.branches where id = pg_temp.f('wh')::uuid));
select pg_temp.chk_true('it cannot be switched back on for customers while it is a warehouse',
  pg_temp.err_of(null, format($q$update public.branches set supports_pickup = true where id = %L::uuid$q$, pg_temp.f('wh'))) is not null);
select pg_temp.chk('a customer cannot fill a cart at the warehouse', 'wh-c1',
  format($q$select public.sync_customer_cart(%L::uuid, jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false)$q$,
    pg_temp.f('wh'), pg_temp.f('prod'), pg_temp.f('var')), 'ok');
select pg_temp.chk('... but cannot order there (pickup)', 'wh-c1',
  format($q$select public.place_order((select id from public.carts where firebase_uid = 'wh-c1' and branch_id = %L::uuid and status = 'open'), false, null, 'Cash on Counter Pickup', '', 'wh-key-1')$q$,
    pg_temp.f('wh')), 'error');
select pg_temp.chk('POS sales are refused at the warehouse', 'wh-ws',
  format($q$select public.staff_create_pos_sale(%L::uuid, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'cash', null, 500)$q$,
    pg_temp.f('wh'), pg_temp.f('var')), 'error');
select pg_temp.chk_true('no order was stored at the warehouse', not exists (select 1 from public.orders where branch_id = pg_temp.f('wh')::uuid));
-- Stock moves from the warehouse to the shop with the existing transfers.
insert into fx select 'tr', pg_temp.call_as('wh-ss',
  format($q$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 10, 'restock')$q$, pg_temp.f('wh'), pg_temp.f('shop'), pg_temp.f('var')));
select pg_temp.chk_true('the shop requested stock from the warehouse', pg_temp.f('tr') is not null);
select pg_temp.chk('the warehouse ships it', 'wh-ws', format($q$select public.staff_respond_transfer(%L, 'ship')$q$, pg_temp.f('tr')), 'ok');
select pg_temp.chk('the shop receives it', 'wh-ss', format($q$select public.staff_respond_transfer(%L, 'receive')$q$, pg_temp.f('tr')), 'ok');
select pg_temp.chk_true('stock moved warehouse -> shop (90 / 10)',
  (select quantity from public.branch_inventory where branch_id = pg_temp.f('wh')::uuid and variant_id = pg_temp.f('var')::uuid) = 90
  and (select quantity from public.branch_inventory where branch_id = pg_temp.f('shop')::uuid and variant_id = pg_temp.f('var')::uuid) = 10);

select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$ declare n int; begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% warehouse check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
