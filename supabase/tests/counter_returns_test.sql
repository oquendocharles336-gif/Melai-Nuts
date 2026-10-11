-- =============================================================================
-- Melai Nuts — counter returns from the app (migration 20261020000000_staff_orders_variant_ids.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/counter_returns_test.sql
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
insert into public.branches (name, address, delivery_fee) values ('CR2-TEST A', 'a', 0);
insert into fx select 'ba', id::text from public.branches where name = 'CR2-TEST A';
insert into public.product_categories (label) values ('CR2-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'CR2-TEST Nut', 100, 'pack' from public.product_categories where label = 'CR2-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'CR2-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'CR2-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 20);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
values ('cr2-sa', 'Cashier', 'cr2-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', true, true);

select pg_temp.call_as('cr2-sa', format($q$select public.staff_open_shift(%L::uuid, 1000, 'cr2-open-1')::text$q$, pg_temp.f('ba')));
insert into fx select 'order', pg_temp.call_as('cr2-sa', format($q$select public.staff_create_pos_sale(%L::uuid,
  jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 3)), 'cash', null, 500, null, 'cr2-sale-1') ->> 'order_id'$q$,
  pg_temp.f('ba'), pg_temp.f('var')));
insert into fx select 'items', pg_temp.call_as('cr2-sa', format($q$select (public.staff_list_orders(%L::uuid, null, null, 10, %L) -> 0 -> 'items')::text$q$,
  pg_temp.f('ba'), pg_temp.f('order')));

-- 1. The order list now carries the ids the return needs ------------------------------
select pg_temp.chk_true('staff_list_orders items carry variant_id',
  (pg_temp.f('items')::jsonb -> 0 ->> 'variant_id') = pg_temp.f('var'), pg_temp.f('items'));
select pg_temp.chk_true('... and product_id', (pg_temp.f('items')::jsonb -> 0 ->> 'product_id') = pg_temp.f('prod'));
select pg_temp.chk_true('... and still the old fields', (pg_temp.f('items')::jsonb -> 0 ->> 'quantity')::int = 3);

-- 2. A counter return built from those ids --------------------------------------------
select pg_temp.chk('return 1 of the 3 packs using the listed variant id', 'cr2-sa',
  format($q$select public.staff_pos_return(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'Customer changed mind', 'cr2-return-1')$q$,
    pg_temp.f('order'), pg_temp.f('items')::jsonb -> 0 ->> 'variant_id'), 'ok');
select pg_temp.chk_true('the pack went back to stock (20 - 3 + 1)',
  (select quantity = 18 from public.branch_inventory where branch_id = pg_temp.f('ba')::uuid and variant_id = pg_temp.f('var')::uuid));
select pg_temp.chk('sending the same return again (same key) is not applied twice', 'cr2-sa',
  format($q$select public.staff_pos_return(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'Customer changed mind', 'cr2-return-1')$q$,
    pg_temp.f('order'), pg_temp.f('var')), 'ok');
select pg_temp.chk_true('... still 18 in stock and one refund',
  (select quantity = 18 from public.branch_inventory where branch_id = pg_temp.f('ba')::uuid and variant_id = pg_temp.f('var')::uuid)
  and (select count(*) = 1 from public.refund_requests where order_id = pg_temp.f('order')));

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% counter return check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
