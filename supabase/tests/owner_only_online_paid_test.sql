-- =============================================================================
-- Melai Nuts — only HitPay or the owner can mark online money as paid
-- (migration 20261102090000_owner_only_online_paid.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/owner_only_online_paid_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
--
-- A statement cannot see what a function it calls has changed, so every action
-- below runs in its own statement and its result is read in the next one.
-- =============================================================================
begin;

do $$ begin
  if to_regclass('public.payment_settings') is not null then
    update public.payment_settings set online_payment_enabled = true where id = 'default';
  end if;
end $$;
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

-- Fixtures ------------------------------------------------------------------------
insert into public.branches (name, address, latitude, longitude, delivery_fee)
values ('OP-TEST A', 'a', 14.2117, 121.1653, 50);
insert into fx select 'ba', id::text from public.branches where name = 'OP-TEST A';
insert into public.product_categories (label) values ('OP-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'OP-TEST Nut', 100, 'pack' from public.product_categories where label = 'OP-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'OP-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'OP-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 100);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_review_refunds)
values ('op-sa', 'Staff A', 'op-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', true),
       ('op-own', 'Owner', 'op-own@test.local', 'owner', null, 'active', false),
       ('op-off', 'Former owner', 'op-off@test.local', 'owner', null, 'inactive', false);
insert into public.customer_profiles (firebase_uid, full_name, email, phone)
values ('op-c1', 'Cust One', 'op-c1@test.local', '09170000021');
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point)
values ('default', 1, 50, 50)
  on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;

create function pg_temp.order_for(p_method text, p_key text) returns text language sql as $$
  select pg_temp.call_as('op-c1', format($q$select public.place_order(%L::uuid, false, null, %L, '', %L)$q$,
    pg_temp.call_as('op-c1', format($q$select (public.sync_customer_cart(%L::uuid,
      jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false) ->> 'cart_id')$q$,
      pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var'))),
    p_method, p_key)) $$;
create function pg_temp.owner_confirm(p_order text, p_reason text, p_reference text default null) returns text language sql as $$
  select format($q$select public.owner_confirm_online_payment(%L, %L, %L)$q$, p_order, p_reason, p_reference) $$;
create function pg_temp.pay_status(p_order text) returns text language sql as $$
  select status from public.payments where order_id = p_order $$;

insert into fx values ('o_online', pg_temp.order_for('Online Payment (GCash, QR Ph, Card)', 'op-online'));
insert into fx values ('o_failed', pg_temp.order_for('Online Payment (GCash, QR Ph, Card)', 'op-failed'));
insert into fx values ('o_cancel', pg_temp.order_for('Online Payment (GCash, QR Ph, Card)', 'op-cancel'));
insert into fx values ('o_cash', pg_temp.order_for('Cash on Counter Pickup', 'op-cash'));

-- 1. Staff can no longer mark online money as paid --------------------------------
select pg_temp.chk('staff cannot mark an online order paid, even with a reference', 'op-sa',
  format($q$select public.staff_confirm_payment(%L, 'REF-12345')$q$, pg_temp.f('o_online')), 'error');
select pg_temp.chk('the owner cannot use the staff function for an online order either', 'op-own',
  format($q$select public.staff_confirm_payment(%L, 'REF-12345')$q$, pg_temp.f('o_online')), 'error');
select pg_temp.chk_true('the online payment is still unpaid',
  pg_temp.pay_status(pg_temp.f('o_online')) in ('pending', 'processing'), pg_temp.pay_status(pg_temp.f('o_online')));

-- 2. Cash still works for staff ---------------------------------------------------
select pg_temp.chk('staff can still confirm cash', 'op-sa',
  format($q$select public.staff_confirm_payment(%L)$q$, pg_temp.f('o_cash')), 'ok');
select pg_temp.chk_true('the cash payment is paid', pg_temp.pay_status(pg_temp.f('o_cash')) = 'success');

-- 3. Who may use the owner fallback -----------------------------------------------
select pg_temp.chk('staff cannot use the owner fallback', 'op-sa',
  pg_temp.owner_confirm(pg_temp.f('o_online'), 'Paid, webhook never arrived'), 'error');
select pg_temp.chk('a customer cannot use the owner fallback', 'op-c1',
  pg_temp.owner_confirm(pg_temp.f('o_online'), 'Paid, webhook never arrived'), 'error');
select pg_temp.chk('an inactive owner cannot use the owner fallback', 'op-off',
  pg_temp.owner_confirm(pg_temp.f('o_online'), 'Paid, webhook never arrived'), 'error');
select pg_temp.chk('signed out cannot use the owner fallback', null,
  pg_temp.owner_confirm(pg_temp.f('o_online'), 'Paid, webhook never arrived'), 'error');

-- 4. The reason is required -------------------------------------------------------
select pg_temp.chk('the owner needs a reason', 'op-own',
  pg_temp.owner_confirm(pg_temp.f('o_online'), '   '), 'error');
select pg_temp.chk('a too short reason is refused', 'op-own',
  pg_temp.owner_confirm(pg_temp.f('o_online'), 'paid'), 'error');
select pg_temp.chk_true('refused attempts changed nothing and logged nothing',
  pg_temp.pay_status(pg_temp.f('o_online')) in ('pending', 'processing')
  and not exists (select 1 from public.staff_audit_logs where entity_id = pg_temp.f('o_online')));

-- 5. The owner fallback on a full online payment ----------------------------------
select pg_temp.chk('the owner can confirm with a reason', 'op-own',
  pg_temp.owner_confirm(pg_temp.f('o_online'), '  Paid, webhook never arrived  ', 'HP-REF-1'), 'ok');
select pg_temp.chk_true('the payment is paid and keeps its reference',
  (select status = 'success' and reference_number = 'HP-REF-1' from public.payments where order_id = pg_temp.f('o_online')));
select pg_temp.chk_true('the reason and the owner are in the audit log',
  exists (select 1 from public.staff_audit_logs
          where action = 'payment.owner_confirmed_online' and entity_id = pg_temp.f('o_online')
            and staff_firebase_uid = 'op-own'
            and metadata ->> 'reason' = 'Paid, webhook never arrived'
            and metadata ->> 'reference' = 'HP-REF-1'
            and metadata ->> 'kind' = 'payment'));
select pg_temp.chk_true('the customer is told',
  exists (select 1 from public.notifications where firebase_uid = 'op-c1' and category = 'payment'
          and body like '%' || pg_temp.f('o_online') || '%'));
select pg_temp.chk('a second confirmation is refused', 'op-own',
  pg_temp.owner_confirm(pg_temp.f('o_online'), 'Paid, webhook never arrived'), 'error');
select pg_temp.chk_true('a late webhook changes nothing',
  public.hitpay_apply_payment(pg_temp.f('o_online'), 'success', 'gcash', 'pay-late', 'HP-LATE', null) = 'success');
select pg_temp.chk_true('the late webhook did not overwrite the reference',
  (select reference_number = 'HP-REF-1' from public.payments where order_id = pg_temp.f('o_online')));

-- 6. A failed payment and a cancelled order ---------------------------------------
select public.hitpay_set_checkout(pg_temp.f('o_failed'), 'preq-f', 'https://pay.example/f');
select public.hitpay_apply_payment(pg_temp.f('o_failed'), 'failed', 'gcash', 'pay-f', null, 'preq-f');
select pg_temp.chk_true('fixture: the payment failed', pg_temp.pay_status(pg_temp.f('o_failed')) = 'failed');
select pg_temp.chk('the owner can confirm a payment HitPay reported as failed', 'op-own',
  pg_temp.owner_confirm(pg_temp.f('o_failed'), 'Bank shows the money arrived'), 'ok');
select pg_temp.chk_true('the failed payment is now paid', pg_temp.pay_status(pg_temp.f('o_failed')) = 'success');

select pg_temp.call_as('op-sa', format($q$select public.staff_update_order_status(%L, 'cancelled')::text$q$, pg_temp.f('o_cancel')));
select pg_temp.chk('a cancelled order cannot be confirmed', 'op-own',
  pg_temp.owner_confirm(pg_temp.f('o_cancel'), 'Paid, webhook never arrived'), 'error');
select pg_temp.chk('the fallback refuses a cash order', 'op-own',
  pg_temp.owner_confirm(pg_temp.f('o_cash'), 'Paid, webhook never arrived'), 'error');

-- 7. The owner fallback on a pickup downpayment -----------------------------------
select pg_temp.call_as('op-own', $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":30,"cod_downpayment_expiry_minutes":30,"cod_downpayment_pickup_days":2}'::jsonb)::text$q$);
insert into fx values ('o_dp', pg_temp.order_for('Cash on Counter Pickup', 'op-dp'));
select pg_temp.chk_true('fixture: the order is waiting for its downpayment',
  (select status = 'awaitingDownpayment' from public.orders where id = pg_temp.f('o_dp'))
  and (select status = 'pending' and amount = 30 from public.order_downpayments where order_id = pg_temp.f('o_dp')));
select pg_temp.chk('staff cannot confirm a downpayment', 'op-sa',
  format($q$select public.staff_confirm_payment(%L, 'REF-12345')$q$, pg_temp.f('o_dp')), 'error');
select pg_temp.chk('staff cannot use the owner fallback for a downpayment', 'op-sa',
  pg_temp.owner_confirm(pg_temp.f('o_dp'), 'Paid, webhook never arrived'), 'error');
select pg_temp.chk('the owner can confirm a downpayment', 'op-own',
  pg_temp.owner_confirm(pg_temp.f('o_dp'), 'Paid, webhook never arrived', 'HP-DP-1'), 'ok');
select pg_temp.chk_true('the downpayment is paid and the order goes to staff',
  (select status = 'success' and paid_at is not null from public.order_downpayments where order_id = pg_temp.f('o_dp'))
  and (select status = 'pending' from public.orders where id = pg_temp.f('o_dp')));
select pg_temp.chk_true('the cash balance is still unpaid',
  (select status = 'pending' and method = 'cash' and amount = 70 from public.payments where order_id = pg_temp.f('o_dp')));
select pg_temp.chk_true('the downpayment reason is in the audit log',
  exists (select 1 from public.staff_audit_logs
          where action = 'payment.owner_confirmed_online' and entity_id = pg_temp.f('o_dp')
            and metadata ->> 'reason' = 'Paid, webhook never arrived'
            and metadata ->> 'reference' = 'HP-DP-1'
            and metadata ->> 'kind' = 'downpayment'));
select pg_temp.chk('a second downpayment confirmation is refused', 'op-own',
  pg_temp.owner_confirm(pg_temp.f('o_dp'), 'Paid, webhook never arrived'), 'error');
select pg_temp.chk('staff can still confirm the cash balance', 'op-sa',
  format($q$select public.staff_confirm_payment(%L)$q$, pg_temp.f('o_dp')), 'ok');
select pg_temp.chk_true('the cash balance is paid', pg_temp.pay_status(pg_temp.f('o_dp')) = 'success');

-- Report --------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;

do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% online payment check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
