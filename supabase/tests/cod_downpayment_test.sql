-- =============================================================================
-- Melai Nuts — the downpayment on Cash on Counter Pickup
-- (migrations 20261101083000_cod_downpayment.sql, 20261101120000_pickup_downpayment.sql)
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

-- Fixtures: one unit costs 100, so a pickup order's total is 100. Delivery costs 50. --
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

create function pg_temp.cart(p_voucher text default null, p_redeem boolean default false) returns text language sql as $$
  select pg_temp.call_as('dp-c1', format($q$select (public.sync_customer_cart(%L::uuid,
    jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), %L, %L) ->> 'cart_id')$q$,
    pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var'), p_voucher, p_redeem)) $$;
create function pg_temp.order_for(p_key text, p_voucher text default null, p_redeem boolean default false) returns text language sql as $$
  select pg_temp.call_as('dp-c1', format($q$select public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', %L)$q$,
    pg_temp.cart(p_voucher, p_redeem), p_key)) $$;
create function pg_temp.settings(p jsonb) returns void language plpgsql as $$
begin
  perform pg_temp.call_as('dp-own', format('select public.owner_update_business_settings(%L::jsonb)::text', p::text));
end $$;
create function pg_temp.pay(p_order text, p_key text) returns void language plpgsql as $$
begin
  perform public.hitpay_set_checkout(p_order, 'preq-' || p_key, 'https://pay.example/' || p_key);
  perform public.hitpay_apply_payment(p_order, 'success', 'qrph', 'pay-' || p_key, null, 'preq-' || p_key);
end $$;
create function pg_temp.to_ready(p_order text) returns void language plpgsql as $$
begin
  perform pg_temp.call_as('dp-sa', format($q$select public.staff_update_order_status(%L, s)::text
    from unnest(array['confirmed', 'preparing', 'readyForPickup']) s$q$, p_order));
end $$;

-- 1. Off until the owner sets it --------------------------------------------------
insert into fx values ('o_off', pg_temp.order_for('dp-off'));
select pg_temp.chk_true('Not set: pickup goes straight to staff',
  (select status = 'pending' from public.orders where id = pg_temp.f('o_off')));
select pg_temp.chk_true('Not set: the whole total is paid in cash',
  (select amount = 100 and method = 'cash' from public.payments where order_id = pg_temp.f('o_off')));
select pg_temp.chk_true('Not set: no downpayment row',
  not exists (select 1 from public.order_downpayments where order_id = pg_temp.f('o_off')));
select pg_temp.chk_true('Not set: the quote says none is required',
  (pg_temp.j('dp-c1', 'public.cod_downpayment_quote(100)') ->> 'required')::boolean = false);

-- 2. The setting ------------------------------------------------------------------
select pg_temp.chk('staff cannot change the setting', 'dp-sa',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":30,"cod_downpayment_expiry_minutes":30,"cod_downpayment_pickup_days":2}'::jsonb)$q$, 'error');
select pg_temp.chk('a customer cannot change the setting', 'dp-c1',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":30,"cod_downpayment_expiry_minutes":30,"cod_downpayment_pickup_days":2}'::jsonb)$q$, 'error');
select pg_temp.chk('type without an amount refused', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_expiry_minutes":30,"cod_downpayment_pickup_days":2}'::jsonb)$q$, 'error');
select pg_temp.chk('no time limit refused', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":30,"cod_downpayment_pickup_days":2}'::jsonb)$q$, 'error');
select pg_temp.chk('no pickup days refused', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":30,"cod_downpayment_expiry_minutes":30}'::jsonb)$q$, 'error');
select pg_temp.chk('31 pickup days refused', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":30,"cod_downpayment_expiry_minutes":30,"cod_downpayment_pickup_days":31}'::jsonb)$q$, 'error');
select pg_temp.chk('100 percent refused', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":100,"cod_downpayment_expiry_minutes":30,"cod_downpayment_pickup_days":2}'::jsonb)$q$, 'error');
select pg_temp.chk('an unknown type refused', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"half","cod_downpayment_value":30,"cod_downpayment_expiry_minutes":30,"cod_downpayment_pickup_days":2}'::jsonb)$q$, 'error');
select pg_temp.chk('the owner sets 30 percent, 30 minutes, 2 days', 'dp-own',
  $q$select public.owner_update_business_settings('{"cod_downpayment_type":"percent","cod_downpayment_value":30,"cod_downpayment_expiry_minutes":30,"cod_downpayment_pickup_days":2}'::jsonb)$q$, 'ok');
select pg_temp.chk_true('the settings read back',
  (select j ->> 'cod_downpayment_type' = 'percent' and (j ->> 'cod_downpayment_value')::numeric = 30
          and (j ->> 'cod_downpayment_expiry_minutes')::int = 30 and (j ->> 'cod_downpayment_pickup_days')::int = 2
   from (select pg_temp.j('dp-own', 'public.get_business_settings()') j) t));
select pg_temp.chk_true('the quote carries the real values for the note',
  (select (j ->> 'required')::boolean and (j ->> 'amount')::numeric = 30 and (j ->> 'balance')::numeric = 70
          and (j ->> 'expiry_minutes')::int = 30 and (j ->> 'percent')::numeric = 30 and (j ->> 'pickup_days')::int = 2
   from (select pg_temp.j('dp-c1', 'public.cod_downpayment_quote(100)') j) t));

-- 3. Online payment switched off: pickup keeps working, full cash ------------------
update public.payment_settings set online_payment_enabled = false where id = 'default';
select pg_temp.chk_true('switched off: the quote says none is required',
  (pg_temp.j('dp-c1', 'public.cod_downpayment_quote(100)') ->> 'required')::boolean = false);
insert into fx values ('o_switch_off', pg_temp.order_for('dp-switch-off'));
select pg_temp.chk_true('switched off: pickup goes straight to staff for the full amount',
  (select o.status = 'pending' and p.amount = 100 from public.orders o join public.payments p on p.order_id = o.id
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
  (select amount = 70 and method = 'cash' and status = 'pending' from public.payments where order_id = pg_temp.f('o1')));
select pg_temp.chk_true('placed: 30 percent is due online, with a time limit',
  (select amount = 30 and status = 'pending' and expires_at > now() + interval '29 minutes'
          and expires_at <= now() + interval '30 minutes'
   from public.order_downpayments where order_id = pg_temp.f('o1')));
select pg_temp.chk_true('placed: the order keeps its own percent and pickup days',
  (select percent = 30 and pickup_days = 2 from public.order_downpayments where order_id = pg_temp.f('o1')));
select pg_temp.chk_true('placed: the stock is held', pg_temp.stock() = pg_temp.f('stock_before')::int - 1);
select pg_temp.chk_true('the same request again is the same order', pg_temp.order_for('dp-1') = pg_temp.f('o1'));

-- Cash on Delivery no longer has a downpayment.
insert into fx values ('o_cod', pg_temp.call_as('dp-c1', format($q$select public.place_order(%L::uuid, true, %L::uuid, 'Cash on Delivery', '', 'dp-cod')$q$,
  pg_temp.cart(), pg_temp.f('addr'))));
select pg_temp.chk_true('Cash on Delivery is full cash again',
  (select o.status = 'pending' and p.amount = 150 from public.orders o join public.payments p on p.order_id = o.id
   where o.id = pg_temp.f('o_cod'))
  and not exists (select 1 from public.order_downpayments where order_id = pg_temp.f('o_cod')));
select pg_temp.chk_true('a delivery order keeps its address',
  (select delivery_address_id = pg_temp.f('addr')::uuid from public.orders where id = pg_temp.f('o_cod')));

-- A pickup order never links an address, even if an app build sends one. The order
-- is undone afterwards, so the stock and order counts below are not affected.
do $$
declare
  v_order text;
  v_address uuid;
begin
  begin
    v_order := pg_temp.call_as('dp-c1', format($q$select public.place_order(%L::uuid, false, %L::uuid, 'Cash on Counter Pickup', '', 'dp-pickup-addr')$q$,
      pg_temp.cart(), pg_temp.f('addr')));
    select delivery_address_id into v_address from public.orders where id = v_order;
    raise exception 'undo this order';
  exception when raise_exception then
    null;
  end;
  perform pg_temp.chk_true('a pickup order ignores an address it was sent',
    v_order is not null and v_address is null, coalesce(v_order, 'no order was placed'));
end $$;

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
select pg_temp.chk_true('the customer reads their own downpayment',
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
select public.hitpay_set_checkout(pg_temp.f('o1'), 'preq-1', 'https://pay.example/1');
select pg_temp.chk_true('a stored link is reused',
  public.hitpay_claim_checkout(pg_temp.f('o1')) ->> 'checkout_url' = 'https://pay.example/1');
select public.hitpay_apply_payment(pg_temp.f('o1'), 'failed', 'qrph', 'pay-old', null, 'preq-old');
select pg_temp.chk_true('a failure from an older link changes nothing',
  (select status = 'processing' from public.order_downpayments where order_id = pg_temp.f('o1')));
select pg_temp.chk_true('the paid event is accepted',
  public.hitpay_apply_payment(pg_temp.f('o1'), 'success', 'qrph', 'pay-1', null, 'preq-1') = 'success');
select pg_temp.chk_true('paid: the downpayment is recorded with the method used',
  (select status = 'success' and method = 'qrph' and gateway_payment_id = 'pay-1' and paid_at is not null
   from public.order_downpayments where order_id = pg_temp.f('o1')));
select pg_temp.chk_true('paid: the order goes to staff',
  (select status = 'pending' from public.orders where id = pg_temp.f('o1')));
select pg_temp.chk_true('paid: staff are told it is pickup, with what to collect',
  (select count(*) = 1 and bool_and(title like 'New pickup order%' and body like '%₱70.00%') from public.staff_notifications
   where recipient_uid = 'dp-sa' and reference = pg_temp.f('o1')));
select pg_temp.chk_true('paid: the customer is told the rest is paid at pickup',
  exists (select 1 from public.notifications where firebase_uid = 'dp-c1' and title = 'Downpayment received'
          and body like '%' || pg_temp.f('o1') || '%' and body like '%when you pick it up%'));
select pg_temp.chk_true('paid: staff see it, with the downpayment and the balance',
  (select (e -> 'downpayment' ->> 'amount')::numeric = 30 and (e -> 'payment' ->> 'amount')::numeric = 70
   from jsonb_array_elements(pg_temp.j('dp-sa', format('public.staff_list_orders(%L::uuid)', pg_temp.f('ba')))) e
   where e ->> 'id' = pg_temp.f('o1')));
select public.hitpay_apply_payment(pg_temp.f('o1'), 'success', 'qrph', 'pay-1', null, 'preq-1');
select pg_temp.chk_true('the same event again changes nothing',
  (select count(*) = 1 from public.staff_notifications where recipient_uid = 'dp-sa' and reference = pg_temp.f('o1')));

-- 7. Picked up: the balance is paid in cash at the counter --------------------------
select pg_temp.to_ready(pg_temp.f('o1'));
select pg_temp.chk_true('ready: the customer is told the deadline',
  exists (select 1 from public.notifications where firebase_uid = 'dp-c1'
          and title like '%' || pg_temp.f('o1') || ' is ready for pickup'
          and body like '%within 2 days%' and body like '%will not be refunded%'));
select pg_temp.chk('it cannot be completed before the cash is confirmed', 'dp-sa',
  format($q$select public.staff_update_order_status(%L, 'completed')$q$, pg_temp.f('o1')), 'error');
select pg_temp.chk('staff confirm the cash balance', 'dp-sa',
  format($q$select public.staff_confirm_payment(%L)$q$, pg_temp.f('o1')), 'ok');
select pg_temp.chk('staff complete the order', 'dp-sa',
  format($q$select public.staff_update_order_status(%L, 'completed')$q$, pg_temp.f('o1')), 'ok');
select pg_temp.chk_true('picked up: completed, with the balance paid',
  (select o.status = 'completed' and p.status = 'success' from public.orders o join public.payments p on p.order_id = o.id
   where o.id = pg_temp.f('o1')));

-- 8. Reports: the total is unchanged, the method line is split -----------------------
insert into fx values ('today', ((now() at time zone 'Asia/Manila')::date)::text);
create temp table ov as select pg_temp.j('dp-own',
  format($q$public.sales_overview(%L::date, %L::date, %L::uuid)$q$, pg_temp.f('today'), pg_temp.f('today'), pg_temp.f('ba'))) j;
select pg_temp.chk_true('report: one sale of 100',
  (select (j -> 'summary' ->> 'orders')::int = 1 and (j -> 'summary' ->> 'gross_sales')::numeric = 100 from ov));
select pg_temp.chk_true('report: 70 in cash',
  (select (m ->> 'amount_paid')::numeric = 70 and (m ->> 'orders')::int = 1
   from ov, jsonb_array_elements(j -> 'by_method') m where m ->> 'method' = 'cash'));
select pg_temp.chk_true('report: 30 by QR Ph',
  (select (m ->> 'amount_paid')::numeric = 30 and (m ->> 'orders')::int = 0
   from ov, jsonb_array_elements(j -> 'by_method') m where m ->> 'method' = 'qrph'));
select pg_temp.chk_true('report: nothing kept yet',
  (select (j -> 'kept_downpayments' ->> 'count')::int = 0 and (j -> 'kept_downpayments' ->> 'amount')::numeric = 0 from ov));

-- 9. Refund after pickup: the online part through HitPay, the rest in cash ------------
insert into fx select 'r1', pg_temp.call_as('dp-c1', format(
  $q$select public.request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','DP-TEST Nut','variant_label','Regular','quantity',1)))$q$,
  pg_temp.f('o1')));
select pg_temp.chk('the website cannot treat it as a cash-only refund', 'dp-sa',
  format($q$select public.admin_portal_review_refund(%L, 'approve_cash')$q$, pg_temp.f('r1')), 'error');
select pg_temp.chk('staff approve', 'dp-sa', format($q$select public.staff_review_refund(%L, 'approve')$q$, pg_temp.f('r1')), 'ok');
insert into fx select 'a1', j ->> 'attempt_id' from (select pg_temp.j('dp-sa', format('public.staff_begin_gateway_refund(%L)', pg_temp.f('r1'))) j) t;
select pg_temp.chk_true('only the downpayment goes to HitPay',
  (select amount = 30 and gateway_payment_id = 'pay-1' from public.refund_gateway_attempts where id = pg_temp.f('a1')::uuid));

-- 10. Not paid in time ----------------------------------------------------------------
update public.loyalty_accounts set points_balance = 20 where firebase_uid = 'dp-c1';
insert into fx values ('stock_e', pg_temp.stock()::text);
insert into fx values ('o2', pg_temp.order_for('dp-2', 'DPTEST10', true));
select pg_temp.chk_true('with a voucher and points: 30 percent of what is left to pay',
  (select o.total = 70 and d.amount = 21 and p.amount = 49
   from public.orders o join public.order_downpayments d on d.order_id = o.id join public.payments p on p.order_id = o.id
   where o.id = pg_temp.f('o2')));
select pg_temp.chk_true('before the time limit: nothing expires', public.expire_unpaid_cod_downpayments() = 0);
select public.hitpay_set_checkout(pg_temp.f('o2'), 'preq-e', 'https://pay.example/e');
update public.order_downpayments set expires_at = now() - interval '1 minute' where order_id = pg_temp.f('o2');
select pg_temp.chk_true('after the time limit, before the job runs: no new link',
  public.hitpay_claim_checkout(pg_temp.f('o2')) ->> 'action' = 'expired');
select pg_temp.chk_true('the job cancels exactly one order', public.expire_unpaid_cod_downpayments() = 1);
select pg_temp.chk_true('expired: the order is cancelled and nothing was kept',
  (select o.status = 'cancelled' and d.status = 'expired' and d.gateway_checkout_url is null
   from public.orders o join public.order_downpayments d on d.order_id = o.id where o.id = pg_temp.f('o2')));
select pg_temp.chk_true('expired: the stock is back', pg_temp.stock() = pg_temp.f('stock_e')::int);
select pg_temp.chk_true('expired: the points are back',
  (select points_balance = 20 from public.loyalty_accounts where firebase_uid = 'dp-c1'));
select pg_temp.chk_true('expired: the voucher is free again',
  (select used_count = 0 from public.vouchers where code = 'DPTEST10'));
select pg_temp.chk_true('expired: no refund, nothing was paid',
  not exists (select 1 from public.refund_requests where order_id = pg_temp.f('o2')));
select pg_temp.chk_true('expired: staff were never told',
  not exists (select 1 from public.staff_notifications where reference = pg_temp.f('o2')));

-- 11. Paid after it expired: the money goes back, and it is not a sale -----------------
select pg_temp.chk_true('the late event is accepted',
  public.hitpay_apply_payment(pg_temp.f('o2'), 'success', 'qrph', 'pay-late', null, 'preq-e') = 'success');
select pg_temp.chk_true('late: a refund for the downpayment is open, and the order stays cancelled',
  (select r.status = 'pending' and r.amount = 21 and o.status = 'cancelled'
   from public.refund_requests r join public.orders o on o.id = r.order_id where r.order_id = pg_temp.f('o2')));
select public.hitpay_apply_payment(pg_temp.f('o2'), 'success', 'qrph', 'pay-late', null, 'preq-e');
select pg_temp.chk_true('late: the same event again opens no second refund',
  (select count(*) = 1 from public.refund_requests where order_id = pg_temp.f('o2')));
select pg_temp.chk_true('late: no sale and no refund in the sales figures',
  not exists (select 1 from public._sales_facts(null, null, array[pg_temp.f('ba')::uuid]) where order_id = pg_temp.f('o2')));

-- 12. The shop cancels: the downpayment is refunded -----------------------------------
insert into fx values ('stock_c', pg_temp.stock()::text);
insert into fx values ('o3', pg_temp.order_for('dp-3'));
select pg_temp.pay(pg_temp.f('o3'), '3');
select pg_temp.to_ready(pg_temp.f('o3'));
select pg_temp.chk('staff cancel the paid, ready order', 'dp-sa',
  format($q$select public.staff_update_order_status(%L, 'cancelled')$q$, pg_temp.f('o3')), 'ok');
select pg_temp.chk_true('shop cancelled: the stock is back', pg_temp.stock() = pg_temp.f('stock_c')::int);
select pg_temp.chk_true('shop cancelled: a refund for the downpayment is open',
  (select status = 'pending' and amount = 30 from public.refund_requests where order_id = pg_temp.f('o3')));
select pg_temp.chk_true('shop cancelled: the downpayment is not kept',
  (select status = 'success' and forfeited_at is null from public.order_downpayments where order_id = pg_temp.f('o3')));
select pg_temp.chk_true('shop cancelled: the customer is told',
  exists (select 1 from public.notifications where firebase_uid = 'dp-c1' and title = 'Your downpayment will be refunded'
          and body like '%' || pg_temp.f('o3') || '%'));
select pg_temp.chk('shop cancelled: staff approve', 'dp-sa',
  format($q$select public.staff_review_refund(r.id, 'approve') from public.refund_requests r where r.order_id = %L$q$, pg_temp.f('o3')), 'ok');
insert into fx select 'a3', j ->> 'attempt_id' from (select pg_temp.j('dp-sa', format('public.staff_begin_gateway_refund(%L)',
  (select id from public.refund_requests where order_id = pg_temp.f('o3')))) j) t;
select pg_temp.chk('shop cancelled: HitPay confirms', 'dp-sa',
  format($q$select public.staff_finish_gateway_refund(%L::uuid, 'succeeded', 'rf-3')$q$, pg_temp.f('a3')), 'ok');
select pg_temp.chk_true('shop cancelled: the downpayment is refunded',
  (select status = 'refunded' from public.order_downpayments where order_id = pg_temp.f('o3')));

-- 13. Not picked up in time: cancelled, stock returned, the shop keeps the downpayment -
insert into fx values ('stock_f', pg_temp.stock()::text);
insert into fx values ('o4', pg_temp.order_for('dp-4'));
select pg_temp.pay(pg_temp.f('o4'), '4');
select pg_temp.call_as('dp-sa', format($q$select public.staff_update_order_status(%L, s)::text
  from unnest(array['confirmed', 'preparing']) s$q$, pg_temp.f('o4')));
-- A pickup window of 0 days has already passed, so the clock can be tested at once.
update public.order_downpayments set pickup_days = 0 where order_id = pg_temp.f('o4');
select pg_temp.chk_true('not ready yet: the clock has not started', public.forfeit_unclaimed_cod_downpayments() = 0);
update public.order_downpayments set pickup_days = 2 where order_id = pg_temp.f('o4');
select pg_temp.call_as('dp-sa', format($q$select public.staff_update_order_status(%L, 'readyForPickup')::text$q$, pg_temp.f('o4')));
select pg_temp.chk_true('ready, within the 2 days: nothing happens', public.expire_unpaid_cod_downpayments() = 0);
select pg_temp.chk_true('ready, within the 2 days: still ready',
  (select status = 'readyForPickup' from public.orders where id = pg_temp.f('o4')));

-- Cash already taken: left for staff, never forfeited.
insert into fx values ('o5', pg_temp.order_for('dp-5'));
select pg_temp.pay(pg_temp.f('o5'), '5');
select pg_temp.to_ready(pg_temp.f('o5'));
select pg_temp.call_as('dp-sa', format($q$select public.staff_confirm_payment(%L)::text$q$, pg_temp.f('o5')));
update public.order_downpayments set pickup_days = 0 where order_id in (pg_temp.f('o4'), pg_temp.f('o5'));
select pg_temp.chk_true('past the 2 days: the job cancels only the unpaid one', public.expire_unpaid_cod_downpayments() = 1);
select pg_temp.chk_true('balance already paid: the order is left for staff',
  (select o.status = 'readyForPickup' and d.status = 'success'
   from public.orders o join public.order_downpayments d on d.order_id = o.id where o.id = pg_temp.f('o5')));
select pg_temp.chk_true('not picked up: the order is cancelled',
  (select status = 'cancelled' from public.orders where id = pg_temp.f('o4')));
select pg_temp.chk_true('not picked up: the shop keeps the downpayment',
  (select status = 'forfeited' and forfeited_at is not null from public.order_downpayments where order_id = pg_temp.f('o4')));
select pg_temp.chk_true('not picked up: no refund is opened',
  not exists (select 1 from public.refund_requests where order_id = pg_temp.f('o4')));
select pg_temp.chk_true('not picked up: its stock is back',
  pg_temp.stock() = pg_temp.f('stock_f')::int - 1);
select pg_temp.chk_true('not picked up: the customer is told it is non-refundable',
  exists (select 1 from public.notifications where firebase_uid = 'dp-c1' and title = 'Order not picked up'
          and body like '%' || pg_temp.f('o4') || '%' and body like '%non-refundable%'));
select pg_temp.chk_true('not picked up: staff are told',
  exists (select 1 from public.staff_notifications where recipient_uid = 'dp-sa' and reference = pg_temp.f('o4')
          and title like 'Order not picked up%'));
select pg_temp.chk_true('the job does not act on it twice', public.expire_unpaid_cod_downpayments() = 0);
select public.hitpay_apply_payment(pg_temp.f('o4'), 'success', 'qrph', 'pay-4', null, 'preq-4');
select pg_temp.chk_true('a repeated paid event neither refunds nor un-keeps it',
  (select d.status = 'forfeited' and not exists (select 1 from public.refund_requests r where r.order_id = d.order_id)
   from public.order_downpayments d where d.order_id = pg_temp.f('o4')));
select pg_temp.chk_true('not picked up: it is not a sale',
  not exists (select 1 from public._sales_facts(null, null, array[pg_temp.f('ba')::uuid]) where order_id = pg_temp.f('o4')));

create temp table ov2 as select pg_temp.j('dp-own',
  format($q$public.sales_overview(%L::date, %L::date, %L::uuid)$q$, pg_temp.f('today'), pg_temp.f('today'), pg_temp.f('ba'))) j;
select pg_temp.chk_true('report: the kept downpayment has its own line',
  (select (j -> 'kept_downpayments' ->> 'count')::int = 1 and (j -> 'kept_downpayments' ->> 'amount')::numeric = 30 from ov2));
create temp table ar as select pg_temp.j('dp-own',
  format($q$public.analytics_report(current_date - 1, current_date, %L::uuid)$q$, pg_temp.f('ba'))) j;
select pg_temp.chk_true('analytics: the kept downpayment has its own line',
  (select (j -> 'summary' -> 'kept_downpayments' ->> 'amount')::numeric = 30 from ar));

-- 14. A fixed amount, and a minimum order ------------------------------------------------
select pg_temp.settings('{"cod_downpayment_type":"fixed","cod_downpayment_value":40}'::jsonb);
select pg_temp.chk_true('fixed: the amount is what the owner set, and no percent is reported',
  (select (j ->> 'amount')::numeric = 40 and (j ->> 'balance')::numeric = 60 and j ->> 'percent' is null
   from (select pg_temp.j('dp-c1', 'public.cod_downpayment_quote(100)') j) t));
select pg_temp.chk_true('a setting change leaves a placed order alone',
  (select amount = 30 and percent = 30 from public.order_downpayments where order_id = pg_temp.f('o5')));

select pg_temp.settings('{"cod_downpayment_value":500}'::jsonb);
insert into fx values ('o6', pg_temp.order_for('dp-6'));
select pg_temp.chk_true('capped: never more than the total, nothing left in cash',
  (select d.amount = 100 and p.amount = 0
   from public.order_downpayments d join public.payments p on p.order_id = d.order_id where d.order_id = pg_temp.f('o6')));
select pg_temp.pay(pg_temp.f('o6'), '6');
select pg_temp.chk_true('capped: once paid, nothing is due at the counter',
  (select o.status = 'pending' and p.status = 'success'
   from public.orders o join public.payments p on p.order_id = o.id where o.id = pg_temp.f('o6')));

select pg_temp.settings('{"cod_downpayment_value":40,"cod_downpayment_min_order":200}'::jsonb);
insert into fx values ('o7', pg_temp.order_for('dp-7'));
select pg_temp.chk_true('below the minimum order: no downpayment',
  (select o.status = 'pending' and p.amount = 100
   from public.orders o join public.payments p on p.order_id = o.id where o.id = pg_temp.f('o7'))
  and not exists (select 1 from public.order_downpayments where order_id = pg_temp.f('o7')));
select pg_temp.settings('{"cod_downpayment_min_order":100}'::jsonb);
select pg_temp.chk_true('exactly the minimum order: downpayment required',
  (pg_temp.j('dp-c1', 'public.cod_downpayment_quote(100)') ->> 'required')::boolean);

select pg_temp.settings('{"cod_downpayment_type":null,"cod_downpayment_value":null,"cod_downpayment_min_order":null,"cod_downpayment_expiry_minutes":null,"cod_downpayment_pickup_days":null}'::jsonb);
select pg_temp.chk_true('the owner can turn it off again',
  (pg_temp.j('dp-c1', 'public.cod_downpayment_quote(100)') ->> 'required')::boolean = false);

-- 15. The saved message no longer mentions delivery -----------------------------------
select pg_temp.chk_true('the unavailable message points to pickup only',
  public.online_payment_disabled_message() not like '%Delivery%');

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
