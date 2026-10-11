-- =============================================================================
-- Melai Nuts — push notifications, server-triggered (migration 20261021000000_push_notifications.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/push_notifications_test.sql
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
insert into public.branches (name, address, delivery_fee) values ('PUSH-TEST A', 'a', 0);
insert into fx select 'ba', id::text from public.branches where name = 'PUSH-TEST A';
insert into public.product_categories (label) values ('PUSH-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'PUSH-TEST Nut', 100, 'pack' from public.product_categories where label = 'PUSH-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'PUSH-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'PUSH-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 50);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory)
values ('push-sa', 'Staff A', 'push-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', true);
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values ('push-c1', 'Push Customer', 'push-c1@test.local', '09170000051');
delete from public.business_settings;

-- 1. Device tokens ------------------------------------------------------------------
select pg_temp.chk('anon cannot register a token', null, $q$select public.register_push_token('tok-anon-0123456789abcdef', 'android')$q$, 'error');
select pg_temp.chk('a customer registers this device', 'push-c1', $q$select public.register_push_token('tok-c1-0123456789abcdef', 'android')$q$, 'ok');
select pg_temp.chk('an invalid platform is refused', 'push-c1', $q$select public.register_push_token('tok-c1-0123456789abcdef', 'toaster')$q$, 'error');
select pg_temp.chk('staff register their device', 'push-sa', $q$select public.register_push_token('tok-sa-0123456789abcdef', 'ios')$q$, 'ok');
select pg_temp.chk('clients cannot read the token table', 'push-c1', 'select count(*) from public.device_push_tokens', 'error');
select pg_temp.chk('clients cannot read the outbox', 'push-c1', 'select count(*) from public.push_outbox', 'error');
select pg_temp.chk('clients cannot claim the outbox', 'push-c1', 'select public.push_outbox_claim(10)', 'error');
select pg_temp.chk('a token moves to whoever signs in on the device', 'push-sa', $q$select public.register_push_token('tok-c1-0123456789abcdef', 'android')$q$, 'ok');
select pg_temp.chk_true('... now owned by the staff member', (select firebase_uid = 'push-sa' from public.device_push_tokens where token = 'tok-c1-0123456789abcdef'));
select pg_temp.chk('the previous owner cannot remove it any more (no effect)', 'push-c1', $q$select public.unregister_push_token('tok-c1-0123456789abcdef')$q$, 'ok');
select pg_temp.chk_true('... still there', exists (select 1 from public.device_push_tokens where token = 'tok-c1-0123456789abcdef'));
select pg_temp.chk('its owner removes it on sign-out', 'push-sa', $q$select public.unregister_push_token('tok-c1-0123456789abcdef')$q$, 'ok');
select pg_temp.chk_true('... gone', not exists (select 1 from public.device_push_tokens where token = 'tok-c1-0123456789abcdef'));
select pg_temp.call_as('push-c1', $q$select public.register_push_token('tok-c1-0123456789abcdef', 'android')::text$q$);

-- 2. Server events become pushes -------------------------------------------------------
insert into public.notifications (firebase_uid, category, title, body) values ('push-c1', 'order', 'Order ready', 'Your order is ready for pickup.');
select pg_temp.chk_true('a customer notification is queued for push',
  exists (select 1 from public.push_outbox where firebase_uid = 'push-c1' and kind = 'customer.order' and title = 'Order ready' and sent_at is null));
update public.business_settings set restock_threshold_default = 10 where id = 'default';
insert into public.business_settings (id, restock_threshold_default) values ('default', 10) on conflict (id) do update set restock_threshold_default = 10;
update public.branch_inventory set quantity = 4 where branch_id = pg_temp.f('ba')::uuid and variant_id = pg_temp.f('var')::uuid;
select pg_temp.chk_true('low stock reaches branch staff as a push (server trigger, no app involved)',
  exists (select 1 from public.push_outbox where firebase_uid = 'push-sa' and kind = 'staff.inventory' and title like 'Low stock:%'));

-- 3. Expiring batches: owner setting, once per batch --------------------------------
insert into public.inventory_batches (branch_id, product_id, variant_id, batch_code, received_date, expiration_date, quantity, initial_quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 'PUSH-B1', current_date - 30, current_date + 5, 4, 4);
select pg_temp.chk_true('expiry alerts are off while the owner has not set a window', public.enqueue_expiring_batch_alerts() = 0);
update public.business_settings set expiry_alert_days = 7 where id = 'default';
select pg_temp.chk_true('with a 7-day window the batch expiring in 5 days is announced', public.enqueue_expiring_batch_alerts() = 1);
select pg_temp.chk_true('... as a push for branch staff',
  exists (select 1 from public.push_outbox where firebase_uid = 'push-sa' and title like 'Expiring soon:%'));
select pg_temp.chk_true('running it again does not repeat the alert', public.enqueue_expiring_batch_alerts() = 0);
select pg_temp.chk('clients cannot trigger expiry alerts', 'push-sa', 'select public.enqueue_expiring_batch_alerts()', 'error');

-- 4. Dispatch bookkeeping (what push-dispatch does with the service role) ------------
insert into fx select 'claim', public.push_outbox_claim(100)::text;
select pg_temp.chk_true('claim returns unsent rows with the recipient''s tokens',
  (select bool_or(e ->> 'firebase_uid' = 'push-c1' and e -> 'tokens' ? 'tok-c1-0123456789abcdef')
     from jsonb_array_elements(pg_temp.f('claim')::jsonb) e));
insert into fx select 'c1row', (select id::text from public.push_outbox where firebase_uid = 'push-c1' limit 1);
select public.push_outbox_report(jsonb_build_array(
  jsonb_build_object('id', pg_temp.f('c1row')::bigint, 'ok', false, 'error', 'UNREGISTERED', 'dead_tokens', jsonb_build_array('tok-c1-0123456789abcdef'))));
select pg_temp.chk_true('a failed send is counted, a dead token is removed',
  (select attempts = 1 and sent_at is null from public.push_outbox where id = pg_temp.f('c1row')::bigint)
  and not exists (select 1 from public.device_push_tokens where token = 'tok-c1-0123456789abcdef'));
select public.push_outbox_report(jsonb_build_array(jsonb_build_object('id', pg_temp.f('c1row')::bigint, 'ok', true)));
select pg_temp.chk_true('a delivered push is marked sent and not claimed again',
  (select sent_at is not null from public.push_outbox where id = pg_temp.f('c1row')::bigint)
  and not exists (select 1 from jsonb_array_elements(public.push_outbox_claim(100)) e where (e ->> 'id')::bigint = pg_temp.f('c1row')::bigint));

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% push notification check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
