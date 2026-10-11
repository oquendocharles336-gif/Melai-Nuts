-- =============================================================================
-- Melai Nuts — suppliers, purchase receipts, OCR review
-- (migration 20261011010000_suppliers_purchase_receipts.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/purchase_receipts_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
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
create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;
create function pg_temp.f(p_k text) returns text language sql as $$ select v from fx where k = p_k $$;
grant execute on function pg_temp.f(text) to public;
create function pg_temp.j(p_uid text, p_sql text) returns jsonb language sql as $$
  select pg_temp.call_as(p_uid, 'select (' || p_sql || ')::text')::jsonb $$;

-- Fixtures ---------------------------------------------------------------------
insert into public.branches (name, address, delivery_fee) values ('PR-TEST A', 'a', 0), ('PR-TEST B', 'b', 0);
insert into fx select 'ba', id::text from public.branches where name = 'PR-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'PR-TEST B';
insert into public.product_categories (label) values ('PR-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, n, 120, 'pack' from public.product_categories, (values ('PR-TEST Garlic Peanuts'), ('PR-TEST Cashew')) v(n)
where label = 'PR-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 120 from public.products where name like 'PR-TEST %';
insert into fx select 'v1', pv.id::text from public.product_variants pv join public.products p on p.id = pv.product_id where p.name = 'PR-TEST Garlic Peanuts';
insert into fx select 'v2', pv.id::text from public.product_variants pv join public.products p on p.id = pv.product_id where p.name = 'PR-TEST Cashew';

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory)
values ('r-inv', 'Stock A', 'r-inv@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', true),
       ('r-cash', 'Cashier A', 'r-cash@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', false),
       ('r-invb', 'Stock B', 'r-invb@test.local', 'staff', pg_temp.f('bb')::uuid, 'active', true),
       ('r-own', 'Owner', 'r-own@test.local', 'owner', null, 'active', false);
insert into public.customer_profiles (firebase_uid, full_name, email) values ('r-c', 'Cust', 'r-c@test.local');

create function pg_temp.stock(p_branch text, p_var text) returns int language sql as $$
  select coalesce((select quantity from public.branch_inventory
                   where branch_id = pg_temp.f(p_branch)::uuid and variant_id = pg_temp.f(p_var)::uuid), 0) $$;

-- 1. Suppliers ------------------------------------------------------------------------
select pg_temp.chk('cashier without inventory permission cannot add supplier', 'r-cash',
  $q$select public.staff_save_supplier(null, 'Laguna Nut Traders')$q$, 'error');
select pg_temp.chk('customer cannot add supplier', 'r-c', $q$select public.staff_save_supplier(null, 'Laguna Nut Traders')$q$, 'error');
insert into fx select 'sup', pg_temp.call_as('r-inv', $q$select public.staff_save_supplier(null, '  Laguna   Nut Traders ', 'Ana', '0917', 'ANA@LNT.PH')::text$q$);
select pg_temp.chk_true('supplier saved with tidy name and lower-case e-mail',
  (select name = 'Laguna Nut Traders' and email = 'ana@lnt.ph' from public.suppliers where id = pg_temp.f('sup')::uuid));
select pg_temp.chk('duplicate supplier name (any case) refused', 'r-own',
  $q$select public.staff_save_supplier(null, 'laguna nut traders')$q$, 'error');
select pg_temp.chk('bad e-mail refused', 'r-own', $q$select public.staff_save_supplier(null, 'Other', null, null, 'nope')$q$, 'error');
select pg_temp.chk_true('cashier can read supplier list',
  jsonb_array_length(pg_temp.j('r-cash', 'public.staff_list_suppliers()')) >= 1);
select pg_temp.chk('suppliers table not readable directly', 'r-own', 'select count(*) from public.suppliers', 'error');

-- 2. Draft from OCR ----------------------------------------------------------------------
select pg_temp.chk('cashier cannot create a receipt', 'r-cash',
  format($q$select public.staff_save_purchase_receipt(null, %L::uuid, null, null, null, '[]'::jsonb)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('branch-B staff cannot create a receipt for branch A', 'r-invb',
  format($q$select public.staff_save_purchase_receipt(null, %L::uuid, null, null, null, '[]'::jsonb)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('future invoice date refused', 'r-inv',
  format($q$select public.staff_save_purchase_receipt(null, %L::uuid, null, 'X1', current_date + 3, '[]'::jsonb)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('negative quantity refused', 'r-inv',
  format($q$select public.staff_save_purchase_receipt(null, %L::uuid, null, 'X1', null, '[{"description":"x","quantity":-2}]'::jsonb)$q$, pg_temp.f('ba')), 'error');
select pg_temp.chk('non-numeric cost refused', 'r-inv',
  format($q$select public.staff_save_purchase_receipt(null, %L::uuid, null, 'X1', null, '[{"description":"x","unit_cost":"abc"}]'::jsonb)$q$, pg_temp.f('ba')), 'error');

insert into fx select 'rcpt', pg_temp.j('r-inv', format($q$public.staff_save_purchase_receipt(null, %L::uuid, %L::uuid, 'SI-0042', current_date - 1,
    jsonb_build_array(
      jsonb_build_object('raw_text', 'Garlic Peanuts 250g  20  85.00  1,700.00', 'description', 'Garlic Peanuts 250g', 'variant_id', %L, 'quantity', 20, 'unit_cost', 85),
      jsonb_build_object('raw_text', 'Cashew 100g 10 @ 150.00 1500.00', 'description', 'Cashew 100g', 'quantity', 10, 'unit_cost', 150),
      jsonb_build_object('raw_text', '', 'description', '', 'variant_id', '')),
    'ocr', 'LAGUNA NUT TRADERS\nSI-0042\nGarlic Peanuts 250g 20 85.00 1,700.00', 81.5, 'receipts/x.jpg')$q$,
  pg_temp.f('ba'), pg_temp.f('sup'), pg_temp.f('v1'))) ->> 'id';
select pg_temp.chk_true('draft saved: 2 lines (blank row skipped), source ocr, total 3200',
  (select j ->> 'status' = 'draft' and j ->> 'source' = 'ocr' and jsonb_array_length(j -> 'lines') = 2
          and (j ->> 'lines_total')::numeric = 3200 and (j ->> 'ocr_confidence')::numeric = 81.5
   from (select pg_temp.j('r-inv', format('public.staff_get_purchase_receipt(%L::uuid)', pg_temp.f('rcpt'))) j) t));
select pg_temp.chk_true('draft posts NO stock', pg_temp.stock('ba', 'v1') = 0);
select pg_temp.chk('approve refuses an unmatched product line', 'r-inv',
  format($q$select public.staff_approve_purchase_receipt(%L::uuid)$q$, pg_temp.f('rcpt')), 'error');
select pg_temp.chk_true('failed approval left no stock and no batch',
  pg_temp.stock('ba', 'v1') = 0 and not exists (select 1 from public.inventory_batches where variant_id = pg_temp.f('v1')::uuid));
select pg_temp.chk('other branch staff cannot read the receipt', 'r-invb',
  format('select public.staff_get_purchase_receipt(%L::uuid)', pg_temp.f('rcpt')), 'error');

-- 3. Human review fills the gaps ---------------------------------------------------------
select pg_temp.chk('review without expiry still saves as draft', 'r-inv', format($q$select public.staff_save_purchase_receipt(%L::uuid, %L::uuid, %L::uuid, 'SI-0042', current_date - 1,
    jsonb_build_array(
      jsonb_build_object('description', 'Garlic Peanuts 250g', 'variant_id', %L, 'quantity', 20, 'unit_cost', 85),
      jsonb_build_object('description', 'Cashew 100g', 'variant_id', %L, 'quantity', 10, 'unit_cost', 150)))$q$,
  pg_temp.f('rcpt'), pg_temp.f('ba'), pg_temp.f('sup'), pg_temp.f('v1'), pg_temp.f('v2')), 'ok');
select pg_temp.chk_true('OCR evidence kept after manual edit',
  (select ocr_text like 'LAGUNA%' and source = 'ocr' and document_path = 'receipts/x.jpg' from public.purchase_receipts where id = pg_temp.f('rcpt')::uuid));
select pg_temp.chk('approve refuses a line without expiry', 'r-inv',
  format($q$select public.staff_approve_purchase_receipt(%L::uuid)$q$, pg_temp.f('rcpt')), 'error');
select pg_temp.call_as('r-inv', format($q$select public.staff_save_purchase_receipt(%L::uuid, %L::uuid, %L::uuid, 'SI-0042', current_date - 1,
    jsonb_build_array(
      jsonb_build_object('description', 'Garlic Peanuts 250g', 'variant_id', %L, 'quantity', 20, 'unit_cost', 85, 'expiration_date', current_date + 120),
      jsonb_build_object('description', 'Cashew 100g', 'variant_id', %L, 'quantity', 10, 'unit_cost', 150, 'expiration_date', current_date + 90, 'batch_code', 'CSH-OCT')))::text$q$,
  pg_temp.f('rcpt'), pg_temp.f('ba'), pg_temp.f('sup'), pg_temp.f('v1'), pg_temp.f('v2')));

-- 4. Approve -----------------------------------------------------------------------------
select pg_temp.chk('cashier cannot approve', 'r-cash',
  format($q$select public.staff_approve_purchase_receipt(%L::uuid)$q$, pg_temp.f('rcpt')), 'error');
select pg_temp.chk('approve works', 'r-inv',
  format($q$select public.staff_approve_purchase_receipt(%L::uuid, 'rcpt-approve-01')$q$, pg_temp.f('rcpt')), 'ok');
select set_config('app.inventory_managed', '', true);
select pg_temp.chk_true('stock posted: +20 and +10', pg_temp.stock('ba', 'v1') = 20 and pg_temp.stock('ba', 'v2') = 10);
select pg_temp.chk_true('batches created with expiry; default code from receipt',
  (select count(*) = 2 from public.inventory_batches b join public.purchase_receipt_lines l on l.batch_id = b.id
   where l.receipt_id = pg_temp.f('rcpt')::uuid and b.expiration_date = l.expiration_date)
  and exists (select 1 from public.inventory_batches where batch_code = 'CSH-OCT')
  and exists (select 1 from public.purchase_receipt_lines where receipt_id = pg_temp.f('rcpt')::uuid and batch_code ~ '^PR-\d{6}-1$'));
select pg_temp.chk_true('stock movements reference the receipt',
  (select count(*) = 2 from public.stock_movements m join public.purchase_receipts r on m.reference = r.receipt_code
   where r.id = pg_temp.f('rcpt')::uuid and m.movement_type = 'receive'));
select pg_temp.chk_true('latest purchase cost recorded',
  (select cost_price = 85 from public.product_variant_costs where variant_id = pg_temp.f('v1')::uuid));
select pg_temp.chk_true('replay of approve with same key returns the result, no double stock',
  pg_temp.j('r-inv', format($q$public.staff_approve_purchase_receipt(%L::uuid, 'rcpt-approve-01')$q$, pg_temp.f('rcpt'))) ->> 'status' = 'approved'
  and pg_temp.stock('ba', 'v1') = 20);
select pg_temp.chk('second approve (new key) refused', 'r-own',
  format($q$select public.staff_approve_purchase_receipt(%L::uuid)$q$, pg_temp.f('rcpt')), 'error');
select pg_temp.chk_true('still exactly +20 after the refused approve', pg_temp.stock('ba', 'v1') = 20);
select pg_temp.chk('approved receipt cannot be edited', 'r-own', format($q$select public.staff_save_purchase_receipt(%L::uuid, %L::uuid, %L::uuid, 'SI-0042', null, '[]'::jsonb)$q$,
  pg_temp.f('rcpt'), pg_temp.f('ba'), pg_temp.f('sup')), 'error');
do $$ begin
  begin
    update public.purchase_receipt_lines set quantity = 999 where receipt_id = (select v from fx where k = 'rcpt')::uuid;
    insert into results(name, passed, detail) values ('approved lines cannot be changed directly', false, 'update succeeded');
  exception when others then
    insert into results(name, passed, detail) values ('approved lines cannot be changed directly', true, sqlerrm);
  end;
end $$;
select pg_temp.chk('approved receipt cannot be cancelled', 'r-inv',
  format($q$select public.staff_cancel_purchase_receipt(%L::uuid, 'oops')$q$, pg_temp.f('rcpt')), 'error');
select pg_temp.chk_true('audit row for approval',
  exists (select 1 from public.staff_audit_logs where action = 'purchase_receipt.approve' and entity_id = pg_temp.f('rcpt')));

-- 5. Same invoice twice ------------------------------------------------------------------
insert into fx select 'dup', pg_temp.j('r-own', format($q$public.staff_save_purchase_receipt(null, %L::uuid, %L::uuid, ' si-0042 ', null,
    jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 5, 'unit_cost', 85, 'expiration_date', current_date + 60)))$q$,
  pg_temp.f('ba'), pg_temp.f('sup'), pg_temp.f('v1'))) ->> 'id';
select pg_temp.chk('the same supplier invoice cannot be posted twice', 'r-own',
  format($q$select public.staff_approve_purchase_receipt(%L::uuid)$q$, pg_temp.f('dup')), 'error');
select pg_temp.chk_true('no extra stock from the duplicate', pg_temp.stock('ba', 'v1') = 20);
select pg_temp.chk('cancel needs a reason', 'r-own', format($q$select public.staff_cancel_purchase_receipt(%L::uuid, '')$q$, pg_temp.f('dup')), 'error');
select pg_temp.chk('draft can be cancelled', 'r-own', format($q$select public.staff_cancel_purchase_receipt(%L::uuid, 'duplicate scan')$q$, pg_temp.f('dup')), 'ok');
select pg_temp.chk('cancelled draft cannot be approved', 'r-own',
  format($q$select public.staff_approve_purchase_receipt(%L::uuid)$q$, pg_temp.f('dup')), 'error');

-- 6. Lists --------------------------------------------------------------------------------
select pg_temp.chk_true('branch staff list their branch',
  jsonb_array_length(pg_temp.j('r-inv', format('public.staff_list_purchase_receipts(%L::uuid)', pg_temp.f('ba')))) = 2);
select pg_temp.chk('branch staff cannot list all branches', 'r-inv', 'select public.staff_list_purchase_receipts(null)', 'error');
select pg_temp.chk_true('owner lists approved only (this test''s receipt included, total 3200)',
  (select bool_and(e ->> 'status' = 'approved')
          and bool_or(e ->> 'id' = pg_temp.f('rcpt') and (e ->> 'total')::numeric = 3200)
          and not bool_or(e ->> 'id' = pg_temp.f('dup'))
   from jsonb_array_elements(pg_temp.j('r-own', $q$public.staff_list_purchase_receipts(null, 'approved')$q$)) e));
select pg_temp.chk_true('supplier shows 1 approved receipt',
  (select (e ->> 'receipts')::int = 1 from jsonb_array_elements(pg_temp.j('r-own', 'public.staff_list_suppliers()')) e
   where e ->> 'id' = pg_temp.f('sup')));
select pg_temp.chk('anon cannot list receipts', null, 'select public.staff_list_purchase_receipts(null)', 'error');

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% purchase receipt check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
