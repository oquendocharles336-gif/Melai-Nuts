-- =============================================================================
-- Melai Nuts — HitPay refund attempts (migration 20261011020000_hitpay_refunds.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/hitpay_refunds_test.sql
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
insert into public.branches (name, address, delivery_fee) values ('HR-TEST A', 'a', 0), ('HR-TEST B', 'b', 0);
insert into fx select 'ba', id::text from public.branches where name = 'HR-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'HR-TEST B';
insert into public.product_categories (label) values ('HR-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'HR-TEST Nut', 100, 'pack' from public.product_categories where label = 'HR-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'HR-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'HR-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 50);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_review_refunds)
values ('h-sa', 'Refunds A', 'h-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', true),
       ('h-sn', 'No refunds A', 'h-sn@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', false),
       ('h-sb', 'Refunds B', 'h-sb@test.local', 'staff', pg_temp.f('bb')::uuid, 'active', true),
       ('h-own', 'Owner', 'h-own@test.local', 'owner', null, 'active', false);
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values ('h-c', 'HR Cust', 'h-c@test.local', '09181112222');
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point)
values ('default', 1, 50, 50)
  on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;

-- Two pickup orders: one paid online through HitPay, one paid cash.
create function pg_temp.order_for(p_method text, p_key text) returns text language plpgsql as $$
declare v_cart text; v_order text;
begin
  v_cart := pg_temp.call_as('h-c', format($q$select (public.sync_customer_cart(%L::uuid,
      jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 2)), null, false) ->> 'cart_id')$q$,
      pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var')));
  v_order := pg_temp.call_as('h-c', format($q$select public.place_order(%L::uuid, false, null, %L, '', %L)$q$, v_cart, p_method, p_key));
  return v_order;
end $$;
insert into fx values ('o_online', pg_temp.order_for('Online Payment (GCash, Maya, Card)', 'hr-key-online-1'));
-- A first link (preq-old) is replaced by a newer one (preq-123) while the
-- customer pays: a late "failed" event from the OLD link must not fail the
-- payment (migration 20261028000000_hitpay_failed_event_link_check.sql).
select public.hitpay_set_checkout(pg_temp.f('o_online'), 'preq-old', 'https://pay.example/old');
select public.hitpay_set_checkout(pg_temp.f('o_online'), 'preq-123', 'https://pay.example/x');
select pg_temp.chk_true('failed event: an OLD link failing leaves the current payment processing',
  public.hitpay_apply_payment(pg_temp.f('o_online'), 'failed', 'GCash', 'pay-old-1', null, 'preq-old') = 'processing'
  and (select status = 'processing' and gateway_payment_id = 'preq-123'
       from public.payments where order_id = pg_temp.f('o_online')));
select pg_temp.chk_true('failed event: no request id is treated as not the current link',
  public.hitpay_apply_payment(pg_temp.f('o_online'), 'failed', 'GCash', 'pay-old-1', null) = 'processing');
select pg_temp.chk_true('failed event: the CURRENT link failing fails the payment',
  public.hitpay_apply_payment(pg_temp.f('o_online'), 'failed', 'GCash', 'pay-cur-1', null, 'preq-123') = 'failed');
-- HitPay lets the buyer retry on the same page: the success below still applies.
select public.hitpay_apply_payment(pg_temp.f('o_online'), 'success', 'GCash', 'pay-abc-001', null);
insert into fx values ('o_cash', pg_temp.order_for('Cash on Counter Pickup', 'hr-key-cash-1'));
select pg_temp.call_as('h-own', format($q$select public.staff_confirm_payment(%L, null)::text$q$, pg_temp.f('o_cash')));
do $$
declare o text;
begin
  foreach o in array array[pg_temp.f('o_online'), pg_temp.f('o_cash')] loop
    perform pg_temp.call_as('h-own', format($q$select public.staff_update_order_status(%L, s)::text from unnest(array['confirmed','preparing','readyForPickup','completed']) s$q$, o));
  end loop;
end $$;
insert into fx select 'r_online', pg_temp.call_as('h-c', format(
  $q$select public.request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','HR-TEST Nut','variant_label','Regular','quantity',2)))$q$,
  pg_temp.f('o_online')));
insert into fx select 'r_cash', pg_temp.call_as('h-c', format(
  $q$select public.request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','HR-TEST Nut','variant_label','Regular','quantity',1)))$q$,
  pg_temp.f('o_cash')));
select pg_temp.chk_true('fixture: online payment is a successful HitPay GCash payment',
  (select status = 'success' and gateway = 'hitpay' and gateway_payment_id = 'pay-abc-001' and method = 'gcash'
   from public.payments where order_id = pg_temp.f('o_online')));

-- 1. Begin ------------------------------------------------------------------------
select pg_temp.chk('pending (not approved) refund cannot be sent', 'h-sa',
  format($q$select public.staff_begin_gateway_refund(%L)$q$, pg_temp.f('r_online')), 'error');
select pg_temp.call_as('h-sa', format($q$select public.admin_portal_review_refund(%L, 'approve')::text$q$, pg_temp.f('r_online')));
select pg_temp.call_as('h-sa', format($q$select public.admin_portal_review_refund(%L, 'approve')::text$q$, pg_temp.f('r_cash')));
select pg_temp.chk('staff without refunds permission cannot send', 'h-sn',
  format($q$select public.staff_begin_gateway_refund(%L)$q$, pg_temp.f('r_online')), 'error');
select pg_temp.chk('other branch cannot send', 'h-sb',
  format($q$select public.staff_begin_gateway_refund(%L)$q$, pg_temp.f('r_online')), 'error');
select pg_temp.chk('customer cannot send', 'h-c',
  format($q$select public.staff_begin_gateway_refund(%L)$q$, pg_temp.f('r_online')), 'error');
select pg_temp.chk('anon cannot send', null,
  format($q$select public.staff_begin_gateway_refund(%L)$q$, pg_temp.f('r_online')), 'error');
select pg_temp.chk('cash refund cannot go through HitPay', 'h-sa',
  format($q$select public.staff_begin_gateway_refund(%L)$q$, pg_temp.f('r_cash')), 'error');

insert into fx select 'a1', j ->> 'attempt_id' from (select pg_temp.j('h-sa', format('public.staff_begin_gateway_refund(%L)', pg_temp.f('r_online'))) j) t;
select pg_temp.chk_true('attempt carries HitPay payment id and the refund amount',
  (select gateway_payment_id = 'pay-abc-001' and amount = (select amount from public.refund_requests where id = pg_temp.f('r_online')) and status = 'sending'
   from public.refund_gateway_attempts where id = pg_temp.f('a1')::uuid));
select pg_temp.chk('second send while the first has no answer is refused (no double refund)', 'h-own',
  format($q$select public.staff_begin_gateway_refund(%L)$q$, pg_temp.f('r_online')), 'error');
do $$ begin
  begin
    insert into public.refund_gateway_attempts (refund_id, order_id, gateway_payment_id, amount, started_by)
    values ((select v from fx where k = 'r_online'), 'x', 'pay-abc-001', 1, 'x');
    insert into results(name, passed, detail) values ('unique index blocks a 2nd live attempt even when inserted directly', false, 'insert succeeded');
  exception when unique_violation then
    insert into results(name, passed, detail) values ('unique index blocks a 2nd live attempt even when inserted directly', true, sqlerrm);
  end;
end $$;
select pg_temp.chk('attempts table not readable by staff directly', 'h-sa', 'select count(*) from public.refund_gateway_attempts', 'error');

-- 2. Failure, abandon, retry --------------------------------------------------------
select pg_temp.chk('bad status refused', 'h-sa', format($q$select public.staff_finish_gateway_refund(%L::uuid, 'maybe')$q$, pg_temp.f('a1')), 'error');
select pg_temp.chk('succeeded needs the HitPay refund id', 'h-sa', format($q$select public.staff_finish_gateway_refund(%L::uuid, 'succeeded')$q$, pg_temp.f('a1')), 'error');
select pg_temp.chk('HitPay refused -> failed', 'h-sa',
  format($q$select public.staff_finish_gateway_refund(%L::uuid, 'failed', null, 'Insufficient balance')$q$, pg_temp.f('a1')), 'ok');
select pg_temp.chk_true('refund still approved after a failed attempt',
  (select status = 'approved' from public.refund_requests where id = pg_temp.f('r_online')));
select pg_temp.chk_true('payment not marked refunded after failure',
  (select status = 'success' from public.payments where order_id = pg_temp.f('o_online')));
select pg_temp.chk('failed attempt cannot later be marked succeeded', 'h-sa',
  format($q$select public.staff_finish_gateway_refund(%L::uuid, 'succeeded', 'rf-1')$q$, pg_temp.f('a1')), 'error');

insert into fx select 'a2', pg_temp.j('h-sa', format('public.staff_begin_gateway_refund(%L)', pg_temp.f('r_online'))) ->> 'attempt_id';
select pg_temp.chk('a fresh unanswered attempt cannot be abandoned yet', 'h-sa',
  format($q$select public.staff_abandon_gateway_refund(%L::uuid, 'checked dashboard, nothing there')$q$, pg_temp.f('a2')), 'error');
update public.refund_gateway_attempts set started_at = now() - interval '10 minutes' where id = pg_temp.f('a2')::uuid;
select pg_temp.chk('abandon needs a note', 'h-sa', format($q$select public.staff_abandon_gateway_refund(%L::uuid, 'ok')$q$, pg_temp.f('a2')), 'error');
select pg_temp.chk('stale attempt can be abandoned after checking HitPay', 'h-sa',
  format($q$select public.staff_abandon_gateway_refund(%L::uuid, 'checked dashboard, no refund listed')$q$, pg_temp.f('a2')), 'ok');

-- 3. Pending then succeeded ---------------------------------------------------------
insert into fx select 'a3', pg_temp.j('h-own', format('public.staff_begin_gateway_refund(%L)', pg_temp.f('r_online'))) ->> 'attempt_id';
select pg_temp.chk('pending recorded with refund id', 'h-sa',
  format($q$select public.staff_finish_gateway_refund(%L::uuid, 'pending', 'rf-777')$q$, pg_temp.f('a3')), 'ok');
select pg_temp.chk('while pending, another send is refused', 'h-sa',
  format($q$select public.staff_begin_gateway_refund(%L)$q$, pg_temp.f('r_online')), 'error');
select pg_temp.chk_true('pending twice is a no-op',
  pg_temp.j('h-sa', format($q$public.staff_finish_gateway_refund(%L::uuid, 'pending', 'rf-777')$q$, pg_temp.f('a3'))) ->> 'status' = 'pending');
select pg_temp.chk_true('succeeded completes the refund',
  pg_temp.j('h-sa', format($q$public.staff_finish_gateway_refund(%L::uuid, 'succeeded', 'rf-777')$q$, pg_temp.f('a3'))) ->> 'refund_status' = 'completed');
select pg_temp.chk_true('payment now refunded (existing trigger)',
  (select status = 'refunded' from public.payments where order_id = pg_temp.f('o_online')));
select pg_temp.chk_true('same success reported twice is a no-op',
  pg_temp.j('h-sa', format($q$public.staff_finish_gateway_refund(%L::uuid, 'succeeded', 'rf-777')$q$, pg_temp.f('a3'))) ->> 'status' = 'succeeded');
select pg_temp.chk('completed refund cannot be sent again', 'h-own',
  format($q$select public.staff_begin_gateway_refund(%L)$q$, pg_temp.f('r_online')), 'error');
select pg_temp.chk_true('history lists all 3 attempts (1 succeeded, 2 failed)',
  (select jsonb_array_length(j) = 3
          and (select count(*) from jsonb_array_elements(j) e where e ->> 'status' = 'succeeded') = 1
          and (select count(*) from jsonb_array_elements(j) e where e ->> 'status' = 'failed') = 2
   from (select pg_temp.j('h-sa', format('public.staff_refund_gateway_attempts(%L)', pg_temp.f('r_online'))) j) t));
select pg_temp.chk('other branch cannot read attempts', 'h-sb',
  format('select public.staff_refund_gateway_attempts(%L)', pg_temp.f('r_online')), 'error');
select pg_temp.chk_true('audit rows for send / failed / succeeded',
  (select count(distinct action) = 4 from public.staff_audit_logs where entity_id = pg_temp.f('r_online')
     and action in ('refund.gateway_send', 'refund.gateway_failed', 'refund.gateway_pending', 'refund.gateway_succeeded')));

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% HitPay refund check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
