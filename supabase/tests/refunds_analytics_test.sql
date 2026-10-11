-- =============================================================================
-- Melai Nuts — refunds count everywhere (migration 20261015000000_refunds_in_analytics.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/refunds_analytics_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
--
-- One branch day with every refund case, then every figure (sales_overview,
-- owner_sales_summary, staff_get_dashboard, analytics_report, product units,
-- owner_staff_overview, cashier summary, order lists, customer view) is checked
-- against the same expected numbers and against each other.
--
--   Branch A, today (Asia/Manila):
--     o1  4 x 100 = 400  partial refund 1 unit  -> 100 completed today
--     o2  2 x 100 = 200  full refund            -> 200 completed today, 1 sellable + 1 expired back
--     o4  1 x 100 = 100  GCash via HitPay       -> 100 completed today (gateway)
--     o5  2 x 100 = 200  refund requested       -> 100 PENDING (not deducted)
--     o6  1 x 100 = 100  refund rejected        -> nothing changes
--     pos 3 x 100 = 300  cash, cashier A        -> counter return 2 (1 sellable, 1 damaged) = 200 cash
--   Branch A, yesterday:
--     o3  3 x 100 = 300, discount 30 (total 270) -> 1 unit refunded TODAY = 90
--   Branch B, today:
--     ob  1 x 100 = 100  no refund
--
--   Branch A today: gross 1300, discounts 0, refunds 690 (5), net 610, pending 1 / 100
--   Branch A yesterday: gross 300, discounts 30, refunds 0, net 270
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
    case when p_expect = 'error' then v_err is not null
         when p_expect like 'like:%' then v_err ilike '%' || substr(p_expect, 6) || '%'
         else v_err is null end,
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
create function pg_temp.j(p_uid text, p_call text) returns jsonb language sql as $$
  select pg_temp.call_as(p_uid, 'select (' || p_call || ')::text')::jsonb $$;
create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;
create function pg_temp.f(p_k text) returns text language sql as $$ select v from fx where k = p_k $$;
grant execute on function pg_temp.f(text) to public;
create function pg_temp.n(p jsonb, variadic p_path text[]) returns numeric language sql immutable as $$
  select (p #>> p_path)::numeric $$;
create function pg_temp.stock(p_branch text) returns int language sql as $$
  select quantity from public.branch_inventory
  where branch_id = pg_temp.f(p_branch)::uuid and variant_id = pg_temp.f('var')::uuid $$;

-- Fixtures ---------------------------------------------------------------------
insert into public.branches (name, address, delivery_fee) values ('RF-TEST A', 'a', 0), ('RF-TEST B', 'b', 0);
insert into fx select 'ba', id::text from public.branches where name = 'RF-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'RF-TEST B';
insert into public.product_categories (label) values ('RF-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'RF-TEST Nut', 100, 'pack' from public.product_categories where label = 'RF-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'RF-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'RF-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select pg_temp.f(b)::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 0 from (values ('ba'), ('bb')) t(b);

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
values ('rf-sa',  'Cashier A', 'rf-sa@test.local',  'staff', pg_temp.f('ba')::uuid, 'active', true, true),
       ('rf-sn',  'Clerk A (no reports, no refunds)', 'rf-sn@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', false, false),
       ('rf-sb',  'Cashier B', 'rf-sb@test.local',  'staff', pg_temp.f('bb')::uuid, 'active', true, true),
       ('rf-own', 'Owner',     'rf-own@test.local', 'owner', null, 'active', false, false);
insert into public.staff_permission_grants (firebase_uid, permission, granted_by) values ('rf-sa', 'view_reports', 'rf-own');
insert into public.customer_profiles (firebase_uid, full_name, email, phone)
values ('rf-c1', 'Cust One', 'rf-c1@test.local', '09170000101'),
       ('rf-c2', 'Cust Two', 'rf-c2@test.local', '09170000102');
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point)
values ('default', 1, 50, 50)
  on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;

select pg_temp.call_as('rf-own', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'RF-A1', 50, current_date + 90)::text$q$,
  pg_temp.f('ba'), pg_temp.f('var')));
select set_config('app.inventory_managed', '', true);

-- A paid, completed pickup order (points are awarded on completion, as in the app).
create function pg_temp.mk_order(p_cust text, p_branch text, p_units int, p_discount numeric, p_method text, p_at timestamptz)
returns text language plpgsql as $$
declare v_id text; v_total numeric := p_units * 100 - p_discount;
begin
  insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method, created_at)
  values (p_cust, pg_temp.f(p_branch)::uuid, 'RF-TEST', false, 'confirmed', p_units * 100, p_discount, 0, v_total,
          case when p_method = 'cash' then 'Cash on Counter Pickup' else 'Online Payment (GCash, Maya, Card)' end, p_at)
  returning id into v_id;
  insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
  values (v_id, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 'RF-TEST Nut', 'Regular', p_units, 100);
  insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number, created_at)
  values (v_id, p_cust, p_method, 'success', v_total, 'REF-' || v_id, p_at);
  update public.orders set status = 'completed' where id = v_id;
  return v_id;
end $$;
create function pg_temp.request(p_cust text, p_order text, p_units int) returns text language sql as $$
  select pg_temp.call_as(p_cust, format(
    $q$select public.request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','RF-TEST Nut','variant_label','Regular','quantity',%s)))$q$,
    p_order, p_units)) $$;

insert into fx values ('today_10', greatest(((now() at time zone 'Asia/Manila')::date::timestamp at time zone 'Asia/Manila') + interval '1 millisecond',
                                            now() - interval '1 second')::text);
insert into fx values ('yday_10', ((((now() at time zone 'Asia/Manila')::date - 1) + time '10:00') at time zone 'Asia/Manila')::text);
insert into fx values ('today', (now() at time zone 'Asia/Manila')::date::text);

insert into fx values ('o1', pg_temp.mk_order('rf-c1', 'ba', 4, 0, 'cash', pg_temp.f('today_10')::timestamptz));
insert into fx values ('o2', pg_temp.mk_order('rf-c2', 'ba', 2, 0, 'cash', pg_temp.f('today_10')::timestamptz));
insert into fx values ('o3', pg_temp.mk_order('rf-c1', 'ba', 3, 30, 'cash', pg_temp.f('yday_10')::timestamptz));
insert into fx values ('o4', pg_temp.mk_order('rf-c2', 'ba', 1, 0, 'gcash', pg_temp.f('today_10')::timestamptz));
insert into fx values ('o5', pg_temp.mk_order('rf-c1', 'ba', 2, 0, 'cash', pg_temp.f('today_10')::timestamptz));
insert into fx values ('o6', pg_temp.mk_order('rf-c2', 'ba', 1, 0, 'cash', pg_temp.f('today_10')::timestamptz));
insert into fx values ('ob', pg_temp.mk_order('rf-c1', 'bb', 1, 0, 'cash', pg_temp.f('today_10')::timestamptz));
update public.payments set gateway = 'hitpay', gateway_payment_id = 'hp-pay-rf-1' where order_id = pg_temp.f('o4');

select pg_temp.chk_true('fixture: points earned on completion (o1 400 -> 8 pts)',
  (select points = 8 from public.loyalty_transactions where order_id = pg_temp.f('o1') and source = 'order_earn'));

-- POS: cashier A sells 3 for cash in an open shift, then takes 2 back (1 sellable, 1 damaged).
select pg_temp.call_as('rf-sa', format($q$select public.staff_open_shift(%L::uuid, 1000)::text$q$, pg_temp.f('ba')));
insert into fx select 'pos', pg_temp.call_as('rf-sa', format(
  $q$select public.staff_create_pos_sale(%L::uuid, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 3)),
       'cash', null, 1000, null, 'rf-pos-1') ->> 'order_id'$q$, pg_temp.f('ba'), pg_temp.f('var')));
insert into fx values ('stock_after_pos_sale', pg_temp.stock('ba')::text);
insert into fx values ('expected_cash_before', pg_temp.call_as('rf-sa', 'select public.staff_get_current_shift() ->> ''expected_cash'''));
insert into fx select 'r_pos', pg_temp.call_as('rf-sa', format(
  $q$select public.staff_pos_return(%L, jsonb_build_array(
       jsonb_build_object('variant_id', %L, 'quantity', 1, 'condition', 'sellable'),
       jsonb_build_object('variant_id', %L, 'quantity', 1, 'condition', 'damaged')), 'Customer changed mind', 'rf-ret-1') ->> 'refund_id'$q$,
  pg_temp.f('pos'), pg_temp.f('var'), pg_temp.f('var')));

-- Online refunds.
insert into fx values ('r1', pg_temp.request('rf-c1', pg_temp.f('o1'), 1));
insert into fx values ('r2', pg_temp.request('rf-c2', pg_temp.f('o2'), 2));
insert into fx values ('r3', pg_temp.request('rf-c1', pg_temp.f('o3'), 1));
insert into fx values ('r4', pg_temp.request('rf-c2', pg_temp.f('o4'), 1));
insert into fx values ('r5', pg_temp.request('rf-c1', pg_temp.f('o5'), 1));
insert into fx values ('r6', pg_temp.request('rf-c2', pg_temp.f('o6'), 1));
do $$
declare r text;
begin
  foreach r in array array['r1', 'r2', 'r3'] loop
    perform pg_temp.call_as('rf-sa', format($q$select public.staff_review_refund(%L, 'approve')::text$q$, pg_temp.f(r)));
    perform pg_temp.call_as('rf-sa', format($q$select public.staff_review_refund(%L, 'complete')::text$q$, pg_temp.f(r)));
  end loop;
end $$;
select pg_temp.call_as('rf-sa', format($q$select public.staff_review_refund(%L, 'approve')::text$q$, pg_temp.f('r4')));
insert into fx select 'att', pg_temp.call_as('rf-sa', format($q$select public.staff_begin_gateway_refund(%L) ->> 'attempt_id'$q$, pg_temp.f('r4')));
select pg_temp.call_as('rf-sa', format($q$select public.staff_finish_gateway_refund(%L::uuid, 'succeeded', 'hp-rf-1')::text$q$, pg_temp.f('att')));
select pg_temp.call_as('rf-own', format($q$select public.admin_portal_review_refund(%L, 'reject', 'Outside the return window')::text$q$, pg_temp.f('r6')));

-- o2: the 2 refunded units come back: 1 sellable (restocks), 1 expired (recorded only).
insert into fx values ('stock_before_receive', pg_temp.stock('ba')::text);
select pg_temp.call_as('rf-sa', format($q$select public.staff_receive_returned_items(%L, jsonb_build_array(
  jsonb_build_object('variant_id', %L, 'quantity', 1, 'condition', 'sellable'),
  jsonb_build_object('variant_id', %L, 'quantity', 1, 'condition', 'expired')))::text$q$,
  pg_temp.f('r2'), pg_temp.f('var'), pg_temp.f('var')));

-- 0. Fixture sanity -------------------------------------------------------------
select pg_temp.chk_true('fixture: refund amounts are 100 / 200 / 90 / 100 / 100 / 100 and POS 200',
  (select array_agg(amount order by id) from public.refund_requests where id in
     (pg_temp.f('r1'), pg_temp.f('r2'), pg_temp.f('r3'), pg_temp.f('r4'), pg_temp.f('r5'), pg_temp.f('r6')))
  = array[100, 200, 90, 100, 100, 100]::numeric[]
  and (select amount from public.refund_requests where id = pg_temp.f('r_pos')) = 200,
  (select string_agg(id || '=' || amount || '/' || status, ', ' order by id) from public.refund_requests
   where order_id in (select v from fx where k in ('o1','o2','o3','o4','o5','o6','pos'))));
select pg_temp.chk_true('fixture: statuses completed x5, pending, rejected',
  (select count(*) from public.refund_requests where id in (pg_temp.f('r1'), pg_temp.f('r2'), pg_temp.f('r3'), pg_temp.f('r4'), pg_temp.f('r_pos'))
     and status = 'completed') = 5
  and (select status from public.refund_requests where id = pg_temp.f('r5')) = 'pending'
  and (select status from public.refund_requests where id = pg_temp.f('r6')) = 'rejected');

-- 1. Access / scope ---------------------------------------------------------------
select pg_temp.chk('anon cannot read sales_overview', null, 'select public.sales_overview()', 'error');
select pg_temp.chk('customer cannot read sales_overview', 'rf-c1', 'select public.sales_overview()', 'error');
select pg_temp.chk('staff B cannot read branch A', 'rf-sb',
  format($q$select public.sales_overview(null, null, %L::uuid)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('range over 400 days refused', 'rf-own', 'select public.sales_overview(current_date - 500, current_date)', 'error');
select pg_temp.chk_true('staff A with no branch argument sees only branch A',
  (select jsonb_array_length(j -> 'by_branch') = 1 and j -> 'by_branch' -> 0 ->> 'branch_id' = pg_temp.f('ba')
   from (select pg_temp.j('rf-sa', 'public.sales_overview()') j) t));
select pg_temp.chk_true('staff without view_reports: totals and products yes, per-cashier breakdown no',
  (select j -> 'summary' is not null and j -> 'by_staff' = 'null'::jsonb and jsonb_typeof(j -> 'by_product') = 'array'
   from (select pg_temp.j('rf-sn', 'public.sales_overview()') j) t));
select pg_temp.chk_true('owner with no branch sees both test branches',
  (select count(*) = 2 from jsonb_array_elements(pg_temp.j('rf-own', 'public.sales_overview()') -> 'by_branch') e
   where e ->> 'branch_id' in (pg_temp.f('ba'), pg_temp.f('bb'))));
select pg_temp.chk('customer cannot read owner_sales_summary', 'rf-c1', 'select public.owner_sales_summary(30)', 'error');
select pg_temp.chk('staff cannot read owner_sales_summary', 'rf-sa', 'select public.owner_sales_summary(30)', 'error');
select pg_temp.chk('staff B dashboard cannot be pointed at branch A (gets own branch)', 'rf-sb',
  format($q$select 1 where (public.staff_get_dashboard(%L::uuid) -> 'branch' ->> 'id') = %L$q$, pg_temp.f('ba'), pg_temp.f('bb')), 'ok');
select pg_temp.chk_true('staff B dashboard shows branch B sales only (100, no refunds)',
  (select pg_temp.n(j, 'sales_today') = 100 and pg_temp.n(j, 'refunds_today') = 0
   from (select pg_temp.j('rf-sb', format('public.staff_get_dashboard(%L::uuid)', pg_temp.f('ba'))) j) t));
select pg_temp.chk('customer cannot call get_my_order_refunds for someone else (only own rows)', 'rf-c2',
  format($q$select 1 where jsonb_array_length(public.get_my_order_refunds(array[%L])) = 0$q$, pg_temp.f('o1')), 'ok');
select pg_temp.chk('anon cannot call get_my_order_refunds', null, 'select public.get_my_order_refunds()', 'error');
select pg_temp.chk_true('nobody calls the internal fact functions directly',
  not has_function_privilege('authenticated', 'public._sales_facts(timestamptz, timestamptz, uuid[])', 'execute')
  and not has_function_privilege('anon', 'public._sales_line_facts(timestamptz, timestamptz, uuid[])', 'execute')
  and not has_function_privilege('authenticated', 'public._pending_refund_facts(uuid[])', 'execute')
  and not has_function_privilege('authenticated', 'public._order_refund_json(text)', 'execute'));

-- 2. Branch A today: the headline numbers ---------------------------------------------
create temp table ov_today as select pg_temp.j('rf-own',
  format($q$public.sales_overview(%L::date, %L::date, %L::uuid)$q$, pg_temp.f('today'), pg_temp.f('today'), pg_temp.f('ba'))) j;
select pg_temp.chk_true('today: gross 1300 (refunded / partially refunded orders still in gross)',
  (select pg_temp.n(j, 'summary', 'gross_sales') = 1300 from ov_today), (select (j -> 'summary')::text from ov_today));
select pg_temp.chk_true('today: refunds 690 = 100 partial + 200 full + 90 cross-day + 100 HitPay + 200 POS',
  (select pg_temp.n(j, 'summary', 'refunds') = 690 and pg_temp.n(j, 'summary', 'refund_count') = 5 from ov_today));
select pg_temp.chk_true('today: net 610 = 1300 - 0 - 690',
  (select pg_temp.n(j, 'summary', 'net_sales') = 610 from ov_today));
select pg_temp.chk_true('today: refund rate 690 / 1300 = 0.5308',
  (select pg_temp.n(j, 'summary', 'refund_rate') = 0.5308 from ov_today));
select pg_temp.chk_true('pending refund shown apart (1 / 100), not deducted',
  (select pg_temp.n(j, 'pending_refunds', 'count') = 1 and pg_temp.n(j, 'pending_refunds', 'amount') = 100 from ov_today));
select pg_temp.chk_true('rejected refund changed nothing (o6 counted in gross, no refund)',
  (select status = 'completed' from public.orders where id = pg_temp.f('o6'))
  and (select status = 'success' from public.payments where order_id = pg_temp.f('o6')));

create temp table ov_2d as select pg_temp.j('rf-own',
  format($q$public.sales_overview((%L::date - 1), %L::date, %L::uuid)$q$, pg_temp.f('today'), pg_temp.f('today'), pg_temp.f('ba'))) j;
select pg_temp.chk_true('cross-day: the sale stays yesterday (gross 300, discounts 30, no refund that day)',
  (select pg_temp.n(d, 'gross_sales') = 300 and pg_temp.n(d, 'discounts') = 30 and pg_temp.n(d, 'refunds') = 0
          and pg_temp.n(d, 'net_sales') = 270
   from ov_2d, jsonb_array_elements(j -> 'by_day') d where d ->> 'date' = (pg_temp.f('today')::date - 1)::text));
select pg_temp.chk_true('cross-day: the 90 refund hits today',
  (select pg_temp.n(d, 'refunds') = 690 from ov_2d, jsonb_array_elements(j -> 'by_day') d where d ->> 'date' = pg_temp.f('today')));
select pg_temp.chk_true('two days: gross 1600, discounts 30, refunds 690, net 880, rate 690/1570',
  (select pg_temp.n(j, 'summary', 'gross_sales') = 1600 and pg_temp.n(j, 'summary', 'discounts') = 30
          and pg_temp.n(j, 'summary', 'net_sales') = 880 and pg_temp.n(j, 'summary', 'refund_rate') = 0.4395 from ov_2d));
select pg_temp.chk_true('day totals add up to the period total',
  (select sum(pg_temp.n(d, 'net_sales')) = pg_temp.n(j, 'summary', 'net_sales')
          and sum(pg_temp.n(d, 'refunds')) = pg_temp.n(j, 'summary', 'refunds')
   from ov_2d, jsonb_array_elements(j -> 'by_day') d group by j));
select pg_temp.chk_true('payment-method rows add up (GCash refund 100 under gcash)',
  (select sum(pg_temp.n(m, 'net_sales')) = 880 and bool_or(m ->> 'method' = 'gcash' and pg_temp.n(m, 'refunds') = 100)
   from ov_2d, jsonb_array_elements(j -> 'by_method') m));

create temp table ov_all as select pg_temp.j('rf-own',
  format($q$public.sales_overview(%L::date, %L::date)$q$, pg_temp.f('today'), pg_temp.f('today'))) j;
select pg_temp.chk_true('branch totals add up to the owner total',
  (select sum(pg_temp.n(b, 'net_sales')) = pg_temp.n(j, 'summary', 'net_sales')
          and sum(pg_temp.n(b, 'gross_sales')) = pg_temp.n(j, 'summary', 'gross_sales')
   from ov_all, jsonb_array_elements(j -> 'by_branch') b group by j));
select pg_temp.chk_true('branch A row: net 610, pending 100',
  (select pg_temp.n(b, 'net_sales') = 610 and pg_temp.n(b, 'pending_refund_amount') = 100
   from ov_all, jsonb_array_elements(j -> 'by_branch') b where b ->> 'branch_id' = pg_temp.f('ba')));

-- 3. Cashier, product, POS ------------------------------------------------------------
select pg_temp.chk_true('POS refund counts against the cashier who made the sale (gross 300, refunds 200, net 100)',
  (select pg_temp.n(s, 'gross_sales') = 300 and pg_temp.n(s, 'refunds') = 200 and pg_temp.n(s, 'net_sales') = 100
   from ov_today, jsonb_array_elements(j -> 'by_staff') s where s ->> 'staff_uid' = 'rf-sa'));
select pg_temp.chk_true('online orders are their own row (net 510)',
  (select pg_temp.n(s, 'net_sales') = 510 from ov_today, jsonb_array_elements(j -> 'by_staff') s where s ->> 'channel' = 'online'));
select pg_temp.chk_true('cashier daily summary agrees with sales_overview for cashier A',
  (select pg_temp.n(c, 'net_sales') = 100 and pg_temp.n(c, 'refunds') = 200
   from jsonb_array_elements(pg_temp.j('rf-sa', format('public.staff_cashier_daily_summary(%L::uuid)', pg_temp.f('ba'))) -> 'cashiers') c
   where c ->> 'staff_uid' = 'rf-sa'));
select pg_temp.chk_true('owner_staff_overview agrees (POS net 100, 1 refund)',
  (select pg_temp.n(s, 'pos_net_sales') = 100 and pg_temp.n(s, 'pos_refunds') = 200 and pg_temp.n(s, 'pos_refund_count') = 1
          and pg_temp.n(s, 'pos_gross_sales') = 300
   from jsonb_array_elements(pg_temp.j('rf-own', format($q$public.owner_staff_overview(%L::timestamptz, now() + interval '1 minute', %L::uuid)$q$,
          (pg_temp.f('today')::date::timestamp at time zone 'Asia/Manila'), pg_temp.f('ba')))) s
   where s ->> 'firebase_uid' = 'rf-sa'));
select pg_temp.chk_true('cash refund left the drawer: expected cash dropped by 200',
  (pg_temp.call_as('rf-sa', 'select public.staff_get_current_shift() ->> ''expected_cash''')::numeric)
  = pg_temp.f('expected_cash_before')::numeric - 200);
select pg_temp.chk_true('channels add up: POS net 100, pickup net 510',
  (select sum(pg_temp.n(c, 'net_sales')) = 610 and bool_or(c ->> 'channel' = 'pos' and pg_temp.n(c, 'net_sales') = 100)
          and bool_or(c ->> 'channel' = 'pickup' and pg_temp.n(c, 'net_sales') = 510)
   from ov_today, jsonb_array_elements(j -> 'by_channel') c));
select pg_temp.chk_true('daily units: today 13 sold, 7 refunded',
  (select pg_temp.n(d, 'units') = 13 and pg_temp.n(d, 'refunded_units') = 7 from ov_today, jsonb_array_elements(j -> 'by_day') d));
select pg_temp.chk_true('product units: sold 13 today, refunded 1+2+1+1+2 = 7, net 6',
  (select pg_temp.n(p, 'units') = 13 and pg_temp.n(p, 'refunded_units') = 7 and pg_temp.n(p, 'net_units') = 6
   from ov_today, jsonb_array_elements(j -> 'by_product') p where p ->> 'product' = 'RF-TEST Nut'));
select pg_temp.chk_true('product money adds up to the order totals (gross, refunds, net)',
  (select sum(pg_temp.n(p, 'gross_sales')) = pg_temp.n(j, 'summary', 'gross_sales')
          and sum(pg_temp.n(p, 'refunds')) = pg_temp.n(j, 'summary', 'refunds')
          and sum(pg_temp.n(p, 'net_sales')) = pg_temp.n(j, 'summary', 'net_sales')
   from ov_2d, jsonb_array_elements(j -> 'by_product') p group by j));
select pg_temp.chk_true('get_product_sales_30d = net units over 30 days, all branches (17 sold - 7 refunded = 10)',
  (select units_sold = 10 from public.get_product_sales_30d() where product_id = pg_temp.f('prod')::uuid),
  (select units_sold::text from public.get_product_sales_30d() where product_id = pg_temp.f('prod')::uuid));
select pg_temp.chk_true('get_popular_products uses the same net units (10, all branches)',
  (select total_quantity = 10 from public.get_popular_products(50) where product_id = pg_temp.f('prod')::uuid));

-- 4. Other screens show the same numbers -----------------------------------------------
create temp table oss as select pg_temp.j('rf-own', 'public.owner_sales_summary(30)') j;
select pg_temp.chk_true('owner_sales_summary branch A: today_revenue = net 610, refunds/gross apart',
  (select pg_temp.n(b, 'today_revenue') = 610 and pg_temp.n(b, 'today', 'gross_sales') = 1300
          and pg_temp.n(b, 'today', 'refunds') = 690 and pg_temp.n(b, 'orders_today') = 6
          and pg_temp.n(b, 'pending_refund_amount') = 100
   from oss, jsonb_array_elements(j -> 'branches') b where b ->> 'branch_id' = pg_temp.f('ba')),
  (select b::text from oss, jsonb_array_elements(j -> 'branches') b where b ->> 'branch_id' = pg_temp.f('ba')));
select pg_temp.chk_true('owner_sales_summary window = sales_overview for the same 30 days (branch A)',
  (select pg_temp.n(b, 'window_revenue') from oss, jsonb_array_elements(j -> 'branches') b where b ->> 'branch_id' = pg_temp.f('ba'))
  = pg_temp.n(pg_temp.j('rf-own', format($q$public.sales_overview(%L::date - 29, %L::date, %L::uuid)$q$,
                                         pg_temp.f('today'), pg_temp.f('today'), pg_temp.f('ba'))), 'summary', 'net_sales'));
select pg_temp.chk_true('owner_sales_summary daily rows add up to the window total',
  (select sum(pg_temp.n(d, 'revenue')) = pg_temp.n(j, 'totals', 'window', 'net_sales') from oss, jsonb_array_elements(j -> 'daily') d group by j));
select pg_temp.chk_true('owner_sales_summary product (all branches): 17 sold - 7 refunded = 10 net units',
  (select pg_temp.n(p, 'units') = 10 and pg_temp.n(p, 'refunded_units') = 7
   from oss, jsonb_array_elements(j -> 'products') p where p ->> 'product_name' = 'RF-TEST Nut'),
  (select p::text from oss, jsonb_array_elements(j -> 'products') p where p ->> 'product_name' = 'RF-TEST Nut'));
select pg_temp.chk_true('staff dashboard (branch A): sales today = net 610, refunds 690, pending 1 / 100',
  (select pg_temp.n(j, 'sales_today') = 610 and pg_temp.n(j, 'refunds_today') = 690 and pg_temp.n(j, 'gross_sales_today') = 1300
          and pg_temp.n(j, 'pending_refunds') = 1 and pg_temp.n(j, 'pending_refund_amount') = 100
   from (select pg_temp.j('rf-sa', 'public.staff_get_dashboard(null)') j) t));
select pg_temp.chk_true('staff without refund rights: pending refund count/amount hidden (null)',
  (select j -> 'pending_refunds' = 'null'::jsonb and j -> 'pending_refund_amount' = 'null'::jsonb and pg_temp.n(j, 'sales_today') = 610
   from (select pg_temp.j('rf-sn', 'public.staff_get_dashboard(null)') j) t));
create temp table rep as select pg_temp.j('rf-own',
  format($q$public.analytics_report(%L::date - 1, %L::date, %L::uuid)$q$, pg_temp.f('today'), pg_temp.f('today'), pg_temp.f('ba'))) j;
select pg_temp.chk_true('analytics_report summary = sales_overview summary (gross, discounts, refunds, net, rate)',
  (select r.j -> 'summary' -> 'gross_sales' = o.j -> 'summary' -> 'gross_sales'
          and r.j -> 'summary' -> 'refunds' = o.j -> 'summary' -> 'refunds'
          and r.j -> 'summary' -> 'net_sales' = o.j -> 'summary' -> 'net_sales'
          and r.j -> 'summary' -> 'refund_rate' = o.j -> 'summary' -> 'refund_rate'
          and pg_temp.n(r.j, 'summary', 'pending_refunds', 'amount') = 100
   from rep r, ov_2d o));
select pg_temp.chk_true('analytics_report by_day = sales_overview by_day',
  (select r.j -> 'by_day' = o.j -> 'by_day' from rep r, ov_2d o));
select pg_temp.chk_true('analytics_report top product shows net units (16 - 7 = 9)',
  (select pg_temp.n(j, 'top_products', '0', 'units') = 9 and pg_temp.n(j, 'top_products', '0', 'refunded_units') = 7 from rep));
select pg_temp.chk_true('analytics_report loyalty: reversed points shown apart from redeemed',
  (select pg_temp.n(j, 'loyalty', 'points_reversed') > 0 and pg_temp.n(j, 'loyalty', 'points_redeemed') = 0 from rep),
  (select (j -> 'loyalty')::text from rep));

-- 5. Order lists and the customer's view ------------------------------------------------
select pg_temp.chk_true('staff_list_orders: o1 partial (100 refunded, 1 unit), o2 full, o5 pending 100, o6 none',
  (select bool_and(case o ->> 'id'
                     when pg_temp.f('o1') then o -> 'refund_summary' ->> 'state' = 'partial' and pg_temp.n(o, 'refund_summary', 'refunded_amount') = 100
                                              and pg_temp.n(o, 'refund_summary', 'refunded_units') = 1
                     when pg_temp.f('o2') then o -> 'refund_summary' ->> 'state' = 'full'
                     when pg_temp.f('o5') then o -> 'refund_summary' ->> 'state' = 'pending' and pg_temp.n(o, 'refund_summary', 'pending_amount') = 100
                     when pg_temp.f('o6') then o -> 'refund_summary' ->> 'state' = 'none'
                     else true end)
   from jsonb_array_elements(pg_temp.j('rf-sa', 'public.staff_list_orders(null, null, null, 300)')) o));
select pg_temp.chk_true('admin_portal_orders carries the same refund summary',
  (select o -> 'refund_summary' ->> 'state' = 'partial' and pg_temp.n(o, 'refund_summary', 'refunded_amount') = 100
   from jsonb_array_elements(pg_temp.j('rf-own', format($q$public.admin_portal_orders(now() - interval '3 days', now(), %L::uuid)$q$, pg_temp.f('ba')))) o
   where o ->> 'id' = pg_temp.f('o1')));
select pg_temp.chk_true('customer sees own refunds: o1 partial 100 with 2 points reversed',
  (select o -> 'state' = '"partial"' and pg_temp.n(o, 'refunded_amount') = 100 and pg_temp.n(o, 'points_reversed') = 2
   from jsonb_array_elements(pg_temp.j('rf-c1', 'public.get_my_order_refunds()')) o where o ->> 'order_id' = pg_temp.f('o1')));
select pg_temp.chk_true('staff_list_refunds: partial flag and returned items',
  (select bool_and(case r ->> 'id' when pg_temp.f('r1') then (r ->> 'is_partial')::boolean
                                   when pg_temp.f('r2') then not (r ->> 'is_partial')::boolean and jsonb_array_length(r -> 'returned') = 2
                                   else true end)
   from jsonb_array_elements(pg_temp.j('rf-sa', 'public.staff_list_refunds()')) r));

-- 6. Loyalty: proportional, exactly once --------------------------------------------------
select pg_temp.chk_true('partial refund (100 of 400) reverses 2 of 8 points, once',
  (select count(*) = 1 and sum(points) = -2 from public.loyalty_transactions where order_id = pg_temp.f('o1') and source = 'order_clawback'));
select pg_temp.chk_true('full refund reverses every point (4)',
  (select sum(points) = -4 from public.loyalty_transactions where order_id = pg_temp.f('o2') and source = 'order_clawback'));
select pg_temp.chk_true('discounted partial refund (90 of 270) reverses round(5 x 1/3) = 2 points',
  (select sum(points) = -2 from public.loyalty_transactions where order_id = pg_temp.f('o3') and source = 'order_clawback'),
  (select string_agg(points::text, ',') from public.loyalty_transactions where order_id = pg_temp.f('o3')));
select pg_temp.chk_true('pending and rejected refunds reverse nothing',
  not exists (select 1 from public.loyalty_transactions where order_id in (pg_temp.f('o5'), pg_temp.f('o6')) and source = 'order_clawback'));
select pg_temp.chk_true('balances still equal the ledger',
  not exists (select 1 from public.loyalty_ledger_drift where firebase_uid in ('rf-c1', 'rf-c2')));

-- 7. Stock ------------------------------------------------------------------------------
select pg_temp.chk_true('POS return restocked only the sellable unit (+1 of 2)',
  (select coalesce(sum(quantity_change), 0) = 1 from public.stock_movements
   where movement_type = 'return_restock' and reference = pg_temp.f('r_pos')));
select pg_temp.chk_true('online refund: only the sellable unit restocked when received (+1), expired recorded only',
  pg_temp.stock('ba') = pg_temp.f('stock_before_receive')::int + 1
  and (select count(*) = 2 from public.refund_returned_items where refund_id = pg_temp.f('r2')));
select pg_temp.chk_true('completed online refunds with nothing received restock nothing (r1, r3, r4)',
  not exists (select 1 from public.stock_movements where movement_type = 'return_restock'
              and reference in (pg_temp.f('r1'), pg_temp.f('r3'), pg_temp.f('r4'))));
select pg_temp.chk('receiving more than was refunded is refused', 'rf-sa',
  format($q$select public.staff_receive_returned_items(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1, 'condition', 'sellable')))$q$,
    pg_temp.f('r2'), pg_temp.f('var')), 'error');

-- 8. No over-refunding --------------------------------------------------------------------
-- As the database owner: the check is a trigger, so it holds for every writer.
do $$
declare v_err text;
begin
  begin
    insert into public.refund_requests (order_id, firebase_uid, reason, amount, payment_method)
    values (pg_temp.f('o6'), 'rf-c2', 'x', 150, 'cash');
  exception when others then v_err := sqlerrm; end;
  perform pg_temp.chk_true('over-refund refused even for the database owner', v_err ilike '%more than what is left%', coalesce(v_err, 'no error'));
end $$;

-- 9. Audit --------------------------------------------------------------------------------
select pg_temp.chk_true('app refund decisions are in the audit log (approve + complete for r1)',
  (select count(*) = 2 from public.staff_audit_logs where entity_id = pg_temp.f('r1') and action in ('refund.approve', 'refund.complete')));
select pg_temp.chk_true('website refund decision logged once (no duplicate from the wrapped call)',
  (select count(*) = 1 from public.staff_audit_logs where entity_id = pg_temp.f('r6') and action like 'refund.%'));

-- Report ------------------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% refund analytics check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
