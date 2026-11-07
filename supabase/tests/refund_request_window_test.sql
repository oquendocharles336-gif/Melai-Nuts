-- =============================================================================
-- Melai Nuts — the time limit on customer refund requests
-- (migration 20261107120000_refund_request_window.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/refund_request_window_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
--
-- A statement cannot see what a function it calls has changed, so every action
-- below runs in its own statement and its result is read in the next one.
-- =============================================================================
begin;

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
    case
      when p_expect = 'error' then v_err is not null
      when p_expect like 'like:%' then v_err ilike '%' || substr(p_expect, 6) || '%'
      else v_err is null
    end,
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
create function pg_temp.run_as(p_uid text, p_sql text) returns void language plpgsql as $$
begin
  perform pg_temp.act_as(p_uid);
  begin execute p_sql;
  exception when others then perform pg_temp.back_to_admin(); raise; end;
  perform pg_temp.back_to_admin();
end $$;
create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;
create function pg_temp.f(p_k text) returns text language sql as $$ select v from fx where k = p_k $$;
grant execute on function pg_temp.f(text) to public;

-- Fixtures: one pickup order of one unit, paid in cash and picked up. ---------------
insert into public.branches (name, address, latitude, longitude, delivery_fee)
values ('RW-TEST A', 'a', 14.2117, 121.1653, 0);
insert into fx select 'ba', id::text from public.branches where name = 'RW-TEST A';
insert into public.product_categories (label) values ('RW-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'RW-TEST Nut', 100, 'pack' from public.product_categories where label = 'RW-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'RW-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'RW-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 100);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_review_refunds)
values ('rw-sa', 'Staff A', 'rw-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', true),
       ('rw-own', 'Owner', 'rw-own@test.local', 'owner', null, 'active', false);
insert into public.customer_profiles (firebase_uid, full_name, email, phone)
values ('rw-c1', 'Cust One', 'rw-c1@test.local', '09170000021');

-- No downpayment: the order goes straight to staff and is paid in cash.
update public.business_settings
   set cod_downpayment_type = null, cod_downpayment_value = null, cod_downpayment_min_order = null,
       cod_downpayment_expiry_minutes = null, cod_downpayment_pickup_days = null, refund_request_days = null
 where id = 'default';

create function pg_temp.picked_up_order(p_key text) returns text language plpgsql as $$
declare v_cart text; v_order text;
begin
  v_cart := pg_temp.call_as('rw-c1', format($q$select (public.sync_customer_cart(%L::uuid,
    jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false) ->> 'cart_id')$q$,
    pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var')));
  v_order := pg_temp.call_as('rw-c1', format($q$select public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', %L)$q$,
    v_cart, p_key));
  perform pg_temp.run_as('rw-sa', format($q$select public.staff_update_order_status(%L, s)
    from unnest(array['confirmed', 'preparing', 'readyForPickup']) s$q$, v_order));
  perform pg_temp.run_as('rw-sa', format($q$select public.staff_confirm_payment(%L)$q$, v_order));
  perform pg_temp.run_as('rw-sa', format($q$select public.staff_update_order_status(%L, 'completed')$q$, v_order));
  return v_order;
end $$;
-- Moves the pickup (the first Completed event) back by p_days.
create function pg_temp.picked_up_days_ago(p_order text, p_days numeric) returns void language sql as $$
  update public.order_status_events set created_at = now() - make_interval(secs => p_days * 86400)
  where id = (select id from public.order_status_events
              where order_id = p_order and status = 'completed' order by created_at limit 1) $$;
create function pg_temp.refund_sql(p_order text) returns text language sql as $$
  select format($q$select public.request_refund(%L, 'Damaged', '', jsonb_build_array(
    jsonb_build_object('product_name','RW-TEST Nut','variant_label','Regular','quantity',1)))$q$, p_order) $$;
create function pg_temp.settings(p jsonb) returns void language plpgsql as $$
begin
  perform pg_temp.run_as('rw-own', format('select public.owner_update_business_settings(%L::jsonb)', p::text));
end $$;

insert into fx values ('o1', pg_temp.picked_up_order('rw-1'));
insert into fx values ('o2', pg_temp.picked_up_order('rw-2'));
insert into fx values ('o3', pg_temp.picked_up_order('rw-3'));
insert into fx values ('o4', pg_temp.picked_up_order('rw-4'));
select pg_temp.chk_true('fixtures: four picked-up orders',
  (select count(*) = 4 from public.orders where id in (pg_temp.f('o1'), pg_temp.f('o2'), pg_temp.f('o3'), pg_temp.f('o4'))
     and status = 'completed'));

-- 1. Not set: no limit, as before ---------------------------------------------------
select pg_temp.chk_true('Not set: the customer reads no limit',
  pg_temp.call_as('rw-c1', 'select public.refund_request_days()::text') is null);
select pg_temp.picked_up_days_ago(pg_temp.f('o1'), 400);
select pg_temp.chk('Not set: an order picked up 400 days ago can still be refunded', 'rw-c1',
  pg_temp.refund_sql(pg_temp.f('o1')), 'ok');

-- 2. Who can set it, and its range --------------------------------------------------
select pg_temp.chk('staff cannot set it', 'rw-sa',
  $q$select public.owner_update_business_settings('{"refund_request_days":7}'::jsonb)$q$, 'error');
select pg_temp.chk('0 days is refused', 'rw-own',
  $q$select public.owner_update_business_settings('{"refund_request_days":0}'::jsonb)$q$, 'like:out of range');
select pg_temp.chk('366 days is refused', 'rw-own',
  $q$select public.owner_update_business_settings('{"refund_request_days":366}'::jsonb)$q$, 'like:out of range');
select pg_temp.chk('text is refused', 'rw-own',
  $q$select public.owner_update_business_settings('{"refund_request_days":"7"}'::jsonb)$q$, 'like:must be a number');
select pg_temp.settings('{"refund_request_days":7}'::jsonb);
select pg_temp.chk_true('the owner sets 7 days and reads it back',
  (pg_temp.call_as('rw-own', 'select public.get_business_settings()::text')::jsonb ->> 'refund_request_days')::int = 7);
select pg_temp.chk_true('the customer reads 7 days',
  pg_temp.call_as('rw-c1', 'select public.refund_request_days()::text')::int = 7);
select pg_temp.settings('{"expiry_alert_days":30}'::jsonb);
select pg_temp.chk_true('saving another setting keeps it',
  (select refund_request_days = 7 from public.business_settings where id = 'default'));
select pg_temp.chk('a signed-out visitor cannot read it', null, 'select public.refund_request_days()', 'error');
select pg_temp.chk('the pickup-time helper is not callable by customers', 'rw-c1',
  format('select public._order_picked_up_at(%L)', pg_temp.f('o2')), 'error');

-- 3. Inside and outside the window ---------------------------------------------------
select pg_temp.picked_up_days_ago(pg_temp.f('o2'), 8);
select pg_temp.chk('8 days after pickup: refused, with the reason', 'rw-c1',
  pg_temp.refund_sql(pg_temp.f('o2')), 'like:within 7 days after pickup');
select pg_temp.chk_true('nothing was recorded for the refused request',
  not exists (select 1 from public.refund_requests where order_id = pg_temp.f('o2')));
select pg_temp.picked_up_days_ago(pg_temp.f('o3'), 6.9);
select pg_temp.chk('6.9 days after pickup: accepted', 'rw-c1', pg_temp.refund_sql(pg_temp.f('o3')), 'ok');

-- 4. A rejected request does not restart the window ----------------------------------
insert into fx select 'r4', pg_temp.call_as('rw-c1', pg_temp.refund_sql(pg_temp.f('o4')));
select pg_temp.chk('staff reject the first request', 'rw-sa',
  format($q$select public.staff_review_refund(%L, 'reject')$q$, pg_temp.f('r4')), 'ok');
select pg_temp.chk_true('the order is Completed again (a second Completed event)',
  (select status = 'completed' from public.orders where id = pg_temp.f('o4'))
  and (select count(*) = 2 from public.order_status_events where order_id = pg_temp.f('o4') and status = 'completed'));
select pg_temp.picked_up_days_ago(pg_temp.f('o4'), 8);
select pg_temp.chk('retry 8 days after the first pickup: refused', 'rw-c1',
  pg_temp.refund_sql(pg_temp.f('o4')), 'like:within 7 days after pickup');

-- 5. The owner turns it off again -----------------------------------------------------
select pg_temp.settings('{"refund_request_days":null}'::jsonb);
select pg_temp.chk('Not set again: the 8-day-old order can be refunded', 'rw-c1',
  pg_temp.refund_sql(pg_temp.f('o2')), 'ok');

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% refund window check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
