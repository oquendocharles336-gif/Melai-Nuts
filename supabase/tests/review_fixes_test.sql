-- =============================================================================
-- Melai Nuts — code-review fixes (migration 20261027000000_review_fixes.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/review_fixes_test.sql
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

create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;
-- Runs p_sql as p_uid; returns its text result, or 'ERROR: <message>'.
create function pg_temp.try_as(p_uid text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.act_as(p_uid);
  begin execute p_sql into v;
  exception when others then v := 'ERROR: ' || sqlerrm; end;
  perform pg_temp.back_to_admin();
  return v;
end $$;
create function pg_temp.f(p_k text) returns text language sql as $$ select v from fx where k = p_k $$;
grant execute on function pg_temp.f(text) to public;
create function pg_temp.stock(p_branch text, p_var text default 'var') returns int language sql as $$
  select quantity from public.branch_inventory
  where branch_id = pg_temp.f(p_branch)::uuid and variant_id = pg_temp.f(p_var)::uuid $$;

-- Fixtures ---------------------------------------------------------------------
insert into public.branches (name, address, delivery_fee) values ('RVW-TEST A', 'a', 0), ('RVW-TEST B', 'b', 0);
insert into fx select 'ba', id::text from public.branches where name = 'RVW-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'RVW-TEST B';
insert into public.product_categories (label) values ('RVW-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, n, 100, 'pack' from public.product_categories, (values ('RVW-TEST Nut'), ('RVW-TEST Seed')) t(n)
where label = 'RVW-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name in ('RVW-TEST Nut', 'RVW-TEST Seed');
insert into fx select 'prod', id::text from public.products where name = 'RVW-TEST Nut';
insert into fx select 'prod2', id::text from public.products where name = 'RVW-TEST Seed';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into fx select 'var2', id::text from public.product_variants where product_id = pg_temp.f('prod2')::uuid;

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
values ('rv-sa',  'Cashier A', 'rv-sa@test.local',  'staff', pg_temp.f('ba')::uuid, 'active', true, true),
       ('rv-sa2', 'Cashier A2', 'rv-sa2@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', true, true),
       ('rv-sb',  'Cashier B', 'rv-sb@test.local',  'staff', pg_temp.f('bb')::uuid, 'active', true, true),
       ('rv-own', 'Owner',     'rv-own@test.local', 'owner', null, 'active', false, false);
insert into public.customer_profiles (firebase_uid, full_name, email, phone)
values ('rv-c1', 'Loyal Cust', 'rv-c1@test.local', '09170000071');

insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select pg_temp.f('ba')::uuid, pg_temp.f(p)::uuid, pg_temp.f(v)::uuid, 0 from (values ('prod', 'var'), ('prod2', 'var2')) t(p, v)
on conflict do nothing;
select pg_temp.try_as('rv-own', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'RVW-A1', 50, current_date + 90)::text$q$,
  pg_temp.f('ba'), pg_temp.f('var')));
select pg_temp.try_as('rv-own', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'RVW-A2', 50, current_date + 90)::text$q$,
  pg_temp.f('ba'), pg_temp.f('var2')));
select set_config('app.inventory_managed', '', true);

-- items: [[var-key, qty], ...]
create function pg_temp.pos(p_staff text, p_branch text, p_items jsonb, p_method text, p_key text,
                            p_customer text default null, p_ref text default null)
returns text language sql as $$
  select pg_temp.try_as(p_staff, format(
    $q$select public.staff_create_pos_sale(%L::uuid, %L::jsonb, %L, %L, %s, %L, %L)::text$q$,
    pg_temp.f(p_branch),
    (select jsonb_agg(jsonb_build_object('variant_id', pg_temp.f(x ->> 0), 'quantity', (x ->> 1)::int)) from jsonb_array_elements(p_items) x),
    p_method, p_ref, case when p_method = 'cash' then '5000' else 'null' end, p_customer, p_key))
$$;

-- =============================================================================
-- 1. POS idempotency key: replay vs. different request
-- =============================================================================
insert into fx values ('stock0', pg_temp.stock('ba'));

-- Case A: walk-in first, retried with a loyalty customer attached.
insert into fx values ('r1', pg_temp.pos('rv-sa', 'ba', '[["var", 2]]', 'cash', 'rvw-key-1'));
insert into fx values ('r1b', pg_temp.pos('rv-sa', 'ba', '[["var", 2]]', 'cash', 'rvw-key-1', 'rv-c1'));
select pg_temp.chk_true('POS: first sale recorded', pg_temp.f('r1')::jsonb ->> 'order_id' is not null, pg_temp.f('r1'));
select pg_temp.chk_true('POS: same key + customer attached is refused (not a second sale)',
  pg_temp.f('r1b') like 'ERROR: This sale was already recorded with different details.%', pg_temp.f('r1b'));
select pg_temp.chk_true('POS: only ONE order exists for the key',
  (select count(*) from public.orders where idempotency_key = 'rvw-key-1') = 1);
select pg_temp.chk_true('POS: stock taken once', pg_temp.stock('ba') = pg_temp.f('stock0')::int - 2,
  pg_temp.stock('ba')::text);

-- Case B: true replay returns the recorded sale.
insert into fx values ('r1c', pg_temp.pos('rv-sa', 'ba', '[["var", 2]]', 'cash', 'rvw-key-1'));
select pg_temp.chk_true('POS: identical replay returns the same order with already_recorded = true',
  (pg_temp.f('r1c')::jsonb ->> 'order_id') = (pg_temp.f('r1')::jsonb ->> 'order_id')
  and (pg_temp.f('r1c')::jsonb ->> 'already_recorded')::boolean, pg_temp.f('r1c'));
select pg_temp.chk_true('POS: first answer says already_recorded = false',
  not (pg_temp.f('r1')::jsonb ->> 'already_recorded')::boolean);
select pg_temp.chk_true('POS: replay with lines in another order / split is still the same sale',
  (pg_temp.pos('rv-sa', 'ba', '[["var", 1], ["var", 1]]', 'cash', 'rvw-key-1')::jsonb ->> 'already_recorded')::boolean);

-- Case C: same key, 5 items instead of 2 → error, not the old receipt.
insert into fx values ('r1d', pg_temp.pos('rv-sa', 'ba', '[["var", 5]]', 'cash', 'rvw-key-1'));
select pg_temp.chk_true('POS: same key with more items is refused',
  pg_temp.f('r1d') like 'ERROR: This sale was already recorded with different details.%', pg_temp.f('r1d'));
insert into fx values ('r1e', pg_temp.pos('rv-sa', 'ba', '[["var", 2], ["var2", 1]]', 'cash', 'rvw-key-1'));
select pg_temp.chk_true('POS: same key with an extra product is refused',
  pg_temp.f('r1e') like 'ERROR: This sale was already recorded%', pg_temp.f('r1e'));
insert into fx values ('r1f', pg_temp.pos('rv-sa', 'ba', '[["var", 2]]', 'gcash', 'rvw-key-1', null, 'REF-9999'));
select pg_temp.chk_true('POS: same key with another payment method is refused',
  pg_temp.f('r1f') like 'ERROR: This sale was already recorded%', pg_temp.f('r1f'));
select pg_temp.chk_true('POS: still exactly one order and stock unchanged after refused replays',
  (select count(*) from public.orders where idempotency_key = 'rvw-key-1') = 1
  and pg_temp.stock('ba') = pg_temp.f('stock0')::int - 2);

-- Case D: customer sale first, retried as walk-in (the opposite direction).
insert into fx values ('r2', pg_temp.pos('rv-sa', 'ba', '[["var", 1]]', 'cash', 'rvw-key-2', 'rv-c1'));
insert into fx values ('r2b', pg_temp.pos('rv-sa', 'ba', '[["var", 1]]', 'cash', 'rvw-key-2'));
select pg_temp.chk_true('POS: customer sale then walk-in retry is refused',
  pg_temp.f('r2b') like 'ERROR: This sale was already recorded%', pg_temp.f('r2b'));
select pg_temp.chk_true('POS: customer sale then walk-in retry made one order',
  (select count(*) from public.orders where idempotency_key = 'rvw-key-2') = 1);

-- Keys belong to the staff member: another cashier's identical key is a new sale.
insert into fx values ('r3', pg_temp.pos('rv-sa2', 'ba', '[["var", 1]]', 'cash', 'rvw-key-2', 'rv-c1'));
select pg_temp.chk_true('POS: a different cashier with the same key is not a replay of someone else''s sale',
  pg_temp.f('r3') like 'ERROR:%'
  or (pg_temp.f('r3')::jsonb ->> 'order_id') <> (pg_temp.f('r2')::jsonb ->> 'order_id'), pg_temp.f('r3'));

-- Fingerprint is stored.
select pg_temp.chk_true('POS: key and fingerprint saved on pos_sales',
  (select idempotency_key = 'rvw-key-1' and request_fingerprint is not null
   from public.pos_sales where order_id = pg_temp.f('r1')::jsonb ->> 'order_id'));

-- =============================================================================
-- 2. HitPay refund check: attempt lookup by id
-- =============================================================================
-- Fixtures written directly (triggers off) — this section tests the lookup only.
set local session_replication_role = replica;
insert into public.refund_requests (id, order_id, firebase_uid, status, reason, amount, payment_method)
values ('RFD-RVW-1', pg_temp.f('r2')::jsonb ->> 'order_id', 'rv-c1', 'approved', 'Test', 100, 'gcash');
insert into public.refund_gateway_attempts (id, refund_id, order_id, gateway_payment_id, amount, status, gateway_refund_id, started_by)
values ('00000000-0000-4000-8000-0000000000a1', 'RFD-RVW-1', pg_temp.f('r2')::jsonb ->> 'order_id', 'hp-pay-1', 100, 'pending', 'hp-rf-1', 'rv-sa');
set local session_replication_role = origin;

insert into fx values ('att', pg_temp.try_as('rv-sa', $q$select public.staff_gateway_refund_attempt('00000000-0000-4000-8000-0000000000a1')::text$q$));
select pg_temp.chk_true('refund check: staff of the branch finds the attempt by id alone',
  (pg_temp.f('att')::jsonb ->> 'refund_id') = 'RFD-RVW-1' and (pg_temp.f('att')::jsonb ->> 'status') = 'pending', pg_temp.f('att'));
select pg_temp.chk_true('refund check: staff of another branch is refused',
  pg_temp.try_as('rv-sb', $q$select public.staff_gateway_refund_attempt('00000000-0000-4000-8000-0000000000a1')::text$q$) like 'ERROR:%');
select pg_temp.chk_true('refund check: a customer is refused',
  pg_temp.try_as('rv-c1', $q$select public.staff_gateway_refund_attempt('00000000-0000-4000-8000-0000000000a1')::text$q$) like 'ERROR:%');
select pg_temp.chk_true('refund check: signed-out callers cannot run it',
  pg_temp.try_as(null, $q$select public.staff_gateway_refund_attempt('00000000-0000-4000-8000-0000000000a1')::text$q$) like 'ERROR:%');
select pg_temp.chk_true('refund check: unknown id answers null for staff',
  pg_temp.try_as('rv-sa', $q$select public.staff_gateway_refund_attempt('00000000-0000-4000-8000-0000000000ff')::text$q$) is null);

-- =============================================================================
-- 3. HitPay checkout links: claim, reuse, expiry
-- =============================================================================
set local session_replication_role = replica;
update public.payments set status = 'pending', method = 'gcash', gateway = null, gateway_payment_id = null,
       gateway_checkout_url = null, gateway_checkout_created_at = null, checkout_started_at = null
 where order_id = pg_temp.f('r2')::jsonb ->> 'order_id';
set local session_replication_role = origin;
insert into fx values ('hp_order', pg_temp.f('r2')::jsonb ->> 'order_id');

create function pg_temp.claim(p_age int default 60) returns jsonb language sql as $$
  select public.hitpay_claim_checkout(pg_temp.f('hp_order'), p_age) $$;
create function pg_temp.pay() returns public.payments language sql as $$
  select * from public.payments where order_id = pg_temp.f('hp_order') $$;

select pg_temp.chk_true('checkout: customers cannot call the claim function',
  pg_temp.try_as('rv-c1', format($q$select public.hitpay_claim_checkout(%L, 60)::text$q$, pg_temp.f('hp_order'))) like 'ERROR:%');
select pg_temp.chk_true('checkout: first caller may create', pg_temp.claim() ->> 'action' = 'create');
select pg_temp.chk_true('checkout: a second caller at the same moment waits (busy), no second request',
  pg_temp.claim() ->> 'action' = 'busy');
select public.hitpay_set_checkout(pg_temp.f('hp_order'), 'req-1', 'https://pay.test/1');
select pg_temp.chk_true('checkout: after the link is stored, callers reuse it',
  pg_temp.claim() = jsonb_build_object('action', 'reuse', 'checkout_url', 'https://pay.test/1', 'payment_request_id', 'req-1'));
select pg_temp.chk_true('checkout: storing the link moved the payment to processing and released the claim',
  (pg_temp.pay()).status = 'processing' and (pg_temp.pay()).checkout_started_at is null
  and (pg_temp.pay()).gateway_checkout_created_at is not null);

set local session_replication_role = replica;
update public.payments set gateway_checkout_created_at = now() - interval '2 hours' where order_id = pg_temp.f('hp_order');
set local session_replication_role = origin;
select pg_temp.chk_true('checkout: an expired link is not reused', pg_temp.claim() ->> 'action' = 'create');
select public.hitpay_release_checkout(pg_temp.f('hp_order'));
select pg_temp.chk_true('checkout: a released claim lets the next caller create at once', pg_temp.claim() ->> 'action' = 'create');
select public.hitpay_set_checkout(pg_temp.f('hp_order'), 'req-2', 'https://pay.test/2');

select pg_temp.chk_true('checkout: an OLD link expiring changes nothing',
  public.hitpay_expire_checkout(pg_temp.f('hp_order'), 'req-1') = 'processing' and (pg_temp.pay()).gateway_payment_id = 'req-2');
select pg_temp.chk_true('checkout: the CURRENT link expiring leaves processing (-> failed) and forgets the link',
  public.hitpay_expire_checkout(pg_temp.f('hp_order'), 'req-2') = 'failed'
  and (pg_temp.pay()).status = 'failed' and (pg_temp.pay()).gateway_checkout_url is null);
select pg_temp.chk_true('checkout: after expiry a new link can be made', pg_temp.claim() ->> 'action' = 'create');
select public.hitpay_set_checkout(pg_temp.f('hp_order'), 'req-3', 'https://pay.test/3');
select public.hitpay_apply_payment(pg_temp.f('hp_order'), 'success', 'gcash', 'req-3', null);
select pg_temp.chk_true('checkout: expiry never touches a paid payment',
  public.hitpay_expire_checkout(pg_temp.f('hp_order'), 'req-3') = 'success' and (pg_temp.pay()).status = 'success');
select pg_temp.chk_true('checkout: a paid payment is closed for new links', pg_temp.claim() ->> 'action' = 'closed');

-- =============================================================================
-- 4. branch_inventory.is_carried
-- =============================================================================
-- Branch B has a seed-style row (0, never stocked) and a carried row.
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity, is_carried)
values (pg_temp.f('bb')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 0, false),
       (pg_temp.f('bb')::uuid, pg_temp.f('prod2')::uuid, pg_temp.f('var2')::uuid, 0, true)
on conflict (branch_id, product_id, variant_id) do update set is_carried = excluded.is_carried, quantity = 0;

create function pg_temp.stock_item(p_uid text, p_branch text, p_var text) returns jsonb language sql as $$
  select i from jsonb_array_elements(pg_temp.try_as(p_uid, 'select public.admin_portal_stock()::text')::jsonb) b,
               jsonb_array_elements(b -> 'items') i
  where b ->> 'branch_id' = pg_temp.f(p_branch) and i ->> 'variant_id' = pg_temp.f(p_var) $$;

select pg_temp.chk_true('carried: a row the branch does not carry is not "carried" in admin_portal_stock',
  (pg_temp.stock_item('rv-own', 'bb', 'var') ->> 'carried')::boolean = false, pg_temp.stock_item('rv-own', 'bb', 'var')::text);
select pg_temp.chk_true('carried: a carried row with 0 is carried (genuinely out of stock)',
  (pg_temp.stock_item('rv-own', 'bb', 'var2') ->> 'carried')::boolean = true);
-- The other stock counts (20261027010000): branch B holds one row it doesn't
-- carry (var) and one carried row with 0 (var2) -> exactly ONE out of stock.
select pg_temp.chk_true('carried: staff dashboard counts only carried rows as out of stock',
  (pg_temp.try_as('rv-sb', format($q$select public.staff_get_dashboard(%L::uuid)::text$q$, pg_temp.f('bb')))::jsonb
     ->> 'out_of_stock_count')::int = 1,
  pg_temp.try_as('rv-sb', format($q$select public.staff_get_dashboard(%L::uuid)::text$q$, pg_temp.f('bb'))));
select pg_temp.chk_true('carried: analytics_report inventory counts only carried rows as out of stock',
  (pg_temp.try_as('rv-own', format($q$select public.analytics_report(current_date, current_date, %L::uuid)::text$q$, pg_temp.f('bb')))::jsonb
     -> 'inventory' ->> 'out_of_stock')::int = 1);
select public.enqueue_owner_daily_digest(current_date);
select pg_temp.chk_true('carried: the owners'' daily digest counts only carried rows as out of stock',
  (select body like '%low, 1 out%' from public.staff_notifications
    where recipient_uid = 'rv-own' and reference = 'digest:' || current_date),
  (select body from public.staff_notifications where recipient_uid = 'rv-own' and reference = 'digest:' || current_date));
create function pg_temp.inv_item(p_uid text, p_branch text, p_var text) returns jsonb language sql as $$
  select i from jsonb_array_elements(
    pg_temp.try_as(p_uid, format($q$select public.staff_get_inventory(%L::uuid)::text$q$, pg_temp.f(p_branch)))::jsonb -> 'items') i
  where i ->> 'variant_id' = pg_temp.f(p_var) $$;
select pg_temp.chk_true('carried: staff inventory marks an item the branch does not sell as not carried',
  (pg_temp.inv_item('rv-sb', 'bb', 'var') ->> 'carried')::boolean = false, pg_temp.inv_item('rv-sb', 'bb', 'var')::text);
select pg_temp.chk_true('carried: staff inventory marks a sold item at 0 as carried (genuinely out of stock)',
  (pg_temp.inv_item('rv-sb', 'bb', 'var2') ->> 'carried')::boolean = true);
select pg_temp.chk_true('carried: staff inventory marks a carried item with stock as carried',
  (pg_temp.inv_item('rv-sa', 'ba', 'var') ->> 'carried')::boolean = true);
select pg_temp.chk_true('carried: new rows are carried by default',
  (select is_carried from public.branch_inventory where branch_id = pg_temp.f('ba')::uuid and variant_id = pg_temp.f('var')::uuid));
select pg_temp.try_as('rv-own', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'RVW-B1', 5, current_date + 90)::text$q$,
  pg_temp.f('bb'), pg_temp.f('var')));
select set_config('app.inventory_managed', '', true);
select pg_temp.chk_true('carried: after receiving, staff inventory shows the item as carried',
  (pg_temp.inv_item('rv-sb', 'bb', 'var') ->> 'carried')::boolean = true);
select pg_temp.chk_true('carried: receiving stock makes the row carried',
  (select is_carried and quantity = 5 from public.branch_inventory where branch_id = pg_temp.f('bb')::uuid and variant_id = pg_temp.f('var')::uuid));
select pg_temp.chk_true('carried: customers can read the flag (the app''s live stock check)',
  pg_temp.try_as('rv-c1', format($q$select is_carried::text from public.branch_inventory where branch_id = %L::uuid and variant_id = %L::uuid$q$,
    pg_temp.f('bb'), pg_temp.f('var2'))) = 'true');

-- =============================================================================
-- 5. branches.daily_sales_target is not public
-- =============================================================================
update public.branches set daily_sales_target = 12345 where id = pg_temp.f('ba')::uuid;
select pg_temp.chk_true('target: signed-out users cannot read daily_sales_target',
  pg_temp.try_as(null, 'select daily_sales_target::text from public.branches limit 1') like 'ERROR:%permission denied%');
select pg_temp.chk_true('target: customers cannot read daily_sales_target',
  pg_temp.try_as('rv-c1', 'select daily_sales_target::text from public.branches limit 1') like 'ERROR:%permission denied%');
select pg_temp.chk_true('target: signed-out users still read the public branch columns the app lists',
  pg_temp.try_as(null, format($q$select name from public.branches where id = %L::uuid$q$, pg_temp.f('ba'))) = 'RVW-TEST A');
select pg_temp.chk_true('target: every column the app selects is readable by customers',
  pg_temp.try_as('rv-c1', 'select count(*)::text from (select id, name, address, is_active, contact_phone, operating_hours, supports_delivery, supports_pickup, delivery_fee, latitude, longitude, is_warehouse from public.branches) x') not like 'ERROR:%');
select pg_temp.chk_true('target: the owner still gets it through get_business_settings',
  (select (b ->> 'daily_sales_target')::numeric = 12345
   from jsonb_array_elements(pg_temp.try_as('rv-own', 'select public.get_business_settings()::text')::jsonb -> 'branches') b
   where b ->> 'id' = pg_temp.f('ba')));


-- =============================================================================
-- 6. owner_delete_driver (rollback of a failed delivery-account creation)
-- =============================================================================
select pg_temp.try_as('rv-own', format($q$select public.owner_upsert_driver('rv-drv-1', 'New Driver', 'd@test.local', %L::uuid)::text$q$, pg_temp.f('ba')));
select pg_temp.chk_true('driver rollback: staff cannot remove a driver',
  pg_temp.try_as('rv-sa', $q$select public.owner_delete_driver('rv-drv-1')::text$q$) like 'ERROR:%'
  and exists (select 1 from public.drivers where firebase_uid = 'rv-drv-1'));
insert into fx values ('drv_del', coalesce(pg_temp.try_as('rv-own', $q$select public.owner_delete_driver('rv-drv-1')::text$q$), ''));
select pg_temp.chk_true('driver rollback: the owner removes a just-created driver row',
  pg_temp.f('drv_del') not like 'ERROR:%' and not exists (select 1 from public.drivers where firebase_uid = 'rv-drv-1'),
  pg_temp.f('drv_del'));

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% review-fix check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
