-- =============================================================================
-- Melai Nuts — analytics, linear-regression forecast, reorder suggestions
-- (migration 20261010020000_analytics_forecasting.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/analytics_forecast_test.sql
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
-- The functions date sales in Asia/Manila; pin the session so current_date agrees
-- (otherwise the suite fails between 00:00 and 08:00 Manila time).
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
create function pg_temp.stock(p_branch text) returns int language sql as $$
  select quantity from public.branch_inventory
  where branch_id = pg_temp.f(p_branch)::uuid and variant_id = pg_temp.f('var')::uuid $$;


-- Fixtures ---------------------------------------------------------------------
-- Synthetic history written straight into the tables (as the database owner):
-- branch A sells units(d) = 20 + 0.5*d (+10 on Saturdays) of one product at
-- P10 per unit on days d = 1..60 before today, except one closed day (d = 45).
insert into public.branches (name, address) values ('AN-TEST A', 'a'), ('AN-TEST B', 'b');
insert into fx select 'ba', id::text from public.branches where name = 'AN-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'AN-TEST B';
insert into public.product_categories (label) values ('AN-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'AN-TEST Nut', 10, 'pack' from public.product_categories where label = 'AN-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 10 from public.products where name = 'AN-TEST Nut';
insert into public.products (category_id, name, price, unit)
select id, 'AN-TEST Slow', 50, 'pack' from public.product_categories where label = 'AN-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 50 from public.products where name = 'AN-TEST Slow';
insert into fx select 'prod', id::text from public.products where name = 'AN-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into fx select 'var_slow', pv.id::text from public.product_variants pv join public.products p on p.id = pv.product_id where p.name = 'AN-TEST Slow';
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 30),
       (pg_temp.f('ba')::uuid, (select product_id from public.product_variants where id = pg_temp.f('var_slow')::uuid), pg_temp.f('var_slow')::uuid, 40);
insert into public.inventory_batches (branch_id, product_id, variant_id, batch_code, received_date, expiration_date, quantity, initial_quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 'AN-EXP-1', current_date - 30, current_date + 3, 10, 10);

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('a-sa', 'Staff A', 'a-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active'),
       ('a-rep', 'Reports A', 'a-rep@test.local', 'staff', pg_temp.f('ba')::uuid, 'active'),
       ('a-own', 'Owner', 'a-own@test.local', 'owner', null, 'active');
insert into public.staff_permission_grants (firebase_uid, permission) values ('a-rep', 'view_reports');
insert into public.customer_profiles (firebase_uid, full_name, email, phone)
values ('a-c1', 'Cust One', 'a-c1@test.local', '0917'), ('a-c2', 'Cust Two', 'a-c2@test.local', '0918');

create function pg_temp.units_for(p_day int) returns int language sql immutable as $$
  select 20 + p_day / 2 + case when extract(dow from (current_date - 61 + p_day)) = 6 then 10 else 0 end
$$;
-- d=1 is 60 days ago; d=60 is yesterday. Customer alternates so both repeat.
do $$
declare d int; v_id text; v_u int; v_at timestamptz;
begin
  for d in 1..60 loop
    continue when d = 45;
    v_u := pg_temp.units_for(d);
    v_at := ((current_date - 61 + d)::timestamp + interval '10 hours') at time zone 'Asia/Manila';
    insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method, created_at)
    values (case when d % 2 = 0 then 'a-c1' else 'a-c2' end, pg_temp.f('ba')::uuid, 'AN-TEST A', false, 'completed',
            v_u * 10, 0, 0, v_u * 10, 'Cash (In-store)', v_at)
    returning id into v_id;
    insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
    values (v_id, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 'AN-TEST Nut', 'Regular', v_u, 10);
    insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number, created_at)
    values (v_id, case when d % 2 = 0 then 'a-c1' else 'a-c2' end, 'cash', 'success', v_u * 10, v_id, v_at);
    if d = 60 then insert into fx values ('last_order', v_id); end if;
  end loop;
end $$;

-- A pending (unverified) online order yesterday: must NOT count as a sale.
do $$
declare v_id text;
begin
  insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method, created_at)
  values ('a-c1', pg_temp.f('ba')::uuid, 'AN-TEST A', false, 'pending', 1000, 0, 0, 1000, 'GCash E-Wallet', now() - interval '1 day')
  returning id into v_id;
  insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
  values (v_id, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 'AN-TEST Nut', 'Regular', 100, 10);
  insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number) values (v_id, 'a-c1', 'gcash', 'pending', 1000, v_id);
end $$;

-- A completed refund of 5 units on yesterday's order, completed today.
do $$
declare v_r text;
begin
  insert into public.refund_requests (order_id, firebase_uid, reason, amount, payment_method, status)
  values (pg_temp.f('last_order'), 'a-c1', 'Damaged', 50, 'Cash (In-store)', 'completed') returning id into v_r;
  insert into public.refund_items (refund_request_id, product_name, variant_label, quantity, unit_price)
  values (v_r, 'AN-TEST Nut', 'Regular', 5, 10);
  insert into public.refund_status_events (refund_request_id, status) values (v_r, 'completed');
end $$;

-- 1. Access ------------------------------------------------------------------------
select pg_temp.chk('staff without view_reports cannot read the report', 'a-sa',
  format($q$select public.analytics_report(current_date - 7, current_date, %L::uuid)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('staff with view_reports reads own branch', 'a-rep',
  format($q$select public.analytics_report(current_date - 7, current_date, %L::uuid)$q$, pg_temp.f('ba')), 'ok');
select pg_temp.chk('staff with view_reports cannot read another branch', 'a-rep',
  format($q$select public.analytics_report(current_date - 7, current_date, %L::uuid)$q$, pg_temp.f('bb')), 'error');
select pg_temp.chk('staff with view_reports cannot read all branches', 'a-rep',
  'select public.analytics_report(current_date - 7, current_date, null)', 'error');
select pg_temp.chk('customer cannot read reports', 'a-c1', 'select public.analytics_report(current_date - 7, current_date, null)', 'error');
select pg_temp.chk('anon cannot read reports', null, 'select public.analytics_report(current_date - 7, current_date, null)', 'error');
select pg_temp.chk('range over 400 days refused', 'a-own', 'select public.analytics_report(current_date - 500, current_date, null)', 'error');
select pg_temp.chk_true('nobody reads the verified-orders view directly',
  pg_temp.visible('a-own', 'select count(*) from public.analytics_verified_orders') = 0);

-- 2. Report numbers ------------------------------------------------------------------
create temp table rep as select pg_temp.call_as('a-own',
  format($q$select public.analytics_report(current_date - 60, current_date, %L::uuid)::text$q$, pg_temp.f('ba')))::jsonb as j;
create temp table expect as
select sum(pg_temp.units_for(d)) * 10 as gross, count(*) as n from generate_series(1, 60) d where d <> 45;
select pg_temp.chk_true('gross = sum of verified subtotals (pending order excluded)',
  (select (j -> 'summary' ->> 'gross_sales')::numeric from rep) = (select gross from expect),
  (select (j -> 'summary')::text from rep));
select pg_temp.chk_true('verified order count = 59', (select (j -> 'summary' ->> 'verified_orders')::int from rep) = 59);
select pg_temp.chk_true('refunds = 50, net = gross - refunds',
  (select (j -> 'summary' ->> 'refunds')::numeric = 50
          and (j -> 'summary' ->> 'net_sales')::numeric = (select gross from expect) - 50 from rep));
select pg_temp.chk_true('pending payments reported apart (1 order, 1000)',
  (select (j -> 'summary' -> 'pending_payments' ->> 'count')::int = 1
          and (j -> 'summary' -> 'pending_payments' ->> 'amount')::numeric = 1000 from rep));
select pg_temp.chk_true('refund rate = refunds / (gross - discounts)',
  (select (j -> 'summary' ->> 'refund_rate')::numeric = round(50::numeric / (select gross from expect), 4) from rep),
  (select (j -> 'summary' ->> 'refund_rate') || ' vs ' || round(50::numeric / (select gross from expect), 4) from rep));
select pg_temp.chk_true('by_day has 61 days and sums to gross',
  (select jsonb_array_length(j -> 'by_day') = 61
          and (select sum((e ->> 'gross_sales')::numeric) from jsonb_array_elements(j -> 'by_day') e) = (select gross from expect) from rep));
select pg_temp.chk_true('the closed day shows 0 orders',
  (select (e ->> 'orders')::int = 0 from rep, jsonb_array_elements(j -> 'by_day') e where (e ->> 'date')::date = current_date - 16));
select pg_temp.chk_true('payment method breakdown: all cash',
  (select jsonb_array_length(j -> 'by_payment_method') = 1 and j -> 'by_payment_method' -> 0 ->> 'method' = 'cash' from rep));
select pg_temp.chk_true('top product is the nut', (select j -> 'top_products' -> 0 ->> 'product' = 'AN-TEST Nut' from rep));
select pg_temp.chk_true('slow mover: in-stock product with 0 sales',
  (select j -> 'slow_movers' -> 0 ->> 'product' = 'AN-TEST Slow' and (j -> 'slow_movers' -> 0 ->> 'units_sold')::int = 0 from rep));
select pg_temp.chk_true('repeat customers = 2 of 2 active',
  (select (j -> 'customers' ->> 'repeat_customers')::int = 2 and (j -> 'customers' ->> 'active_customers')::int = 2 from rep));
select pg_temp.chk_true('category breakdown present', (select j -> 'by_category' -> 0 ->> 'category' = 'AN-TEST Cat' from rep));
select pg_temp.chk_true('inventory block counts units on hand (70)',
  (select (j -> 'inventory' ->> 'units_on_hand')::int = 70 from rep));
select pg_temp.chk_true('definitions included', (select j -> 'definitions' ? 'net_sales' from rep));

-- 3. Forecast -------------------------------------------------------------------------
create temp table fc as select pg_temp.call_as('a-own',
  format($q$select public.analytics_sales_forecast(%L::uuid, %L::uuid, 'units', 'day', current_date - 60, current_date - 6, 7, 14)::text$q$,
         pg_temp.f('ba'), pg_temp.f('var')))::jsonb as j;
select pg_temp.chk_true('forecast status ok', (select j ->> 'status' = 'ok' from fc), (select left(j::text, 300) from fc));
-- The series is net of refunds, but the refunded day (yesterday) is outside this window.
select pg_temp.chk_true('recovers the slope (0.5 units/day)',
  (select abs((j -> 'model' ->> 'slope_per_period')::numeric - 0.5) < 0.06 from fc), (select (j -> 'model')::text from fc));
select pg_temp.chk_true('Saturday effect found (largest weekday effect is Saturday)',
  (select (j -> 'model' -> 'weekday_effects' ->> 6)::numeric
          = (select max(e::numeric) from jsonb_array_elements_text(j -> 'model' -> 'weekday_effects') e) from fc));
select pg_temp.chk_true('hold-out MAE and RMSE reported and small (< 1 unit)',
  (select (j -> 'evaluation' ->> 'mae')::numeric < 1 and (j -> 'evaluation' ->> 'rmse')::numeric < 1 from fc),
  (select (j -> 'evaluation')::text from fc));
select pg_temp.chk_true('model beats the naive mean baseline', (select (j -> 'evaluation' ->> 'beats_baseline')::boolean from fc));
select pg_temp.chk_true('hold-out is the LAST 14 observed periods (chronological)',
  (select jsonb_array_length(j -> 'evaluation' -> 'points') = 14
      and (j -> 'evaluation' -> 'points' -> 13 ->> 'period')::date = current_date - 6 from fc));
select pg_temp.chk_true('7 forecast periods, all after the training window',
  (select jsonb_array_length(j -> 'forecast') = 7 and (j -> 'forecast' -> 0 ->> 'period')::date = current_date - 5 from fc));
select pg_temp.chk_true('forecast close to the true future values',
  (select bool_and(abs((e ->> 'predicted')::numeric - pg_temp.units_for(61 - (current_date - (e ->> 'period')::date)::int)) < 2)
   from fc, jsonb_array_elements(j -> 'forecast') e));
select pg_temp.chk_true('intervals bracket the prediction',
  (select bool_and((e ->> 'lower')::numeric <= (e ->> 'predicted')::numeric and (e ->> 'predicted')::numeric <= (e ->> 'upper')::numeric)
   from fc, jsonb_array_elements(j -> 'forecast') e));
select pg_temp.chk_true('closed day left out of training (54 observed of 55 days)',
  (select (j ->> 'observed_periods')::int = 54 from fc));
select pg_temp.chk_true('notes explain it is an estimate', (select j -> 'notes' ->> 0 like 'Forecasts are estimates%' from fc));

-- No leakage: a huge sale AFTER the training window must not change the model.
do $$
declare v_id text;
begin
  insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method, created_at)
  values ('a-c1', pg_temp.f('ba')::uuid, 'AN-TEST A', false, 'completed', 99990, 0, 0, 99990, 'Cash (In-store)',
          ((current_date - 3)::timestamp + interval '11 hours') at time zone 'Asia/Manila')
  returning id into v_id;
  insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
  values (v_id, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 'AN-TEST Nut', 'Regular', 9999, 10);
  insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number) values (v_id, 'a-c1', 'cash', 'success', 99990, v_id);
end $$;
create temp table fc2 as select pg_temp.call_as('a-own',
  format($q$select public.analytics_sales_forecast(%L::uuid, %L::uuid, 'units', 'day', current_date - 60, current_date - 6, 7, 14)::text$q$,
         pg_temp.f('ba'), pg_temp.f('var')))::jsonb as j;
select pg_temp.chk_true('data after train_to does not change the model (no leakage)',
  (select j -> 'model' from fc2) = (select j -> 'model' from fc) and (select j -> 'forecast' from fc2) = (select j -> 'forecast' from fc));
select pg_temp.chk_true('train_to cannot reach today (incomplete day)',
  (pg_temp.call_as('a-own', format($q$select public.analytics_sales_forecast(%L::uuid, null, 'units', 'day', current_date - 60, current_date + 5, 3)::text$q$,
     pg_temp.f('ba')))::jsonb ->> 'train_to')::date = current_date - 1);

select pg_temp.chk_true('weekly forecast works',
  (pg_temp.call_as('a-own', format($q$select public.analytics_sales_forecast(%L::uuid, null, 'revenue', 'week', current_date - 70, null, 4, 2)::text$q$,
     pg_temp.f('ba')))::jsonb ->> 'status') in ('ok', 'insufficient_data'));
select pg_temp.chk_true('branch with no history -> insufficient_data, not a made-up forecast',
  (pg_temp.call_as('a-own', format($q$select public.analytics_sales_forecast(%L::uuid)::text$q$, pg_temp.f('bb')))::jsonb ->> 'status') = 'insufficient_data');
select pg_temp.chk('horizon over 90 days refused', 'a-own',
  format($q$select public.analytics_sales_forecast(%L::uuid, null, 'units', 'day', null, null, 200)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('staff without view_reports cannot forecast', 'a-sa',
  format($q$select public.analytics_sales_forecast(%L::uuid)$q$, pg_temp.f('ba')), 'error');

-- Saved forecast compared with what happened.
create temp table fc3 as select pg_temp.call_as('a-rep',
  format($q$select public.analytics_sales_forecast(%L::uuid, %L::uuid, 'units', 'day', current_date - 60, current_date - 11, 5, 14, true)::text$q$,
         pg_temp.f('ba'), pg_temp.f('var')))::jsonb as j;
select pg_temp.chk_true('saved forecast run id returned', (select j ->> 'run_id' is not null from fc3));
create temp table acc as select pg_temp.call_as('a-rep',
  format($q$select public.analytics_forecast_accuracy(%L::uuid)::text$q$, (select j ->> 'run_id' from fc3)))::jsonb as j;
select pg_temp.chk_true('accuracy: 5 periods with actuals, small MAE',
  (select (j ->> 'periods_with_actuals')::int = 5 and (j ->> 'mae')::numeric < 2 from acc), (select left(j::text, 300) from acc));
select pg_temp.chk('other staff without reports cannot read the saved run', 'a-sa',
  format($q$select public.analytics_forecast_accuracy(%L::uuid)$q$, (select j ->> 'run_id' from fc3)), 'error');

-- 4. Reorder suggestions and expiring batches --------------------------------------------
create temp table ro as select pg_temp.call_as('a-sa',
  format($q$select public.staff_reorder_suggestions(%L::uuid, 28, 7, 3, 14)::text$q$, pg_temp.f('ba')))::jsonb as j;
select pg_temp.chk_true('fast seller needs reorder with a positive suggested quantity',
  (select (e ->> 'needs_reorder')::boolean and (e ->> 'suggested_quantity')::int > 0
   from ro, jsonb_array_elements(j -> 'items') e where e ->> 'product' = 'AN-TEST Nut'), (select left(j::text, 400) from ro));
select pg_temp.chk_true('units expiring within lead time are not counted as usable (30 - 10 = 20)',
  (select (e ->> 'usable')::int = 20 and (e ->> 'expiring_within_lead_time')::int = 10
   from ro, jsonb_array_elements(j -> 'items') e where e ->> 'product' = 'AN-TEST Nut'));
select pg_temp.chk_true('product with no sales is not suggested',
  (select not (e ->> 'needs_reorder')::boolean from ro, jsonb_array_elements(j -> 'items') e where e ->> 'product' = 'AN-TEST Slow'));
select pg_temp.chk('other branch staff cannot read reorder suggestions', 'a-sa',
  format($q$select public.staff_reorder_suggestions(%L::uuid)$q$, pg_temp.f('bb')), 'error');
select pg_temp.chk_true('expiring batch listed with days left',
  (select (e ->> 'days_left')::int = 3 from jsonb_array_elements(pg_temp.call_as('a-sa',
     format($q$select public.staff_expiring_batches(%L::uuid, 7)::text$q$, pg_temp.f('ba')))::jsonb) e where e ->> 'batch_code' = 'AN-EXP-1'));

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% analytics check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
