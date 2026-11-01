-- =============================================================================
-- Melai Nuts — required downpayment for Cash on Delivery
-- (migration 20261101083000_cod_downpayment.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/cod_downpayment_test.sql
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
create function pg_temp.j(p_uid text, p_sql text) returns jsonb language sql as $$
  select pg_temp.call_as(p_uid, 'select (' || p_sql || ')::text')::jsonb $$;
create function pg_temp.stock() returns int language sql as $$
  select quantity from public.branch_inventory
  where branch_id = pg_temp.f('ba')::uuid and variant_id = pg_temp.f('var')::uuid $$;

-- Fixtures: one unit costs 100 and delivery costs 50, so an order's total is 150. --
insert into public.branches (name, address, latitude, longitude, delivery_fee)
values ('DP-TEST A', 'a', 14.2117, 121.1653, 50);
insert into fx select 'ba', id::text from public.branches where name = 'DP-TEST A';
insert into public.product_categories (label) values ('DP-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'DP-TEST Nut', 100, 'pack' from public.product_categories where label = 'DP-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'DP-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'DP-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 100);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_review_refunds)
values ('dp-sa', 'Staff A', 'dp-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', true),
       ('dp-own', 'Owner', 'dp-own@test.local', 'owner', null, 'active', false);
insert into public.customer_profiles (firebase_uid, full_name, email, phone)
values ('dp-c1', 'Cust One', 'dp-c1@test.local', '09170000011'), ('dp-c2', 'Cust Two', 'dp-c2@test.local', '09170000012');
insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city, latitude, longitude)
values ('dp-c1', 'Cust One', '09170000011', '1 Test St', 'Calamba', 14.205, 121.156);
insert into fx select 'addr', id::text from public.customer_addresses where firebase_uid = 'dp-c1';
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point)
values ('default', 1, 50, 50)
  on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;
insert into public.vouchers (code, discount_type, discount_value) values ('DPTEST10', 'fixed', 10);

create function pg_temp.order_for(p_key text, p_voucher text default null, p_redeem boolean default false) returns text language sql as $$
  select pg_temp.call_as('dp-c1', format($q$select public.place_order(%L::uuid, true, %L::uuid, 'Cash on Delivery', '', %L)$q$,
    pg_temp.call_as('dp-c1', format($q$select (public.sync_customer_cart(%L::uuid,
      jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), %L, %L) ->> 'cart_id')$q$,
      pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var'), p_voucher, p_redeem)),
    pg_temp.f('addr'), p_key))
$$;
create function pg_temp.settings(p jsonb) returns void language plpgsql as $$
begin
  perform pg_temp.call_as('dp-own', format('select public.owner_update_business_settings(%L::jsonb)::text', p::text));
end $$;

-- 1. Off until the owner sets it --------------------------------------------------
insert into fx values ('o_off', pg_temp.order_for('dp-off'));
select pg_temp.chk_true('Not set: COD goes straight to staff',
  (select status = 'pending' from public.orders where id = pg_temp.f('o_off')));
select pg_temp.chk_true('Not set: the whole total is collected in cash',
  (select amount = 150 and method = 'cash' from public.payments where order_id = pg_temp.f('o_off')));
select pg_temp.chk_true('Not set: no downpayment row',
  not exists (select 1 from public.order_downpayments where order_id = pg_temp.f('o_off')));
select pg_temp.chk_true('Not set: the quote says none is required',
  (pg_temp.j('dp-c1', 'public.cod_downpayment_quote(150)') ->> 'required')::boolean = false);

-- 2. The setting ------------------------------------------------------------------
select pg_temp.chk('staff cannot change the setting', 'dp-sa',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":30,"cod_downpayment_expiry_minutes":30}'::jsonb)$q$, 'error');
select pg_temp.chk('a customer cannot change the setting', 'dp-c1',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":30,"cod_downpayment_expiry_minutes":30}'::jsonb)$q$, 'error');
select pg_temp.chk('type without an amount refused', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_expiry_minutes":30}'::jsonb)$q$, 'error');
select pg_temp.chk('no time limit refused', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":30}'::jsonb)$q$, 'error');
select pg_temp.chk('100 percent refused', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":100,"cod_downpayment_expiry_minutes":30}'::jsonb)$q$, 'error');
select pg_temp.chk('an unknown type refused', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"half","cod_downpayment_value":30,"cod_downpayment_expiry_minutes":30}'::jsonb)$q$, 'error');
select pg_temp.chk('the owner sets 30 percent, 30 minutes', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":30,"cod_downpayment_expiry_minutes":30}'::jsonb)$q$, 'ok');
select pg_temp.chk_true('the settings read back',
  (select j ->> 'cod_downpayment_type' = 'percent' and (j ->> 'cod_downpayment_value')::numeric = 30
          and (j ->> 'cod_downpayment_expiry_minutes')::int = 30
   from (select pg_temp.j('dp-own', 'public.get_business_settings()') j) t));
select pg_temp.chk_true('the quote is worked out by the server',
  (select (j ->> 'required')::boolean and (j ->> 'amount')::numeric = 45 and (j ->> 'balance')::numeric = 105
          and (j ->> 'expiry_minutes')::int = 30
   from (select pg_temp.j('dp-c1', 'public.cod_downpayment_quote(150)') j) t));

-- 3. Online payment switched off: COD keeps working, full cash ---------------------
update public.payment_settings set online_payment_enabled = false where id = 'default';
select pg_temp.chk_true('switched off: the quote says none is required',
  (pg_temp.j('dp-c1', 'public.cod_downpayment_quote(150)') ->> 'required')::boolean = false);
insert into fx values ('o_switch_off', pg_temp.order_for('dp-switch-off'));
select pg_temp.chk_true('switched off: COD goes straight to staff for the full amount',
  (select o.status = 'pending' and p.amount = 150 from public.orders o join public.payments p on p.order_id = o.id
   where o.id = pg_temp.f('o_switch_off')));
select pg_temp.chk_true('switched off: no downpayment row',
  not exists (select 1 from public.order_downpayments where order_id = pg_temp.f('o_switch_off')));
update public.payment_settings set online_payment_enabled = true where id = 'default';

-- 4. Placing an order -------------------------------------------------------------
insert into fx values ('stock_before', pg_temp.stock()::text);
insert into fx values ('o1', pg_temp.order_for('dp-1'));
select pg_temp.chk_true('placed: the order waits for its downpayment',
  (select status = 'awaitingDownpayment' from public.orders where id = pg_temp.f('o1')));
select pg_temp.chk_true('placed: the balance is the cash payment',
  (select amount = 105 and method = 'cash' and status = 'pending' from public.payments where order_id = pg_temp.f('o1')));
select pg_temp.chk_true('placed: 30 percent is due online, with a time limit',
  (select amount = 45 and status = 'pending' and expires_at > now() + interval '29 minutes'
          and expires_at <= now() + interval '30 minutes'
   from public.order_downpayments where order_id = pg_temp.f('o1')));
select pg_temp.chk_true('placed: the stock is held', pg_temp.stock() = pg_temp.f('stock_before')::int - 1);
select pg_temp.chk_true('the same request again is the same order',
  pg_temp.order_for('dp-1') = pg_temp.f('o1'));

-- 5. Staff cannot see or touch an unpaid order --------------------------------------
select pg_temp.chk_true('staff: not in the order list',
  not exists (select 1 from jsonb_array_elements(pg_temp.j('dp-sa', format('public.staff_list_orders(%L::uuid)', pg_temp.f('ba')))) e
              where e ->> 'id' = pg_temp.f('o1')));
select pg_temp.chk_true('staff: not readable directly',
  pg_temp.visible('dp-sa', format($q$select count(*) from public.orders where id = %L$q$, pg_temp.f('o1'))) = 0);
select pg_temp.chk_true('owner: not readable directly either',
  pg_temp.visible('dp-own', format($q$select count(*) from public.orders where id = %L$q$, pg_temp.f('o1'))) = 0);
select pg_temp.chk_true('staff: no new-order notification yet',
  not exists (select 1 from public.staff_notifications where recipient_uid = 'dp-sa' and reference = pg_temp.f('o1')));
select pg_temp.chk_true('staff: not counted on the dashboard',
  (pg_temp.j('dp-sa', format('public.staff_get_dashboard(%L::uuid)', pg_temp.f('ba'))) ->> 'pending_orders')::int = 2);
select pg_temp.chk('staff cannot accept it', 'dp-sa',
  format($q$select public.staff_update_order_status(%L, 'confirmed')$q$, pg_temp.f('o1')), 'error');
select pg_temp.chk('staff cannot cancel it', 'dp-sa',
  format($q$select public.staff_update_order_status(%L, 'cancelled')$q$, pg_temp.f('o1')), 'error');
select pg_temp.chk('staff cannot confirm its cash', 'dp-sa',
  format($q$select public.staff_confirm_payment(%L)$q$, pg_temp.f('o1')), 'error');
do $$
declare v_err text;
begin
  begin
    update public.orders set status = 'confirmed' where id = pg_temp.f('o1');
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk_true('an unpaid order cannot jump ahead', v_err is not null, coalesce(v_err, ''));
end $$;

-- Who can read and write the downpayment.
select pg_temp.chk_true('the customer reads their own',
  pg_temp.visible('dp-c1', format($q$select count(*) from public.order_downpayments where order_id = %L$q$, pg_temp.f('o1'))) = 1);
select pg_temp.chk_true('another customer does not',
  pg_temp.visible('dp-c2', format($q$select count(*) from public.order_downpayments where order_id = %L$q$, pg_temp.f('o1'))) = 0);
select pg_temp.chk_true('anon does not',
  pg_temp.visible(null, format($q$select count(*) from public.order_downpayments where order_id = %L$q$, pg_temp.f('o1'))) = 0);
select pg_temp.chk('a customer cannot mark it paid', 'dp-c1',
  format($q$update public.order_downpayments set status = 'success' where order_id = %L$q$, pg_temp.f('o1')), 'error');

-- 6. Paying online ------------------------------------------------------------------
select pg_temp.chk_true('first tap: create a link',
  public.hitpay_claim_checkout(pg_temp.f('o1')) ->> 'action' = 'create');
select pg_temp.chk_true('double tap: wait for the first',
  public.hitpay_claim_checkout(pg_temp.f('o1')) ->> 'action' = 'busy');
select public.hitpay_release_checkout(pg_temp.f('o1'));
select pg_temp.chk_true('after a release: create again',
  public.hitpay_claim_checkout(pg_temp.f('o1')) ->> 'action' = 'create');
select public.hitpay_set_checkout(pg_temp.f('o1'), 'preq-1', 'https://pay.example/1');
select pg_temp.chk_true('link stored on the downpayment, cash payment untouched',
  (select d.status = 'processing' and d.gateway_checkout_url = 'https://pay.example/1' and d.gateway_payment_id = 'preq-1'
          and p.status = 'pending' and p.gateway_payment_id is null
   from public.order_downpayments d join public.payments p on p.order_id = d.order_id where d.order_id = pg_temp.f('o1')));
select pg_temp.chk_true('a stored link is reused',
  public.hitpay_claim_checkout(pg_temp.f('o1')) ->> 'checkout_url' = 'https://pay.example/1');

select public.hitpay_apply_payment(pg_temp.f('o1'), 'failed', 'qrph', 'pay-old', null, 'preq-old');
select pg_temp.chk_true('a failure from an older link changes nothing',
  (select status = 'processing' from public.order_downpayments where order_id = pg_temp.f('o1')));
select public.hitpay_apply_payment(pg_temp.f('o1'), 'failed', 'qrph', 'pay-cur', null, 'preq-1');
select pg_temp.chk_true('a failure of the current link is recorded and clears the link',
  (select status = 'failed' and gateway_checkout_url is null from public.order_downpayments where order_id = pg_temp.f('o1')));
select pg_temp.chk_true('after a failure the order still waits',
  (select status = 'awaitingDownpayment' from public.orders where id = pg_temp.f('o1')));
select pg_temp.chk_true('after a failure a new link can be made',
  public.hitpay_claim_checkout(pg_temp.f('o1')) ->> 'action' = 'create');
select public.hitpay_set_checkout(pg_temp.f('o1'), 'preq-2', 'https://pay.example/2');
select public.hitpay_expire_checkout(pg_temp.f('o1'), 'preq-old');
select pg_temp.chk_true('an older link expiring changes nothing',
  (select status = 'processing' from public.order_downpayments where order_id = pg_temp.f('o1')));

select pg_temp.chk_true('the paid event is accepted',
  public.hitpay_apply_payment(pg_temp.f('o1'), 'success', 'qrph', 'pay-1', null, 'preq-2') = 'success');
select pg_temp.chk_true('paid: the downpayment is recorded with the method used',
  (select status = 'success' and method = 'qrph' and gateway_payment_id = 'pay-1' and paid_at is not null
   from public.order_downpayments where order_id = pg_temp.f('o1')));
select pg_temp.chk_true('paid: the order goes to staff',
  (select status = 'pending' from public.orders where id = pg_temp.f('o1')));
select pg_temp.chk_true('paid: the cash balance is still due',
  (select status = 'pending' and amount = 105 from public.payments where order_id = pg_temp.f('o1')));
select pg_temp.chk_true('paid: staff are told, with what to collect',
  (select count(*) = 1 and bool_and(body like '%₱105.00%') from public.staff_notifications
   where recipient_uid = 'dp-sa' and reference = pg_temp.f('o1')));
select pg_temp.chk_true('paid: the customer is told',
  exists (select 1 from public.notifications where firebase_uid = 'dp-c1' and title = 'Downpayment received'
          and body like '%' || pg_temp.f('o1') || '%'));
select pg_temp.chk_true('paid: staff see it, with the downpayment',
  (select (e -> 'downpayment' ->> 'amount')::numeric = 45 and (e -> 'payment' ->> 'amount')::numeric = 105
   from jsonb_array_elements(pg_temp.j('dp-sa', format('public.staff_list_orders(%L::uuid)', pg_temp.f('ba')))) e
   where e ->> 'id' = pg_temp.f('o1')));
select public.hitpay_apply_payment(pg_temp.f('o1'), 'success', 'qrph', 'pay-1', null, 'preq-2');
select pg_temp.chk_true('the same event again changes nothing',
  (select count(*) = 1 from public.staff_notifications where recipient_uid = 'dp-sa' and reference = pg_temp.f('o1')));
select pg_temp.chk_true('a paid downpayment has no link to open',
  public.hitpay_claim_checkout(pg_temp.f('o1')) ->> 'action' = 'closed');

-- 7. The rider collects exactly the balance -----------------------------------------
select pg_temp.chk('the owner registers a rider', 'dp-own',
  format($q$select public.owner_upsert_driver('dp-drv', 'Rider One', 'r1@x', %L::uuid)$q$, pg_temp.f('ba')), 'ok');
select pg_temp.chk('staff accept the paid order', 'dp-sa',
  format($q$select public.staff_update_order_status(%L, 'confirmed')$q$, pg_temp.f('o1')), 'ok');
insert into fx select 'run1', pg_temp.call_as('dp-sa', format(
  $q$select public.staff_create_delivery(%L::uuid, 'Motorbike', 'TBD', array[%L]) ->> 'id'$q$,
  pg_temp.f('ba'), pg_temp.f('o1')));
insert into fx select 'stop1', id::text from public.delivery_stops where order_id = pg_temp.f('o1');
select pg_temp.call_as('dp-sa', format($q$select public.staff_assign_driver(%L, 'dp-drv')::text$q$, pg_temp.f('run1')));
select pg_temp.chk('the rider accepts', 'dp-drv', format($q$select public.driver_respond_assignment(%L, 'accept')$q$, pg_temp.f('run1')), 'ok');
select pg_temp.chk('the rider picks up', 'dp-drv', format($q$select public.driver_mark_picked_up(%L)$q$, pg_temp.f('run1')), 'ok');
select pg_temp.chk_true('the rider sees the balance and the downpayment',
  (select (s ->> 'order_total')::numeric = 150 and (s ->> 'cash_due')::numeric = 105 and (s ->> 'downpayment_paid')::numeric = 45
   from jsonb_array_elements(public._delivery_to_jsonb(pg_temp.f('run1')) -> 'stops') s));
select pg_temp.chk('the rider heads out', 'dp-drv', format($q$select public.driver_update_stop(%L::uuid, 'enRoute')$q$, pg_temp.f('stop1')), 'ok');
select pg_temp.chk('the full order total is refused', 'dp-drv',
  format($q$select public.driver_update_stop(%L::uuid, 'delivered', null, null, null, 'Cust One', 150)$q$, pg_temp.f('stop1')), 'error');
select pg_temp.chk('no cash at all is refused', 'dp-drv',
  format($q$select public.driver_update_stop(%L::uuid, 'delivered', null, null, null, 'Cust One')$q$, pg_temp.f('stop1')), 'error');
select pg_temp.chk('the balance is accepted', 'dp-drv',
  format($q$select public.driver_update_stop(%L::uuid, 'delivered', null, null, null, 'Cust One', 105)$q$, pg_temp.f('stop1')), 'ok');
select pg_temp.chk_true('delivered: the order is completed and the cash confirmed',
  (select o.status = 'completed' and p.status = 'success' from public.orders o join public.payments p on p.order_id = o.id
   where o.id = pg_temp.f('o1')));

-- 8. Reports: the total is unchanged, the method line is split -----------------------
insert into fx values ('today', ((now() at time zone 'Asia/Manila')::date)::text);
create temp table ov as select pg_temp.j('dp-own',
  format($q$public.sales_overview(%L::date, %L::date, %L::uuid)$q$, pg_temp.f('today'), pg_temp.f('today'), pg_temp.f('ba'))) j;
select pg_temp.chk_true('report: one sale of 100 goods plus 50 delivery',
  (select (j -> 'summary' ->> 'orders')::int = 1 and (j -> 'summary' ->> 'gross_sales')::numeric = 100 from ov));
select pg_temp.chk_true('report: 105 in cash',
  (select (m ->> 'amount_paid')::numeric = 105 and (m ->> 'orders')::int = 1
   from ov, jsonb_array_elements(j -> 'by_method') m where m ->> 'method' = 'cash'));
select pg_temp.chk_true('report: 45 by QR Ph',
  (select (m ->> 'amount_paid')::numeric = 45 and (m ->> 'orders')::int = 0
   from ov, jsonb_array_elements(j -> 'by_method') m where m ->> 'method' = 'qrph'));
select pg_temp.chk_true('report: the methods add up to what was paid',
  (select sum((m ->> 'amount_paid')::numeric) = 150 from ov, jsonb_array_elements(j -> 'by_method') m));
create temp table ar as select pg_temp.j('dp-own',
  format($q$public.analytics_report(current_date - 1, current_date, %L::uuid)$q$, pg_temp.f('ba'))) j;
select pg_temp.chk_true('analytics: the methods add up too',
  (select sum((m ->> 'amount')::numeric) = 150 and bool_or(m ->> 'method' = 'qrph' and (m ->> 'amount')::numeric = 45)
   from ar, jsonb_array_elements(j -> 'by_payment_method') m));

-- 9. Refund after delivery: the online part through HitPay, the rest in cash ---------
insert into fx select 'r1', pg_temp.call_as('dp-c1', format(
  $q$select public.request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','DP-TEST Nut','variant_label','Regular','quantity',1)))$q$,
  pg_temp.f('o1')));
select pg_temp.chk_true('the customer can ask for more than the downpayment',
  (select amount = 100 from public.refund_requests where id = pg_temp.f('r1')));
select pg_temp.chk('the website cannot treat it as a cash-only refund', 'dp-sa',
  format($q$select public.admin_portal_review_refund(%L, 'approve_cash')$q$, pg_temp.f('r1')), 'error');
select pg_temp.chk('staff approve', 'dp-sa', format($q$select public.staff_review_refund(%L, 'approve')$q$, pg_temp.f('r1')), 'ok');
select pg_temp.chk_true('staff see how much of it was the downpayment',
  (select (e ->> 'downpayment_amount')::numeric = 45
   from jsonb_array_elements(pg_temp.j('dp-sa', 'public.staff_list_refunds()')) e where e ->> 'id' = pg_temp.f('r1')));
insert into fx select 'a1', j ->> 'attempt_id' from (select pg_temp.j('dp-sa', format('public.staff_begin_gateway_refund(%L)', pg_temp.f('r1'))) j) t;
select pg_temp.chk_true('only the downpayment goes to HitPay, against the HitPay payment',
  (select amount = 45 and gateway_payment_id = 'pay-1' from public.refund_gateway_attempts where id = pg_temp.f('a1')::uuid));
select pg_temp.chk('HitPay confirms', 'dp-sa',
  format($q$select public.staff_finish_gateway_refund(%L::uuid, 'succeeded', 'rf-1')$q$, pg_temp.f('a1')), 'ok');
select pg_temp.chk_true('refunded: the downpayment and the cash payment are marked',
  (select d.status = 'refunded' and p.status = 'refunded' and o.status = 'refunded'
   from public.order_downpayments d join public.payments p on p.order_id = d.order_id join public.orders o on o.id = d.order_id
   where d.order_id = pg_temp.f('o1')));

-- 10. Not paid in time -----------------------------------------------------------------
update public.loyalty_accounts set points_balance = 20 where firebase_uid = 'dp-c1';
insert into fx values ('stock_e', pg_temp.stock()::text);
insert into fx values ('o2', pg_temp.order_for('dp-2', 'DPTEST10', true));
select pg_temp.chk_true('with a voucher and points: 30 percent of what is left to pay',
  (select o.total = 120 and d.amount = 36 and p.amount = 84
   from public.orders o join public.order_downpayments d on d.order_id = o.id join public.payments p on p.order_id = o.id
   where o.id = pg_temp.f('o2')));
select pg_temp.chk_true('the points and voucher are in use',
  (select points_balance = 0 from public.loyalty_accounts where firebase_uid = 'dp-c1')
  and (select used_count = 1 from public.vouchers where code = 'DPTEST10'));
select pg_temp.chk_true('before the time limit: nothing expires', public.expire_unpaid_cod_downpayments() = 0);
select pg_temp.chk_true('before the time limit: still waiting',
  (select status = 'awaitingDownpayment' from public.orders where id = pg_temp.f('o2')));
select pg_temp.chk_true('a link can still be made',
  public.hitpay_claim_checkout(pg_temp.f('o2')) ->> 'action' = 'create');
select public.hitpay_set_checkout(pg_temp.f('o2'), 'preq-e', 'https://pay.example/e');
update public.order_downpayments set expires_at = now() - interval '1 minute' where order_id = pg_temp.f('o2');
select pg_temp.chk_true('after the time limit, before the job runs: no new link',
  public.hitpay_claim_checkout(pg_temp.f('o2')) ->> 'action' = 'expired');
select pg_temp.chk_true('the job cancels exactly one order', public.expire_unpaid_cod_downpayments() = 1);
select pg_temp.chk_true('expired: the order is cancelled',
  (select status = 'cancelled' from public.orders where id = pg_temp.f('o2')));
select pg_temp.chk_true('expired: the downpayment is closed and its link removed',
  (select status = 'expired' and gateway_checkout_url is null from public.order_downpayments where order_id = pg_temp.f('o2')));
select pg_temp.chk_true('expired: the stock is back', pg_temp.stock() = pg_temp.f('stock_e')::int);
select pg_temp.chk_true('expired: the points are back',
  (select points_balance = 20 from public.loyalty_accounts where firebase_uid = 'dp-c1'));
select pg_temp.chk_true('expired: the voucher is free again',
  (select used_count = 0 from public.vouchers where code = 'DPTEST10'));
select pg_temp.chk_true('expired: the customer is told',
  exists (select 1 from public.notifications where firebase_uid = 'dp-c1' and title = 'Order cancelled'
          and body like '%' || pg_temp.f('o2') || '%'));
select pg_temp.chk_true('expired: no refund, nothing was paid',
  not exists (select 1 from public.refund_requests where order_id = pg_temp.f('o2')));
select pg_temp.chk_true('expired: staff were never told',
  not exists (select 1 from public.staff_notifications where reference = pg_temp.f('o2')));
select pg_temp.chk_true('the job finds nothing else', public.expire_unpaid_cod_downpayments() = 0);

-- 11. Paid after it expired: the money goes back, and it is not a sale -----------------
select pg_temp.chk_true('the late event is accepted',
  public.hitpay_apply_payment(pg_temp.f('o2'), 'success', 'qrph', 'pay-late', null, 'preq-e') = 'success');
select pg_temp.chk_true('late: recorded, and the order stays cancelled',
  (select d.status = 'success' and o.status = 'cancelled'
   from public.order_downpayments d join public.orders o on o.id = d.order_id where d.order_id = pg_temp.f('o2')));
insert into fx select 'r2', id from public.refund_requests where order_id = pg_temp.f('o2');
select pg_temp.chk_true('late: a refund for the downpayment is open',
  (select status = 'pending' and amount = 36 from public.refund_requests where id = pg_temp.f('r2')));
select public.hitpay_apply_payment(pg_temp.f('o2'), 'success', 'qrph', 'pay-late', null, 'preq-e');
select pg_temp.chk_true('late: the same event again opens no second refund',
  (select count(*) = 1 from public.refund_requests where order_id = pg_temp.f('o2')));
select pg_temp.chk('late: staff approve', 'dp-sa', format($q$select public.staff_review_refund(%L, 'approve')$q$, pg_temp.f('r2')), 'ok');
insert into fx select 'a2', j ->> 'attempt_id' from (select pg_temp.j('dp-sa', format('public.staff_begin_gateway_refund(%L)', pg_temp.f('r2'))) j) t;
select pg_temp.chk_true('late: the whole amount goes to HitPay',
  (select amount = 36 and gateway_payment_id = 'pay-late' from public.refund_gateway_attempts where id = pg_temp.f('a2')::uuid));
select pg_temp.chk('late: HitPay confirms', 'dp-sa',
  format($q$select public.staff_finish_gateway_refund(%L::uuid, 'succeeded', 'rf-2')$q$, pg_temp.f('a2')), 'ok');
select pg_temp.chk_true('late: the downpayment is refunded, the order stays cancelled',
  (select d.status = 'refunded' and o.status = 'cancelled'
   from public.order_downpayments d join public.orders o on o.id = d.order_id where d.order_id = pg_temp.f('o2')));
select pg_temp.chk_true('late: no sale and no refund in the sales figures',
  not exists (select 1 from public._sales_facts(null, null, array[pg_temp.f('ba')::uuid]) where order_id = pg_temp.f('o2')));

-- 12. Cancelled after paying -----------------------------------------------------------
insert into fx values ('stock_c', pg_temp.stock()::text);
insert into fx values ('o3', pg_temp.order_for('dp-3'));
select public.hitpay_set_checkout(pg_temp.f('o3'), 'preq-3', 'https://pay.example/3');
select public.hitpay_apply_payment(pg_temp.f('o3'), 'success', 'gcash', 'pay-3', null, 'preq-3');
select pg_temp.chk('staff cancel the paid order', 'dp-sa',
  format($q$select public.staff_update_order_status(%L, 'cancelled')$q$, pg_temp.f('o3')), 'ok');
select pg_temp.chk_true('cancelled: the stock is back', pg_temp.stock() = pg_temp.f('stock_c')::int);
select pg_temp.chk_true('cancelled: a refund for the downpayment is open',
  (select status = 'pending' and amount = 45 from public.refund_requests where order_id = pg_temp.f('o3')));
select pg_temp.chk_true('cancelled: the customer is told',
  exists (select 1 from public.notifications where firebase_uid = 'dp-c1' and title = 'Your downpayment will be refunded'
          and body like '%' || pg_temp.f('o3') || '%'));
select pg_temp.chk_true('cancelled: the refund cannot exceed what was paid',
  (select (public._order_refund_json(pg_temp.f('o3')) ->> 'refundable_amount')::numeric = 45));
select pg_temp.chk_true('cancelled: the order stays cancelled',
  (select status = 'cancelled' from public.orders where id = pg_temp.f('o3')));

-- 13. A fixed amount, and a minimum order ------------------------------------------------
select pg_temp.settings('{"cod_downpayment_type":"fixed","cod_downpayment_value":100}'::jsonb);
select pg_temp.chk_true('fixed: the amount is what the owner set',
  (select (j ->> 'amount')::numeric = 100 and (j ->> 'balance')::numeric = 50
   from (select pg_temp.j('dp-c1', 'public.cod_downpayment_quote(150)') j) t));
select pg_temp.chk_true('a setting change leaves a placed order alone',
  (select amount = 45 from public.order_downpayments where order_id = pg_temp.f('o3')));

select pg_temp.settings('{"cod_downpayment_value":500}'::jsonb);
insert into fx values ('o4', pg_temp.order_for('dp-4'));
select pg_temp.chk_true('capped: never more than the total, nothing left in cash',
  (select d.amount = 150 and p.amount = 0
   from public.order_downpayments d join public.payments p on p.order_id = d.order_id where d.order_id = pg_temp.f('o4')));
select public.hitpay_set_checkout(pg_temp.f('o4'), 'preq-4', 'https://pay.example/4');
select public.hitpay_apply_payment(pg_temp.f('o4'), 'success', 'gcash', 'pay-4', null, 'preq-4');
select pg_temp.chk_true('capped: once paid, nothing is due at the door',
  (select o.status = 'pending' and p.status = 'success'
   from public.orders o join public.payments p on p.order_id = o.id where o.id = pg_temp.f('o4')));

select pg_temp.settings('{"cod_downpayment_value":100,"cod_downpayment_min_order":200}'::jsonb);
insert into fx values ('o5', pg_temp.order_for('dp-5'));
select pg_temp.chk_true('below the minimum order: no downpayment',
  (select o.status = 'pending' and p.amount = 150
   from public.orders o join public.payments p on p.order_id = o.id where o.id = pg_temp.f('o5'))
  and not exists (select 1 from public.order_downpayments where order_id = pg_temp.f('o5')));
select pg_temp.settings('{"cod_downpayment_min_order":150}'::jsonb);
select pg_temp.chk_true('exactly the minimum order: downpayment required',
  (pg_temp.j('dp-c1', 'public.cod_downpayment_quote(150)') ->> 'required')::boolean);

select pg_temp.settings('{"cod_downpayment_type":null,"cod_downpayment_value":null,"cod_downpayment_min_order":null,"cod_downpayment_expiry_minutes":null}'::jsonb);
select pg_temp.chk_true('the owner can turn it off again',
  (pg_temp.j('dp-c1', 'public.cod_downpayment_quote(150)') ->> 'required')::boolean = false);

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% downpayment check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
