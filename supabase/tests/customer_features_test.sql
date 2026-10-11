-- =============================================================================
-- Melai Nuts — customer features (migration 20261023000000_customer_features.sql)
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/customer_features_test.sql
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


insert into public.branches (name, address, delivery_fee) values ('CF-TEST Shop', 'a', 0);
insert into fx select 'shop', id::text from public.branches where name = 'CF-TEST Shop';
insert into public.product_categories (label) values ('CF-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'CF-TEST Nut', 100, 'pack' from public.product_categories where label = 'CF-TEST Cat';
insert into public.products (category_id, name, price, unit, is_active)
select id, 'CF-TEST Gone', 100, 'pack', false from public.product_categories where label = 'CF-TEST Cat';
insert into fx select 'prod', id::text from public.products where name = 'CF-TEST Nut';
insert into fx select 'gone', id::text from public.products where name = 'CF-TEST Gone';
insert into public.product_variants (product_id, label, price) values (pg_temp.f('prod')::uuid, 'Regular', 100);
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity) values
  (pg_temp.f('shop')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 2);
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('cf-c1', 'CF One', 'cf-c1@test.local', '09170000071'),
  ('cf-c2', 'CF Two', 'cf-c2@test.local', '09170000072');
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status) values
  ('cf-own', 'Owner', 'cf-own@test.local', 'owner', null, 'active');

-- 1. "Only N left" setting -------------------------------------------------------
select pg_temp.chk_true('storefront setting is Not set by default',
  (pg_temp.call_as(null, 'select public.get_storefront_settings()::text')::jsonb ->> 'low_stock_badge_qty') is null);
select pg_temp.chk('a customer cannot change it', 'cf-c1',
  $q$select public.owner_update_business_settings('{"low_stock_badge_qty": 3}'::jsonb)$q$, 'error');
select pg_temp.chk('the owner sets it to 3', 'cf-own',
  $q$select public.owner_update_business_settings('{"low_stock_badge_qty": 3}'::jsonb)$q$, 'ok');
select pg_temp.chk_true('signed-out shoppers read 3',
  (pg_temp.call_as(null, 'select public.get_storefront_settings()::text')::jsonb ->> 'low_stock_badge_qty') = '3');
select pg_temp.chk_true('owner settings include it',
  (pg_temp.call_as('cf-own', 'select public.get_business_settings()::text')::jsonb ->> 'low_stock_badge_qty') = '3');
select pg_temp.chk('0 is refused', 'cf-own',
  $q$select public.owner_update_business_settings('{"low_stock_badge_qty": 0}'::jsonb)$q$, 'error');
select pg_temp.chk('the owner clears it', 'cf-own',
  $q$select public.owner_update_business_settings('{"low_stock_badge_qty": null}'::jsonb)$q$, 'ok');
select pg_temp.chk_true('cleared means Not set again',
  (pg_temp.call_as(null, 'select public.get_storefront_settings()::text')::jsonb ->> 'low_stock_badge_qty') is null);

-- 2. Favourites -----------------------------------------------------------------
select pg_temp.chk('signed out cannot save a favourite', null,
  format('select public.toggle_favorite(%L::uuid)', pg_temp.f('prod')), 'error');
select pg_temp.chk_true('toggle adds',
  pg_temp.call_as('cf-c1', format('select public.toggle_favorite(%L::uuid)::text', pg_temp.f('prod'))) = 'true');
select pg_temp.chk_true('the customer sees it',
  pg_temp.call_as('cf-c1', 'select public.get_my_favorites()::text')::jsonb ? pg_temp.f('prod'));
select pg_temp.chk_true('another customer does not',
  jsonb_array_length(pg_temp.call_as('cf-c2', 'select public.get_my_favorites()::text')::jsonb) = 0);
select pg_temp.chk('the table is not readable directly', 'cf-c1', 'select count(*) from public.customer_favorites', 'error');
select pg_temp.chk('an inactive product cannot be added', 'cf-c1',
  format('select public.toggle_favorite(%L::uuid)', pg_temp.f('gone')), 'error');
select pg_temp.chk_true('toggle again removes',
  pg_temp.call_as('cf-c1', format('select public.toggle_favorite(%L::uuid)::text', pg_temp.f('prod'))) = 'false'
  and jsonb_array_length(pg_temp.call_as('cf-c1', 'select public.get_my_favorites()::text')::jsonb) = 0);

-- 3. Order-ready alert ------------------------------------------------
insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method)
values ('cf-c1', pg_temp.f('shop')::uuid, 'CF-TEST Shop', false, 'pending', 500, 0, 0, 500, 'cash');
insert into fx select 'order', id from public.orders where firebase_uid = 'cf-c1' order by created_at desc, id desc limit 1;
insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
values (pg_temp.f('order'), pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 'CF-TEST Nut', 'Regular', 5, 100);
update public.orders set status = 'confirmed' where id = pg_temp.f('order');
update public.orders set status = 'preparing' where id = pg_temp.f('order');
update public.orders set status = 'readyForPickup' where id = pg_temp.f('order');
select pg_temp.chk_true('ready-for-pickup notification names the branch',
  exists (select 1 from public.notifications where firebase_uid = 'cf-c1'
           and title = 'Order ' || pg_temp.f('order') || ' is ready for pickup' and body like '%at CF-TEST Shop%'));
select pg_temp.chk_true('and it is queued as a push',
  exists (select 1 from public.push_outbox where firebase_uid = 'cf-c1' and title like '%ready for pickup' and sent_at is null));
select pg_temp.chk_true('no raw status names in customer messages',
  not exists (select 1 from public.notifications where firebase_uid = 'cf-c1' and body like '%readyForPickup%'));

select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$ declare n int; begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% customer-features check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
