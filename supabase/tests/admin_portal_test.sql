-- =============================================================================
-- Melai Nuts — admin portal (20261009000000_admin_portal.sql) test suite
-- =============================================================================
-- Proves the functions the Laravel admin portal calls are scoped exactly like
-- the mobile app: owners see every branch, staff only their own, customers and
-- anonymous callers nothing; owner-only writes refuse staff; loyalty
-- adjustments are validated, append-only, idempotent and never go negative;
-- the earn rate setting really changes the points on the next order.
--
-- HOW TO RUN (DEV / staging only):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/admin_portal_test.sql
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

-- Fixtures ------------------------------------------------------------------
insert into public.branches (name, address, supports_delivery, supports_pickup, delivery_fee)
values ('AP-TEST A', 'a', true, true, 30), ('AP-TEST B', 'b', true, true, 30);
insert into fx select 'ba', id::text from public.branches where name = 'AP-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'AP-TEST B';

insert into public.product_categories (label) values ('AP-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'AP-TEST Nut', 100, 'pack' from public.product_categories where label = 'AP-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'AP-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'AP-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = (select v from fx where k='prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select (select v from fx where k = b)::uuid, (select v from fx where k='prod')::uuid, (select v from fx where k='var')::uuid, 40
from (values ('ba'), ('bb')) t(b);

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
select 'ap-sa', 'Staff A', 'ap-sa@test.local', 'staff', (select v from fx where k='ba')::uuid, 'active', true, false
union all select 'ap-sb', 'Staff B', 'ap-sb@test.local', 'staff', (select v from fx where k='bb')::uuid, 'active', true, true
union all select 'ap-own', 'Owner', 'ap-own@test.local', 'owner', null, 'active', false, false
union all select 'ap-off', 'Former owner', 'ap-off@test.local', 'owner', null, 'inactive', false, false;

insert into public.customer_profiles (firebase_uid, full_name, email, phone, rfid_card_number)
values ('ap-c1', 'AP Customer', 'ap-c1@test.local', '09180000001', 'AP-CARD-1');
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent)
values ('default', 1, 50) on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;

-- One pickup order in each branch through the real checkout.
do $$
declare v_cart text; v_order text; b text;
begin
  foreach b in array array['ba', 'bb'] loop
    v_cart := pg_temp.call_as('ap-c1', format($q$select (public.sync_customer_cart(%L::uuid,
        jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 2)), null, false) ->> 'cart_id')$q$,
        (select v from fx where k=b), (select v from fx where k='prod'), (select v from fx where k='var')));
    v_order := pg_temp.call_as('ap-c1', format($q$select public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', %L)$q$,
        v_cart, 'ap-key-' || b));
    insert into fx values ('order_' || b, v_order);
  end loop;
end $$;

-- 1. Order reads are branch-scoped ------------------------------------------
select pg_temp.chk_true('owner sees orders from both branches',
  (select count(*) from jsonb_array_elements(pg_temp.call_as('ap-own',
     $q$select public.admin_portal_orders(now() - interval '1 day', now() + interval '1 day')::text$q$)::jsonb) e
   where e->>'id' in ((select v from fx where k='order_ba'), (select v from fx where k='order_bb'))) = 2);
select pg_temp.chk_true('staff A sees branch A''s order but never branch B''s',
  position((select v from fx where k='order_ba') in pg_temp.call_as('ap-sa',
     $q$select public.admin_portal_orders(now() - interval '1 day', now() + interval '1 day')::text$q$)) > 0
  and position((select v from fx where k='order_bb') in pg_temp.call_as('ap-sa',
     $q$select public.admin_portal_orders(now() - interval '1 day', now() + interval '1 day')::text$q$)) = 0);
select pg_temp.chk('staff A asking for branch B explicitly is refused', 'ap-sa',
  format($q$select public.admin_portal_orders(now() - interval '1 day', now(), %L::uuid)$q$, (select v from fx where k='bb')), 'error');
select pg_temp.chk_true('orders carry their payment record',
  (select (e->'payment'->>'status') from jsonb_array_elements(pg_temp.call_as('ap-own',
     $q$select public.admin_portal_orders(now() - interval '1 day', now() + interval '1 day')::text$q$)::jsonb) e
   where e->>'id' = (select v from fx where k='order_ba')) = 'pending');
select pg_temp.chk('date range over 400 days is refused', 'ap-own',
  $q$select public.admin_portal_orders(now() - interval '500 days', now())$q$, 'error');
select pg_temp.chk('customer cannot list orders through the portal', 'ap-c1',
  $q$select public.admin_portal_orders(now() - interval '1 day', now())$q$, 'error');
select pg_temp.chk('anonymous cannot list orders through the portal', null,
  $q$select public.admin_portal_orders(now() - interval '1 day', now())$q$, 'error');
select pg_temp.chk('deactivated owner cannot list orders', 'ap-off',
  $q$select public.admin_portal_orders(now() - interval '1 day', now())$q$, 'error');

-- 2. Stock / products / movements -------------------------------------------
select pg_temp.chk_true('owner stock covers both test branches',
  (select count(*) from jsonb_array_elements(pg_temp.call_as('ap-own', $q$select public.admin_portal_stock()::text$q$)::jsonb) e
   where e->>'branch_name' like 'AP-TEST %') = 2);
select pg_temp.chk_true('staff A stock covers only branch A',
  (select string_agg(e->>'branch_name', ',') from jsonb_array_elements(pg_temp.call_as('ap-sa', $q$select public.admin_portal_stock()::text$q$)::jsonb) e)
  = 'AP-TEST A');
select pg_temp.chk_true('stock reflects the checkout deduction (40 - 2 = 38)',
  (select (i->>'quantity')::int from jsonb_array_elements(pg_temp.call_as('ap-sa', $q$select public.admin_portal_stock()::text$q$)::jsonb) e,
          jsonb_array_elements(e->'items') i where i->>'variant_id' = (select v from fx where k='var')) = 38);
select pg_temp.chk_true('product catalog includes the test product with its variant',
  position('AP-TEST Nut' in pg_temp.call_as('ap-sa', $q$select public.admin_portal_products()::text$q$)) > 0);
select pg_temp.chk('customer cannot read the staff catalog', 'ap-c1', $q$select public.admin_portal_products()$q$, 'error');
select pg_temp.chk('staff A cannot read branch B stock movements', 'ap-sa',
  format($q$select public.admin_portal_stock_movements(%L::uuid, 10)$q$, (select v from fx where k='bb')), 'error');
select pg_temp.chk('owner can read branch B stock movements', 'ap-own',
  format($q$select public.admin_portal_stock_movements(%L::uuid, 10)$q$, (select v from fx where k='bb')), 'ok');

-- 3. Admin actions go through the existing staff functions -------------------
select pg_temp.chk('owner confirms the cash payment of branch B''s order', 'ap-own',
  format($q$select public.staff_confirm_payment(%L, null)$q$, (select v from fx where k='order_bb')), 'ok');
select pg_temp.chk('confirming the same payment twice is refused (no double payment)', 'ap-own',
  format($q$select public.staff_confirm_payment(%L, null)$q$, (select v from fx where k='order_bb')), 'error');
select pg_temp.chk('staff B cannot confirm branch A''s payment', 'ap-sb',
  format($q$select public.staff_confirm_payment(%L, null)$q$, (select v from fx where k='order_ba')), 'error');
select pg_temp.chk('staff A confirms its own branch''s payment', 'ap-sa',
  format($q$select public.staff_confirm_payment(%L, null)$q$, (select v from fx where k='order_ba')), 'ok');
select pg_temp.chk_true('refund details hidden from staff without the refunds permission',
  (select bool_and(e->'refund' = 'null'::jsonb or e->'refund' is null)
   from jsonb_array_elements(pg_temp.call_as('ap-sa',
     $q$select public.admin_portal_orders(now() - interval '1 day', now() + interval '1 day')::text$q$)::jsonb) e));

-- 3b. Refund review through the portal wrapper ---------------------------------
do $$
declare b text; o text;
begin
  foreach b in array array['ba', 'bb'] loop
    o := (select v from fx where k = 'order_' || b);
    perform pg_temp.call_as('ap-own', format($q$select public.staff_update_order_status(%L, s)::text from unnest(array['confirmed','preparing','readyForPickup','completed']) s$q$, o));
  end loop;
end $$;
-- (the statement above runs the four transitions in order inside one call)
insert into fx select 'refund_bb', pg_temp.call_as('ap-c1', format(
  $q$select public.request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','AP-TEST Nut','variant_label','Regular','quantity',2)))$q$,
  (select v from fx where k='order_bb')));
insert into fx select 'refund_ba', pg_temp.call_as('ap-c1', format(
  $q$select public.request_refund(%L, 'Wrong item', '', jsonb_build_array(jsonb_build_object('product_name','AP-TEST Nut','variant_label','Regular','quantity',1)))$q$,
  (select v from fx where k='order_ba')));
select pg_temp.chk_true('fixture: two refund requests exist',
  (select count(*) from public.refund_requests where id in ((select v from fx where k='refund_bb'), (select v from fx where k='refund_ba'))) = 2);
select pg_temp.chk('staff without the refunds permission cannot review', 'ap-sa',
  format($q$select public.admin_portal_review_refund(%L, 'reject', 'Not eligible for refund')$q$, (select v from fx where k='refund_ba')), 'error');
select pg_temp.chk('staff B cannot review branch A''s refund', 'ap-sb',
  format($q$select public.admin_portal_review_refund(%L, 'reject', 'Not eligible for refund')$q$, (select v from fx where k='refund_ba')), 'error');
select pg_temp.chk('reject without a reason refused', 'ap-sb',
  format($q$select public.admin_portal_review_refund(%L, 'reject', ' ')$q$, (select v from fx where k='refund_bb')), 'error');
select pg_temp.chk('unknown action refused', 'ap-sb',
  format($q$select public.admin_portal_review_refund(%L, 'delete', null)$q$, (select v from fx where k='refund_bb')), 'error');
select pg_temp.chk('staff B refunds its cash order in one step', 'ap-sb',
  format($q$select public.admin_portal_review_refund(%L, 'approve_cash', 'Cash returned at counter')$q$, (select v from fx where k='refund_bb')), 'ok');
select pg_temp.chk_true('refund completed, order refunded, payment refunded',
  (select r.status = 'completed' and o.status = 'refunded' and p.status = 'refunded'
   from public.refund_requests r join public.orders o on o.id = r.order_id join public.payments p on p.order_id = o.id
   where r.id = (select v from fx where k='refund_bb')));
select pg_temp.chk('a completed refund cannot be reviewed again', 'ap-sb',
  format($q$select public.admin_portal_review_refund(%L, 'approve_cash', null)$q$, (select v from fx where k='refund_bb')), 'error');
select pg_temp.chk('owner approves branch A''s refund', 'ap-own',
  format($q$select public.admin_portal_review_refund(%L, 'approve', null)$q$, (select v from fx where k='refund_ba')), 'ok');
select pg_temp.chk('complete without a provider reference refused', 'ap-own',
  format($q$select public.admin_portal_review_refund(%L, 'complete', null)$q$, (select v from fx where k='refund_ba')), 'error');
select pg_temp.chk('owner rejects the approved refund with a reason', 'ap-own',
  format($q$select public.admin_portal_review_refund(%L, 'reject', 'Item was opened and used')$q$, (select v from fx where k='refund_ba')), 'ok');
select pg_temp.chk_true('customer received the rejection reason',
  exists (select 1 from public.notifications where firebase_uid = 'ap-c1' and body like '%Item was opened and used%'));
select pg_temp.chk_true('refund actions are audited (approve_cash, approve, reject)',
  (select count(*) from public.staff_audit_logs where action in ('refund.approve_cash', 'refund.approve', 'refund.reject')
     and entity_id in ((select v from fx where k='refund_bb'), (select v from fx where k='refund_ba'))) = 3);

-- 4. Loyalty reads ------------------------------------------------------------
insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points) values ('ap-c1', 10, 10)
on conflict (firebase_uid) do update set points_balance = 10, lifetime_points = 10;
select pg_temp.chk_true('member search by card number finds the customer',
  position('ap-c1' in pg_temp.call_as('ap-sa', $q$select public.admin_portal_loyalty_members('ap-card', 50)::text$q$)) > 0);
select pg_temp.chk_true('member detail returns balance 10',
  (pg_temp.call_as('ap-own', $q$select public.admin_portal_loyalty_member('ap-c1')::text$q$)::jsonb ->> 'balance')::int = 10);
select pg_temp.chk_true('walk-in is never a loyalty member',
  pg_temp.call_as('ap-own', $q$select public.admin_portal_loyalty_member('walk-in')::text$q$) is null);
select pg_temp.chk('customer cannot list loyalty members', 'ap-c1', $q$select public.admin_portal_loyalty_members(null, 10)$q$, 'error');
select pg_temp.chk('staff can read loyalty settings', 'ap-sa', $q$select public.admin_portal_loyalty_settings()$q$, 'ok');

-- 5. Loyalty adjustments ------------------------------------------------------
select pg_temp.chk('staff cannot adjust points (owner only)', 'ap-sb',
  $q$select public.owner_adjust_loyalty_points('ap-c1', 5, 'Goodwill', 'key-staff-0001')$q$, 'error');
select pg_temp.chk('deactivated owner cannot adjust points', 'ap-off',
  $q$select public.owner_adjust_loyalty_points('ap-c1', 5, 'Goodwill', 'key-off-00001')$q$, 'error');
select pg_temp.chk('zero points refused', 'ap-own',
  $q$select public.owner_adjust_loyalty_points('ap-c1', 0, 'Goodwill', 'key-zero-0001')$q$, 'error');
select pg_temp.chk('missing reason refused', 'ap-own',
  $q$select public.owner_adjust_loyalty_points('ap-c1', 5, '  ', 'key-reas-0001')$q$, 'error');
select pg_temp.chk('bad request key refused', 'ap-own',
  $q$select public.owner_adjust_loyalty_points('ap-c1', 5, 'Goodwill', 'x')$q$, 'error');
select pg_temp.chk('unknown member refused', 'ap-own',
  $q$select public.owner_adjust_loyalty_points('nobody', 5, 'Goodwill', 'key-nobo-0001')$q$, 'error');
select pg_temp.chk('deducting more than the balance refused', 'ap-own',
  $q$select public.owner_adjust_loyalty_points('ap-c1', -11, 'Correction', 'key-over-0001')$q$, 'error');
select pg_temp.chk('owner adds 25 points', 'ap-own',
  $q$select public.owner_adjust_loyalty_points('ap-c1', 25, 'Goodwill for late delivery', 'key-add-00001')$q$, 'ok');
select pg_temp.chk_true('same request key again is a no-op (duplicate=true)',
  (pg_temp.call_as('ap-own', $q$select public.owner_adjust_loyalty_points('ap-c1', 25, 'Goodwill for late delivery', 'key-add-00001')::text$q$)::jsonb ->> 'duplicate')::boolean);
select pg_temp.chk_true('balance is 35 after one +25 (not 60)',
  (select points_balance from public.loyalty_accounts where firebase_uid = 'ap-c1') = 35);
select pg_temp.chk('owner deducts 35 points (down to exactly zero)', 'ap-own',
  $q$select public.owner_adjust_loyalty_points('ap-c1', -35, 'Correction', 'key-ded-00001')$q$, 'ok');
select pg_temp.chk_true('balance is 0 and lifetime only grew by the +25',
  (select points_balance = 0 and lifetime_points = 35 from public.loyalty_accounts where firebase_uid = 'ap-c1'));
select pg_temp.chk_true('two admin_adjust ledger rows were appended',
  (select count(*) from public.loyalty_transactions where firebase_uid = 'ap-c1' and source = 'admin_adjust') = 2);
select pg_temp.chk_true('each adjustment is in the staff audit log',
  (select count(*) from public.staff_audit_logs where staff_firebase_uid = 'ap-own' and action = 'loyalty.adjusted') = 2);
select pg_temp.chk_true('customer was notified of both adjustments',
  (select count(*) from public.notifications where firebase_uid = 'ap-c1' and category = 'loyalty') = 2);
select pg_temp.chk_true('customer sees the adjustment in their own history (RLS)',
  pg_temp.call_as('ap-c1', $q$select count(*)::text from public.loyalty_transactions where source = 'admin_adjust'$q$)::int = 2);
do $$
declare v_err text;
begin
  begin
    update public.loyalty_transactions set points = 1 where firebase_uid = 'ap-c1' and source = 'admin_adjust';
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk_true('ledger stays append-only even for the database owner', v_err is not null, coalesce(v_err, 'update succeeded'));
end $$;

-- 6. Loyalty settings -----------------------------------------------------------
select pg_temp.chk('staff cannot change loyalty settings', 'ap-sb',
  $q$select public.owner_update_loyalty_settings(10, 1, 50)$q$, 'error');
select pg_temp.chk('earn rate below 1 refused', 'ap-own',
  $q$select public.owner_update_loyalty_settings(0.5, 1, 50)$q$, 'error');
select pg_temp.chk('max discount over 100% refused', 'ap-own',
  $q$select public.owner_update_loyalty_settings(10, 1, 120)$q$, 'error');
select pg_temp.chk('owner sets earn rate to 1 point per PHP 10', 'ap-own',
  $q$select public.owner_update_loyalty_settings(10, 1, 50)$q$, 'ok');
select pg_temp.chk_true('settings change is audited',
  exists (select 1 from public.staff_audit_logs where staff_firebase_uid = 'ap-own' and action = 'loyalty.settings_updated'));
do $$
declare v_cart text; v_order text;
begin
  v_cart := pg_temp.call_as('ap-c1', format($q$select (public.sync_customer_cart(%L::uuid,
      jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 2)), null, false) ->> 'cart_id')$q$,
      (select v from fx where k='ba'), (select v from fx where k='prod'), (select v from fx where k='var')));
  v_order := pg_temp.call_as('ap-c1', format($q$select public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', 'ap-key-rate')$q$, v_cart));
  insert into fx values ('order_rate', v_order);
end $$;
select pg_temp.chk_true('next order earns at the new rate (PHP 200 / 10 = 20 points; old rule gave 4)',
  (select points_earned from public.orders where id = (select v from fx where k='order_rate')) = 20,
  (select 'total=' || total || ' points=' || points_earned from public.orders where id = (select v from fx where k='order_rate')));
select pg_temp.chk_true('customers and guests can read the earn rate the app displays (10)',
  pg_temp.call_as('ap-c1', $q$select public.get_loyalty_earn_rate()::text$q$)::numeric = 10
  and pg_temp.call_as(null, $q$select public.get_loyalty_earn_rate()::text$q$)::numeric = 10);
select pg_temp.chk_true('earlier orders keep their original points (4)',
  (select points_earned from public.orders where id = (select v from fx where k='order_ba')) = 4);

-- 7. Directory / audit ----------------------------------------------------------
select pg_temp.chk('staff cannot read the staff directory', 'ap-sa', $q$select public.admin_portal_staff_directory()$q$, 'error');
select pg_temp.chk_true('owner directory lists the test staff',
  position('ap-sb@test.local' in pg_temp.call_as('ap-own', $q$select public.admin_portal_staff_directory()::text$q$)) > 0);
select pg_temp.chk_true('staff only see their own audit entries',
  position('loyalty.adjusted' in pg_temp.call_as('ap-sb', $q$select public.admin_portal_audit_logs(100, null)::text$q$)) = 0);
select pg_temp.chk_true('owner sees the adjustment audit entries',
  position('loyalty.adjusted' in pg_temp.call_as('ap-own', $q$select public.admin_portal_audit_logs(100, null)::text$q$)) > 0);

-- 8. The Laravel login role has no privileges of its own -------------------------
select pg_temp.chk_true('melai_admin_portal exists, NOINHERIT, member of authenticated only',
  exists (select 1 from pg_roles r where r.rolname = 'melai_admin_portal' and not r.rolinherit and not r.rolsuper and not r.rolbypassrls)
  and (select array_agg(g.rolname::text) from pg_auth_members m join pg_roles g on g.oid = m.roleid
       join pg_roles u on u.oid = m.member where u.rolname = 'melai_admin_portal') = array['authenticated']);
select pg_temp.chk_true('melai_admin_portal cannot read orders without becoming authenticated',
  not has_table_privilege('melai_admin_portal', 'public.orders', 'select'));

-- Report ---------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where passed) as passed, count(*) filter (where not passed) as failed, count(*) as total from results;

do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% admin portal check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
