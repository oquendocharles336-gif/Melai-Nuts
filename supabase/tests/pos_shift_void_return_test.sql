-- =============================================================================
-- Melai Nuts — POS shifts, voids, counter returns, returned-stock receipt
-- (migration 20261010000000_pos_shifts_voids_returns.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pos_shift_void_return_test.sql
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
insert into public.branches (name, address) values ('POS-TEST A', 'a'), ('POS-TEST B', 'b');
insert into fx select 'ba', id::text from public.branches where name = 'POS-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'POS-TEST B';
insert into public.product_categories (label) values ('POS-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'POS-TEST Nut', 100, 'pack' from public.product_categories where label = 'POS-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'POS-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'POS-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select pg_temp.f(b)::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 0 from (values ('ba'), ('bb')) t(b);

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
values ('p-sa',  'Cashier A', 'p-sa@test.local',  'staff', pg_temp.f('ba')::uuid, 'active', true, true),
       ('p-sa2', 'Cashier A2 (no refunds)', 'p-sa2@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', false, false),
       ('p-mgr', 'Manager A', 'p-mgr@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', true, true),
       ('p-sb',  'Cashier B', 'p-sb@test.local',  'staff', pg_temp.f('bb')::uuid, 'active', true, true),
       ('p-own', 'Owner',     'p-own@test.local', 'owner', null, 'active', false, false);
insert into public.staff_permission_grants (firebase_uid, permission, granted_by) values ('p-mgr', 'void_pos_sales', 'p-own');
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values ('p-c1', 'Cust', 'p-c1@test.local', '09170000009');

select pg_temp.call_as('p-own', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'POS-A1', 50, current_date + 90)::text$q$,
  pg_temp.f('ba'), pg_temp.f('var')));
select pg_temp.call_as('p-own', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'POS-B1', 50, current_date + 90)::text$q$,
  pg_temp.f('bb'), pg_temp.f('var')));

-- staff_receive_batch sets the transaction-local flag app.inventory_managed; in
-- production every RPC is its own transaction, but this suite is ONE
-- transaction, so clear it or the FEFO batch sync would be skipped below.
select set_config('app.inventory_managed', '', true);

create function pg_temp.sale(p_uid text, p_branch text, p_qty int, p_method text, p_key text, p_customer text default null)
returns text language sql as $$
  select (pg_temp.call_as(p_uid, format(
    $q$select public.staff_create_pos_sale(%L::uuid, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', %s)),
         %L, %L, %s, %L, %L)::text$q$,
    pg_temp.f(p_branch), pg_temp.f('var'), p_qty, p_method,
    case when p_method = 'cash' then null else 'REF-' || p_key end,
    case when p_method = 'cash' then '1000' else 'null' end, p_customer, p_key))::jsonb ->> 'order_id')
$$;

-- 1. Backward compatible: a sale with no shift still works --------------------
insert into fx values ('o_noshift', pg_temp.sale('p-sa', 'ba', 1, 'cash', 'pos-noshift-1'));
select pg_temp.chk_true('sale without an open shift still works (session_id null)',
  (select session_id is null from public.pos_sales where order_id = pg_temp.f('o_noshift')));

-- 2. Opening a shift -----------------------------------------------------------
select pg_temp.chk('negative opening cash refused', 'p-sa',
  format($q$select public.staff_open_shift(%L::uuid, -5)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('staff cannot open a shift in another branch', 'p-sa',
  format($q$select public.staff_open_shift(%L::uuid, 100)$q$, pg_temp.f('bb')), 'error');
select pg_temp.chk('customer cannot open a shift', 'p-c1',
  format($q$select public.staff_open_shift(%L::uuid, 100)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('anon cannot open a shift', null,
  format($q$select public.staff_open_shift(%L::uuid, 100)$q$, pg_temp.f('ba')), 'error');
insert into fx select 'shift_a', pg_temp.call_as('p-sa',
  format($q$select public.staff_open_shift(%L::uuid, 1000, 'open-key-0001') ->> 'session_id'$q$, pg_temp.f('ba')));
select pg_temp.chk_true('replay of open with same key returns the same shift',
  pg_temp.call_as('p-sa', format($q$select public.staff_open_shift(%L::uuid, 1000, 'open-key-0001') ->> 'session_id'$q$, pg_temp.f('ba')))
  = pg_temp.f('shift_a'));
select pg_temp.chk('second open shift refused', 'p-sa',
  format($q$select public.staff_open_shift(%L::uuid, 500, 'open-key-0002')$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk_true('exactly one shift row', (select count(*) = 1 from public.cash_drawer_sessions where staff_uid = 'p-sa'));
insert into fx select 'shift_m', pg_temp.call_as('p-mgr',
  format($q$select public.staff_open_shift(%L::uuid, 500) ->> 'session_id'$q$, pg_temp.f('ba')));

-- 3. Sales attach to the shift --------------------------------------------------
insert into fx values ('o_cash', pg_temp.sale('p-sa', 'ba', 2, 'cash', 'pos-cash-0001'));
insert into fx values ('o_gcash', pg_temp.sale('p-sa', 'ba', 1, 'gcash', 'pos-gcash-001'));
select pg_temp.chk_true('cash sale attached to the open shift',
  (select session_id = pg_temp.f('shift_a') from public.pos_sales where order_id = pg_temp.f('o_cash')));
select pg_temp.chk_true('other cashier''s sale does NOT attach to this shift',
  (select count(*) = 0 from public.pos_sales where session_id = pg_temp.f('shift_a') and staff_uid <> 'p-sa'));
create temp table s1 as select pg_temp.call_as('p-sa', 'select public.staff_get_current_shift()::text')::jsonb as j;
select pg_temp.chk_true('summary: 2 transactions', (select (j ->> 'transaction_count')::int = 2 from s1), (select j::text from s1));
select pg_temp.chk_true('summary: cash sales 200, gross 300', (select (j ->> 'cash_sales')::numeric = 200 and (j ->> 'gross_sales')::numeric = 300 from s1));
select pg_temp.chk_true('summary: expected cash = 1000 + 200', (select (j ->> 'expected_cash')::numeric = 1200 from s1));
select pg_temp.chk_true('summary: gcash broken out', (select (j -> 'by_method' -> 'gcash' ->> 'amount')::numeric = 100 from s1));

select pg_temp.chk('branch B staff cannot read branch A shift', 'p-sb',
  format($q$select public.staff_get_shift(%L)$q$, pg_temp.f('shift_a')), 'error');
select pg_temp.chk('branch B staff cannot close branch A shift', 'p-sb',
  format($q$select public.staff_close_shift(%L, 1200)$q$, pg_temp.f('shift_a')), 'error');
select pg_temp.chk('another cashier (no manager rights) cannot close my shift', 'p-sa2',
  format($q$select public.staff_close_shift(%L, 1200)$q$, pg_temp.f('shift_a')), 'error');
select pg_temp.chk_true('branch B staff sees 0 branch A shifts directly',
  pg_temp.visible('p-sb', format($q$select count(*) from public.cash_drawer_sessions where branch_id = %L$q$, pg_temp.f('ba'))) = 0);
select pg_temp.chk_true('customer sees 0 shifts', pg_temp.visible('p-c1', 'select count(*) from public.cash_drawer_sessions') = 0);
select pg_temp.chk_true('anon sees 0 shifts', pg_temp.visible(null, 'select count(*) from public.cash_drawer_sessions') = 0);
select pg_temp.chk('staff cannot insert drawer events directly', 'p-sa',
  format($q$insert into public.cash_drawer_events (session_id, event_type, amount, created_by) values (%L, 'paid_in', 5, 'p-sa')$q$, pg_temp.f('shift_a')), 'error');
select pg_temp.chk('staff cannot edit a shift directly', 'p-sa',
  format($q$update public.cash_drawer_sessions set opening_cash = 0 where id = %L$q$, pg_temp.f('shift_a')), 'error');

-- 4. Paid out ---------------------------------------------------------------------
select pg_temp.chk('paid out without reason refused', 'p-sa',
  format($q$select public.staff_record_cash_movement(%L, 'paid_out', 50, '')$q$, pg_temp.f('shift_a')), 'error');
select pg_temp.chk('paid out more than the drawer holds refused', 'p-sa',
  format($q$select public.staff_record_cash_movement(%L, 'paid_out', 99999, 'too much')$q$, pg_temp.f('shift_a')), 'error');
select pg_temp.chk('paid out 50 ok', 'p-sa',
  format($q$select public.staff_record_cash_movement(%L, 'paid_out', 50, 'Ice for display', 'move-key-001')$q$, pg_temp.f('shift_a')), 'ok');
select pg_temp.chk('paid out replay ok', 'p-sa',
  format($q$select public.staff_record_cash_movement(%L, 'paid_out', 50, 'Ice for display', 'move-key-001')$q$, pg_temp.f('shift_a')), 'ok');
select pg_temp.chk_true('paid out replay recorded once',
  (select count(*) = 1 from public.cash_drawer_events where session_id = pg_temp.f('shift_a') and event_type = 'paid_out'));
select pg_temp.chk_true('expected cash after paid out = 1150',
  (pg_temp.call_as('p-sa', 'select public.staff_get_current_shift() ->> ''expected_cash''')::numeric) = 1150);

-- 5. Void ---------------------------------------------------------------------------
insert into fx values ('stock_before_void', pg_temp.stock('ba')::text);
select pg_temp.chk('cashier without void permission cannot void', 'p-sa',
  format($q$select public.staff_void_pos_sale(%L, 'Wrong item rung')$q$, pg_temp.f('o_cash')), 'error');
select pg_temp.chk('branch B staff cannot void branch A sale', 'p-sb',
  format($q$select public.staff_void_pos_sale(%L, 'Wrong item rung')$q$, pg_temp.f('o_cash')), 'error');
select pg_temp.chk('void needs a reason', 'p-mgr',
  format($q$select public.staff_void_pos_sale(%L, '')$q$, pg_temp.f('o_cash')), 'error');
select pg_temp.chk('manager voids the cash sale', 'p-mgr',
  format($q$select public.staff_void_pos_sale(%L, 'Wrong item rung', 'void-key-0001')$q$, pg_temp.f('o_cash')), 'ok');
select pg_temp.chk('void replay with same key ok', 'p-mgr',
  format($q$select public.staff_void_pos_sale(%L, 'Wrong item rung', 'void-key-0001')$q$, pg_temp.f('o_cash')), 'ok');
select pg_temp.chk('second void refused', 'p-mgr',
  format($q$select public.staff_void_pos_sale(%L, 'Again', 'void-key-0002')$q$, pg_temp.f('o_cash')), 'error');
select pg_temp.chk_true('voided order is refunded', (select status = 'refunded' from public.orders where id = pg_temp.f('o_cash')));
select pg_temp.chk_true('voided payment is refunded', (select status = 'refunded' from public.payments where order_id = pg_temp.f('o_cash')));
select pg_temp.chk_true('void restocked 2 units', pg_temp.stock('ba') = pg_temp.f('stock_before_void')::int + 2,
  pg_temp.stock('ba')::text || ' vs ' || pg_temp.f('stock_before_void'));
select pg_temp.chk_true('void logged as return_restock movement',
  (select coalesce(sum(quantity_change), 0) = 2 from public.stock_movements
   where movement_type = 'return_restock' and reference = (select refund_id from public.pos_voids where order_id = pg_temp.f('o_cash'))));
select pg_temp.chk_true('batches still add up to branch stock',
  (select coalesce(sum(quantity), 0) from public.inventory_batches where branch_id = pg_temp.f('ba')::uuid and variant_id = pg_temp.f('var')::uuid)
  <= pg_temp.stock('ba'));
select pg_temp.chk_true('exactly one void row and one cash refund event',
  (select count(*) = 1 from public.pos_voids where order_id = pg_temp.f('o_cash'))
  and (select count(*) = 1 from public.cash_drawer_events where event_type = 'cash_refund' and session_id = pg_temp.f('shift_a')));
select pg_temp.chk_true('expected cash after void = 1150 - 200 = 950',
  (pg_temp.call_as('p-sa', 'select public.staff_get_current_shift() ->> ''expected_cash''')::numeric) = 950);
select pg_temp.chk_true('void written to the audit log',
  (select count(*) = 1 from public.staff_audit_logs where action = 'pos.void' and entity_id = pg_temp.f('o_cash')));

-- GCash void: stock back, refund waits for the wallet reversal, no drawer cash
select pg_temp.chk('manager voids the GCash sale', 'p-mgr',
  format($q$select public.staff_void_pos_sale(%L, 'Customer changed mind')$q$, pg_temp.f('o_gcash')), 'ok');
select pg_temp.chk_true('GCash void refund is approved (not completed)',
  (select r.status = 'approved' from public.refund_requests r where r.order_id = pg_temp.f('o_gcash')));
select pg_temp.chk_true('GCash void took no cash from the drawer',
  (select count(*) = 1 from public.cash_drawer_events where event_type = 'cash_refund' and session_id = pg_temp.f('shift_a')));
select pg_temp.chk('completing the GCash refund after the wallet reversal', 'p-mgr',
  format($q$select public.staff_review_refund((select id from public.refund_requests where order_id = %L), 'complete')$q$, pg_temp.f('o_gcash')), 'ok');
select pg_temp.chk_true('GCash payment is now refunded', (select status = 'refunded' from public.payments where order_id = pg_temp.f('o_gcash')));

-- Void of yesterday's sale refused (simulate by back-dating the sale row)
insert into fx values ('o_old', pg_temp.sale('p-mgr', 'ba', 1, 'cash', 'pos-old-00001'));
update public.pos_sales set created_at = now() - interval '2 days' where order_id = pg_temp.f('o_old');
select pg_temp.chk('void of a sale from another day refused', 'p-mgr',
  format($q$select public.staff_void_pos_sale(%L, 'late void')$q$, pg_temp.f('o_old')), 'error');
select pg_temp.chk('void of a cash sale with no shift refused', 'p-mgr',
  format($q$select public.staff_void_pos_sale(%L, 'no shift')$q$, pg_temp.f('o_noshift')), 'error');

-- 6. Counter return ----------------------------------------------------------------
insert into fx values ('o_ret', pg_temp.sale('p-sa', 'ba', 3, 'cash', 'pos-ret-00001'));
insert into fx values ('stock_before_ret', pg_temp.stock('ba')::text);
select pg_temp.chk('cashier without refund permission cannot return', 'p-sa2',
  format($q$select public.staff_pos_return(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'Stale')$q$,
    pg_temp.f('o_ret'), pg_temp.f('var')), 'error');
select pg_temp.chk('return more than sold refused', 'p-sa',
  format($q$select public.staff_pos_return(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 9)), 'Stale')$q$,
    pg_temp.f('o_ret'), pg_temp.f('var')), 'error');
select pg_temp.chk('return 1 sellable + 1 damaged', 'p-sa',
  format($q$select public.staff_pos_return(%L, jsonb_build_array(
      jsonb_build_object('variant_id', %L, 'quantity', 1, 'condition', 'sellable'),
      jsonb_build_object('variant_id', %L, 'quantity', 1, 'condition', 'damaged')), 'Stale taste', 'ret-key-0001')$q$,
    pg_temp.f('o_ret'), pg_temp.f('var'), pg_temp.f('var')), 'ok');
select pg_temp.chk_true('return refund amount = 2 x 100, completed',
  (select amount = 200 and status = 'completed' from public.refund_requests where order_id = pg_temp.f('o_ret')));
select pg_temp.chk_true('only the sellable unit went back to stock', pg_temp.stock('ba') = pg_temp.f('stock_before_ret')::int + 1);
select pg_temp.chk_true('both conditions recorded',
  (select count(*) = 2 from public.refund_returned_items ri join public.refund_requests r on r.id = ri.refund_id where r.order_id = pg_temp.f('o_ret')));
select pg_temp.chk('second return on the same sale refused', 'p-sa',
  format($q$select public.staff_pos_return(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'Again', 'ret-key-0002')$q$,
    pg_temp.f('o_ret'), pg_temp.f('var')), 'error');
select pg_temp.chk('receiving more than was refunded refused', 'p-sa',
  format($q$select public.staff_receive_returned_items((select id from public.refund_requests where order_id = %L),
      jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)))$q$, pg_temp.f('o_ret'), pg_temp.f('var')), 'error');

-- 7. Online-style refund: customer requests, staff approves, items received later
insert into fx values ('o_cust', pg_temp.sale('p-sa', 'ba', 2, 'cash', 'pos-cust-0001', 'p-c1'));
insert into fx select 'r_cust', pg_temp.call_as('p-c1', format(
  $q$select public.request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','POS-TEST Nut','variant_label','Regular','quantity',2)))$q$,
  pg_temp.f('o_cust')));
insert into fx values ('stock_before_cust', pg_temp.stock('ba')::text);
select pg_temp.chk('items cannot be received before approval', 'p-sa',
  format($q$select public.staff_receive_returned_items(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)))$q$,
    pg_temp.f('r_cust'), pg_temp.f('var')), 'error');
select pg_temp.call_as('p-sa', format($q$select public.staff_review_refund(%L, 'approve')::text$q$, pg_temp.f('r_cust')));
select pg_temp.chk_true('approving a refund alone does NOT restock', pg_temp.stock('ba') = pg_temp.f('stock_before_cust')::int);
select pg_temp.chk('branch B staff cannot receive branch A returns', 'p-sb',
  format($q$select public.staff_receive_returned_items(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)))$q$,
    pg_temp.f('r_cust'), pg_temp.f('var')), 'error');
select pg_temp.chk('receive 1 sellable', 'p-sa',
  format($q$select public.staff_receive_returned_items(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'rcv-key-0001')$q$,
    pg_temp.f('r_cust'), pg_temp.f('var')), 'ok');
select pg_temp.chk('receive replay', 'p-sa',
  format($q$select public.staff_receive_returned_items(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'rcv-key-0001')$q$,
    pg_temp.f('r_cust'), pg_temp.f('var')), 'ok');
select pg_temp.chk_true('received unit restocked exactly once', pg_temp.stock('ba') = pg_temp.f('stock_before_cust')::int + 1);
select pg_temp.chk('receive 1 expired', 'p-sa',
  format($q$select public.staff_receive_returned_items(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1, 'condition', 'expired')))$q$,
    pg_temp.f('r_cust'), pg_temp.f('var')), 'ok');
select pg_temp.chk('a third unit is refused (only 2 refunded)', 'p-sa',
  format($q$select public.staff_receive_returned_items(%L, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)))$q$,
    pg_temp.f('r_cust'), pg_temp.f('var')), 'error');

-- 8. Daily summary ------------------------------------------------------------------
create temp table d1 as select pg_temp.call_as('p-sa', format($q$select public.staff_cashier_daily_summary(%L::uuid)::text$q$, pg_temp.f('ba')))::jsonb as j;
select pg_temp.chk_true('daily summary: refunds include the completed void + return + gcash void',
  (select (j -> 'totals' ->> 'refunds')::numeric = 200 + 200 + 100 from d1), (select (j -> 'totals')::text from d1));
select pg_temp.chk_true('daily summary: net = gross - discounts - refunds',
  (select (j -> 'totals' ->> 'net_sales')::numeric
          = (j -> 'totals' ->> 'gross_sales')::numeric - (j -> 'totals' ->> 'discounts')::numeric - (j -> 'totals' ->> 'refunds')::numeric from d1));
select pg_temp.chk_true('daily summary: void count 2', (select (j -> 'totals' ->> 'void_count')::int = 2 from d1));
select pg_temp.chk_true('voids count against the cashier who rang the sale, not the manager',
  (select jsonb_array_length(j -> 'cashiers') = 1 and j -> 'cashiers' -> 0 ->> 'staff_uid' = 'p-sa'
          and (j -> 'cashiers' -> 0 ->> 'void_count')::int = 2 from d1), (select (j -> 'cashiers')::text from d1));
select pg_temp.chk('branch B staff cannot read branch A daily summary', 'p-sb',
  format($q$select public.staff_cashier_daily_summary(%L::uuid)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('owner can read any branch daily summary', 'p-own',
  format($q$select public.staff_cashier_daily_summary(%L::uuid)$q$, pg_temp.f('ba')), 'ok');

-- 9. Closing ------------------------------------------------------------------------
create temp table s2 as select pg_temp.call_as('p-sa', 'select public.staff_get_current_shift()::text')::jsonb as j;
select pg_temp.chk('close with a difference and no note refused', 'p-sa',
  format($q$select public.staff_close_shift(%L, %s)$q$, pg_temp.f('shift_a'), (select (j ->> 'expected_cash')::numeric - 10 from s2)), 'error');
select pg_temp.chk('close with a difference and a note', 'p-sa',
  format($q$select public.staff_close_shift(%L, %s, 'Short 10, coin miscount', 'close-key-001')$q$,
    pg_temp.f('shift_a'), (select (j ->> 'expected_cash')::numeric - 10 from s2)), 'ok');
select pg_temp.chk_true('closed shift stores expected, counted and -10 difference',
  (select status = 'closed' and cash_difference = -10 and expected_cash = (select (j ->> 'expected_cash')::numeric from s2)
   from public.cash_drawer_sessions where id = pg_temp.f('shift_a')));
select pg_temp.chk('close replay ok', 'p-sa',
  format($q$select public.staff_close_shift(%L, %s, 'Short 10, coin miscount', 'close-key-001')$q$,
    pg_temp.f('shift_a'), (select (j ->> 'expected_cash')::numeric - 10 from s2)), 'ok');
select pg_temp.chk('closing twice refused', 'p-sa',
  format($q$select public.staff_close_shift(%L, 0, 'again')$q$, pg_temp.f('shift_a')), 'error');
select pg_temp.chk('paid in on a closed shift refused', 'p-sa',
  format($q$select public.staff_record_cash_movement(%L, 'paid_in', 5, 'late coins')$q$, pg_temp.f('shift_a')), 'error');
select pg_temp.chk_true('managers are notified of the cash difference',
  (select count(*) >= 1 from public.staff_notifications where reference = pg_temp.f('shift_a') and recipient_uid = 'p-mgr'));
select pg_temp.chk('manager can close the cashier''s shift... (none open) but closes own', 'p-mgr',
  format($q$select public.staff_close_shift(%L, (public.staff_get_shift(%L) ->> 'expected_cash')::numeric)$q$, pg_temp.f('shift_m'), pg_temp.f('shift_m')), 'ok');
insert into fx values ('o_after', pg_temp.sale('p-sa', 'ba', 1, 'cash', 'pos-after-001'));
select pg_temp.chk_true('sale after close is not attached to the closed shift',
  (select session_id is null from public.pos_sales where order_id = pg_temp.f('o_after')));
select pg_temp.chk_true('list shifts for branch A shows 2', (select jsonb_array_length(
  pg_temp.call_as('p-sa', format($q$select public.staff_list_shifts(%L::uuid)::text$q$, pg_temp.f('ba')))::jsonb) = 2));

-- 10. Branch that requires a shift ---------------------------------------------------
update public.branches set pos_requires_shift = true where id = pg_temp.f('bb')::uuid;
select pg_temp.chk('branch requiring a shift refuses a sale without one', 'p-sb',
  format($q$select public.staff_create_pos_sale(%L::uuid, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'cash', null, 500)$q$,
    pg_temp.f('bb'), pg_temp.f('var')), 'error');
select pg_temp.chk_true('the refused sale left no stock change', pg_temp.stock('bb') = 50);
select pg_temp.call_as('p-sb', format($q$select public.staff_open_shift(%L::uuid, 0)::text$q$, pg_temp.f('bb')));
select pg_temp.chk('with an open shift the sale goes through', 'p-sb',
  format($q$select public.staff_create_pos_sale(%L::uuid, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 1)), 'cash', null, 500)$q$,
    pg_temp.f('bb'), pg_temp.f('var')), 'ok');

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% POS shift/void/return check(s) FAILED — see the report above.', n; end if;
end $$;

-- ROLLBACK_MARK
select movement_type, quantity_change, reference, batch_quantity_after from public.stock_movements where variant_id = pg_temp.f($$var$$)::uuid and branch_id = pg_temp.f($$ba$$)::uuid order by created_at;
select quantity, initial_quantity from public.inventory_batches where variant_id = pg_temp.f($$var$$)::uuid;
select pg_temp.stock($$ba$$), current_setting($$app.inventory_managed$$, true);
rollback;
