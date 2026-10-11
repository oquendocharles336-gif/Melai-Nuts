-- =============================================================================
-- Melai Nuts — delivery pins (migration 20261016000000_delivery_pins_app_only.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/delivery_pins_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
--
-- Who may write / read a customer's delivery pin:
--   customer  writes only their own saved addresses; reads only their own
--   rider     only stops of runs assigned to them, only while stop + run are open
--   staff     only their own branch's orders and runs
--   owner     every branch
--   anon      nothing
-- and the pin a rider / staff sees is the one snapshot on the order at checkout.
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
create function pg_temp.visible(p_uid text, p_sql text) returns bigint language plpgsql as $$
declare v bigint;
begin
  perform pg_temp.act_as(p_uid);
  begin execute p_sql into v; exception when insufficient_privilege then v := 0; end;
  perform pg_temp.back_to_admin();
  return v;
end $$;
create function pg_temp.affected(p_uid text, p_sql text) returns bigint language plpgsql as $$
declare v bigint;
begin
  perform pg_temp.act_as(p_uid);
  begin execute p_sql; get diagnostics v = row_count; exception when insufficient_privilege then v := 0; end;
  perform pg_temp.back_to_admin();
  return v;
end $$;
create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;
create function pg_temp.f(p_k text) returns text language sql as $$ select v from fx where k = p_k $$;
grant execute on function pg_temp.f(text) to public;

-- Fixtures ---------------------------------------------------------------------
insert into public.branches (name, address, latitude, longitude, delivery_fee)
values ('PIN-TEST A', 'a', 14.2117, 121.1653, 0), ('PIN-TEST B', 'b', 14.3, 121.2, 0);
insert into fx select 'ba', id::text from public.branches where name = 'PIN-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'PIN-TEST B';
insert into public.product_categories (label) values ('PIN-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'PIN-TEST Nut', 100, 'pack' from public.product_categories where label = 'PIN-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'PIN-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'PIN-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select pg_temp.f(b)::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 100 from (values ('ba'), ('bb')) t(b);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('p-sa', 'Staff A', 'p-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active'),
       ('p-sb', 'Staff B', 'p-sb@test.local', 'staff', pg_temp.f('bb')::uuid, 'active'),
       ('p-own', 'Owner', 'p-own@test.local', 'owner', null, 'active');
insert into public.customer_profiles (firebase_uid, full_name, email, phone)
values ('p-c1', 'Pia Pinned', 'p-c1@test.local', '09170000011'), ('p-c2', 'Nico Nopin', 'p-c2@test.local', '09170000012');
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point)
values ('default', 1, 50, 50)
  on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;

-- 1. Customer writes the pin on their own saved address ------------------------
select pg_temp.chk('customer saves a pinned address', 'p-c1',
  $q$insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city, latitude, longitude)
     values ('p-c1', 'Pia Pinned', '09170000011', '7 Pin St', 'Calamba', 14.20501, 121.15602)$q$, 'ok');
insert into fx select 'addr1', id::text from public.customer_addresses where firebase_uid = 'p-c1';
select pg_temp.chk('customer saves an address without a pin (allowed, the app warns)', 'p-c2',
  $q$insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city)
     values ('p-c2', 'Nico Nopin', '09170000012', '9 No Pin Rd', 'Calamba')$q$, 'ok');
insert into fx select 'addr2', id::text from public.customer_addresses where firebase_uid = 'p-c2';
select pg_temp.chk('a pin at 0,0 is refused', 'p-c1',
  format($q$update public.customer_addresses set latitude = 0, longitude = 0 where id = %L$q$, pg_temp.f('addr1')), 'error');
select pg_temp.chk('an out-of-range pin is refused', 'p-c1',
  format($q$update public.customer_addresses set latitude = 95 where id = %L$q$, pg_temp.f('addr1')), 'error');
select pg_temp.chk('a customer cannot create an address for someone else', 'p-c2',
  $q$insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city, latitude, longitude)
     values ('p-c1', 'X', '0', 'x', 'x', 14.1, 121.1)$q$, 'error');
select pg_temp.chk_true('a customer cannot move someone else''s pin (0 rows)',
  pg_temp.affected('p-c2', format($q$update public.customer_addresses set latitude = 14.9 where id = %L$q$, pg_temp.f('addr1'))) = 0
  and (select latitude = 14.20501 from public.customer_addresses where id = pg_temp.f('addr1')::uuid));
select pg_temp.chk_true('a customer sees only their own addresses',
  pg_temp.visible('p-c2', format($q$select count(*) from public.customer_addresses where id = %L$q$, pg_temp.f('addr1'))) = 0);
select pg_temp.chk_true('anon sees no addresses', pg_temp.visible(null, 'select count(*) from public.customer_addresses') = 0);
select pg_temp.chk_true('a rider/unknown account sees no addresses',
  pg_temp.visible('p-drv-1', 'select count(*) from public.customer_addresses') = 0);

-- 2. The pin is snapshot on the order ---------------------------------------------
create function pg_temp.order_for(p_cust text, p_addr text, p_delivery boolean, p_method text, p_key text) returns text language sql as $$
  select pg_temp.call_as(p_cust, format($q$select public.place_order(%L::uuid, %L::boolean, %L::uuid, %L, '', %L)$q$,
    pg_temp.call_as(p_cust, format($q$select (public.sync_customer_cart(%L::uuid,
      jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false) ->> 'cart_id')$q$,
      pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var'))),
    p_delivery, p_addr, p_method, p_key))
$$;
insert into fx values ('o1', pg_temp.order_for('p-c1', pg_temp.f('addr1'), true, 'Cash on Delivery', 'pin-key-1'));
insert into fx values ('o2', pg_temp.order_for('p-c2', pg_temp.f('addr2'), true, 'Cash on Delivery', 'pin-key-2'));
insert into fx values ('o3', pg_temp.order_for('p-c1', null, false, 'Cash on Counter Pickup', 'pin-key-3'));

select pg_temp.chk_true('delivery order keeps the pin the customer confirmed',
  (select delivery_latitude = 14.20501 and delivery_longitude = 121.15602 from public.orders where id = pg_temp.f('o1')));
select pg_temp.chk_true('an unpinned address gives an order without a pin (never 0,0)',
  (select delivery_latitude is null and delivery_longitude is null from public.orders where id = pg_temp.f('o2')));
select pg_temp.chk_true('a pickup order has no pin',
  (select delivery_latitude is null from public.orders where id = pg_temp.f('o3')));
do $$
declare v_err text;
begin
  begin
    update public.orders set delivery_latitude = 14.5 where id = (select v from fx where k = 'o1');
  exception when others then v_err := sqlerrm; end;
  insert into results(name, passed, detail) values ('the order''s pin cannot be changed afterwards (even by a privileged role)', v_err is not null, coalesce(v_err, 'no error'));
end $$;

-- The customer edits (then deletes) the saved address: the order keeps its pin.
select pg_temp.chk('customer moves the saved address pin later', 'p-c1',
  format($q$update public.customer_addresses set latitude = 14.30001, longitude = 121.30001 where id = %L$q$, pg_temp.f('addr1')), 'ok');
select pg_temp.chk_true('the order still has the checkout pin',
  (select delivery_latitude = 14.20501 from public.orders where id = pg_temp.f('o1')));
select pg_temp.chk_true('the customer reads the pin on their own order',
  pg_temp.call_as('p-c1', format($q$select delivery_latitude::text from public.orders where id = %L$q$, pg_temp.f('o1')))::float = 14.20501);
select pg_temp.chk_true('another customer cannot read that order',
  pg_temp.visible('p-c2', format($q$select count(*) from public.orders where id = %L$q$, pg_temp.f('o1'))) = 0);
select pg_temp.chk_true('anon reads no orders', pg_temp.visible(null, 'select count(*) from public.orders') = 0);

-- 3. Staff / owner see where the customer pinned -------------------------------
select pg_temp.call_as('p-sa', format($q$select public.staff_update_order_status(%L, 'confirmed')::text$q$, pg_temp.f(k)))
from (values ('o1'), ('o2')) t(k);

create temp table pins_a as select pg_temp.call_as('p-sa', format($q$select public.staff_order_delivery_pins(array[%L, %L, %L])::text$q$,
  pg_temp.f('o1'), pg_temp.f('o2'), pg_temp.f('o3')))::jsonb as j;
select pg_temp.chk_true('staff A gets both delivery orders of the branch (not the pickup)',
  (select jsonb_array_length(j) = 2 from pins_a), (select j::text from pins_a));
select pg_temp.chk_true('staff A sees the snapshot pin, address, contact and branch position',
  (select (e ->> 'latitude')::float = 14.20501 and (e ->> 'longitude')::float = 121.15602
          and e ->> 'address' like '%7 Pin St%' and e ->> 'contact_phone' is not null
          and (e ->> 'branch_latitude')::float = 14.2117 and (e ->> 'pin_snapshot')::boolean
   from pins_a, jsonb_array_elements(j) e where e ->> 'order_id' = pg_temp.f('o1')));
select pg_temp.chk_true('distance from the branch is computed (about 1.25 km)',
  (select (e ->> 'distance_km')::numeric between 1.15 and 1.35
   from pins_a, jsonb_array_elements(j) e where e ->> 'order_id' = pg_temp.f('o1')));
select pg_temp.chk_true('an unpinned order comes back without coordinates',
  (select e -> 'latitude' = 'null'::jsonb and e -> 'distance_km' = 'null'::jsonb
   from pins_a, jsonb_array_elements(j) e where e ->> 'order_id' = pg_temp.f('o2')));
select pg_temp.chk_true('staff B gets nothing for branch A orders',
  pg_temp.call_as('p-sb', format($q$select jsonb_array_length(public.staff_order_delivery_pins(array[%L, %L]))::text$q$,
    pg_temp.f('o1'), pg_temp.f('o2'))) = '0');
select pg_temp.chk_true('the owner gets branch A pins',
  pg_temp.call_as('p-own', format($q$select jsonb_array_length(public.staff_order_delivery_pins(array[%L]))::text$q$, pg_temp.f('o1'))) = '1');
select pg_temp.chk('a customer cannot use the staff pin lookup', 'p-c1',
  format($q$select public.staff_order_delivery_pins(array[%L])$q$, pg_temp.f('o1')), 'error');
select pg_temp.chk('anon cannot use the staff pin lookup', null,
  format($q$select public.staff_order_delivery_pins(array[%L])$q$, pg_temp.f('o1')), 'error');
select pg_temp.chk('more than 300 orders at once is refused', 'p-own',
  $q$select public.staff_order_delivery_pins(array(select 'x' || g from generate_series(1, 301) g))$q$, 'error');

create temp table cand as select pg_temp.call_as('p-sa', format($q$select public.staff_list_deliverable_orders(%L::uuid)::text$q$, pg_temp.f('ba')))::jsonb as j;
select pg_temp.chk_true('orders to put on a run carry their pins',
  (select (e ->> 'latitude')::float = 14.20501 from cand, jsonb_array_elements(j) e where e ->> 'order_id' = pg_temp.f('o1'))
  and (select e -> 'latitude' = 'null'::jsonb from cand, jsonb_array_elements(j) e where e ->> 'order_id' = pg_temp.f('o2')),
  (select j::text from cand));
select pg_temp.chk_true('staff B asking for branch A gets only their own branch (no branch A pins)',
  position(pg_temp.f('o1') in pg_temp.call_as('p-sb', format($q$select public.staff_list_deliverable_orders(%L::uuid)::text$q$, pg_temp.f('ba')))) = 0);

-- The website never receives coordinates or addresses.
select pg_temp.chk_true('admin_portal_orders has no address or coordinates',
  (select position('14.20501' in r) = 0 and position('delivery_latitude' in r) = 0 and position('7 Pin St' in r) = 0
   from (select pg_temp.call_as('p-own', $q$select public.admin_portal_orders(now() - interval '1 day', now() + interval '1 minute', null)::text$q$) as r) t));

-- 4. Rider: the pin while the stop and the run are open, hidden afterwards -------
select pg_temp.call_as('p-own', format($q$select public.owner_upsert_driver('p-drv-1', 'Pin Rider', 'pr@x', %L::uuid, '09990000011')::text$q$, pg_temp.f('ba')));
select pg_temp.call_as('p-own', format($q$select public.owner_upsert_driver('p-drv-2', 'Other Rider', 'or@x', %L::uuid)::text$q$, pg_temp.f('ba')));
insert into fx select 'run1', pg_temp.call_as('p-sa', format(
  $q$select public.staff_create_delivery(%L::uuid, 'Motorbike', 'TBD', array[%L, %L]) ->> 'id'$q$,
  pg_temp.f('ba'), pg_temp.f('o1'), pg_temp.f('o2')));
insert into fx select 'stop1', id::text from public.delivery_stops where order_id = pg_temp.f('o1');
insert into fx select 'stop2', id::text from public.delivery_stops where order_id = pg_temp.f('o2');
select pg_temp.call_as('p-sa', format($q$select public.staff_assign_driver(%L, 'p-drv-1')::text$q$, pg_temp.f('run1')));
select pg_temp.call_as('p-drv-1', format($q$select public.driver_respond_assignment(%L, 'accept')::text$q$, pg_temp.f('run1')));

create function pg_temp.rider_stop(p_uid text, p_order text) returns jsonb language sql as $$
  select s from jsonb_array_elements(pg_temp.call_as(p_uid, 'select public.driver_list_my_deliveries(true)::text')::jsonb) r,
                jsonb_array_elements(r -> 'stops') s
  where s ->> 'order_id' = p_order
$$;
select pg_temp.chk_true('the rider sees the checkout pin (not the edited saved address)',
  (pg_temp.rider_stop('p-drv-1', pg_temp.f('o1')) ->> 'latitude')::float = 14.20501,
  pg_temp.rider_stop('p-drv-1', pg_temp.f('o1'))::text);
select pg_temp.chk_true('a stop without a pin reaches the rider with null coordinates and the address text',
  pg_temp.rider_stop('p-drv-1', pg_temp.f('o2')) -> 'latitude' = 'null'::jsonb
  and pg_temp.rider_stop('p-drv-1', pg_temp.f('o2')) ->> 'address' like '%9 No Pin Rd%');
select pg_temp.chk_true('another rider sees nothing of this run',
  pg_temp.rider_stop('p-drv-2', pg_temp.f('o1')) is null);
select pg_temp.chk_true('staff A sees the stop pin in the run list',
  (select (s ->> 'latitude')::float = 14.20501
   from jsonb_array_elements(pg_temp.call_as('p-sa', format($q$select public.staff_get_deliveries(%L::uuid)::text$q$, pg_temp.f('ba')))::jsonb) r,
        jsonb_array_elements(r -> 'stops') s where s ->> 'order_id' = pg_temp.f('o1')));
select pg_temp.chk('staff B cannot read branch A runs', 'p-sb',
  format($q$select public.staff_get_deliveries(%L::uuid)$q$, pg_temp.f('ba')), 'error');

select pg_temp.call_as('p-drv-1', format($q$select public.driver_mark_picked_up(%L)::text$q$, pg_temp.f('run1')));
select pg_temp.call_as('p-drv-1', format($q$select public.driver_update_stop(%L::uuid, 'enRoute')::text$q$, pg_temp.f('stop1')));
select pg_temp.chk_true('customer tracking points at the checkout pin',
  (pg_temp.call_as('p-c1', format($q$select public.customer_get_delivery_tracking(%L)::text$q$, pg_temp.f('o1')))::jsonb
     -> 'destination' ->> 'lat')::float = 14.20501);
select pg_temp.chk_true('customer tracking of an unpinned order has a null destination (no 0,0)',
  (pg_temp.call_as('p-c2', format($q$select public.customer_get_delivery_tracking(%L)::text$q$, pg_temp.f('o2')))::jsonb
     -> 'destination' -> 'lat') = 'null'::jsonb);
select pg_temp.chk('stop 1 delivered', 'p-drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'delivered', null, null, null, 'Pia Pinned', 100)$q$, pg_temp.f('stop1')), 'ok');
select pg_temp.chk_true('a delivered stop hides address, pin and phone from the rider while the run goes on',
  (select s ->> 'address' = 'Hidden after delivery' and s -> 'latitude' = 'null'::jsonb and s -> 'contact_phone' is null
   from (select pg_temp.rider_stop('p-drv-1', pg_temp.f('o1')) as s) t)
  and (select status = 'dispatched' or status = 'inTransit' from public.deliveries where id = pg_temp.f('run1')));
select pg_temp.chk_true('the open stop still shows its address to the rider',
  pg_temp.rider_stop('p-drv-1', pg_temp.f('o2')) ->> 'address' like '%9 No Pin Rd%');
select pg_temp.chk('stop 2 failed (nobody home)', 'p-drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'failed', 'Nobody home')$q$, pg_temp.f('stop2')), 'ok');
select pg_temp.chk_true('after the run every stop is hidden from the rider',
  (select bool_and(s ->> 'address' = 'Hidden after delivery' and s -> 'latitude' = 'null'::jsonb and s -> 'longitude' = 'null'::jsonb)
   from jsonb_array_elements(pg_temp.call_as('p-drv-1', 'select public.driver_list_my_deliveries(true)::text')::jsonb) r,
        jsonb_array_elements(r -> 'stops') s));
select pg_temp.chk_true('branch staff still see the stop pin after the run (their branch)',
  (select (s ->> 'latitude')::float = 14.20501
   from jsonb_array_elements(pg_temp.call_as('p-sa', format($q$select public.staff_get_deliveries(%L::uuid)::text$q$, pg_temp.f('ba')))::jsonb) r,
        jsonb_array_elements(r -> 'stops') s where s ->> 'order_id' = pg_temp.f('o1')));

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% delivery pin check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
