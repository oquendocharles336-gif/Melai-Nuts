-- =============================================================================
-- Melai Nuts — panel criteria checks for migrations 20261025000000 … 20261025040000
--   1  input rules enforced by the database (CHECK constraints, phone format)
--   2  rate limits (refunds, addresses), least-privilege grants, RLS everywhere,
--      owner-only functions
--   9  paged lists with hard limits
--   11 Terms / Privacy acceptance record
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/panel_compliance_test.sql
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
create function pg_temp.call_as(p_uid text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.act_as(p_uid);
  begin execute p_sql into v;
  exception when others then perform pg_temp.back_to_admin(); raise; end;
  perform pg_temp.back_to_admin();
  return v;
end $$;
-- Runs p_sql as the database owner but with p_uid's verified token (triggers see the caller).
create function pg_temp.owner_sql_as(p_uid text, p_sql text) returns text language plpgsql as $$
declare v_err text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  begin execute p_sql; exception when others then v_err := sqlerrm; end;
  perform set_config('request.jwt.claims', '', true);
  return v_err;
end $$;
create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;
create function pg_temp.f(p_k text) returns text language sql as $$ select v from fx where k = p_k $$;
grant execute on function pg_temp.f(text) to public;
create function pg_temp.fails(p_sql text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end $$;

-- Fixtures ---------------------------------------------------------------------
insert into public.branches (name, address, delivery_fee) values ('PC-TEST A', 'a street', 0);
insert into fx select 'ba', id::text from public.branches where name = 'PC-TEST A';
insert into public.product_categories (label) values ('PC-TEST Cat');
insert into fx select 'cat', id::text from public.product_categories where label = 'PC-TEST Cat';
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status) values
  ('pc-own', 'Owner PC', 'pc-own@test.local', 'owner', null, 'active'),
  ('pc-sa', 'Staff PC', 'pc-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active');

-- 1. Input rules in the database ---------------------------------------------------
select pg_temp.chk_true('product name of 1 character is refused',
  pg_temp.fails(format($q$insert into public.products (category_id, name, price, unit) values (%L, 'A', 10, 'pack')$q$, pg_temp.f('cat'))));
select pg_temp.chk_true('product price 0 is refused',
  pg_temp.fails(format($q$insert into public.products (category_id, name, price, unit) values (%L, 'PC Nuts', 0, 'pack')$q$, pg_temp.f('cat'))));
insert into public.products (category_id, name, price, unit) values (pg_temp.f('cat')::uuid, 'PC-TEST Nuts', 100, 'pack');
insert into fx select 'prod', id::text from public.products where name = 'PC-TEST Nuts';
select pg_temp.chk_true('variant SKU with a space is refused',
  pg_temp.fails(format($q$insert into public.product_variants (product_id, label, price, sku) values (%L, 'Big', 10, 'SKU 1')$q$, pg_temp.f('prod'))));
select pg_temp.chk_true('negative stock is refused',
  pg_temp.fails(format($q$insert into public.branch_inventory (branch_id, product_id, quantity) values (%L, %L, -1)$q$, pg_temp.f('ba'), pg_temp.f('prod'))));
select pg_temp.chk_true('voucher code with spaces is refused',
  pg_temp.fails($q$insert into public.vouchers (code, description, discount_type, discount_value) values ('BAD CODE', 'x', 'fixed', 5)$q$));

insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('pc-c1', 'PC Customer', 'pc-c1@test.local', '0917 000 0051'),
  ('pc-c2', 'PC Customer 2', 'pc-c2@test.local', '');
select pg_temp.chk_true('a PH mobile is stored as E.164',
  (select phone = '+639170000051' from public.customer_profiles where firebase_uid = 'pc-c1'));
select pg_temp.chk_true('letters in a phone number are refused',
  pg_temp.fails($q$update public.customer_profiles set phone = 'call me' where firebase_uid = 'pc-c2'$q$));
select pg_temp.chk_true('postal code must be 4 digits',
  pg_temp.fails($q$insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city, postal_code)
                   values ('pc-c1', 'Ana', '09170000051', 'Blk 1 Lot 2', 'Calamba', '40271')$q$));
select pg_temp.chk_true('normalize_ph_mobile keeps landlines as typed',
  public.normalize_ph_mobile(' (049) 123 4567 ') = '(049) 123 4567' and public.normalize_ph_mobile('639171234567') = '+639171234567');

-- 2a. Rate limits --------------------------------------------------------------------
select set_config('melai.force_rate_limits', 'on', true);
do $$ begin
  for i in 1..20 loop
    perform pg_temp.owner_sql_as('pc-c1', format($q$insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city)
      values ('pc-c1', 'Ana', '09170000051', 'Blk %s Lot 2', 'Calamba')$q$, i));
  end loop;
end $$;
select pg_temp.chk_true('20 new addresses in an hour are accepted',
  (select count(*) = 20 from public.customer_addresses where firebase_uid = 'pc-c1'));
select pg_temp.chk_true('the 21st new address in an hour is refused',
  pg_temp.owner_sql_as('pc-c1', $q$insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city)
      values ('pc-c1', 'Ana', '09170000051', 'Blk 21 Lot 2', 'Calamba')$q$) like 'Too many new addresses%');
select pg_temp.chk_true('another customer is not affected',
  pg_temp.owner_sql_as('pc-c2', $q$insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city)
      values ('pc-c2', 'Ben', '09170000052', 'Blk 1 Lot 9', 'Calamba')$q$) is null);

-- Refund requests: 3 per 30 minutes per account (rows inserted directly; the transaction is
-- rolled back, so the commit-time order checks never run).
insert into public.orders (id, firebase_uid, branch_id, branch_name, status, subtotal, discount, delivery_fee, total, payment_method)
select 'PC-ORD-' || g, 'pc-c1', pg_temp.f('ba')::uuid, 'PC-TEST A', 'completed', 100, 0, 0, 100, 'Cash on Counter Pickup'
  from generate_series(1, 4) g;
do $$ begin
  for i in 1..3 loop
    perform pg_temp.owner_sql_as('pc-c1', format($q$insert into public.refund_requests (order_id, firebase_uid, reason, amount, payment_method)
      values ('PC-ORD-%s', 'pc-c1', 'Damaged items', 50, 'Cash')$q$, i));
  end loop;
end $$;
select pg_temp.chk_true('3 refund requests are accepted',
  (select count(*) = 3 from public.refund_requests where firebase_uid = 'pc-c1'));
select pg_temp.chk_true('the 4th refund request within 30 minutes is refused',
  pg_temp.owner_sql_as('pc-c1', $q$insert into public.refund_requests (order_id, firebase_uid, reason, amount, payment_method)
      values ('PC-ORD-4', 'pc-c1', 'Damaged items', 50, 'Cash')$q$) like 'Too many refund requests%');
select set_config('melai.force_rate_limits', '', true);

-- 2b. Least privilege -------------------------------------------------------------------
select pg_temp.chk_true('anon has no INSERT/UPDATE/DELETE on any public table',
  not exists (select 1 from information_schema.role_table_grants
               where table_schema = 'public' and grantee = 'anon'
                 and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')));
select pg_temp.chk_true('anon reads only the public catalog tables',
  not exists (select 1 from information_schema.role_table_grants
               where table_schema = 'public' and grantee = 'anon' and privilege_type = 'SELECT'
                 and table_name not in ('branches', 'branch_inventory', 'products', 'product_variants',
                                        'product_categories', 'promotions', 'rewards', 'payment_settings')),
  (select string_agg(table_name, ', ') from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'anon' and privilege_type = 'SELECT'));
select pg_temp.chk_true('every public table has Row Level Security',
  not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
               where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  (select string_agg(c.relname, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity));
select pg_temp.chk_true('anon cannot run pgcrypto (crypt / digest / pgp_*)',
  not has_function_privilege('anon', 'public.crypt(text, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.pgp_sym_decrypt(bytea, text)', 'execute'));
select pg_temp.chk_true('internal helper functions are not callable by the app',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname like '\_%' and p.proname <> '_phone_chars_ok'
                 and has_function_privilege('authenticated', p.oid, 'execute')
                 and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')),
  (select string_agg(p.proname, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like '\_%' and p.proname <> '_phone_chars_ok'
      and has_function_privilege('authenticated', p.oid, 'execute')));
select pg_temp.chk_true('no owner_* function is callable by anon',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname like 'owner\_%'
                 and has_function_privilege('anon', p.oid, 'execute')));
select pg_temp.chk('staff cannot list every user (owner only)', 'pc-sa', $q$select public.owner_all_users()$q$, 'error');
select pg_temp.chk('staff cannot create staff accounts (owner only)', 'pc-sa',
  $q$select public.owner_upsert_staff_member('pc-new', 'New Person', 'pc-new@test.local', 'staff', null)$q$, 'error');
select pg_temp.chk('a customer cannot read other customers'' addresses', 'pc-c2',
  $q$do $d$ begin if (select count(*) from public.customer_addresses where firebase_uid = 'pc-c1') > 0 then raise exception 'leak'; end if; end $d$$q$, 'ok');
select pg_temp.chk('a customer cannot read other customers'' orders', 'pc-c2',
  $q$do $d$ begin if (select count(*) from public.orders where firebase_uid = 'pc-c1') > 0 then raise exception 'leak'; end if; end $d$$q$, 'ok');
select pg_temp.chk('a customer cannot read other customers'' refunds', 'pc-c2',
  $q$do $d$ begin if (select count(*) from public.refund_requests where firebase_uid = 'pc-c1') > 0 then raise exception 'leak'; end if; end $d$$q$, 'ok');

-- 9. Paged lists ------------------------------------------------------------------------
select pg_temp.chk_true('the orders page returns at most 100 rows and the total',
  (select (j ->> 'limit')::int = 100 and (j ->> 'total')::int = 4 and jsonb_array_length(j -> 'rows') = 4
     from (select pg_temp.call_as('pc-own', format($q$select public.admin_portal_orders_page(now() - interval '1 day', now() + interval '1 day', %L::uuid, null, null, null, 'total', 'asc', 1000000, 0)::text$q$, pg_temp.f('ba')))::jsonb as j) t));
select pg_temp.chk_true('the orders page pages (limit 1, offset 1) and searches',
  (select jsonb_array_length(j -> 'rows') = 1 and (j ->> 'total')::int = 4
     from (select pg_temp.call_as('pc-own', format($q$select public.admin_portal_orders_page(now() - interval '1 day', now() + interval '1 day', %L::uuid, null, null, null, 'created_at', 'desc', 1, 1)::text$q$, pg_temp.f('ba')))::jsonb as j) t)
  and (select (j ->> 'total')::int = 1
     from (select pg_temp.call_as('pc-own', format($q$select public.admin_portal_orders_page(now() - interval '1 day', now() + interval '1 day', %L::uuid, 'pc-ord-3', null, null, 'created_at', 'desc', 25, 0)::text$q$, pg_temp.f('ba')))::jsonb as j) t));
select pg_temp.chk('customers cannot read the orders page', 'pc-c1',
  format($q$select public.admin_portal_orders_page(now() - interval '1 day', now(), %L::uuid)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk_true('popular products is capped at 50',
  pg_get_functiondef('public.get_popular_products(integer)'::regprocedure) like '%least(greatest(coalesce(p_limit, 8), 0), 50)%');

-- 11. Terms / Privacy acceptance --------------------------------------------------------
select pg_temp.chk('anon cannot accept terms for anyone', null,
  $q$select public.accept_legal_terms('2026-10-11', '2026-10-11')$q$, 'error');
select pg_temp.chk('a customer accepts the current terms', 'pc-c1',
  $q$select public.accept_legal_terms('2026-10-11', '2026-10-11', false)$q$, 'ok');
select pg_temp.chk_true('the profile records version and time',
  (select terms_version = '2026-10-11' and privacy_version = '2026-10-11' and terms_accepted_at is not null
     from public.customer_profiles where firebase_uid = 'pc-c1'));
select pg_temp.chk_true('the optional "order updates" choice is applied',
  (select order_updates = false and delivery_updates = false from public.notification_preferences where firebase_uid = 'pc-c1'));
select pg_temp.chk_true('my_legal_acceptance returns the accepted versions',
  (pg_temp.call_as('pc-c1', $q$select public.my_legal_acceptance()::text$q$)::jsonb ->> 'terms_version') = '2026-10-11');
select pg_temp.chk_true('another account sees nothing of it',
  (pg_temp.call_as('pc-c2', $q$select public.my_legal_acceptance()::text$q$)::jsonb ->> 'terms_version') is null);
select pg_temp.chk('acceptances are append-only (no update)', 'pc-c1',
  $q$update public.legal_acceptances set version = 'x'$q$, 'error');
select pg_temp.chk_true('even the owner''s SQL cannot rewrite an acceptance',
  pg_temp.fails($q$update public.legal_acceptances set version = 'x' where firebase_uid = 'pc-c1'$q$));
-- Consent given at sign-up (before the profile exists) stamps the profile when it is created.
select pg_temp.chk('a new account accepts before its profile exists', 'pc-c3',
  $q$select public.accept_legal_terms('2026-10-11', '2026-10-11')$q$, 'ok');
insert into public.customer_profiles (firebase_uid, full_name, email) values ('pc-c3', 'PC Three', 'pc-c3@test.local');
select pg_temp.chk_true('... and the profile is stamped when it is created',
  (select terms_version = '2026-10-11' from public.customer_profiles where firebase_uid = 'pc-c3'));
select pg_temp.chk('a version longer than 40 characters is refused', 'pc-c1',
  format($q$select public.accept_legal_terms(%L, '2026-10-11')$q$, repeat('x', 41)), 'error');

-- Report ---------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;

do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% panel compliance check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
