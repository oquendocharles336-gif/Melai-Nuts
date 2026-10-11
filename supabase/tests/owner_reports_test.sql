-- =============================================================================
-- Melai Nuts — owner reports (migration 20261024000000_owner_reports.sql)
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/owner_reports_test.sql
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


insert into public.branches (name, address, delivery_fee) values ('OR-TEST Shop', 'a', 0);
insert into fx select 'shop', id::text from public.branches where name = 'OR-TEST Shop';
insert into public.product_categories (label) values ('OR-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'OR-TEST Nut', 100, 'pack' from public.product_categories where label = 'OR-TEST Cat';
insert into fx select 'prod', id::text from public.products where name = 'OR-TEST Nut';
insert into public.product_variants (product_id, label, price) values
  (pg_temp.f('prod')::uuid, 'Costed', 100), (pg_temp.f('prod')::uuid, 'NoCost', 100);
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid and label = 'Costed';
insert into fx select 'var2', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid and label = 'NoCost';
insert into public.product_variant_costs (variant_id, cost_price) values (pg_temp.f('var')::uuid, 60);
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity) values
  (pg_temp.f('shop')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 10),
  (pg_temp.f('shop')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var2')::uuid, 4);
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values ('or-c1', 'OR Cust', 'or-c1@test.local', '09170000081');
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status) values
  ('or-own', 'Owner', 'or-own@test.local', 'owner', null, 'active'),
  ('or-st', 'Staff', 'or-st@test.local', 'staff', pg_temp.f('shop')::uuid, 'active');
insert into fx values ('day', ((now() at time zone 'Asia/Manila')::date - 1)::text);

create function pg_temp.mk_order(p_variant text, p_label text, p_units int, p_discount numeric) returns text language plpgsql as $$
declare v_id text; v_total numeric := p_units * 100 - p_discount;
  v_at timestamptz := (pg_temp.f('day')::date + time '12:00') at time zone 'Asia/Manila';
begin
  insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method, created_at)
  values ('or-c1', pg_temp.f('shop')::uuid, 'OR-TEST Shop', false, 'confirmed', p_units * 100, p_discount, 0, v_total, 'Cash on Counter Pickup', v_at)
  returning id into v_id;
  insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
  values (v_id, pg_temp.f('prod')::uuid, pg_temp.f(p_variant)::uuid, 'OR-TEST Nut', p_label, p_units, 100);
  insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number, created_at)
  values (v_id, 'or-c1', 'cash', 'success', v_total, 'REF-' || v_id, v_at);
  update public.orders set status = 'completed' where id = v_id;
  return v_id;
end $$;
select pg_temp.mk_order('var', 'Costed', 3, 30);   -- net 270, cost 3 x 60 = 180, profit 90
select pg_temp.mk_order('var2', 'NoCost', 2, 0);   -- net 200, no cost

-- Profit report ----------------------------------------------------------------
select pg_temp.chk('staff cannot read the profit report', 'or-st',
  format('select public.owner_profit_report(%L::date, %L::date)', pg_temp.f('day'), pg_temp.f('day')), 'error');
select pg_temp.chk('signed out cannot', null,
  format('select public.owner_profit_report(%L::date, %L::date)', pg_temp.f('day'), pg_temp.f('day')), 'error');
insert into fx select 'rep', pg_temp.call_as('or-own',
  format('select public.owner_profit_report(%L::date, %L::date, %L::uuid)::text', pg_temp.f('day'), pg_temp.f('day'), pg_temp.f('shop')));
select pg_temp.chk_true('costed line: net 270, cogs 180, profit 90, margin 33.3',
  exists (select 1 from jsonb_array_elements(pg_temp.f('rep')::jsonb -> 'rows') r
           where r ->> 'variant' = 'Costed' and (r ->> 'net_sales')::numeric = 270 and (r ->> 'cogs')::numeric = 180
             and (r ->> 'profit')::numeric = 90 and (r ->> 'margin_percent')::numeric = 33.3), pg_temp.f('rep'));
select pg_temp.chk_true('uncosted line shows Not set, never zero cost',
  exists (select 1 from jsonb_array_elements(pg_temp.f('rep')::jsonb -> 'rows') r
           where r ->> 'variant' = 'NoCost' and r -> 'cogs' = 'null'::jsonb and r -> 'profit' = 'null'::jsonb));
select pg_temp.chk_true('totals keep uncosted sales apart',
  (pg_temp.f('rep')::jsonb #>> '{totals,net_sales}')::numeric = 470
  and (pg_temp.f('rep')::jsonb #>> '{totals,profit}')::numeric = 90
  and (pg_temp.f('rep')::jsonb #>> '{totals,options_without_cost}')::int = 1
  and (pg_temp.f('rep')::jsonb #>> '{totals,net_sales_without_cost}')::numeric = 200);
select pg_temp.chk_true('the cost basis is stated', pg_temp.f('rep')::jsonb ->> 'cost_basis' like 'current cost%');
select pg_temp.chk('a reversed range is refused', 'or-own',
  format('select public.owner_profit_report(%L::date, %L::date - 2)', pg_temp.f('day'), pg_temp.f('day')), 'error');

-- Inventory valuation ----------------------------------------------------------
select pg_temp.chk('staff cannot read the valuation', 'or-st', 'select public.owner_inventory_valuation()', 'error');
insert into fx select 'val', pg_temp.call_as('or-own', format('select public.owner_inventory_valuation(%L::uuid)::text', pg_temp.f('shop')));
select pg_temp.chk_true('valued at current cost: 10 x 60 = 600; 4 units without cost',
  (pg_temp.f('val')::jsonb #>> '{totals,value}')::numeric = 600
  and (pg_temp.f('val')::jsonb #>> '{totals,units}')::int = 14
  and (pg_temp.f('val')::jsonb #>> '{totals,units_without_cost}')::int = 4, pg_temp.f('val'));

-- Daily digest -----------------------------------------------------------------
select pg_temp.chk('apps cannot trigger the digest', 'or-own', 'select public.enqueue_owner_daily_digest()', 'error');
select pg_temp.chk_true('one digest per owner', public.enqueue_owner_daily_digest(pg_temp.f('day')::date) >= 1);
select pg_temp.chk_true('never twice for the same day', public.enqueue_owner_daily_digest(pg_temp.f('day')::date) = 0);
select pg_temp.chk_true('it carries yesterday''s real figures and is pushed',
  exists (select 1 from public.staff_notifications where recipient_uid = 'or-own' and reference = 'digest:' || pg_temp.f('day')
            and body like '%net ₱%' and body like '%Stock:%')
  and exists (select 1 from public.push_outbox where firebase_uid = 'or-own' and title like 'Daily summary%'));
select pg_temp.chk_true('staff do not get the owner digest',
  not exists (select 1 from public.staff_notifications where recipient_uid = 'or-st' and reference like 'digest:%'));

select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$ declare n int; begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% owner-report check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
