-- =============================================================================
-- Melai Nuts — driver module (migration 20261010010000_driver_module.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/driver_module_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
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
create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;
create function pg_temp.f(p_k text) returns text language sql as $$ select v from fx where k = p_k $$;
grant execute on function pg_temp.f(text) to public;
create function pg_temp.stock(p_branch text) returns int language sql as $$
  select quantity from public.branch_inventory
  where branch_id = pg_temp.f(p_branch)::uuid and variant_id = pg_temp.f('var')::uuid $$;


-- Fixtures ---------------------------------------------------------------------
insert into public.branches (name, address, latitude, longitude, delivery_fee)
values ('DRV-TEST A', 'a', 14.2117, 121.1653, 0), ('DRV-TEST B', 'b', 14.3, 121.2, 0);
insert into fx select 'ba', id::text from public.branches where name = 'DRV-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'DRV-TEST B';
insert into public.product_categories (label) values ('DRV-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'DRV-TEST Nut', 100, 'pack' from public.product_categories where label = 'DRV-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'DRV-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'DRV-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select pg_temp.f(b)::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 100 from (values ('ba'), ('bb')) t(b);

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('d-sa', 'Staff A', 'd-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active'),
       ('d-sb', 'Staff B', 'd-sb@test.local', 'staff', pg_temp.f('bb')::uuid, 'active'),
       ('d-own', 'Owner', 'd-own@test.local', 'owner', null, 'active');
insert into public.customer_profiles (firebase_uid, full_name, email, phone)
values ('d-c1', 'Cust One', 'd-c1@test.local', '09170000001'), ('d-c2', 'Cust Two', 'd-c2@test.local', '09170000002');
insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city, latitude, longitude)
values ('d-c1', 'Cust One', '09170000001', '1 Test St', 'Calamba', 14.205, 121.156);
insert into fx select 'addr1', id::text from public.customer_addresses where firebase_uid = 'd-c1';
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent)
values ('default', 1, 50) on conflict (id) do nothing;

create function pg_temp.order_for(p_cust text, p_method text, p_key text) returns text language sql as $$
  select pg_temp.call_as(p_cust, format($q$select public.place_order(%L::uuid, true, %L::uuid, %L, '', %L)$q$,
    pg_temp.call_as(p_cust, format($q$select (public.sync_customer_cart(%L::uuid,
      jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false) ->> 'cart_id')$q$,
      pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var'))),
    pg_temp.f('addr1'), p_method, p_key))
$$;
insert into fx values ('o1', pg_temp.order_for('d-c1', 'Cash on Delivery', 'drv-key-1'));
insert into fx values ('o2', pg_temp.order_for('d-c1', 'Cash on Delivery', 'drv-key-2'));
insert into fx values ('o3', pg_temp.order_for('d-c1', 'Cash on Delivery', 'drv-key-3'));
insert into fx values ('o4', pg_temp.order_for('d-c1', 'GCash E-Wallet', 'drv-key-4'));
select pg_temp.call_as('d-sa', format($q$select public.staff_update_order_status(%L, 'confirmed')::text$q$, pg_temp.f(k)))
from (values ('o1'), ('o2'), ('o3'), ('o4')) t(k);
insert into fx select 'run1', pg_temp.call_as('d-sa', format(
  $q$select public.staff_create_delivery(%L::uuid, 'Motorbike', 'TBD', array[%L, %L]) ->> 'id'$q$,
  pg_temp.f('ba'), pg_temp.f('o1'), pg_temp.f('o2')));
insert into fx select 'stop1', id::text from public.delivery_stops where order_id = pg_temp.f('o1');
insert into fx select 'stop2', id::text from public.delivery_stops where order_id = pg_temp.f('o2');

-- 1. Owner registers drivers ---------------------------------------------------
select pg_temp.chk('staff cannot register a driver', 'd-sa',
  format($q$select public.owner_upsert_driver('drv-1', 'Rider One', 'r1@x', %L::uuid)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('owner registers driver 1 (branch A)', 'd-own',
  format($q$select public.owner_upsert_driver('drv-1', 'Rider One', 'r1@x', %L::uuid, '09990000001', 'Motorbike ABC')$q$, pg_temp.f('ba')), 'ok');
select pg_temp.chk('owner registers driver 2 (branch A)', 'd-own',
  format($q$select public.owner_upsert_driver('drv-2', 'Rider Two', 'r2@x', %L::uuid)$q$, pg_temp.f('ba')), 'ok');
select pg_temp.chk('owner registers driver 3 (branch B)', 'd-own',
  format($q$select public.owner_upsert_driver('drv-3', 'Rider Three', 'r3@x', %L::uuid)$q$, pg_temp.f('bb')), 'ok');
select pg_temp.chk('a staff account cannot be registered as a driver', 'd-own',
  format($q$select public.owner_upsert_driver('d-sa', 'Staff A', 'x', %L::uuid)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('a driver account cannot be added as staff', 'd-own',
  format($q$select public.owner_upsert_staff_member('drv-1', 'Rider One', 'r1@x', 'staff', 'DRV-TEST A')$q$), 'error');

-- 2. Identity ------------------------------------------------------------------
select pg_temp.chk_true('driver context: active',
  pg_temp.call_as('drv-1', 'select public.get_my_driver_context() ->> ''status''') = 'active');
select pg_temp.chk_true('customer driver context: not_provisioned',
  pg_temp.call_as('d-c1', 'select public.get_my_driver_context() ->> ''status''') = 'not_provisioned');
select pg_temp.chk('anon cannot read driver context', null, 'select public.get_my_driver_context()', 'error');
select pg_temp.chk('driver cannot use staff RPCs', 'drv-1',
  format($q$select public.staff_get_deliveries(%L::uuid)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('driver cannot use the POS', 'drv-1',
  format($q$select public.staff_open_shift(%L::uuid, 0)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('customer cannot use driver RPCs', 'd-c1', 'select public.driver_list_my_deliveries()', 'error');
select pg_temp.chk_true('driver sees only own driver row',
  pg_temp.visible('drv-1', 'select count(*) from public.drivers') = 1);
select pg_temp.chk_true('customer sees no driver rows', pg_temp.visible('d-c1', 'select count(*) from public.drivers') = 0);
select pg_temp.chk_true('staff A sees only branch A drivers', pg_temp.visible('d-sa', 'select count(*) from public.drivers') = 2);
select pg_temp.chk('driver sets availability', 'drv-1', 'select public.driver_set_availability(true)', 'ok');
select pg_temp.chk_true('driver has no runs before assignment',
  pg_temp.call_as('drv-1', 'select jsonb_array_length(public.driver_list_my_deliveries())::text') = '0');

-- 3. Assignment ------------------------------------------------------------------
select pg_temp.chk('branch B staff cannot assign on a branch A run', 'd-sb',
  format($q$select public.staff_assign_driver(%L, 'drv-3')$q$, pg_temp.f('run1')), 'error');
select pg_temp.chk('a branch B driver cannot be put on a branch A run', 'd-sa',
  format($q$select public.staff_assign_driver(%L, 'drv-3')$q$, pg_temp.f('run1')), 'error');
select pg_temp.chk('staff A assigns driver 1', 'd-sa',
  format($q$select public.staff_assign_driver(%L, 'drv-1')$q$, pg_temp.f('run1')), 'ok');
select pg_temp.chk_true('order shows the driver name and phone',
  (select rider_name = 'Rider One' and rider_phone = '09990000001' from public.orders where id = pg_temp.f('o1')));
select pg_temp.chk_true('driver got a notification it can read',
  pg_temp.visible('drv-1', 'select count(*) from public.staff_notifications where title = ''New delivery assigned''') = 1);
select pg_temp.chk_true('driver 1 now lists 1 run with addresses',
  (pg_temp.call_as('drv-1', 'select public.driver_list_my_deliveries()::text')::jsonb -> 0 -> 'stops' -> 0 ->> 'address') like '%Test St%');
select pg_temp.chk_true('driver 2 lists no runs', pg_temp.call_as('drv-2', 'select jsonb_array_length(public.driver_list_my_deliveries())::text') = '0');
select pg_temp.chk('driver 2 cannot accept driver 1''s run', 'drv-2',
  format($q$select public.driver_respond_assignment(%L, 'accept')$q$, pg_temp.f('run1')), 'error');
select pg_temp.chk('driver 1 cannot pick up before accepting', 'drv-1',
  format($q$select public.driver_mark_picked_up(%L)$q$, pg_temp.f('run1')), 'error');
select pg_temp.chk_true('driver 1 cannot post location before pickup (tracking false)',
  not (pg_temp.call_as('drv-1', format($q$select public.driver_post_location(%L, 14.2, 121.1)::text$q$, pg_temp.f('run1')))::jsonb ->> 'tracking')::boolean
  and (select count(*) = 0 from public.driver_locations where delivery_id = pg_temp.f('run1')));
select pg_temp.chk('driver 1 accepts', 'drv-1', format($q$select public.driver_respond_assignment(%L, 'accept')$q$, pg_temp.f('run1')), 'ok');
select pg_temp.chk('accept replay is harmless', 'drv-1', format($q$select public.driver_respond_assignment(%L, 'accept')$q$, pg_temp.f('run1')), 'ok');
select pg_temp.chk('driver 1 picks up', 'drv-1', format($q$select public.driver_mark_picked_up(%L)$q$, pg_temp.f('run1')), 'ok');
select pg_temp.chk_true('pickup turns tracking on and dispatches the run',
  (select tracking_active and driver_status = 'picked_up' and status = 'dispatched' from public.deliveries where id = pg_temp.f('run1')));
select pg_temp.chk('staff cannot unassign after pickup', 'd-sa',
  format($q$select public.staff_unassign_driver(%L, 'x')$q$, pg_temp.f('run1')), 'error');
select pg_temp.chk('driver cannot reject after pickup', 'drv-1',
  format($q$select public.driver_respond_assignment(%L, 'reject', 'flat tyre')$q$, pg_temp.f('run1')), 'error');

-- 4. Location -------------------------------------------------------------------
select pg_temp.chk('invalid coordinates refused', 'drv-1',
  format($q$select public.driver_post_location(%L, 120, 121.1)$q$, pg_temp.f('run1')), 'error');
select pg_temp.chk('stale timestamp refused', 'drv-1',
  format($q$select public.driver_post_location(%L, 14.2, 121.1, 5, now() - interval '1 hour')$q$, pg_temp.f('run1')), 'error');
select pg_temp.chk('future timestamp refused', 'drv-1',
  format($q$select public.driver_post_location(%L, 14.2, 121.1, 5, now() + interval '1 hour')$q$, pg_temp.f('run1')), 'error');
select pg_temp.chk_true('first point accepted',
  (pg_temp.call_as('drv-1', format($q$select public.driver_post_location(%L, 14.210, 121.160, 8, now() - interval '30 seconds')::text$q$, pg_temp.f('run1')))::jsonb ->> 'accepted')::boolean);
select pg_temp.chk_true('point 2 seconds later is throttled',
  not (pg_temp.call_as('drv-1', format($q$select public.driver_post_location(%L, 14.209, 121.159, 8, now() - interval '28 seconds')::text$q$, pg_temp.f('run1')))::jsonb ->> 'accepted')::boolean);
select pg_temp.chk_true('point 20 seconds later accepted',
  (pg_temp.call_as('drv-1', format($q$select public.driver_post_location(%L, 14.208, 121.158, 8, now() - interval '10 seconds')::text$q$, pg_temp.f('run1')))::jsonb ->> 'accepted')::boolean);
select pg_temp.chk('driver 2 cannot post on driver 1''s run', 'drv-2',
  format($q$select public.driver_post_location(%L, 14.2, 121.1)$q$, pg_temp.f('run1')), 'error');
select pg_temp.chk_true('nobody reads locations directly (driver)', pg_temp.visible('drv-1', 'select count(*) from public.driver_locations') = 0);
select pg_temp.chk_true('nobody reads locations directly (staff)', pg_temp.visible('d-sa', 'select count(*) from public.driver_locations') = 0);
select pg_temp.chk_true('staff A sees the trail (2 points)',
  jsonb_array_length(pg_temp.call_as('d-sa', format($q$select public.staff_get_delivery_tracking(%L)::text$q$, pg_temp.f('run1')))::jsonb -> 'trail') = 2);
select pg_temp.chk('staff B cannot see the trail', 'd-sb',
  format($q$select public.staff_get_delivery_tracking(%L)$q$, pg_temp.f('run1')), 'error');
select pg_temp.chk_true('owner sees 1 active driver position',
  jsonb_array_length(pg_temp.call_as('d-own', 'select public.staff_active_driver_positions()::text')::jsonb) = 1);
select pg_temp.chk_true('staff B sees 0 active positions',
  jsonb_array_length(pg_temp.call_as('d-sb', 'select public.staff_active_driver_positions()::text')::jsonb) = 0);

-- 5. Customer tracking -----------------------------------------------------------
create temp table t1 as select pg_temp.call_as('d-c1', format($q$select public.customer_get_delivery_tracking(%L)::text$q$, pg_temp.f('o1')))::jsonb as j;
select pg_temp.chk_true('customer sees the live driver location', (select (j ->> 'tracking_available')::boolean and (j -> 'driver_location' ->> 'lat')::float = 14.208 from t1), (select j::text from t1));
select pg_temp.chk_true('customer sees first name only', (select j ->> 'driver_name' = 'Rider' from t1));
select pg_temp.chk_true('customer sees branch and destination coordinates',
  (select (j -> 'branch' ->> 'lat') is not null and (j -> 'destination' ->> 'lat') is not null from t1));
select pg_temp.chk('another customer cannot track this order', 'd-c2',
  format($q$select public.customer_get_delivery_tracking(%L)$q$, pg_temp.f('o1')), 'error');
select pg_temp.chk('anon cannot track', null, format($q$select public.customer_get_delivery_tracking(%L)$q$, pg_temp.f('o1')), 'error');

-- 6. Stop outcomes ----------------------------------------------------------------
select pg_temp.chk('driver 2 cannot update driver 1''s stop', 'drv-2',
  format($q$select public.driver_update_stop(%L::uuid, 'enRoute')$q$, pg_temp.f('stop1')), 'error');
select pg_temp.chk('stop 1 en route', 'drv-1', format($q$select public.driver_update_stop(%L::uuid, 'enRoute')$q$, pg_temp.f('stop1')), 'ok');
select pg_temp.chk_true('run is in transit', (select driver_status = 'in_transit' and status = 'inTransit' from public.deliveries where id = pg_temp.f('run1')));
select pg_temp.chk('delivered without proof refused', 'drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'delivered', null, null, null, null, 100)$q$, pg_temp.f('stop1')), 'error');
select pg_temp.chk('COD delivered without collecting cash refused', 'drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'delivered', null, null, null, 'Cust One')$q$, pg_temp.f('stop1')), 'error');
select pg_temp.chk('COD delivered with the wrong cash amount refused', 'drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'delivered', null, null, null, 'Cust One', 50)$q$, pg_temp.f('stop1')), 'error');
select pg_temp.chk('proof photo outside the run folder refused', 'drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'delivered', null, null, 'DEL-other/x.jpg', null, 100)$q$, pg_temp.f('stop1')), 'error');
select pg_temp.chk('stop 1 delivered with cash + photo + recipient', 'drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'delivered', null, 'Left with guard', %L, 'Cust One', 100)$q$,
    pg_temp.f('stop1'), pg_temp.f('run1') || '/stop1.jpg'), 'ok');
select pg_temp.chk_true('order 1 completed and COD payment confirmed',
  (select o.status = 'completed' and p.status = 'success' from public.orders o join public.payments p on p.order_id = o.id where o.id = pg_temp.f('o1')));
select pg_temp.chk_true('COD collection audited',
  (select count(*) = 1 from public.staff_audit_logs where action = 'payment.cod_collected' and entity_id = pg_temp.f('o1')));
select pg_temp.chk('delivered replay is harmless', 'drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'delivered', null, null, null, 'Cust One', 100)$q$, pg_temp.f('stop1')), 'ok');
select pg_temp.chk('failing a delivered stop refused', 'drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'failed', 'oops')$q$, pg_temp.f('stop1')), 'error');
select pg_temp.chk_true('customer tracking stops showing the driver after delivery',
  (pg_temp.call_as('d-c1', format($q$select public.customer_get_delivery_tracking(%L)::text$q$, pg_temp.f('o1')))::jsonb -> 'driver_location') = 'null'::jsonb);

select pg_temp.chk('failed without reason refused', 'drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'failed')$q$, pg_temp.f('stop2')), 'error');
select pg_temp.chk('stop 2 failed: nobody home', 'drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'failed', 'Nobody home, phone off')$q$, pg_temp.f('stop2')), 'ok');
select pg_temp.chk_true('failed order returns to the branch queue (confirmed)',
  (select status = 'confirmed' and rider_name is null from public.orders where id = pg_temp.f('o2')));
select pg_temp.chk_true('branch staff told about the failure',
  (select count(*) >= 1 from public.staff_notifications where recipient_uid = 'd-sa' and reference = pg_temp.f('o2')));
select pg_temp.chk_true('run completed, tracking off, all location points deleted',
  (select status = 'completed' and driver_status = 'completed' and not tracking_active and completed_at is not null
   from public.deliveries where id = pg_temp.f('run1'))
  and (select count(*) = 0 from public.driver_locations where delivery_id = pg_temp.f('run1')));
select pg_temp.chk('replaying the last outcome after the run completed is harmless', 'drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'failed', 'Nobody home, phone off')$q$, pg_temp.f('stop2')), 'ok');
select pg_temp.chk('a different outcome after completion is refused', 'drv-1',
  format($q$select public.driver_update_stop(%L::uuid, 'delivered', null, null, null, 'X', 100)$q$, pg_temp.f('stop2')), 'error');
select pg_temp.chk_true('posting after completion tells the app to stop',
  not (pg_temp.call_as('drv-1', format($q$select public.driver_post_location(%L, 14.2, 121.1)::text$q$, pg_temp.f('run1')))::jsonb ->> 'tracking')::boolean);
select pg_temp.chk_true('finished runs hide customer addresses from the driver',
  (pg_temp.call_as('drv-1', 'select public.driver_list_my_deliveries(true)::text')::jsonb -> 0 -> 'stops' -> 0 ->> 'address') = 'Hidden after delivery'
  and (pg_temp.call_as('drv-1', 'select public.driver_list_my_deliveries(true)::text')::jsonb -> 0 -> 'stops' -> 0 -> 'contact_phone') is null);
select pg_temp.chk_true('failed order can be put on a new run',
  pg_temp.call_as('d-sa', format($q$select public.staff_create_delivery(%L::uuid, 'Van', 'TBD', array[%L]) ->> 'id'$q$,
    pg_temp.f('ba'), pg_temp.f('o2'))) is not null);

-- 7. Reject and online-payment guard ---------------------------------------------
insert into fx select 'run2', pg_temp.call_as('d-sa', format(
  $q$select public.staff_create_delivery(%L::uuid, 'Motorbike', 'TBD', array[%L, %L]) ->> 'id'$q$,
  pg_temp.f('ba'), pg_temp.f('o3'), pg_temp.f('o4')));
select pg_temp.call_as('d-sa', format($q$select public.staff_assign_driver(%L, 'drv-2')::text$q$, pg_temp.f('run2')));
select pg_temp.chk('reject needs a reason', 'drv-2', format($q$select public.driver_respond_assignment(%L, 'reject')$q$, pg_temp.f('run2')), 'error');
select pg_temp.chk('driver 2 rejects with a reason', 'drv-2',
  format($q$select public.driver_respond_assignment(%L, 'reject', 'Motorbike in repair')$q$, pg_temp.f('run2')), 'ok');
select pg_temp.chk_true('rejected run has no driver and staff are told',
  (select driver_uid is null and driver_status is null from public.deliveries where id = pg_temp.f('run2'))
  and (select count(*) >= 1 from public.staff_notifications where recipient_uid = 'd-sa' and title = 'Delivery rejected by driver'));
select pg_temp.chk_true('assignment history kept (assigned, rejected)',
  (select count(*) = 2 from public.delivery_assignment_events where delivery_id = pg_temp.f('run2')));
select pg_temp.call_as('d-sa', format($q$select public.staff_assign_driver(%L, 'drv-1')::text$q$, pg_temp.f('run2')));
select pg_temp.call_as('drv-1', format($q$select public.driver_respond_assignment(%L, 'accept')::text$q$, pg_temp.f('run2')));
select pg_temp.call_as('drv-1', format($q$select public.driver_mark_picked_up(%L)::text$q$, pg_temp.f('run2')));
select pg_temp.chk('unpaid GCash order cannot be handed over', 'drv-1',
  format($q$select public.driver_update_stop((select id from public.delivery_stops where order_id = %L), 'delivered', null, null, null, 'Cust One')$q$, pg_temp.f('o4')), 'error');
select pg_temp.call_as('drv-1', format($q$select public.driver_post_location(%L, 14.2, 121.1)::text$q$, pg_temp.f('run2')));
select pg_temp.chk('staff cancel the run', 'd-sa', format($q$select public.staff_cancel_delivery(%L)$q$, pg_temp.f('run2')), 'ok');
select pg_temp.chk_true('cancelling erases location points and stops tracking',
  (select not tracking_active from public.deliveries where id = pg_temp.f('run2'))
  and (select count(*) = 0 from public.driver_locations where delivery_id = pg_temp.f('run2')));

-- 7b. Delivery pins (migration 20261016000000) -----------------------------------
select pg_temp.chk_true('delivery orders keep the pin from checkout (snapshot)',
  (select delivery_latitude = 14.205 and delivery_longitude = 121.156 from public.orders where id = pg_temp.f('o1')));
select pg_temp.chk_true('staff A sees the customer pin of a branch A order',
  (pg_temp.call_as('d-sa', format($q$select public.staff_order_delivery_pins(array[%L])::text$q$, pg_temp.f('o1')))::jsonb -> 0 ->> 'latitude')::float = 14.205);
select pg_temp.chk_true('staff B sees no pin of a branch A order',
  pg_temp.call_as('d-sb', format($q$select jsonb_array_length(public.staff_order_delivery_pins(array[%L]))::text$q$, pg_temp.f('o1'))) = '0');
select pg_temp.chk('a rider cannot use the staff pin lookup', 'drv-2',
  format($q$select public.staff_order_delivery_pins(array[%L])$q$, pg_temp.f('o1')), 'error');
select pg_temp.chk_true('finished runs also hide the pin from the rider',
  (pg_temp.call_as('drv-1', 'select public.driver_list_my_deliveries(true)::text')::jsonb -> 0 -> 'stops' -> 0 -> 'latitude') = 'null'::jsonb);

-- 8. Suspension -------------------------------------------------------------------
select pg_temp.chk('owner suspends driver 1', 'd-own', $q$select public.owner_set_driver_status('drv-1', 'suspended')$q$, 'ok');
select pg_temp.chk_true('suspended driver context says suspended',
  pg_temp.call_as('drv-1', 'select public.get_my_driver_context() ->> ''status''') = 'suspended');
select pg_temp.chk('suspended driver cannot list runs', 'drv-1', 'select public.driver_list_my_deliveries()', 'error');
select pg_temp.chk('suspended driver cannot be assigned', 'd-sa',
  format($q$select public.staff_assign_driver(%L, 'drv-1')$q$, pg_temp.f('run2')), 'error');
select pg_temp.chk('staff cannot suspend drivers', 'd-sa', $q$select public.owner_set_driver_status('drv-2', 'suspended')$q$, 'error');

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% driver module check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
