-- =============================================================================
-- Melai Nuts — owner-editable business settings (migration 20261018000000_business_settings.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/business_settings_test.sql
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

-- Start from "nothing set" (as on a new project), whatever the database had.
delete from public.business_settings;
delete from public.loyalty_cart_settings;

-- Fixtures ---------------------------------------------------------------------
insert into public.branches (name, address, delivery_fee) values ('BS-TEST A', 'a', 0), ('BS-TEST B', 'b', 0);
insert into fx select 'ba', id::text from public.branches where name = 'BS-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'BS-TEST B';
insert into public.product_categories (label) values ('BS-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'BS-TEST Nut', 100, 'pack' from public.product_categories where label = 'BS-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'BS-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'BS-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 100);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status) values
  ('bs-own', 'Owner', 'bs-own@test.local', 'owner', null, 'active'),
  ('bs-sa', 'Staff A', 'bs-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active');
insert into public.customer_profiles (firebase_uid, full_name, email, phone)
values ('bs-c1', 'BS Customer', 'bs-c1@test.local', '09170000031');

create function pg_temp.cart() returns text language sql as $$
  select pg_temp.call_as('bs-c1', format($q$select (public.sync_customer_cart(%L::uuid,
    jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 2)), null, false) ->> 'cart_id')$q$,
    pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var')))
$$;

-- 1. Nothing set = nothing invented ------------------------------------------------
select pg_temp.chk_true('earn rate is NULL (Not set) when the owner never set it', public.get_loyalty_earn_rate() is null);
select pg_temp.chk_true('restock threshold fallback is NULL when not set', public._default_restock_threshold() is null);
select pg_temp.chk('an order without an earn rate is accepted', 'bs-c1',
  format($q$select public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'bs-key-1')$q$, pg_temp.cart()), 'ok');
select pg_temp.chk_true('... and earns 0 points (no invented 1 pt per PHP 50)',
  (select points_earned = 0 from public.orders where firebase_uid = 'bs-c1' order by created_at desc limit 1));
select pg_temp.chk_true('settings read shows every value as null',
  (select (s ->> 'restock_threshold_default') is null and (s ->> 'stock_low_ratio') is null
      and (s ->> 'healthy_margin_percent') is null and (s -> 'loyalty' ->> 'earn_pesos_per_point') is null
   from (select pg_temp.call_as('bs-own', 'select public.get_business_settings()::text')::jsonb as s) x));
select pg_temp.chk_true('a new branch has no default delivery fee',
  (select column_default is null from information_schema.columns
   where table_schema = 'public' and table_name = 'branches' and column_name = 'delivery_fee'));

-- 2. Who can read ----------------------------------------------------------------------
select pg_temp.chk('a customer cannot read business settings', 'bs-c1', 'select public.get_business_settings()', 'error');
select pg_temp.chk('anon cannot read business settings', null, 'select public.get_business_settings()', 'error');
select pg_temp.chk('a customer cannot read the table directly', 'bs-c1', 'select * from public.business_settings', 'error');
select pg_temp.chk('staff can read business settings', 'bs-sa', 'select public.get_business_settings()', 'ok');
select pg_temp.chk_true('staff see only their own branch',
  (select jsonb_array_length(s -> 'branches') = 1 and s -> 'branches' -> 0 ->> 'id' = pg_temp.f('ba')
   from (select pg_temp.call_as('bs-sa', 'select public.get_business_settings()::text')::jsonb as s) x));
select pg_temp.chk_true('the owner sees every branch',
  (select jsonb_array_length(s -> 'branches') >= 2
   from (select pg_temp.call_as('bs-own', 'select public.get_business_settings()::text')::jsonb as s) x));

-- 3. Who can write -------------------------------------------------------------------
select pg_temp.chk('staff cannot change business settings', 'bs-sa',
  $q$select public.owner_update_business_settings('{"restock_threshold_default": 5}')$q$, 'error');
select pg_temp.chk('a customer cannot change business settings', 'bs-c1',
  $q$select public.owner_update_business_settings('{"restock_threshold_default": 5}')$q$, 'error');
select pg_temp.chk('unknown keys are refused', 'bs-own',
  $q$select public.owner_update_business_settings('{"free_money": 5}')$q$, 'error');
select pg_temp.chk('text values are refused', 'bs-own',
  $q$select public.owner_update_business_settings('{"restock_threshold_default": "lots"}')$q$, 'error');
select pg_temp.chk('stock low ratio must be below plenty ratio', 'bs-own',
  $q$select public.owner_update_business_settings('{"stock_low_ratio": 0.9, "stock_plenty_ratio": 0.5}')$q$, 'error');
select pg_temp.chk('margin above 99% is refused', 'bs-own',
  $q$select public.owner_update_business_settings('{"healthy_margin_percent": 150}')$q$, 'error');
select pg_temp.chk('the owner can set the values', 'bs-own',
  $q$select public.owner_update_business_settings('{"restock_threshold_default": 15, "stock_low_ratio": 0.3,
      "stock_plenty_ratio": 0.75, "sales_low_ratio": 0.6, "sales_high_ratio": 1.1,
      "default_daily_sales_target": 5000, "healthy_margin_percent": 40}')$q$, 'ok');
select pg_temp.chk_true('the restock fallback now reads the setting', public._default_restock_threshold() = 15);
select pg_temp.chk_true('the save is audited',
  exists (select 1 from public.staff_audit_logs where action = 'business.settings_updated' and staff_firebase_uid = 'bs-own'));
select pg_temp.chk('a value can be cleared again (null)', 'bs-own',
  $q$select public.owner_update_business_settings('{"default_daily_sales_target": null}')$q$, 'ok');
select pg_temp.chk_true('... cleared, others kept',
  (select default_daily_sales_target is null and restock_threshold_default = 15 and not carried_over
   from public.business_settings where id = 'default'));

-- 4. Low-stock warnings follow the setting -----------------------------------------------
update public.business_settings set restock_threshold_default = null where id = 'default';
update public.branch_inventory set quantity = 3 where branch_id = pg_temp.f('ba')::uuid and variant_id = pg_temp.f('var')::uuid;
select pg_temp.chk_true('without a threshold no "low stock" warning is invented',
  not exists (select 1 from public.staff_notifications where branch_id = pg_temp.f('ba')::uuid and title like 'Low stock:%'));
update public.branch_inventory set quantity = 100 where branch_id = pg_temp.f('ba')::uuid and variant_id = pg_temp.f('var')::uuid;
update public.business_settings set restock_threshold_default = 10 where id = 'default';
update public.branch_inventory set quantity = 3 where branch_id = pg_temp.f('ba')::uuid and variant_id = pg_temp.f('var')::uuid;
select pg_temp.chk_true('with a threshold the warning is raised',
  exists (select 1 from public.staff_notifications where branch_id = pg_temp.f('ba')::uuid and title like 'Low stock:%'));

-- 5. Earn rate set by the owner is used ------------------------------------------------------
select pg_temp.chk('owner sets loyalty rules', 'bs-own', 'select public.owner_update_loyalty_settings(25, 1, 40)', 'ok');
select pg_temp.chk_true('earn rate is now 25', public.get_loyalty_earn_rate() = 25);
update public.branch_inventory set quantity = 100 where branch_id = pg_temp.f('ba')::uuid and variant_id = pg_temp.f('var')::uuid;
select pg_temp.chk('order with an earn rate', 'bs-c1',
  format($q$select public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'bs-key-2')$q$, pg_temp.cart()), 'ok');
select pg_temp.chk_true('... earns floor(total / 25) points',
  (select points_earned = floor(total / 25)::int and points_earned > 0
   from public.orders where firebase_uid = 'bs-c1' order by id desc limit 1));

-- 6. Branch details ------------------------------------------------------------------------
select pg_temp.chk('staff cannot edit a branch', 'bs-sa',
  format($q$select public.owner_save_branch(%L::uuid, 'BS-TEST A', 'x', null, null, 0, null, true, true, true)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('a branch needs a delivery fee', 'bs-own',
  $q$select public.owner_save_branch(null, 'BS-TEST C', null, null, null, null, null, false, true, true)$q$, 'error');
select pg_temp.chk('the owner creates a branch', 'bs-own',
  $q$select public.owner_save_branch(null, 'BS-TEST C', 'Real street', '09170000000', '9-5', 45, 3000, true, true, true)$q$, 'ok');
select pg_temp.chk_true('... with exactly what was typed',
  (select address = 'Real street' and delivery_fee = 45 and daily_sales_target = 3000 and operating_hours = '9-5'
   from public.branches where name = 'BS-TEST C'));
select pg_temp.chk('a duplicate name is refused', 'bs-own',
  $q$select public.owner_save_branch(null, 'BS-TEST C', null, null, null, 0, null, false, true, true)$q$, 'error');
select pg_temp.chk('the owner updates a branch (blank values become empty)', 'bs-own',
  format($q$select public.owner_save_branch(%L::uuid, 'BS-TEST A', '  ', '', null, 30, null, true, true, true)$q$, pg_temp.f('ba')), 'ok');
select pg_temp.chk_true('... address/phone cleared, fee saved',
  (select address is null and contact_phone is null and delivery_fee = 30 from public.branches where id = pg_temp.f('ba')::uuid));
select pg_temp.chk_true('branch changes are audited',
  (select count(*) >= 2 from public.staff_audit_logs where action in ('branch.created', 'branch.updated') and staff_firebase_uid = 'bs-own'));

-- 7. Online payment text comes from the database ---------------------------------------------
update public.payment_settings set online_payment_enabled = false,
  online_payment_disabled_message = 'BS-TEST: paying online is paused' where id = 'default';
select pg_temp.chk_true('the order trigger uses the database message',
  pg_temp.err_of('bs-c1', format($q$select public.place_order(%L::uuid, false, null, 'Online Payment (GCash, Maya, Card)', '', 'bs-key-3')$q$,
    pg_temp.cart())) = 'BS-TEST: paying online is paused');
select pg_temp.chk_true('customers can read the message (for the checkout notice)',
  pg_temp.call_as('bs-c1', 'select online_payment_disabled_message from public.payment_settings where id = ''default''') = 'BS-TEST: paying online is paused');

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% business settings check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
