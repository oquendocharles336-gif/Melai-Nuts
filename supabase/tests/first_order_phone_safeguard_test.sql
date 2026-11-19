-- =============================================================================
-- Melai Nuts — first order without phone verification: account-based flag, phone-match
-- safeguard, owner confirmation never uses up the first order, remaining balance online
-- (migration 20261119000000_remove_phone_verification.sql, on top of 20261118015010 / 20261118040000)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/first_order_phone_safeguard_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
-- =============================================================================
begin;

set local timezone = 'Asia/Manila';

create temp table results (id serial primary key, name text not null, passed boolean not null, detail text);
create temp table fx (k text primary key, v text);
grant select on fx to public;

-- p_phone = the phone_number claim Firebase puts in the ID token (null = no verified number).
create function pg_temp.act_as(p_uid text, p_phone text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', (jsonb_build_object(
    'sub', p_uid, 'role', 'authenticated', 'email', p_uid || '@test.local', 'email_verified', true)
    || case when p_phone is null then '{}'::jsonb else jsonb_build_object('phone_number', p_phone) end)::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.back_to_admin() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on function pg_temp.back_to_admin() to public;
create function pg_temp.chk(p_name text, p_uid text, p_phone text, p_sql text, p_expect text, p_like text default null)
returns void language plpgsql as $$
declare v_err text;
begin
  perform pg_temp.act_as(p_uid, p_phone);
  begin execute p_sql; exception when others then v_err := sqlerrm; end;
  perform pg_temp.back_to_admin();
  insert into results(name, passed, detail) values (p_name,
    case p_expect when 'error' then v_err is not null and (p_like is null or v_err like p_like)
                  else v_err is null end,
    'expected ' || p_expect || ' -> ' || coalesce('error: ' || v_err, 'no error'));
end $$;
create function pg_temp.call_as(p_uid text, p_phone text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.act_as(p_uid, p_phone);
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
create function pg_temp.first(p_uid text) returns boolean language sql as $$ select public.is_first_order(p_uid) $$;

-- Fixtures: one unit costs 100 (pickup total 100). ----------------------------------------
insert into public.branches (name, address, latitude, longitude, delivery_fee)
values ('VP-TEST A', 'a', 14.2117, 121.1653, 50);
insert into fx select 'ba', id::text from public.branches where name = 'VP-TEST A';
insert into public.product_categories (label) values ('VP-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'VP-TEST Nut', 100, 'pack' from public.product_categories where label = 'VP-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'VP-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'VP-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
values (pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 100);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_review_refunds)
values ('vp-sa', 'Staff A', 'vp-sa@test.local', 'staff', pg_temp.f('ba')::uuid, 'active', true),
       ('vp-own', 'Owner', 'vp-own@test.local', 'owner', null, 'active', false);
-- vp-paid: pays its first order through the webhook (number 0917 000 0101).
-- vp-new: brand-new account that typed vp-paid's number. vp-dup: flagged as paid (grandfathered)
-- but its profile number is vp-paid's. vp-nophone: paid, no number. vp-man: the owner confirms
-- its payment by hand. vp-bal / vp-bal2: pay the remaining balance online.
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('vp-paid', 'Paid', 'vp-paid@test.local', '09170000101'),
  ('vp-new', 'New', 'vp-new@test.local', '0917 000 0101'),
  ('vp-dup', 'Dup', 'vp-dup@test.local', '+639170000101'),
  ('vp-nophone', 'NoPhone', 'vp-nophone@test.local', ''),
  ('vp-man', 'Manual', 'vp-man@test.local', '09170000104'),
  ('vp-bal', 'Balance', 'vp-bal@test.local', '09170000105'),
  ('vp-bal2', 'Balance2', 'vp-bal2@test.local', '09170000106');
update public.customer_profiles set first_paid_order_at = now() - interval '30 days'
 where firebase_uid in ('vp-dup', 'vp-nophone');
update public.payment_settings set online_payment_enabled = true where id = 'default';
update public.business_settings set cod_downpayment_type = null, cod_downpayment_value = null,
  cod_downpayment_min_order = null, cod_downpayment_expiry_minutes = null, cod_downpayment_pickup_days = null
 where id = 'default';

create function pg_temp.cart(p_uid text, p_phone text) returns text language sql as $$
  select pg_temp.call_as(p_uid, p_phone, format($q$select (public.sync_customer_cart(%L::uuid,
    jsonb_build_array(jsonb_build_object('product_id', %L, 'variant_id', %L, 'quantity', 1)), null, false) ->> 'cart_id')$q$,
    pg_temp.f('ba'), pg_temp.f('prod'), pg_temp.f('var'))) $$;
create function pg_temp.place_sql(p_cart text, p_method text, p_choice text, p_key text) returns text language sql as $$
  select format($q$select public.place_order(%L::uuid, false, null, %L, '', %L, %L)$q$, p_cart, p_method, p_key, p_choice) $$;
create function pg_temp.place(p_uid text, p_phone text, p_method text, p_choice text, p_key text) returns text language sql as $$
  select pg_temp.call_as(p_uid, p_phone, pg_temp.place_sql(pg_temp.cart(p_uid, p_phone), p_method, p_choice, p_key)) $$;
create function pg_temp.pay(p_order text, p_key text) returns text language plpgsql as $$
begin
  perform public.hitpay_set_checkout(p_order, 'preq-' || p_key, 'https://pay.example/' || p_key);
  return public.hitpay_apply_payment(p_order, 'success', 'qrph', 'pay-' || p_key, null, 'preq-' || p_key);
end $$;

-- 0. The verification pieces are gone; the phone list stays private -----------------------------
select pg_temp.chk_true('claim_verified_phone() and the other verified-number functions are gone',
  to_regprocedure('public.claim_verified_phone()') is null
  and to_regprocedure('public._require_verified_phone(text)') is null
  and to_regprocedure('public._phone_status(text)') is null
  and to_regprocedure('public.jwt_verified_phone()') is null);
select pg_temp.chk_true('customer_profiles.verified_phone / phone_verified_at are gone',
  not exists (select 1 from information_schema.columns where table_schema = 'public'
              and table_name = 'customer_profiles' and column_name in ('verified_phone', 'phone_verified_at')));
select pg_temp.chk('a customer cannot read the first-order phone list', 'vp-new', null,
  $q$select count(*) from public.first_order_phones$q$, 'error');
select pg_temp.chk('a customer cannot write the first-order phone list', 'vp-new', null,
  $q$insert into public.first_order_phones (phone, firebase_uid) values ('+639170000101', 'vp-new')$q$, 'error');
select pg_temp.chk('a customer cannot call is_first_order', 'vp-new', null,
  $q$select public.is_first_order('vp-paid')$q$, 'error');

-- 1. Number normalization (normalize_ph_mobile, 20261025000000) ---------------------------------
select pg_temp.chk_true('09171234567, 0917 123 4567, 639171234567, +63 917-123-4567 are the same number',
  public.normalize_ph_mobile('09171234567') = '+639171234567'
  and public.normalize_ph_mobile('0917 123 4567') = '+639171234567'
  and public.normalize_ph_mobile('639171234567') = '+639171234567'
  and public.normalize_ph_mobile('+63 917-123-4567') = '+639171234567');

-- 2. Checkout needs no verified number ---------------------------------------------------------
select pg_temp.chk_true('a brand-new account is a first order', pg_temp.first('vp-paid') and pg_temp.first('vp-new'));
select pg_temp.chk_true('the quote has no phone_* fields any more',
  (select (j ->> 'first_order')::boolean and not (j ? 'phone_verified') and not (j ? 'phone_claimable')
   from (select pg_temp.call_as('vp-paid', null,
     format('select public.first_order_quote(%L::uuid, false)::text', pg_temp.cart('vp-paid', null)))::jsonb j) t));
insert into fx values ('o_paid', pg_temp.place('vp-paid', null, 'Online Payment (GCash, QR Ph, Card)', 'full', 'vp-paid-1'));
select pg_temp.chk_true('placed without any phone_number claim; pickup contact = the profile number',
  (select status = 'awaitingDownpayment' and contact_phone = '+639170000101' from public.orders where id = pg_temp.f('o_paid')));
select pg_temp.chk_true('webhook: paid', pg_temp.pay(pg_temp.f('o_paid'), 'paid') = 'success');
select pg_temp.chk_true('webhook: the account is returning and its number is recorded (normalized)',
  not pg_temp.first('vp-paid')
  and exists (select 1 from public.first_order_phones where phone = '+639170000101' and firebase_uid = 'vp-paid'));
select pg_temp.chk('a returning customer checks out in cash, no SMS step', 'vp-paid', null,
  pg_temp.place_sql(pg_temp.cart('vp-paid', null), 'Cash on Counter Pickup', null, 'vp-paid-2'), 'ok');

-- 3. Phone-match safeguard ----------------------------------------------------------------------
select pg_temp.chk_true('the new account that typed the paying customer''s number is still a first order',
  pg_temp.first('vp-new'));
select pg_temp.chk('...so its cash checkout is refused: the first order is paid online', 'vp-new', null,
  pg_temp.place_sql(pg_temp.cart('vp-new', null), 'Cash on Counter Pickup', null, 'vp-new-1'), 'error',
  '%Your first order is paid online%');
select pg_temp.chk_true('an account flagged as paid whose number another customer paid with: prepayment again',
  pg_temp.first('vp-dup'));
select pg_temp.chk_true('...the quote says first order',
  (select (j ->> 'first_order')::boolean
   from (select pg_temp.call_as('vp-dup', null,
     format('select public.first_order_quote(%L::uuid, false)::text', pg_temp.cart('vp-dup', null)))::jsonb j) t));
insert into fx values ('o_dup', pg_temp.place('vp-dup', null, 'Online Payment (GCash, QR Ph, Card)', 'half', 'vp-dup-1'));
select pg_temp.chk_true('webhook: vp-dup pays its 50%', pg_temp.pay(pg_temp.f('o_dup'), 'dup') = 'success');
select pg_temp.chk_true('...and has now paid with that number itself: returning; vp-paid unaffected',
  not pg_temp.first('vp-dup') and not pg_temp.first('vp-paid')
  and (select count(*) = 2 from public.first_order_phones where phone = '+639170000101'));
select pg_temp.chk_true('the new account still prepays (a match it never paid with)', pg_temp.first('vp-new'));
select pg_temp.chk_true('a paid account without a number is returning', not pg_temp.first('vp-nophone'));
update public.customer_profiles set phone = '09170000101' where firebase_uid = 'vp-nophone';
select pg_temp.chk_true('...until it puts a number other customers paid with on its profile', pg_temp.first('vp-nophone'));
update public.customer_profiles set phone = '09170000199' where firebase_uid = 'vp-nophone';
select pg_temp.chk_true('...an unused number is fine again', not pg_temp.first('vp-nophone'));
select pg_temp.chk('signing up with a number a paying customer has is never refused', 'vp-signup', null,
  $q$insert into public.customer_profiles (firebase_uid, full_name, email, phone) values ('vp-signup', 'Sign Up', 'vp-signup@test.local', '09170000101')$q$, 'ok');

-- 4. Owner's manual confirmation never uses up the first order -------------------------------------
select pg_temp.chk_true('owner_confirm_online_payment never refers to the first-order flag (source check)',
  (select prosrc !~ '(_mark_first_paid_order|first_paid_order_at|first_order_mark|first_order_phones)'
   from pg_proc where oid = 'public.owner_confirm_online_payment(text,text,text)'::regprocedure));
select pg_temp.chk_true('_cod_downpayment_apply (shared with the owner path) never refers to it either',
  (select prosrc !~ '(_mark_first_paid_order|first_paid_order_at|first_order_mark|first_order_phones)'
   from pg_proc where oid = 'public._cod_downpayment_apply(public.orders,public.order_downpayments,text,text,text,text)'::regprocedure));
insert into fx values ('o_man', pg_temp.place('vp-man', null, 'Online Payment (GCash, QR Ph, Card)', 'full', 'vp-man-1'));
select pg_temp.chk('the owner confirms the online payment by hand', 'vp-own', null,
  format($q$select public.owner_confirm_online_payment(%L, 'HitPay webhook never arrived, checked dashboard', 'REF-VP')$q$, pg_temp.f('o_man')), 'ok');
select pg_temp.chk_true('owner confirmation: the order is released to staff',
  (select o.status = 'pending' and d.status = 'success'
   from public.orders o join public.order_downpayments d on d.order_id = o.id where o.id = pg_temp.f('o_man')));
select pg_temp.chk_true('owner confirmation: first_paid_order_at untouched, number not recorded, still a first order',
  (select first_paid_order_at is null from public.customer_profiles where firebase_uid = 'vp-man')
  and not exists (select 1 from public.first_order_phones where firebase_uid = 'vp-man')
  and pg_temp.first('vp-man'));
insert into fx values ('r_man', public.hitpay_apply_payment(pg_temp.f('o_man'), 'success', 'qrph', 'pay-man', null, null));
select pg_temp.chk_true('a late webhook for the same (already confirmed) payment does not use it up either',
  pg_temp.f('r_man') = 'success'
  and pg_temp.first('vp-man'));
select pg_temp.chk_true('so the next order shows the 50% / 100% step again',
  (select (j ->> 'first_order')::boolean
   from (select pg_temp.call_as('vp-man', null,
     format('select public.first_order_quote(%L::uuid, false)::text', pg_temp.cart('vp-man', null)))::jsonb j) t));

-- The guard: an API caller can never set the flag, whatever function it goes through.
create function pg_temp.guard(p_role text, p_mark boolean) returns text language plpgsql as $$
declare v_err text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', 'vp-own', 'role', p_role)::text, true);
  if p_mark then perform set_config('app.first_order_mark', 'on', true); end if;
  begin
    update public.customer_profiles set first_paid_order_at = now() where firebase_uid = 'vp-man';
  exception when others then v_err := sqlerrm; end;
  perform set_config('app.first_order_mark', 'off', true);
  perform set_config('request.jwt.claims', '', true);
  return coalesce(v_err, 'ok');
end $$;
select pg_temp.chk_true('guard: an owner request (role authenticated) cannot set first_paid_order_at',
  pg_temp.guard('authenticated', false) like '%only by the HitPay payment webhook%');
select pg_temp.chk_true('guard: the service role cannot set it outside the webhook function either',
  pg_temp.guard('service_role', false) like '%only by the HitPay payment webhook%');
select pg_temp.chk_true('guard: inside _mark_first_paid_order (webhook) it is allowed', pg_temp.guard('service_role', true) = 'ok');
update public.customer_profiles set first_paid_order_at = null where firebase_uid = 'vp-man';   -- fixture reset (SQL editor: allowed)

-- 5. Remaining balance online ---------------------------------------------------------------
insert into fx values ('o_bal', pg_temp.place('vp-bal', null, 'Online Payment (GCash, QR Ph, Card)', 'half', 'vp-bal-1'));
select pg_temp.chk_true('50%: downpayment 50 online, balance 50 on the payments row',
  (select d.amount = 50 and p.amount = 50 and p.method = 'cash'
   from public.order_downpayments d join public.payments p on p.order_id = d.order_id where d.order_id = pg_temp.f('o_bal')));
select pg_temp.chk_true('before the downpayment is paid, checkout is for the downpayment',
  public.hitpay_claim_checkout(pg_temp.f('o_bal'), 60) ->> 'action' = 'create');
select pg_temp.chk_true('webhook: the 50% is paid', pg_temp.pay(pg_temp.f('o_bal'), 'bal-dp') = 'success');
select pg_temp.chk_true('the customer is told the rest can be paid online',
  exists (select 1 from public.notifications where firebase_uid = 'vp-bal'
          and body like '%' || pg_temp.f('o_bal') || '%can be paid online now%'));
select pg_temp.chk_true('balance: a new checkout opens on the payments row',
  public.hitpay_claim_checkout(pg_temp.f('o_bal'), 60) ->> 'action' = 'create');
select public.hitpay_set_checkout(pg_temp.f('o_bal'), 'preq-bal-1', 'https://pay.example/bal-1');
select pg_temp.chk_true('balance: the link is stored on the payments row, the paid downpayment is untouched',
  (select p.gateway_payment_id = 'preq-bal-1' and p.status = 'processing' and d.gateway_payment_id = 'pay-bal-dp' and d.status = 'success'
   from public.payments p join public.order_downpayments d on d.order_id = p.order_id where p.order_id = pg_temp.f('o_bal')));
insert into fx values ('r_fail', public.hitpay_apply_payment(pg_temp.f('o_bal'), 'failed', null, null, null, 'preq-bal-1'));
select pg_temp.chk_true('balance: a failed attempt leaves it open (pending) for cash or another try',
  pg_temp.f('r_fail') = 'failed'
  and (select status = 'pending' and gateway_checkout_url is null from public.payments where order_id = pg_temp.f('o_bal')));
select public.hitpay_claim_checkout(pg_temp.f('o_bal'), 60);
select public.hitpay_set_checkout(pg_temp.f('o_bal'), 'preq-bal-2', 'https://pay.example/bal-2');
insert into fx values ('r_bal', public.hitpay_apply_payment(pg_temp.f('o_bal'), 'success', 'gcash', 'pay-bal-2', 'REF', 'preq-bal-2'));
select pg_temp.chk_true('balance: the webhook marks the payments row paid with the method used',
  pg_temp.f('r_bal') = 'success'
  and (select status = 'success' and method = 'gcash' from public.payments where order_id = pg_temp.f('o_bal'))
  and (select status = 'success' and amount = 50 from public.order_downpayments where order_id = pg_temp.f('o_bal')));
select pg_temp.chk_true('balance paid: no more checkout', public.hitpay_claim_checkout(pg_temp.f('o_bal'), 60) ->> 'action' = 'closed');

-- Cash collected while the online checkout was open, then paid online too: refund opened.
insert into fx values ('o_bal2', pg_temp.place('vp-bal2', null, 'Online Payment (GCash, QR Ph, Card)', 'half', 'vp-bal2-1'));
select pg_temp.pay(pg_temp.f('o_bal2'), 'bal2-dp');
select public.hitpay_claim_checkout(pg_temp.f('o_bal2'), 60);
select public.hitpay_set_checkout(pg_temp.f('o_bal2'), 'preq-bal2-1', 'https://pay.example/bal2-1');
select pg_temp.chk('staff collect the balance in cash', 'vp-sa', null,
  format($q$select public.staff_confirm_payment(%L)$q$, pg_temp.f('o_bal2')), 'ok');
insert into fx values ('r_bal2', public.hitpay_apply_payment(pg_temp.f('o_bal2'), 'success', 'gcash', 'pay-bal2-1', null, 'preq-bal2-1'));
select pg_temp.chk_true('paid online as well: the owner is told to refund the online part, the order goes on',
  pg_temp.f('r_bal2') = 'success'
  and exists (select 1 from public.staff_notifications where reference = pg_temp.f('o_bal2') and title = 'Refund needed: balance paid twice')
  and (select status = 'pending' from public.orders where id = pg_temp.f('o_bal2')));

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% first-order phone safeguard check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
