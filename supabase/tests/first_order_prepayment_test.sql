-- =============================================================================
-- Melai Nuts — the first online order is paid online, 50% or 100%
-- (migration 20261118015010_first_order_prepayment.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/first_order_prepayment_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
-- Races (two first orders at once): first_order_concurrency_test.sh.
-- =============================================================================
begin;

set local timezone = 'Asia/Manila';

create temp table results (id serial primary key, name text not null, passed boolean not null, detail text);
create temp table fx (k text primary key, v text);
grant select on fx to public;

create function pg_temp.act_as(p_uid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', p_uid, 'role', 'authenticated',
    'email', p_uid || '@test.local', 'email_verified', true, 'phone_number', '+639' || lpad((abs(hashtext(p_uid)) % 1000000000)::text, 9, '0'))::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.back_to_admin() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on function pg_temp.back_to_admin() to public;
create function pg_temp.chk(p_name text, p_uid text, p_sql text, p_expect text, p_like text default null)
returns void language plpgsql as $$
declare v_err text;
begin
  perform pg_temp.act_as(p_uid);
  begin execute p_sql; exception when others then v_err := sqlerrm; end;
  perform pg_temp.back_to_admin();
  insert into results(name, passed, detail) values (p_name,
    case p_expect when 'error' then v_err is not null and (p_like is null or v_err like p_like)
                  else v_err is null end,
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
create function pg_temp.j(p_uid text, p_sql text) returns jsonb language sql as $$
  select pg_temp.call_as(p_uid, 'select (' || p_sql || ')::text')::jsonb $$;
create function pg_temp.stock() returns int language sql as $$
  select quantity from public.branch_inventory
  where branch_id = pg_temp.f('ba')::uuid and variant_id = pg_temp.f('var')::uuid $$;
create function pg_temp.first(p_uid text) returns boolean language sql as $$
  select public.is_first_order(p_uid) $$;

-- Fixtures: one unit costs 100 (pickup total 100). Delivery costs 50 (total 150). ---------
insert into public.branches (name, address, latitude, longitude, delivery_fee)
values ('FO-TEST A', 'a', 14.2117, 121.1653, 50);
insert into fx select 'ba', id::text from public.branches where name = 'FO-TEST A';
insert into public.product_categories (label) values ('FO-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'FO-TEST Nut', 100, 'pack' from public.product_categories where label = 'FO-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'FO-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'FO-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 100);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_review_refunds)
values ('fo-sa', 'Staff A', 'fo-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', true),
       ('fo-own', 'Owner', 'fo-own@test.local', 'owner', null, 'active', false);
-- fo-new: brand new. fo-old: already had a paid online order (grandfathered).
-- fo-late: pays after cancellation. fo-pos: owns a POS order.
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('fo-new', 'New', 'fo-new@test.local', '09170000031'),
  ('fo-old', 'Old', 'fo-old@test.local', '09170000032'),
  ('fo-late', 'Late', 'fo-late@test.local', '09170000033'),
  ('fo-pos', 'Pos', 'fo-pos@test.local', '09170000034');
update public.customer_profiles set first_paid_order_at = now() - interval '30 days' where firebase_uid = 'fo-old';
-- Since 20261118040000 a returning customer also needs its verified number (claimed here).
insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city, latitude, longitude)
values ('fo-new', 'New', '09170000031', '1 Test St', 'Calamba', 14.205, 121.156);
insert into fx select 'addr', id::text from public.customer_addresses where firebase_uid = 'fo-new';
update public.payment_settings set online_payment_enabled = true where id = 'default';
-- No pickup downpayment setting: returning customers pay pickup fully in cash.
update public.business_settings set cod_downpayment_type = null, cod_downpayment_value = null,
  cod_downpayment_min_order = null, cod_downpayment_expiry_minutes = null, cod_downpayment_pickup_days = null
 where id = 'default';

create function pg_temp.cart(p_uid text) returns text language sql as $$
  select pg_temp.call_as(p_uid, format($q$select (public.sync_customer_cart(%L::uuid,
    jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false) ->> 'cart_id')$q$,
    pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var'))) $$;
create function pg_temp.place(p_uid text, p_method text, p_choice text, p_key text, p_delivery boolean default false)
returns text language sql as $$
  select pg_temp.call_as(p_uid, format(
    $q$select public.place_order(%L::uuid, %L, %L::uuid, %L, '', %L, %L)$q$,
    pg_temp.cart(p_uid), p_delivery, case when p_delivery then pg_temp.f('addr') end, p_method, p_key, p_choice)) $$;
create function pg_temp.place_sql(p_uid text, p_method text, p_choice text, p_key text) returns text language sql as $$
  select format($q$select public.place_order(%L::uuid, false, null, %L, '', %L, %L)$q$,
    pg_temp.cart(p_uid), p_method, p_key, p_choice) $$;
create function pg_temp.pay(p_order text, p_key text) returns text language plpgsql as $$
begin
  perform public.hitpay_set_checkout(p_order, 'preq-' || p_key, 'https://pay.example/' || p_key);
  return public.hitpay_apply_payment(p_order, 'success', 'qrph', 'pay-' || p_key, null, 'preq-' || p_key);
end $$;

select pg_temp.call_as('fo-old', 'select public.claim_verified_phone()::text');

-- 0. Who may call what ------------------------------------------------------------------
select pg_temp.chk('a customer cannot call is_first_order', 'fo-new', $q$select public.is_first_order('fo-old')$q$, 'error');
select pg_temp.chk('a customer cannot call the place_order core (no idempotency, no checks bypass)', 'fo-new',
  $q$select public._place_order_core(null, false, null, 'x', '', 'full')$q$, 'error');
select pg_temp.chk('a customer cannot call the place_order API body directly', 'fo-new',
  $q$select public._place_order_api(null, false, null, 'x', '', 'k', 'full')$q$, 'error');
select pg_temp.chk_true('both entry points exist for customers: 6 args (no choice) and 7 args (choice)',
  has_function_privilege('authenticated', 'public.place_order(uuid,boolean,uuid,text,text,text)', 'execute')
  and has_function_privilege('authenticated', 'public.place_order(uuid,boolean,uuid,text,text,text,text)', 'execute')
  and not has_function_privilege('anon', 'public.place_order(uuid,boolean,uuid,text,text,text,text)', 'execute'));
select pg_temp.chk_true('the 7-arg entry point has no default (PostgREST never sees two candidates)',
  (select pronargdefaults = 0 from pg_proc where oid = 'public.place_order(uuid,boolean,uuid,text,text,text,text)'::regprocedure));
select pg_temp.chk('a customer cannot mark an order as the first paid one', 'fo-new',
  $q$select public._mark_first_paid_order('x')$q$, 'error');
select pg_temp.chk('a customer cannot write first_paid_order_at', 'fo-new',
  $q$update public.customer_profiles set first_paid_order_at = now() where firebase_uid = 'fo-new'$q$, 'error');
select pg_temp.chk('a customer cannot create a profile that is already "returning"', 'fo-x',
  $q$insert into public.customer_profiles (firebase_uid, full_name, email, first_paid_order_at) values ('fo-x', 'X', 'fo-x@test.local', now())$q$, 'error');
select pg_temp.chk_true('first-order state: new customer is first, grandfathered one is not',
  pg_temp.first('fo-new') and not pg_temp.first('fo-old'));

-- 1. The quote ------------------------------------------------------------------------
insert into fx values ('cart_new', pg_temp.cart('fo-new'));
create temp table q1 as select pg_temp.j('fo-new', format('public.first_order_quote(%L::uuid, false)', pg_temp.f('cart_new'))) j;
select pg_temp.chk_true('quote: a first order, 50% = 50 (balance 50), 100% = 100, 30 min',
  (select (j ->> 'first_order')::boolean and (j ->> 'total')::numeric = 100 and (j ->> 'half_amount')::numeric = 50
          and (j ->> 'half_balance')::numeric = 50 and (j ->> 'full_amount')::numeric = 100
          and (j ->> 'expiry_minutes')::int = 30 and j ->> 'pending_order_id' is null from q1));
select pg_temp.chk_true('quote: a returning customer is not asked',
  (pg_temp.j('fo-old', format('public.first_order_quote(%L::uuid, false)', pg_temp.cart('fo-old'))) ->> 'first_order')::boolean = false);
select pg_temp.chk_true('quote: delivery adds the fee (150 -> 75 / 75)',
  (select (j ->> 'half_amount')::numeric = 75 and (j ->> 'half_balance')::numeric = 75
   from (select pg_temp.j('fo-new', format('public.first_order_quote(%L::uuid, true)', pg_temp.f('cart_new'))) j) t));

-- 2. Methods that skip the upfront payment are refused ---------------------------------
select pg_temp.chk('first order: Cash on Counter Pickup refused', 'fo-new',
  pg_temp.place_sql('fo-new', 'Cash on Counter Pickup', null, 'fo-coc'), 'error', '%first order is paid online%');
select pg_temp.chk('first order: Cash on Counter Pickup refused even with a choice', 'fo-new',
  pg_temp.place_sql('fo-new', 'Cash on Counter Pickup', 'half', 'fo-coc2'), 'error', '%first order is paid online%');
select pg_temp.chk('first order: Cash on Delivery refused', 'fo-new',
  format($q$select public.place_order(%L::uuid, true, %L::uuid, 'Cash on Delivery', '', 'fo-cod', 'half')$q$,
         pg_temp.cart('fo-new'), pg_temp.f('addr')), 'error', '%first order is paid online%');
select pg_temp.chk('first order: an unknown choice is refused', 'fo-new',
  pg_temp.place_sql('fo-new', 'Online Payment (GCash, QR Ph, Card)', 'quarter', 'fo-bad'), 'error', '%50% or 100%%');
select pg_temp.chk('first order: a long choice is refused', 'fo-new',
  pg_temp.place_sql('fo-new', 'Online Payment (GCash, QR Ph, Card)', 'half-and-some-more', 'fo-bad2'), 'error');
update public.payment_settings set online_payment_enabled = false where id = 'default';
select pg_temp.chk('first order: refused while online payment is off', 'fo-new',
  pg_temp.place_sql('fo-new', 'Online Payment (GCash, QR Ph, Card)', 'half', 'fo-off'), 'error');
update public.payment_settings set online_payment_enabled = true where id = 'default';
select pg_temp.chk_true('nothing was created by the refused attempts',
  not exists (select 1 from public.orders where firebase_uid = 'fo-new'));

-- 3. Pay 50% now -----------------------------------------------------------------------
insert into fx values ('stock0', pg_temp.stock()::text);
insert into fx values ('o_half', pg_temp.place('fo-new', 'Online Payment (GCash, QR Ph, Card)', 'half', 'fo-half'));
select pg_temp.chk_true('50%: waits for the online payment',
  (select status = 'awaitingDownpayment' from public.orders where id = pg_temp.f('o_half')));
select pg_temp.chk_true('50%: 50 online (first_order, half, 50%), with a 30 minute limit',
  (select amount = 50 and kind = 'first_order' and choice = 'half' and percent = 50 and pickup_days is null
          and status = 'pending' and expires_at > now() + interval '29 minutes' and expires_at <= now() + interval '30 minutes'
   from public.order_downpayments where order_id = pg_temp.f('o_half')));
select pg_temp.chk_true('50%: the other 50 is the cash balance',
  (select amount = 50 and method = 'cash' and status = 'pending' from public.payments where order_id = pg_temp.f('o_half')));
select pg_temp.chk_true('50%: the stock is held', pg_temp.stock() = pg_temp.f('stock0')::int - 1);
select pg_temp.chk_true('50%: the same request again is the same order',
  pg_temp.place('fo-new', 'Online Payment (GCash, QR Ph, Card)', 'half', 'fo-half') = pg_temp.f('o_half'));
select pg_temp.chk_true('50%: staff cannot see it yet',
  pg_temp.visible('fo-sa', format($q$select count(*) from public.orders where id = %L$q$, pg_temp.f('o_half'))) = 0);
select pg_temp.chk('50%: staff cannot move it forward', 'fo-sa',
  format($q$select public.staff_update_order_status(%L, 'confirmed')$q$, pg_temp.f('o_half')), 'error');
select pg_temp.chk('50%: staff cannot take the cash yet', 'fo-sa',
  format($q$select public.staff_confirm_payment(%L)$q$, pg_temp.f('o_half')), 'error');
select pg_temp.chk_true('HitPay is asked for exactly the 50',
  (select public.hitpay_claim_checkout(pg_temp.f('o_half')) ->> 'action' = 'create')
  and (select amount = 50 from public.order_downpayments where order_id = pg_temp.f('o_half')));
select public.hitpay_release_checkout(pg_temp.f('o_half'));

-- 4. One unpaid first order at a time -----------------------------------------------------
select pg_temp.chk('a second first order is refused while the first is unpaid', 'fo-new',
  pg_temp.place_sql('fo-new', 'Online Payment (GCash, QR Ph, Card)', 'full', 'fo-second'), 'error', '%still waiting for its online payment%');
select pg_temp.chk_true('the quote points to the unpaid first order',
  pg_temp.j('fo-new', format('public.first_order_quote(%L::uuid, false)', pg_temp.cart('fo-new'))) ->> 'pending_order_id' = pg_temp.f('o_half'));

-- 5. Not paid in time: cancelled, stock back, still a first order ------------------------
update public.order_downpayments set expires_at = now() - interval '1 minute' where order_id = pg_temp.f('o_half');
select pg_temp.chk_true('the expiry job cancels it', public.expire_unpaid_cod_downpayments() = 1);
select pg_temp.chk_true('expired: cancelled, nothing paid',
  (select o.status = 'cancelled' and d.status = 'expired'
   from public.orders o join public.order_downpayments d on d.order_id = o.id where o.id = pg_temp.f('o_half')));
select pg_temp.chk_true('expired: the stock is back', pg_temp.stock() = pg_temp.f('stock0')::int);
select pg_temp.chk_true('cancelled before payment: still a first order', pg_temp.first('fo-new'));
select pg_temp.chk_true('the customer is told about the online payment, not a downpayment',
  exists (select 1 from public.notifications where firebase_uid = 'fo-new'
          and body like '%' || pg_temp.f('o_half') || '%online payment was not paid in time%'));

-- 6. Pay 100% now, paid through the webhook ---------------------------------------------
insert into fx values ('o_full', pg_temp.place('fo-new', 'Online Payment (GCash, QR Ph, Card)', 'full', 'fo-full'));
select pg_temp.chk_true('100%: the whole 100 is due online, nothing in cash',
  (select d.amount = 100 and d.choice = 'full' and d.percent = 100 and p.amount = 0 and p.method = 'online'
   from public.order_downpayments d join public.payments p on p.order_id = d.order_id where d.order_id = pg_temp.f('o_full')));
select pg_temp.chk_true('100%: the owner confirming it by hand does not use up the first order',
  pg_temp.first('fo-new'));
select pg_temp.chk_true('100%: the webhook marks it paid', pg_temp.pay(pg_temp.f('o_full'), 'full') = 'success');
select pg_temp.chk_true('100%: released to staff, fully paid',
  (select o.status = 'pending' and p.status = 'success' and d.status = 'success'
   from public.orders o join public.payments p on p.order_id = o.id join public.order_downpayments d on d.order_id = o.id
   where o.id = pg_temp.f('o_full')));
select pg_temp.chk_true('100%: first_paid_order_at is set, by that payment', not pg_temp.first('fo-new'));
insert into fx select 'first_at', first_paid_order_at::text from public.customer_profiles where firebase_uid = 'fo-new';
select pg_temp.chk_true('the same webhook again changes nothing',
  public.hitpay_apply_payment(pg_temp.f('o_full'), 'success', 'qrph', 'pay-full', null, 'preq-full') = 'success'
  and (select first_paid_order_at::text = pg_temp.f('first_at') from public.customer_profiles where firebase_uid = 'fo-new'));
select pg_temp.chk_true('100%: staff see it now',
  pg_temp.visible('fo-sa', format($q$select count(*) from public.orders where id = %L$q$, pg_temp.f('o_full'))) = 1);
select pg_temp.chk_true('100%: staff are told it is fully paid',
  exists (select 1 from public.staff_notifications where reference = pg_temp.f('o_full') and body like '%Fully paid online%'));

-- 6b. The 6-argument entry point (older builds): an online first order pays in full.
update public.customer_profiles set first_paid_order_at = null where firebase_uid = 'fo-pos';
insert into fx values ('o_six', pg_temp.call_as('fo-pos', format(
  $q$select public.place_order(%L::uuid, false, null, 'Online Payment (GCash, QR Ph, Card)', '', 'fo-six')$q$, pg_temp.cart('fo-pos'))));
select pg_temp.chk_true('6-arg call, first order, online: 100% due online',
  (select d.choice = 'full' and d.amount = 100 and o.status = 'awaitingDownpayment'
   from public.orders o join public.order_downpayments d on d.order_id = o.id where o.id = pg_temp.f('o_six')));
update public.order_downpayments set expires_at = now() - interval '1 minute' where order_id = pg_temp.f('o_six');
select public.expire_unpaid_cod_downpayments();

-- 7. Returning customer: normal checkout ------------------------------------------------
insert into fx values ('o_ret', pg_temp.place('fo-new', 'Cash on Counter Pickup', null, 'fo-ret'));
select pg_temp.chk_true('returning: Cash on Counter Pickup goes straight to staff, full cash',
  (select o.status = 'pending' and p.amount = 100 and p.method = 'cash'
   from public.orders o join public.payments p on p.order_id = o.id where o.id = pg_temp.f('o_ret'))
  and not exists (select 1 from public.order_downpayments where order_id = pg_temp.f('o_ret')));
insert into fx values ('o_old', pg_temp.place('fo-old', 'Cash on Counter Pickup', null, 'fo-old-1'));
select pg_temp.chk_true('grandfathered: Cash on Counter Pickup as before',
  (select status = 'pending' from public.orders where id = pg_temp.f('o_old')));
insert into fx values ('o_old_online', pg_temp.place('fo-old', 'Online Payment (GCash, QR Ph, Card)', 'half', 'fo-old-2'));
select pg_temp.chk_true('returning + online: the choice is ignored, the normal online order',
  (select o.status = 'pending' and p.amount = 100 and p.method = 'online'
   from public.orders o join public.payments p on p.order_id = o.id where o.id = pg_temp.f('o_old_online'))
  and not exists (select 1 from public.order_downpayments where order_id = pg_temp.f('o_old_online')));

-- 8. Refunded first order still counts as used -----------------------------------------
select pg_temp.call_as('fo-sa', format($q$select public.staff_update_order_status(%L, s)::text
  from unnest(array['confirmed', 'preparing', 'readyForPickup', 'completed']) s$q$, pg_temp.f('o_full')));
insert into fx select 'r_full', pg_temp.call_as('fo-new', format(
  $q$select public.request_refund(%L, 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','FO-TEST Nut','variant_label','Regular','quantity',1)))$q$,
  pg_temp.f('o_full')));
select pg_temp.chk('staff approve the refund', 'fo-sa', format($q$select public.staff_review_refund(%L, 'approve')$q$, pg_temp.f('r_full')), 'ok');
insert into fx select 'a_full', j ->> 'attempt_id' from (select pg_temp.j('fo-sa', format('public.staff_begin_gateway_refund(%L)', pg_temp.f('r_full'))) j) t;
select pg_temp.chk_true('refund: the whole 100 goes back through HitPay, to the right payment',
  (select amount = 100 and gateway_payment_id = 'pay-full' from public.refund_gateway_attempts where id = pg_temp.f('a_full')::uuid));
update public.refund_requests set status = 'completed' where id = pg_temp.f('r_full');
select pg_temp.chk_true('refunded: still not a first order', not pg_temp.first('fo-new'));

-- 9. Delivery, 50%: the balance is cash on delivery -------------------------------------
update public.customer_profiles set first_paid_order_at = null where firebase_uid = 'fo-new';   -- fixture reset
insert into fx values ('o_dlv', pg_temp.place('fo-new', 'Online Payment (GCash, QR Ph, Card)', 'half', 'fo-dlv', true));
select pg_temp.chk_true('delivery 50%: 75 online, 75 cash on delivery',
  (select d.amount = 75 and p.amount = 75 and p.method = 'cash' and o.total = 150
   from public.orders o join public.order_downpayments d on d.order_id = o.id join public.payments p on p.order_id = o.id
   where o.id = pg_temp.f('o_dlv')));
select pg_temp.chk_true('delivery 50%: paid', pg_temp.pay(pg_temp.f('o_dlv'), 'dlv') = 'success');
select pg_temp.chk_true('delivery 50%: the cash balance is still open for the rider',
  (select o.status = 'pending' and p.status = 'pending' and p.amount = 75
   from public.orders o join public.payments p on p.order_id = o.id where o.id = pg_temp.f('o_dlv')));
select pg_temp.chk_true('delivery 50%: the customer is told what is left',
  exists (select 1 from public.notifications where firebase_uid = 'fo-new' and body like '%remaining ₱75.00 can be paid online now%or in cash on delivery.%'));
select pg_temp.chk_true('a paid half also uses up the first order', not pg_temp.first('fo-new'));

-- 10. Paid after it was cancelled: refunded, does NOT use up the first order -------------
insert into fx values ('o_late', pg_temp.place('fo-late', 'Online Payment (GCash, QR Ph, Card)', 'full', 'fo-late'));
select public.hitpay_set_checkout(pg_temp.f('o_late'), 'preq-late', 'https://pay.example/late');
update public.order_downpayments set expires_at = now() - interval '1 minute' where order_id = pg_temp.f('o_late');
select public.expire_unpaid_cod_downpayments();
select pg_temp.chk_true('late: the payment is recorded',
  public.hitpay_apply_payment(pg_temp.f('o_late'), 'success', 'qrph', 'pay-late', null, 'preq-late') = 'success');
select pg_temp.chk_true('late: the order stays cancelled and a refund is open',
  (select status = 'cancelled' from public.orders where id = pg_temp.f('o_late'))
  and exists (select 1 from public.refund_requests where order_id = pg_temp.f('o_late') and amount = 100));
select pg_temp.chk_true('late: still a first order (cancelled before it was paid)', pg_temp.first('fo-late'));

-- 11. POS / staff orders never set it ---------------------------------------------------
insert into fx values ('o_pos', pg_temp.place('fo-pos', 'Online Payment (GCash, QR Ph, Card)', 'full', 'fo-pos'));
insert into public.pos_sales (order_id, branch_id, staff_uid) values (pg_temp.f('o_pos'), pg_temp.f('ba')::uuid, 'fo-sa');
select pg_temp.chk_true('POS: a paid order recorded as a POS sale does not set it',
  pg_temp.pay(pg_temp.f('o_pos'), 'pos') = 'success' and pg_temp.first('fo-pos'));

-- 12. Owner's manual confirmation does not set it ----------------------------------------
delete from public.pos_sales where order_id = pg_temp.f('o_pos');
insert into fx values ('o_own', pg_temp.place('fo-late', 'Online Payment (GCash, QR Ph, Card)', 'half', 'fo-own-1'));
select pg_temp.chk('the owner confirms the online part by hand', 'fo-own',
  format($q$select public.owner_confirm_online_payment(%L, 'HitPay webhook never arrived, checked dashboard', 'REF-1')$q$, pg_temp.f('o_own')), 'ok');
select pg_temp.chk_true('owner confirmation: the order is released, but only the webhook sets first_paid_order_at',
  (select status = 'pending' from public.orders where id = pg_temp.f('o_own')) and pg_temp.first('fo-late'));

-- 13. Grandfathering query of the migration ---------------------------------------------
-- A customer with a completed online order and no first_paid_order_at gets one.
update public.customer_profiles set first_paid_order_at = null where firebase_uid = 'fo-new';
update public.customer_profiles cp set first_paid_order_at = x.first_at
  from (select o.firebase_uid, min(o.created_at) as first_at from public.orders o
        where o.firebase_uid is not null and not exists (select 1 from public.pos_sales ps where ps.order_id = o.id)
          and (o.status in ('completed', 'refundRequested', 'refunded')
               or exists (select 1 from public.payments p where p.order_id = o.id and p.status in ('success', 'refunded'))
               or exists (select 1 from public.order_downpayments d where d.order_id = o.id and d.status in ('success', 'refunded', 'forfeited')))
        group by o.firebase_uid) x
 where cp.firebase_uid = x.firebase_uid and cp.first_paid_order_at is null and cp.firebase_uid = 'fo-new';
select pg_temp.chk_true('backfill: a customer with a paid online order is not first', not pg_temp.first('fo-new'));

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% first-order check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
