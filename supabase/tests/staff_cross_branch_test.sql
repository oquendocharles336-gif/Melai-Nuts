-- =============================================================================
-- Melai Nuts — staff cross-branch / least-privilege test suite
-- =============================================================================
-- Fills a gap in the existing suites: they prove identity and the branch helper
-- functions, but not that every staff MUTATION and every staff READ is refused
-- when a staff member from branch A reaches for branch B's data, or when a
-- staff member lacks the permission flag. Also checks customers cannot reach
-- staff RPCs.
--
-- HOW TO RUN (DEV / staging only):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/staff_cross_branch_test.sql
-- One transaction, rolled back at the end. Raises if any check fails.
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

-- Row count the caller can SEE (RLS applied). A permission-denied counts as 0 visible.
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

-- Fixtures ------------------------------------------------------------------
insert into public.branches (name, address, supports_delivery, supports_pickup, delivery_fee)
values ('XB-TEST A', 'a', true, true, 30), ('XB-TEST B', 'b', true, true, 30);
insert into fx select 'ba', id::text from public.branches where name = 'XB-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'XB-TEST B';

insert into public.product_categories (label) values ('XB-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'XB-TEST Nut', 100, 'pack' from public.product_categories where label = 'XB-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'XB-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'XB-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = (select v from fx where k='prod')::uuid;

insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select (select v from fx where k = b)::uuid, (select v from fx where k='prod')::uuid, (select v from fx where k='var')::uuid, 20
from (values ('ba'), ('bb')) t(b);

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
select 'x-sa',  'Staff A',  'x-sa@test.local',  'staff', (select v from fx where k='ba')::uuid, 'active', true,  true
union all select 'x-sb',  'Staff B',  'x-sb@test.local',  'staff', (select v from fx where k='bb')::uuid, 'active', true,  true
union all select 'x-sc',  'Staff C (no flags)', 'x-sc@test.local', 'staff', (select v from fx where k='ba')::uuid, 'active', false, false
union all select 'x-own', 'Owner',    'x-own@test.local', 'owner', null, 'active', false, false;

insert into public.customer_profiles (firebase_uid, full_name, email, phone)
values ('x-c1', 'Cust One', 'x-c1@test.local', '09180000001');
insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city)
values ('x-c1', 'Cust One', '09180000001', '1 Private St', 'Calamba');
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent)
values ('default', 1, 50) on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50;

-- Batches via the real RPC (owner works in both branches).
select pg_temp.call_as('x-own', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-A1', 5, current_date + 90, null, null, true)::text$q$,
  (select v from fx where k='ba'), (select v from fx where k='var')));
select pg_temp.call_as('x-own', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-B1', 5, current_date + 90, null, null, true)::text$q$,
  (select v from fx where k='bb'), (select v from fx where k='var')));
insert into fx select 'batch_a', id::text from public.inventory_batches where batch_code = 'XB-A1';
insert into fx select 'batch_b', id::text from public.inventory_batches where batch_code = 'XB-B1';

-- Customer places two pickup orders at branch B through the real checkout.
do $$
declare v_cart text; v_order text; i int;
begin
  for i in 1..2 loop
    v_cart := pg_temp.call_as('x-c1', format($q$select (public.sync_customer_cart(%L::uuid,
        jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false) ->> 'cart_id')$q$,
        (select v from fx where k='bb'), (select v from fx where k='prod'), (select v from fx where k='var')));
    v_order := pg_temp.call_as('x-c1', format($q$select public.place_order(%L::uuid, false, null, 'Cash on Counter Pickup', '', %L)$q$,
        v_cart, 'xb-key-' || i));
    insert into fx values ('order' || i, v_order);
  end loop;
end $$;

-- Order 1: legitimately completed by branch B staff, then the customer asks for a refund.
select pg_temp.call_as('x-sb', format($q$select public.staff_confirm_payment(%L, null)::text$q$, (select v from fx where k='order1')));
select pg_temp.call_as('x-sb', format($q$select public.staff_update_order_status(%L, 'confirmed')::text$q$, (select v from fx where k='order1')));
select pg_temp.call_as('x-sb', format($q$select public.staff_update_order_status(%L, 'preparing')::text$q$, (select v from fx where k='order1')));
select pg_temp.call_as('x-sb', format($q$select public.staff_update_order_status(%L, 'readyForPickup')::text$q$, (select v from fx where k='order1')));
select pg_temp.call_as('x-sb', format($q$select public.staff_update_order_status(%L, 'completed')::text$q$, (select v from fx where k='order1')));
insert into fx select 'refund1', (pg_temp.call_as('x-c1', format(
  $q$select public.request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','XB-TEST Nut','variant_label','Regular','quantity',1)))$q$,
  (select v from fx where k='order1'))));

-- A transfer FROM branch B TO branch A, requested legitimately by A's staff.
insert into fx select 'xfer', pg_temp.call_as('x-sa', format($q$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 2, 'xb')$q$,
  (select v from fx where k='bb'), (select v from fx where k='ba'), (select v from fx where k='var')));

-- 0. Positive controls (so a later denial can't be blamed on broken fixtures) -----
select pg_temp.chk('control: B staff CAN adjust B''s batch', 'x-sb',
  format($$select public.staff_adjust_batch(%L::uuid, 1, 'Recount')$$, (select v from fx where k='batch_b')), 'ok');
select pg_temp.chk('control: A staff CAN adjust A''s batch', 'x-sa',
  format($$select public.staff_adjust_batch(%L::uuid, 1, 'Recount')$$, (select v from fx where k='batch_a')), 'ok');
select pg_temp.chk('control: owner CAN adjust either branch''s batch', 'x-own',
  format($$select public.staff_adjust_batch(%L::uuid, 1, 'Recount')$$, (select v from fx where k='batch_b')), 'ok');
select pg_temp.chk_true('control: fixture refund and orders exist',
  (select v from fx where k='refund1') is not null and (select v from fx where k='order2') is not null,
  coalesce((select v from fx where k='refund1'), 'no refund'));

-- 1. Staff A attacks branch B's WRITES ------------------------------------------
select pg_temp.chk('A cannot adjust B''s batch', 'x-sa',
  format($$select public.staff_adjust_batch(%L::uuid, 50, 'Recount')$$, (select v from fx where k='batch_b')), 'error');
select pg_temp.chk('A cannot receive stock into B', 'x-sa',
  format($$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-EVIL', 10, current_date + 30)$$, (select v from fx where k='bb'), (select v from fx where k='var')), 'error');
select pg_temp.chk('A cannot change status of B''s order', 'x-sa',
  format($$select public.staff_update_order_status(%L, 'confirmed')$$, (select v from fx where k='order2')), 'error');
select pg_temp.chk('A cannot confirm payment of B''s order', 'x-sa',
  format($$select public.staff_confirm_payment(%L, null)$$, (select v from fx where k='order2')), 'error');
select pg_temp.chk('A cannot review B''s refund', 'x-sa',
  format($$select public.staff_review_refund(%L, 'approve')$$, (select v from fx where k='refund1')), 'error');
select pg_temp.chk('A cannot ring a POS sale at B', 'x-sa',
  format($$select public.staff_create_pos_sale(%L::uuid, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'cash', null, 500, null, 'xb-pos-evil')$$,
    (select v from fx where k='bb'), (select v from fx where k='var')), 'error');
select pg_temp.chk('A cannot request a transfer INTO B', 'x-sa',
  format($$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 1)$$, (select v from fx where k='ba'), (select v from fx where k='bb'), (select v from fx where k='var')), 'error');
select pg_temp.chk('A cannot ship stock OUT of B', 'x-sa',
  format($$select public.staff_respond_transfer(%L, 'ship')$$, (select v from fx where k='xfer')), 'error');
select pg_temp.chk('A cannot reject a transfer sourced from B', 'x-sa',
  format($$select public.staff_respond_transfer(%L, 'reject')$$, (select v from fx where k='xfer')), 'error');

-- 2. Staff A attacks branch B's READS (RPCs) ------------------------------------
-- Non-owners asking for another branch are silently re-scoped to their OWN branch
-- (fail-closed). So the assertion is on CONTENT: nothing of B's may come back.
select pg_temp.chk_true('A asking for B''s inventory gets A''s branch, never B''s',
  pg_temp.call_as('x-sa', format($$select (public.staff_get_inventory(%L::uuid) ->> 'branch_id')$$, (select v from fx where k='bb')))
    = (select v from fx where k='ba'));
select pg_temp.chk_true('A asking for B''s orders gets none of B''s orders',
  position((select v from fx where k='order2') in
    pg_temp.call_as('x-sa', format($$select public.staff_list_orders(%L::uuid, null, null, 50, null)::text$$, (select v from fx where k='bb')))) = 0);
select pg_temp.chk_true('control: B''s own order list does contain B''s order',
  position((select v from fx where k='order2') in
    pg_temp.call_as('x-sb', format($$select public.staff_list_orders(%L::uuid, null, null, 50, null)::text$$, (select v from fx where k='bb')))) > 0);
select pg_temp.chk_true('A asking for B''s refunds gets none of B''s refunds',
  position((select v from fx where k='refund1') in
    pg_temp.call_as('x-sa', format($$select public.staff_list_refunds(%L::uuid, null)::text$$, (select v from fx where k='bb')))) = 0);
select pg_temp.chk_true('control: B''s own refund list does contain B''s refund',
  position((select v from fx where k='refund1') in
    pg_temp.call_as('x-sb', format($$select public.staff_list_refunds(%L::uuid, null)::text$$, (select v from fx where k='bb')))) > 0);
select pg_temp.chk_true('A asking for B''s dashboard is scoped to A''s branch',
  coalesce(pg_temp.call_as('x-sa', format($$select (public.staff_get_dashboard(%L::uuid))::text$$, (select v from fx where k='bb'))), '')
    not like '%' || (select v from fx where k='order2') || '%');

-- 3. Staff A attacks via direct table access (RLS) ------------------------------
select pg_temp.chk_true('A sees none of B''s orders (RLS)', pg_temp.visible('x-sa', format($$select count(*) from public.orders where branch_id = %L::uuid$$, (select v from fx where k='bb'))) = 0);
select pg_temp.chk_true('control: B sees its own orders (RLS)', pg_temp.visible('x-sb', format($$select count(*) from public.orders where branch_id = %L::uuid$$, (select v from fx where k='bb'))) >= 2);
select pg_temp.chk_true('A sees none of B''s refunds (RLS)', pg_temp.visible('x-sa', $$select count(*) from public.refund_requests$$) = 0);
select pg_temp.chk_true('A sees none of B''s batches (RLS)', pg_temp.visible('x-sa', format($$select count(*) from public.inventory_batches where branch_id = %L::uuid$$, (select v from fx where k='bb'))) = 0);
select pg_temp.chk_true('A sees none of B''s stock movements (RLS)', pg_temp.visible('x-sa', format($$select count(*) from public.stock_movements where branch_id = %L::uuid$$, (select v from fx where k='bb'))) = 0);
select pg_temp.chk_true('A sees none of B''s POS rows (RLS)', pg_temp.visible('x-sa', format($$select count(*) from public.pos_sales where branch_id = %L::uuid$$, (select v from fx where k='bb'))) = 0);
select pg_temp.chk_true('A sees no customer profiles (RLS)', pg_temp.visible('x-sa', $$select count(*) from public.customer_profiles$$) = 0);
select pg_temp.chk_true('A sees no customer addresses (RLS)', pg_temp.visible('x-sa', $$select count(*) from public.customer_addresses$$) = 0);
select pg_temp.chk_true('A sees no loyalty accounts (RLS)', pg_temp.visible('x-sa', $$select count(*) from public.loyalty_accounts$$) = 0);
select pg_temp.chk_true('A sees none of B''s order lines (RLS)',
  pg_temp.visible('x-sa', format($$select count(*) from public.order_items where order_id = %L$$, (select v from fx where k='order2'))) = 0);
select pg_temp.chk_true('A sees none of B''s payments (RLS)',
  pg_temp.visible('x-sa', format($$select count(*) from public.payments where order_id = %L$$, (select v from fx where k='order2'))) = 0);
select pg_temp.chk('A cannot UPDATE an order directly', 'x-sa', format($$update public.orders set status = 'cancelled' where id = %L$$, (select v from fx where k='order2')), 'error');
select pg_temp.chk('A cannot UPDATE stock directly', 'x-sa', $$update public.branch_inventory set quantity = 9999$$, 'error');
select pg_temp.chk('A cannot INSERT a batch directly', 'x-sa',
  format($$insert into public.inventory_batches (branch_id, product_id, variant_id, batch_code, expiration_date, quantity, initial_quantity) values (%L::uuid, %L::uuid, %L::uuid, 'DIRECT', current_date+9, 5, 5)$$,
  (select v from fx where k='ba'), (select v from fx where k='prod'), (select v from fx where k='var')), 'error');
select pg_temp.chk('A cannot read the cost table', 'x-sa', $$select * from public.product_variant_costs$$, 'error');

-- 4. Permission flags: staff C holds neither inventory nor refund rights -------------
select pg_temp.chk('C (no inventory flag) cannot adjust even own branch''s batch', 'x-sc',
  format($$select public.staff_adjust_batch(%L::uuid, 1, 'Recount')$$, (select v from fx where k='batch_a')), 'error');
select pg_temp.chk('C (no inventory flag) cannot receive stock', 'x-sc',
  format($$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-C', 5, current_date + 30)$$, (select v from fx where k='ba'), (select v from fx where k='var')), 'error');
select pg_temp.chk('C (no refund flag) cannot review a refund even if it were in-branch', 'x-sc',
  format($$select public.staff_review_refund(%L, 'approve')$$, (select v from fx where k='refund1')), 'error');

-- 5. Customers and the signed-out cannot reach staff RPCs ---------------------
select pg_temp.chk('customer cannot adjust a batch', 'x-c1', format($$select public.staff_adjust_batch(%L::uuid, 5, 'x')$$, (select v from fx where k='batch_b')), 'error');
select pg_temp.chk('customer cannot confirm own payment', 'x-c1', format($$select public.staff_confirm_payment(%L, 'REF-12345')$$, (select v from fx where k='order2')), 'error');
select pg_temp.chk('customer cannot complete own order', 'x-c1', format($$select public.staff_update_order_status(%L, 'completed')$$, (select v from fx where k='order2')), 'error');
select pg_temp.chk('customer cannot approve own refund', 'x-c1', format($$select public.staff_review_refund(%L, 'approve')$$, (select v from fx where k='refund1')), 'error');
select pg_temp.chk('customer cannot look up other customers', 'x-c1', $$select public.staff_lookup_customer('x-c1@test.local')$$, 'error');
select pg_temp.chk('customer cannot read owner analytics', 'x-c1', $$select public.owner_sales_summary(30)$$, 'error');
select pg_temp.chk('customer cannot provision themselves as owner', 'x-c1', $$select public.owner_upsert_staff_member('x-c1', 'me', 'x-c1@test.local', 'owner')$$, 'error');
select pg_temp.chk('staff (non-owner) cannot read owner analytics', 'x-sa', $$select public.owner_sales_summary(30)$$, 'error');
select pg_temp.chk('staff (non-owner) cannot provision an owner', 'x-sa', $$select public.owner_upsert_staff_member('x-sa', 'me', 'x-sa@test.local', 'owner')$$, 'error');
select pg_temp.chk('anon cannot adjust a batch', null, format($$select public.staff_adjust_batch(%L::uuid, 5, 'x')$$, (select v from fx where k='batch_b')), 'error');
select pg_temp.chk('anon cannot read owner analytics', null, $$select public.owner_sales_summary(30)$$, 'error');
select pg_temp.chk('owner CAN read owner analytics (control)', 'x-own', $$select public.owner_sales_summary(30)$$, 'ok');

-- 6. Replay behaviour (what an offline queue relies on) --------------------------
select pg_temp.chk('POS: replaying the same idempotency key does not double-sell', 'x-sb',
  format($$select public.staff_create_pos_sale(%L::uuid, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'cash', null, 500, null, 'xb-pos-1')$$,
    (select v from fx where k='bb'), (select v from fx where k='var')), 'ok');
select pg_temp.chk('POS: replay returns the original, no error', 'x-sb',
  format($$select public.staff_create_pos_sale(%L::uuid, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'cash', null, 500, null, 'xb-pos-1')$$,
    (select v from fx where k='bb'), (select v from fx where k='var')), 'ok');
select pg_temp.chk_true('POS replay created exactly one sale',
  (select count(*) from public.orders where idempotency_key = 'xb-pos-1') = 1);

-- 6b. Idempotency keys (20261008020000) -------------------------------------------
-- Helper: a stock number read as admin, so the assertions are about real state.
create function pg_temp.batch_qty(p_code text) returns int language sql as
  $$ select quantity from public.inventory_batches where batch_code = p_code $$;
grant execute on function pg_temp.batch_qty(text) to public;

insert into fx values ('qty_before', pg_temp.batch_qty('XB-B1')::text);

select pg_temp.chk('keyed adjust: first call applies', 'x-sb',
  format($$select public.staff_adjust_batch(%L::uuid, 3, 'Keyed probe', null, 'adjust-key-0001')$$, (select v from fx where k='batch_b')), 'ok');
insert into fx values ('first_result', pg_temp.call_as('x-sb',
  format($q$select public.staff_adjust_batch(%L::uuid, 3, 'Keyed probe', null, 'adjust-key-0001')::text$q$, (select v from fx where k='batch_b'))));
select pg_temp.chk_true('keyed adjust: replay applied exactly once (+3, not +6)',
  pg_temp.batch_qty('XB-B1') = (select v from fx where k='qty_before')::int + 3,
  'before ' || (select v from fx where k='qty_before') || ', after ' || pg_temp.batch_qty('XB-B1'));
select pg_temp.chk_true('keyed adjust: replay recorded one movement',
  (select count(*) from public.stock_movements where reason = 'Keyed probe') = 1);
select pg_temp.chk_true('keyed adjust: replay returns the ORIGINAL result',
  (select v from fx where k='first_result')::jsonb ->> 'adjustment' = '3'
  and (select v from fx where k='first_result')::jsonb ->> 'new_quantity' = (pg_temp.batch_qty('XB-B1'))::text);

select pg_temp.chk('keyed adjust: same key + different delta is refused', 'x-sb',
  format($$select public.staff_adjust_batch(%L::uuid, 7, 'Keyed probe', null, 'adjust-key-0001')$$, (select v from fx where k='batch_b')), 'error');
select pg_temp.chk('keyed adjust: same key + different reason is refused', 'x-sb',
  format($$select public.staff_adjust_batch(%L::uuid, 3, 'Damaged', null, 'adjust-key-0001')$$, (select v from fx where k='batch_b')), 'error');
-- Same key, same staff, DIFFERENT batch: the owner can reach both branches.
select pg_temp.chk('keyed adjust: key first used on batch A', 'x-own',
  format($$select public.staff_adjust_batch(%L::uuid, 1, 'Keyed probe', null, 'adjust-key-0004')$$, (select v from fx where k='batch_a')), 'ok');
select pg_temp.chk('keyed adjust: same key + different batch is refused', 'x-own',
  format($$select public.staff_adjust_batch(%L::uuid, 1, 'Keyed probe', null, 'adjust-key-0004')$$, (select v from fx where k='batch_b')), 'error');
select pg_temp.chk_true('keyed adjust: mismatches changed no stock', pg_temp.batch_qty('XB-B1') = (select v from fx where k='qty_before')::int + 3);

-- Keys are scoped per staff member: the owner using the same key string runs independently.
select pg_temp.chk('keyed adjust: another staff member''s identical key is NOT a replay', 'x-own',
  format($$select public.staff_adjust_batch(%L::uuid, 3, 'Keyed probe', null, 'adjust-key-0001')$$, (select v from fx where k='batch_b')), 'ok');
select pg_temp.chk_true('keyed adjust: per-staff scoping applied the second staff member''s change',
  pg_temp.batch_qty('XB-B1') = (select v from fx where k='qty_before')::int + 6);

-- A FAILED attempt stores nothing, so the same key can be retried with a corrected request.
select pg_temp.chk('keyed adjust: an invalid attempt fails', 'x-sb',
  format($$select public.staff_adjust_batch(%L::uuid, -999999, 'Keyed probe', null, 'adjust-key-0003')$$, (select v from fx where k='batch_b')), 'error');
select pg_temp.chk('keyed adjust: failed key can be reused for a corrected request', 'x-sb',
  format($$select public.staff_adjust_batch(%L::uuid, 1, 'Keyed probe', null, 'adjust-key-0003')$$, (select v from fx where k='batch_b')), 'ok');

select pg_temp.chk('keyed adjust: a too-short key is refused', 'x-sb',
  format($$select public.staff_adjust_batch(%L::uuid, 1, 'Keyed probe', null, 'abc')$$, (select v from fx where k='batch_b')), 'error');
select pg_temp.chk('keyed adjust: unauthorized staff cannot use a key to probe', 'x-sa',
  format($$select public.staff_adjust_batch(%L::uuid, 1, 'Keyed probe', null, 'adjust-key-0001')$$, (select v from fx where k='batch_b')), 'error');
select pg_temp.chk_true('keyed adjust: the refused call stored nothing for that staff member',
  (select count(*) from public.staff_request_keys where firebase_uid = 'x-sa' and idempotency_key = 'adjust-key-0001') = 0);

-- Transfers
insert into fx values ('xfer_k1', pg_temp.call_as('x-sa', format($q$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 1, 'keyed', 'xfer-key-00001')$q$,
  (select v from fx where k='bb'), (select v from fx where k='ba'), (select v from fx where k='var'))));
insert into fx values ('xfer_k2', pg_temp.call_as('x-sa', format($q$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 1, 'keyed', 'xfer-key-00001')$q$,
  (select v from fx where k='bb'), (select v from fx where k='ba'), (select v from fx where k='var'))));
select pg_temp.chk_true('keyed transfer: replay returns the SAME transfer id',
  (select v from fx where k='xfer_k1') is not null and (select v from fx where k='xfer_k1') = (select v from fx where k='xfer_k2'));
select pg_temp.chk_true('keyed transfer: replay created exactly one row',
  (select count(*) from public.stock_transfers where note = 'keyed') = 1);
select pg_temp.chk('keyed transfer: same key + different quantity is refused', 'x-sa',
  format($$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 2, 'keyed', 'xfer-key-00001')$$,
  (select v from fx where k='bb'), (select v from fx where k='ba'), (select v from fx where k='var')), 'error');
select pg_temp.chk('keyed transfer: key first used for B -> A', 'x-own',
  format($$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 1, 'keyed-own', 'xfer-key-00003')$$,
  (select v from fx where k='bb'), (select v from fx where k='ba'), (select v from fx where k='var')), 'ok');
select pg_temp.chk('keyed transfer: same key + reversed direction is refused', 'x-own',
  format($$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 1, 'keyed-own', 'xfer-key-00003')$$,
  (select v from fx where k='ba'), (select v from fx where k='bb'), (select v from fx where k='var')), 'error');
select pg_temp.chk_true('keyed transfer: the refused reversal created no row',
  (select count(*) from public.stock_transfers where note = 'keyed-own') = 1);
select pg_temp.chk('keyed transfer: A still cannot request INTO B with a key', 'x-sa',
  format($$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 1, 'x', 'xfer-key-00002')$$,
  (select v from fx where k='ba'), (select v from fx where k='bb'), (select v from fx where k='var')), 'error');

-- The bookkeeping table and helpers are sealed off from clients.
select pg_temp.chk('staff cannot read the key table', 'x-sb', $$select * from public.staff_request_keys$$, 'error');
select pg_temp.chk('staff cannot write the key table', 'x-sb', $$insert into public.staff_request_keys values ('x-sb','forged-key-1','adjust_batch','h','{}')$$, 'error');
select pg_temp.chk('customer cannot read the key table', 'x-c1', $$select * from public.staff_request_keys$$, 'error');
select pg_temp.chk('anon cannot read the key table', null, $$select * from public.staff_request_keys$$, 'error');
select pg_temp.chk('staff cannot call the internal begin helper', 'x-sb', $$select public._idem_begin('x-sb','adjust-key-0001','adjust_batch','{}'::jsonb)$$, 'error');
select pg_temp.chk('staff cannot call the internal finish helper', 'x-sb', $$select public._idem_finish('x-sb','forged-key-2','adjust_batch','{}'::jsonb,'{}'::jsonb)$$, 'error');
select pg_temp.chk('anon cannot call the keyed adjust RPC', null,
  format($$select public.staff_adjust_batch(%L::uuid, 1, 'x', null, 'adjust-key-0009')$$, (select v from fx where k='batch_b')), 'error');
select pg_temp.chk_true('no stale 4-argument adjust overload remains',
  not exists (select 1 from pg_proc where proname = 'staff_adjust_batch' and pronargs = 4));
select pg_temp.chk_true('no stale 5-argument transfer overload remains',
  not exists (select 1 from pg_proc where proname = 'staff_request_transfer' and pronargs = 5));

-- 6c. Replay-safe transfer responses and receive-batch (20261008030000) ------------
create function pg_temp.inv_qty(p_branch uuid) returns int language sql as
  $$ select quantity from public.branch_inventory
     where branch_id = p_branch and variant_id = (select v from fx where k='var')::uuid $$;
grant execute on function pg_temp.inv_qty(uuid) to public;
create function pg_temp.n(p_sql text) returns bigint language plpgsql as $$ declare v bigint; begin execute p_sql into v; return v; end $$;
grant execute on function pg_temp.n(text) to public;

insert into fx values ('t1', pg_temp.call_as('x-sa', format($q$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 2, 'life')$q$,
  (select v from fx where k='bb'), (select v from fx where k='ba'), (select v from fx where k='var'))));
insert into fx values ('t1_b0', pg_temp.inv_qty((select v from fx where k='bb')::uuid)::text);
insert into fx values ('t1_a0', pg_temp.inv_qty((select v from fx where k='ba')::uuid)::text);
select pg_temp.chk('control: B ships the transfer', 'x-sb', format($$select public.staff_respond_transfer(%L, 'ship')$$, (select v from fx where k='t1')), 'ok');
insert into fx values ('t1_lines', pg_temp.n(format($q$select count(*) from public.stock_transfer_batches where transfer_id = %L$q$, (select v from fx where k='t1'))) ::text);
insert into fx values ('t1_out', pg_temp.n(format($q$select count(*) from public.stock_movements where movement_type = 'transfer_out' and reference = %L$q$, (select v from fx where k='t1')))::text);
select pg_temp.chk('replayed ship succeeds (no error)', 'x-sb', format($$select public.staff_respond_transfer(%L, 'ship')$$, (select v from fx where k='t1')), 'ok');
select pg_temp.chk('double-tapped ship succeeds again', 'x-sb', format($$select public.staff_respond_transfer(%L, 'ship')$$, (select v from fx where k='t1')), 'ok');
select pg_temp.chk_true('ship replays moved the source stock once (-2)', pg_temp.inv_qty((select v from fx where k='bb')::uuid) = (select v from fx where k='t1_b0')::int - 2, 'before ' || (select v from fx where k='t1_b0') || ', now ' || pg_temp.inv_qty((select v from fx where k='bb')::uuid));
select pg_temp.chk_true('ship replays did not duplicate the batch lines', pg_temp.n(format($q$select count(*) from public.stock_transfer_batches where transfer_id = %L$q$, (select v from fx where k='t1'))) = (select v from fx where k='t1_lines')::int and (select v from fx where k='t1_lines')::int >= 1);
select pg_temp.chk_true('ship replays did not duplicate the outgoing movements', pg_temp.n(format($q$select count(*) from public.stock_movements where movement_type = 'transfer_out' and reference = %L$q$, (select v from fx where k='t1'))) = (select v from fx where k='t1_out')::int and (select v from fx where k='t1_out')::int >= 1, 'movements ' || (select v from fx where k='t1_out'));
select pg_temp.chk('control: A receives the transfer', 'x-sa', format($$select public.staff_respond_transfer(%L, 'receive')$$, (select v from fx where k='t1')), 'ok');
insert into fx values ('t1_in', pg_temp.n(format($q$select count(*) from public.stock_movements where movement_type = 'transfer_in' and reference = %L$q$, (select v from fx where k='t1')))::text);
select pg_temp.chk('replayed receive succeeds (no error)', 'x-sa', format($$select public.staff_respond_transfer(%L, 'receive')$$, (select v from fx where k='t1')), 'ok');
select pg_temp.chk('double-tapped receive succeeds again', 'x-sa', format($$select public.staff_respond_transfer(%L, 'receive')$$, (select v from fx where k='t1')), 'ok');
select pg_temp.chk_true('receive replays added the stock once (+2)', pg_temp.inv_qty((select v from fx where k='ba')::uuid) = (select v from fx where k='t1_a0')::int + 2, 'before ' || (select v from fx where k='t1_a0') || ', now ' || pg_temp.inv_qty((select v from fx where k='ba')::uuid));
select pg_temp.chk_true('receive replays did not duplicate the incoming movements', pg_temp.n(format($q$select count(*) from public.stock_movements where movement_type = 'transfer_in' and reference = %L$q$, (select v from fx where k='t1'))) = (select v from fx where k='t1_in')::int and (select v from fx where k='t1_in')::int >= 1);
select pg_temp.chk_true('the source branch stock is unchanged by the receive replays', pg_temp.inv_qty((select v from fx where k='bb')::uuid) = (select v from fx where k='t1_b0')::int - 2);
select pg_temp.chk('conflict: shipping an already-received transfer still errors', 'x-sb', format($$select public.staff_respond_transfer(%L, 'ship')$$, (select v from fx where k='t1')), 'error');
select pg_temp.chk('conflict: rejecting an already-received transfer still errors', 'x-sb', format($$select public.staff_respond_transfer(%L, 'reject')$$, (select v from fx where k='t1')), 'error');
select pg_temp.chk('conflict: cancelling an already-received transfer still errors', 'x-sa', format($$select public.staff_respond_transfer(%L, 'cancel')$$, (select v from fx where k='t1')), 'error');
select pg_temp.chk('replay still authorizes: destination staff cannot "ship" an in-transit/received transfer', 'x-sa', format($$select public.staff_respond_transfer(%L, 'ship')$$, (select v from fx where k='t1')), 'error');
select pg_temp.chk('replay still authorizes: source staff cannot "receive" for the destination', 'x-sb', format($$select public.staff_respond_transfer(%L, 'receive')$$, (select v from fx where k='t1')), 'error');
select pg_temp.chk('replay still authorizes: staff without the inventory flag cannot replay a receive', 'x-sc', format($$select public.staff_respond_transfer(%L, 'receive')$$, (select v from fx where k='t1')), 'error');
select pg_temp.chk('replay still authorizes: customer cannot replay a receive', 'x-c1', format($$select public.staff_respond_transfer(%L, 'receive')$$, (select v from fx where k='t1')), 'error');
insert into fx values ('t2', pg_temp.call_as('x-sa', format($q$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 2, 'reject-path')$q$,
  (select v from fx where k='bb'), (select v from fx where k='ba'), (select v from fx where k='var'))));
select pg_temp.chk('wrong-state: receiving a transfer that was never shipped errors', 'x-sa', format($$select public.staff_respond_transfer(%L, 'receive')$$, (select v from fx where k='t2')), 'error');
select pg_temp.chk('control: B rejects the request', 'x-sb', format($$select public.staff_respond_transfer(%L, 'reject')$$, (select v from fx where k='t2')), 'ok');
select pg_temp.chk('replayed reject succeeds', 'x-sb', format($$select public.staff_respond_transfer(%L, 'reject')$$, (select v from fx where k='t2')), 'ok');
select pg_temp.chk('conflict: shipping a rejected transfer errors', 'x-sb', format($$select public.staff_respond_transfer(%L, 'ship')$$, (select v from fx where k='t2')), 'error');
select pg_temp.chk('conflict: cancelling a rejected transfer errors', 'x-sa', format($$select public.staff_respond_transfer(%L, 'cancel')$$, (select v from fx where k='t2')), 'error');
insert into fx values ('t3', pg_temp.call_as('x-sa', format($q$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 2, 'cancel-path')$q$,
  (select v from fx where k='bb'), (select v from fx where k='ba'), (select v from fx where k='var'))));
insert into fx values ('t3_b0', pg_temp.inv_qty((select v from fx where k='bb')::uuid)::text);
insert into fx values ('t3_a0', pg_temp.inv_qty((select v from fx where k='ba')::uuid)::text);
select pg_temp.chk('control: A cancels its request', 'x-sa', format($$select public.staff_respond_transfer(%L, 'cancel')$$, (select v from fx where k='t3')), 'ok');
select pg_temp.chk('replayed cancel succeeds', 'x-sa', format($$select public.staff_respond_transfer(%L, 'cancel')$$, (select v from fx where k='t3')), 'ok');
select pg_temp.chk('conflict: shipping a cancelled transfer errors', 'x-sb', format($$select public.staff_respond_transfer(%L, 'ship')$$, (select v from fx where k='t3')), 'error');
select pg_temp.chk('conflict: rejecting a cancelled transfer errors', 'x-sb', format($$select public.staff_respond_transfer(%L, 'reject')$$, (select v from fx where k='t3')), 'error');
select pg_temp.chk_true('reject/cancel replays moved no stock anywhere', pg_temp.inv_qty((select v from fx where k='bb')::uuid) = (select v from fx where k='t3_b0')::int and pg_temp.inv_qty((select v from fx where k='ba')::uuid) = (select v from fx where k='t3_a0')::int);

-- staff_receive_batch with a key
insert into fx values ('rb_b0', pg_temp.inv_qty((select v from fx where k='bb')::uuid)::text);
select pg_temp.chk('control: keyed receive creates the batch', 'x-sb', format($$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-KEYED', 4, current_date + 60, null, null, false, 'recv-key-0001')$$, (select v from fx where k='bb'), (select v from fx where k='var')), 'ok');
insert into fx values ('rb1', pg_temp.call_as('x-sb', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-KEYED', 4, current_date + 60, null, null, false, 'recv-key-0001')::text$q$, (select v from fx where k='bb'), (select v from fx where k='var'))));
select pg_temp.chk_true('keyed receive replay returns the ORIGINAL batch id', (select v from fx where k='rb1') is not null and (select v from fx where k='rb1')::uuid = (select id from public.inventory_batches where batch_code = 'XB-KEYED' and branch_id = (select v from fx where k='bb')::uuid));
select pg_temp.chk_true('keyed receive replay added the stock once (+4)', pg_temp.inv_qty((select v from fx where k='bb')::uuid) = (select v from fx where k='rb_b0')::int + 4, 'before ' || (select v from fx where k='rb_b0') || ', now ' || pg_temp.inv_qty((select v from fx where k='bb')::uuid));
select pg_temp.chk_true('keyed receive replay left exactly one batch and one movement', (select count(*) from public.inventory_batches where batch_code = 'XB-KEYED') = 1 and (select count(*) from public.stock_movements m join public.inventory_batches b on b.id = m.batch_id where b.batch_code = 'XB-KEYED' and m.movement_type = 'receive') = 1);
select pg_temp.chk('keyed receive: same key + different quantity is refused', 'x-sb', format($$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-KEYED', 9, current_date + 60, null, null, false, 'recv-key-0001')$$, (select v from fx where k='bb'), (select v from fx where k='var')), 'error');
select pg_temp.chk('keyed receive: same key + different batch code is refused', 'x-sb', format($$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-OTHER', 4, current_date + 60, null, null, false, 'recv-key-0001')$$, (select v from fx where k='bb'), (select v from fx where k='var')), 'error');
select pg_temp.chk('unkeyed receive of an existing code still errors (behaviour unchanged)', 'x-sb', format($$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-KEYED', 4, current_date + 60, null, null, false)$$, (select v from fx where k='bb'), (select v from fx where k='var')), 'error');
select pg_temp.chk_true('refused receives changed no stock', pg_temp.inv_qty((select v from fx where k='bb')::uuid) = (select v from fx where k='rb_b0')::int + 4);
select pg_temp.chk('keyed receive: A cannot receive into B', 'x-sa', format($$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-EVIL2', 3, current_date + 60, null, null, false, 'recv-key-0002')$$, (select v from fx where k='bb'), (select v from fx where k='var')), 'error');
select pg_temp.chk('keyed receive: staff without the inventory flag cannot receive', 'x-sc', format($$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-EVIL3', 3, current_date + 60, null, null, false, 'recv-key-0003')$$, (select v from fx where k='ba'), (select v from fx where k='var')), 'error');
select pg_temp.chk('keyed receive: customer cannot receive', 'x-c1', format($$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-EVIL4', 3, current_date + 60, null, null, false, 'recv-key-0004')$$, (select v from fx where k='bb'), (select v from fx where k='var')), 'error');
select pg_temp.chk('keyed receive: anon cannot receive', null, format($$select public.staff_receive_batch(%L::uuid, %L::uuid, 'XB-EVIL5', 3, current_date + 60, null, null, false, 'recv-key-0005')$$, (select v from fx where k='bb'), (select v from fx where k='var')), 'error');
select pg_temp.chk_true('no stale 8-argument receive overload remains', not exists (select 1 from pg_proc where proname = 'staff_receive_batch' and pronargs = 8));

-- Informational ("known gaps"): stock adjustments and transfer requests carry no
-- idempotency key, so an offline queue that replays them after a lost response
-- applies them twice. Printed separately; they do not fail the suite.
create temp table gaps (name text, observed text);
select pg_temp.call_as('x-sb', format($q$select public.staff_adjust_batch(%L::uuid, 3, 'Replay probe')::text$q$, (select v from fx where k='batch_b')));
select pg_temp.call_as('x-sb', format($q$select public.staff_adjust_batch(%L::uuid, 3, 'Replay probe')::text$q$, (select v from fx where k='batch_b')));
insert into gaps select '(no key supplied) same stock adjustment sent twice -> applied N times',
  (select count(*)::text from public.stock_movements where reason like 'Replay probe%');
select pg_temp.call_as('x-sa', format($q$select public.staff_request_transfer(%L::uuid, %L::uuid, %L::uuid, 2, 'xb')$q$,
  (select v from fx where k='bb'), (select v from fx where k='ba'), (select v from fx where k='var')));
insert into gaps select '(no key supplied) same transfer request sent twice -> N transfer rows',
  (select count(*)::text from public.stock_transfers
   where from_branch_id = (select v from fx where k='bb')::uuid and to_branch_id = (select v from fx where k='ba')::uuid
     and status = 'requested' and note = 'xb' and requested_by = 'x-sa');
select pg_temp.call_as('x-sb', format($q$select public.staff_confirm_payment(%L, 'REUSED-REF-1')::text$q$, (select v from fx where k='order2')));
insert into fx select 'order3', pg_temp.call_as('x-c1', format($q$select public.place_order(%L::uuid, false, null, 'GCash E-Wallet', '', 'xb-key-3')$q$,
  pg_temp.call_as('x-c1', format($q$select (public.sync_customer_cart(%L::uuid,
    jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false) ->> 'cart_id')$q$,
    (select v from fx where k='bb'), (select v from fx where k='prod'), (select v from fx where k='var')))));
select pg_temp.call_as('x-sb', format($q$select public.staff_confirm_payment(%L, 'REUSED-REF-1')::text$q$, (select v from fx where k='order3')));
insert into gaps select 'same payment reference accepted on two different orders -> N payments (want 1)',
  (select count(*)::text from public.payments where reference_number = 'REUSED-REF-1');

-- Report ---------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;

select 'KNOWN GAP' as kind, name, observed from gaps;

do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% staff cross-branch check(s) FAILED — see the report above.', n; end if;
end $$;

rollback;
