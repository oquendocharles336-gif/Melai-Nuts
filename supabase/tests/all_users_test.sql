-- =============================================================================
-- Melai Nuts — owner_all_users() (20261014000000_admin_portal_all_users.sql) test suite
-- =============================================================================
-- Proves the all-users read is OWNER ONLY, returns staff, drivers and customers,
-- never the walk-in placeholder, counts only paid orders in the paid total,
-- searches name / email / phone / card number, and caps the customer list
-- while still reporting how many matched.
--
-- HOW TO RUN (DEV / staging only):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/all_users_test.sql
-- One transaction, rolled back at the end. Raises if any check fails.
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
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
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

-- The owner's answer, searched or not.
create function pg_temp.all_users(p_search text default null, p_limit int default 500) returns jsonb language sql as $$
  select pg_temp.call_as('au-own', format('select public.owner_all_users(%L, %s)::text', p_search, p_limit))::jsonb
$$;

-- Fixtures ------------------------------------------------------------------
insert into public.branches (name, address, supports_delivery, supports_pickup, delivery_fee)
values ('AU-TEST A', 'a', true, true, 30);
insert into fx select 'ba', id::text from public.branches where name = 'AU-TEST A';

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('au-own', 'AU Owner', 'au-own@test.local', 'owner', null, 'active'),
       ('au-sa', 'AU Staff', 'au-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active'),
       ('au-off', 'AU Former owner', 'au-off@test.local', 'owner', null, 'inactive');

insert into public.drivers (firebase_uid, full_name, email, phone, branch_id, vehicle, account_status)
values ('au-drv', 'AU Rider', 'au-drv@test.local', '09170000009', pg_temp.f('ba')::uuid, 'Motorcycle', 'active');

insert into public.customer_profiles (firebase_uid, full_name, email, phone, rfid_card_number, default_branch_id)
values ('walk-in', 'Walk-in', '', '', null, null)
on conflict (firebase_uid) do nothing;
insert into public.customer_profiles (firebase_uid, full_name, email, phone, rfid_card_number, default_branch_id, created_at)
values ('au-c1', 'AU Buyer One', 'au-c1@test.local', '09181112222', 'AU-CARD-77', pg_temp.f('ba')::uuid, now() - interval '2 days'),
       ('au-c2', 'AU Buyer Two', 'au-c2@test.local', '', null, null, now() - interval '1 day');
insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points) values ('au-c1', 42, 42)
on conflict (firebase_uid) do update set points_balance = 42;

-- au-c1: one PAID order (500), one PENDING order (300), one CANCELLED order (900).
do $$
declare v_id text; r record;
begin
  for r in select * from (values (500, 'completed', 'success'), (300, 'pending', 'pending'), (900, 'cancelled', 'failed')) t(total, status, pay) loop
    insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method)
    values ('au-c1', pg_temp.f('ba')::uuid, 'AU-TEST A', false, r.status, r.total, 0, 0, r.total, 'Cash (In-store)')
    returning id into v_id;
    insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number)
    values (v_id, 'au-c1', 'cash', r.pay, r.total, v_id);
  end loop;
end $$;

-- 1. Who may call it ----------------------------------------------------------
select pg_temp.chk('owner can read all users', 'au-own', $q$select public.owner_all_users()$q$, 'ok');
select pg_temp.chk('staff cannot read all users', 'au-sa', $q$select public.owner_all_users()$q$, 'error');
select pg_temp.chk('driver cannot read all users', 'au-drv', $q$select public.owner_all_users()$q$, 'error');
select pg_temp.chk('customer cannot read all users', 'au-c1', $q$select public.owner_all_users()$q$, 'error');
select pg_temp.chk('deactivated owner cannot read all users', 'au-off', $q$select public.owner_all_users()$q$, 'error');
select pg_temp.chk('anonymous cannot read all users', null, $q$select public.owner_all_users()$q$, 'error');

-- 2. The three lists -----------------------------------------------------------
select pg_temp.chk_true('staff list has owner, staff and the inactive owner',
  (select count(*) from jsonb_array_elements(pg_temp.all_users()->'staff') e where e->>'firebase_uid' like 'au-%') = 3);
select pg_temp.chk_true('staff rows carry branch name and account status',
  (select e->>'branch_name' = 'AU-TEST A' and e->>'account_status' = 'active'
   from jsonb_array_elements(pg_temp.all_users()->'staff') e where e->>'firebase_uid' = 'au-sa'));
select pg_temp.chk_true('driver listed with branch, vehicle and open runs',
  (select e->>'branch_name' = 'AU-TEST A' and e->>'vehicle' = 'Motorcycle' and (e->>'active_runs')::int = 0
   from jsonb_array_elements(pg_temp.all_users()->'drivers') e where e->>'firebase_uid' = 'au-drv'));
select pg_temp.chk_true('both customers listed',
  (select count(*) from jsonb_array_elements(pg_temp.all_users()->'customers') e where e->>'firebase_uid' in ('au-c1', 'au-c2')) = 2);
select pg_temp.chk_true('the walk-in placeholder is never listed',
  not exists (select 1 from jsonb_array_elements(pg_temp.all_users()->'customers') e where e->>'firebase_uid' = 'walk-in'));
select pg_temp.chk_true('customers are newest first (au-c2 before au-c1)',
  (select min(ord) filter (where e->>'firebase_uid' = 'au-c2') < min(ord) filter (where e->>'firebase_uid' = 'au-c1')
   from jsonb_array_elements(pg_temp.all_users()->'customers') with ordinality x(e, ord)));

-- 3. Customer figures ------------------------------------------------------------
select pg_temp.chk_true('orders count excludes the cancelled order (2)',
  (select (e->>'orders')::int from jsonb_array_elements(pg_temp.all_users()->'customers') e where e->>'firebase_uid' = 'au-c1') = 2);
select pg_temp.chk_true('paid total counts only the paid order (500)',
  (select (e->>'paid_total')::numeric from jsonb_array_elements(pg_temp.all_users()->'customers') e where e->>'firebase_uid' = 'au-c1') = 500);
select pg_temp.chk_true('loyalty balance and card number come through',
  (select (e->>'points_balance')::int = 42 and e->>'card_number' = 'AU-CARD-77'
   from jsonb_array_elements(pg_temp.all_users()->'customers') e where e->>'firebase_uid' = 'au-c1'));
select pg_temp.chk_true('a customer with no orders has 0 orders, 0 paid and no last order',
  (select (e->>'orders')::int = 0 and (e->>'paid_total')::numeric = 0 and e->'last_order_at' = 'null'::jsonb
   from jsonb_array_elements(pg_temp.all_users()->'customers') e where e->>'firebase_uid' = 'au-c2'));
select pg_temp.chk_true('empty phone is returned as null',
  (select e->'phone' = 'null'::jsonb from jsonb_array_elements(pg_temp.all_users()->'customers') e where e->>'firebase_uid' = 'au-c2'));

-- 4. Search and limit ---------------------------------------------------------------
select pg_temp.chk_true('search by card number finds au-c1 only',
  (select string_agg(e->>'firebase_uid', ',') from jsonb_array_elements(pg_temp.all_users('au-card-77')->'customers') e) = 'au-c1'
  and (pg_temp.all_users('au-card-77')->>'customers_total')::int = 1);
select pg_temp.chk_true('search by phone finds au-c1',
  (select count(*) from jsonb_array_elements(pg_temp.all_users('0918111')->'customers') e where e->>'firebase_uid' = 'au-c1') = 1);
select pg_temp.chk_true('search is case-insensitive on name',
  (select count(*) from jsonb_array_elements(pg_temp.all_users('  BUYER two ')->'customers') e) = 1);
select pg_temp.chk_true('limit 1 returns one customer but the total still counts every match',
  jsonb_array_length(pg_temp.all_users('au buyer', 1)->'customers') = 1
  and (pg_temp.all_users('au buyer', 1)->>'customers_total')::int = 2);
select pg_temp.chk_true('a zero or negative limit is raised to 1',
  jsonb_array_length(pg_temp.all_users('au buyer', 0)->'customers') = 1);

-- 5. Privileges -----------------------------------------------------------------------
select pg_temp.chk_true('anon has no EXECUTE on owner_all_users',
  not has_function_privilege('anon', 'public.owner_all_users(text, int)', 'execute'));

-- Report ---------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where passed) as passed, count(*) filter (where not passed) as failed, count(*) as total from results;

do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% all-users check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
