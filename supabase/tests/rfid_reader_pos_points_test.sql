-- =============================================================================
-- Melai Nuts — Wi-Fi card readers, customer self-link, loyalty PIN and POS points (migration 20261119050000)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rfid_reader_pos_points_test.sql
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
      'email', p_uid || '@test.local', 'email_verified', true, 'phone_number', '+639' || lpad((abs(hashtext(p_uid)) % 1000000000)::text, 9, '0'))::text, true);
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
insert into public.branches (name, address, delivery_fee) values ('RDR-TEST A', 'a', 0), ('RDR-TEST B', 'b', 0);
-- Test fixture: 1 point = PHP 1 off, at most 50% of a sale; earn 1 point per PHP 50.
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point)
values ('default', 1, 50, 50)
  on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;
insert into fx select 'ba', id::text from public.branches where name = 'RDR-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'RDR-TEST B';
insert into public.product_categories (label) values ('RDR-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'RDR-TEST Nut', 100, 'pack' from public.product_categories where label = 'RDR-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'RDR-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'RDR-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 0;

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('r-sa',  'Cashier A', 'r-sa@test.local',  'staff', pg_temp.f('ba')::uuid, 'active'),
       ('r-sb',  'Cashier B', 'r-sb@test.local',  'staff', pg_temp.f('bb')::uuid, 'active'),
       ('r-own', 'Owner',     'r-own@test.local', 'owner', null, 'active');
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('r-c1', 'Reader Customer One', 'r-c1@test.local', '09172220001'),
  ('r-c2', 'Reader Customer Two', 'r-c2@test.local', '09172220002');

select pg_temp.call_as('r-own', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'RDR-A1', 50, current_date + 90)::text$q$,
  pg_temp.f('ba'), pg_temp.f('var')));
select set_config('app.inventory_managed', '', true);

-- 1. Readers --------------------------------------------------------------------------
insert into fx select 'dev1', public.rfid_register_device('Counter 1', pg_temp.f('ba')::uuid)::text;
insert into fx select 'dev2', public.rfid_register_device('Counter 2', pg_temp.f('bb')::uuid)::text;
insert into fx select 'code1', pg_temp.f('dev1')::jsonb ->> 'device_code';
insert into fx select 'key1',  pg_temp.f('dev1')::jsonb ->> 'device_key';
insert into fx select 'code2', pg_temp.f('dev2')::jsonb ->> 'device_code';
insert into fx select 'key2',  pg_temp.f('dev2')::jsonb ->> 'device_key';
insert into fx select 'dev1id', id::text from public.rfid_devices where device_code = pg_temp.f('code1');
insert into fx select 'dev2id', id::text from public.rfid_devices where device_code = pg_temp.f('code2');

create function pg_temp.tap(p_code text, p_key text, p_uid text) returns jsonb language sql as $$
  select public.rfid_device_tap(p_code, public._device_key_hash(p_key), p_uid, '10.0.0.1') $$;

select pg_temp.chk_true('device code format and 64-char key',
  pg_temp.f('code1') ~ '^MN-RDR-[0-9A-F]{8}$' and length(pg_temp.f('key1')) = 64);
select pg_temp.chk_true('only the key hash is stored',
  (select key_hash = public._device_key_hash(pg_temp.f('key1')) and key_hash <> pg_temp.f('key1')
   from public.rfid_devices where device_code = pg_temp.f('code1')));
select pg_temp.chk('customer cannot register a reader', 'r-c1', $q$select public.rfid_register_device('x', null)$q$, 'error');
select pg_temp.chk('owner cannot register a reader through the API', 'r-own', $q$select public.rfid_register_device('x', null)$q$, 'error');
select pg_temp.chk('customer cannot call the reader function', 'r-c1',
  format($q$select public.rfid_device_tap(%L, 'x', '04A1B2C3')$q$, pg_temp.f('code1')), 'error');
select pg_temp.chk('anon cannot call the reader function', null,
  format($q$select public.rfid_device_tap(%L, 'x', '04A1B2C3')$q$, pg_temp.f('code1')), 'error');
select pg_temp.chk('customer cannot read readers table', 'r-c1', 'select count(*) from public.rfid_devices', 'error');

select pg_temp.chk_true('wrong key refused',
  pg_temp.tap(pg_temp.f('code1'), 'WRONG', '04A1B2C3') ->> 'result' = 'device_rejected');
select pg_temp.chk_true('wrong key logged',
  exists (select 1 from public.rfid_device_taps where device_code = pg_temp.f('code1') and result = 'device_rejected'));
select pg_temp.chk_true('unknown device code refused',
  pg_temp.tap('MN-RDR-00000000', pg_temp.f('key1'), '04A1B2C3') ->> 'result' = 'device_rejected');
select pg_temp.chk_true('key of another reader refused',
  pg_temp.tap(pg_temp.f('code1'), pg_temp.f('key2'), '04A1B2C3') ->> 'result' = 'device_rejected');
select pg_temp.chk_true('bad UID refused',
  pg_temp.tap(pg_temp.f('code1'), pg_temp.f('key1'), 'hello') ->> 'result' = 'invalid_card');
select pg_temp.chk_true('unlinked card, no session: unregistered, no customer data',
  (select j ->> 'result' = 'unregistered' and j -> 'points_balance' = 'null'::jsonb
   from (select pg_temp.tap(pg_temp.f('code1'), pg_temp.f('key1'), '04:a1:b2:c3') as j) t));
select pg_temp.chk_true('reader last_seen updated', (select last_seen_at is not null from public.rfid_devices where device_code = pg_temp.f('code1')));

-- 2. Pairing ---------------------------------------------------------------------------
select pg_temp.chk_true('customer sees active readers (name + branch only)',
  (select jsonb_array_length(j) = 2 and not (j -> 0 ? 'device_code')
   from (select pg_temp.j('r-c1', 'public.customer_list_card_readers()') as j) t));
select pg_temp.chk('staff-only account (no profile) cannot start pairing', 'r-sa',
  format($q$select public.customer_start_card_pairing(%L::uuid)$q$, pg_temp.f('dev1id')), 'error');
insert into fx select 's1', pg_temp.j('r-c1', format($q$public.customer_start_card_pairing(%L::uuid)$q$, pg_temp.f('dev1id'))) ->> 'id';
select pg_temp.chk_true('pairing session open, 60 s',
  (select status = 'waiting' and expires_at between now() + interval '55 seconds' and now() + interval '61 seconds'
   from public.rfid_pairing_sessions where id = pg_temp.f('s1')::uuid));
select pg_temp.chk('second customer on the same reader: busy', 'r-c2',
  format($q$select public.customer_start_card_pairing(%L::uuid)$q$, pg_temp.f('dev1id')), 'error');
select pg_temp.chk_true('customer reads own session (RLS)',
  pg_temp.call_as('r-c1', 'select count(*)::text from public.rfid_pairing_sessions') = '1');
select pg_temp.chk_true('other customer cannot see it (RLS)',
  pg_temp.call_as('r-c2', 'select count(*)::text from public.rfid_pairing_sessions') = '0');
select pg_temp.chk('customer cannot write sessions directly', 'r-c1',
  format($q$update public.rfid_pairing_sessions set status = 'linked' where id = %L$q$, pg_temp.f('s1')), 'error');

-- Tap on the OTHER reader does not use the session.
select pg_temp.chk_true('tap on another reader: not linked',
  pg_temp.tap(pg_temp.f('code2'), pg_temp.f('key2'), '04A1B2C3') ->> 'result' = 'unregistered');

insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points) values ('r-c1', 0, 0)
  on conflict (firebase_uid) do nothing;
insert into fx select 'link', pg_temp.tap(pg_temp.f('code1'), pg_temp.f('key1'), '04A1B2C3')::text;
select pg_temp.chk_true('tap during session links the card',
  pg_temp.f('link')::jsonb ->> 'result' = 'linked' and pg_temp.f('link')::jsonb ->> 'card_label' ~ '^GK-'
  and not (pg_temp.f('link')::jsonb ? 'customer_name'));
select pg_temp.chk_true('card registry row, active, issued at the reader branch',
  (select status = 'active' and issued_branch_id = pg_temp.f('ba')::uuid and issued_by = 'reader:' || pg_temp.f('code1')
   from public.loyalty_cards where card_uid_hash = public._card_uid_hash('04A1B2C3') and firebase_uid = 'r-c1'));
select pg_temp.chk_true('session closed as linked with balance',
  (select status = 'linked' and points_balance = 0 and card_label is not null
   from public.rfid_pairing_sessions where id = pg_temp.f('s1')::uuid));
select pg_temp.chk_true('profile label synced (app shows Active)',
  (select rfid_card_number ~ '^GK-' from public.customer_profiles where firebase_uid = 'r-c1'));
select pg_temp.chk_true('card history: registered by the customer',
  exists (select 1 from public.loyalty_card_events e join public.loyalty_cards c on c.id = e.card_id
          where c.firebase_uid = 'r-c1' and e.event = 'registered' and e.note like 'Linked by the customer%'));

select pg_temp.chk_true('tap again, no session: synced with balance',
  (select j ->> 'result' = 'synced' and (j ->> 'points_balance')::int = 0
   from (select pg_temp.tap(pg_temp.f('code1'), pg_temp.f('key1'), '04A1B2C3') as j) t));
select pg_temp.chk_true('still exactly one card for that UID',
  (select count(*) = 1 from public.loyalty_cards where card_uid_hash = public._card_uid_hash('04A1B2C3')));
select pg_temp.chk_true('customer sees own tap results (column grant)',
  pg_temp.call_as('r-c1', $q$select count(*)::text from public.rfid_device_taps where result in ('linked','synced')$q$) = '2');
select pg_temp.chk('customer cannot read card hashes in the log', 'r-c1',
  'select card_uid_hash from public.rfid_device_taps', 'error');
do $$ begin
  begin update public.rfid_device_taps set result = 'synced'; raise exception 'no error';
  exception when others then
    insert into results(name, passed, detail) values ('tap log cannot be rewritten (even by the owner role)',
      sqlerrm like '%cannot be changed%', sqlerrm);
  end;
end $$;

-- Customer 2 tries to take customer 1's card.
insert into fx select 's2', pg_temp.j('r-c2', format($q$public.customer_start_card_pairing(%L::uuid)$q$, pg_temp.f('dev1id'))) ->> 'id';
select pg_temp.chk_true('card of another account: refused',
  pg_temp.tap(pg_temp.f('code1'), pg_temp.f('key1'), '04A1B2C3') ->> 'result' = 'card_taken');
select pg_temp.chk_true('session failed with card_taken, no balance leaked',
  (select status = 'failed' and result_code = 'card_taken' and points_balance is null
   from public.rfid_pairing_sessions where id = pg_temp.f('s2')::uuid));
select pg_temp.chk_true('card still belongs to customer 1',
  (select firebase_uid = 'r-c1' from public.loyalty_cards where card_uid_hash = public._card_uid_hash('04A1B2C3')));

-- Customer 1 cannot pair a second card while one is active.
select pg_temp.chk('one active card per customer (pairing refused)', 'r-c1',
  format($q$select public.customer_start_card_pairing(%L::uuid)$q$, pg_temp.f('dev1id')), 'error');

-- Expiry
insert into fx select 's3', pg_temp.j('r-c2', format($q$public.customer_start_card_pairing(%L::uuid)$q$, pg_temp.f('dev2id'))) ->> 'id';
update public.rfid_pairing_sessions set expires_at = now() - interval '1 second' where id = pg_temp.f('s3')::uuid;
select pg_temp.chk_true('expired session does not link',
  pg_temp.tap(pg_temp.f('code2'), pg_temp.f('key2'), '11223344') ->> 'result' = 'unregistered');
select pg_temp.chk_true('expired session closed',
  (select status from public.rfid_pairing_sessions where id = pg_temp.f('s3')::uuid) = 'expired');
insert into fx select 's4', pg_temp.j('r-c2', format($q$public.customer_start_card_pairing(%L::uuid)$q$, pg_temp.f('dev2id'))) ->> 'id';
select pg_temp.chk_true('cancel closes the session',
  pg_temp.j('r-c2', format($q$public.customer_cancel_card_pairing(%L::uuid)$q$, pg_temp.f('s4'))) ->> 'status' = 'cancelled');
select pg_temp.chk('cannot cancel another customer''s session', 'r-c1',
  format($q$select public.customer_cancel_card_pairing(%L::uuid)$q$, pg_temp.f('s4')), 'error');

-- 3. Rate limits ---------------------------------------------------------------------
do $$ declare i int; begin
  for i in 1..25 loop perform pg_temp.tap(pg_temp.f('code2'), 'WRONG', '11223344'); end loop;
end $$;
select pg_temp.chk_true('wrong-key flood blocks the device code (even with the right key)',
  pg_temp.tap(pg_temp.f('code2'), pg_temp.f('key2'), '11223344') ->> 'result' = 'rate_limited');
do $$ declare i int; begin
  for i in 1..35 loop perform pg_temp.tap(pg_temp.f('code1'), pg_temp.f('key1'), '04A1B2C3'); end loop;
end $$;
select pg_temp.chk_true('more than 30 taps per minute: rate limited',
  pg_temp.tap(pg_temp.f('code1'), pg_temp.f('key1'), '04A1B2C3') ->> 'result' = 'rate_limited');
-- Let the window pass for the rest of the suite.
alter table public.rfid_device_taps disable trigger rfid_device_taps_append_only;
update public.rfid_device_taps set created_at = created_at - interval '1 hour';
alter table public.rfid_device_taps enable trigger rfid_device_taps_append_only;
select set_config('melai.force_rate_limits', 'on', true);
insert into public.rfid_pairing_sessions (firebase_uid, device_id, status, expires_at)
select 'r-c2', pg_temp.f('dev2id')::uuid, 'cancelled', now() from generate_series(1, 10);
select pg_temp.chk('customer pairing attempts are limited', 'r-c2',
  format($q$select public.customer_start_card_pairing(%L::uuid)$q$, pg_temp.f('dev2id')), 'error');
select set_config('melai.force_rate_limits', '', true);
update public.rfid_pairing_sessions set status = 'cancelled' where firebase_uid = 'r-c2' and status = 'waiting';

-- 4. Customer block / remove --------------------------------------------------------------
select pg_temp.chk_true('block my card',
  pg_temp.j('r-c1', $q$public.customer_block_my_card('lost on a jeepney')$q$) ->> 'status' = 'blocked');
select pg_temp.chk_true('blocked card refused at the reader',
  pg_temp.tap(pg_temp.f('code1'), pg_temp.f('key1'), '04A1B2C3') ->> 'result' = 'card_blocked');
select pg_temp.chk_true('profile label cleared (app shows not active)',
  (select rfid_card_number is null from public.customer_profiles where firebase_uid = 'r-c1'));
select pg_temp.chk_true('blocked card refused at the POS lookup',
  pg_temp.j('r-sa', $q$public.staff_lookup_card('04A1B2C3')$q$) ->> 'status' = 'blocked');
-- New card replaces the blocked one.
insert into fx select 's5', pg_temp.j('r-c1', format($q$public.customer_start_card_pairing(%L::uuid)$q$, pg_temp.f('dev1id'))) ->> 'id';
select pg_temp.chk_true('new card links after blocking',
  pg_temp.tap(pg_temp.f('code1'), pg_temp.f('key1'), 'A1B2C3D4') ->> 'result' = 'linked');
select pg_temp.chk_true('blocked card retired and points to the new one',
  (select o.status = 'replaced' and o.replaced_by = n.id
   from public.loyalty_cards o, public.loyalty_cards n
   where o.card_uid_hash = public._card_uid_hash('04A1B2C3') and n.card_uid_hash = public._card_uid_hash('A1B2C3D4')));
select pg_temp.chk('customer cannot block a card with none active', 'r-c2', 'select public.customer_block_my_card(null)', 'error');

-- 5. PIN -------------------------------------------------------------------------------
select pg_temp.chk_true('no PIN by default', (pg_temp.j('r-c1', 'public.get_my_loyalty_pin_status()') ->> 'has_pin')::boolean = false);
select pg_temp.chk('PIN must be 4-6 digits', 'r-c1', $q$select public.customer_set_loyalty_pin('12a4')$q$, 'error');
select pg_temp.chk_true('set PIN',
  (pg_temp.j('r-c1', $q$public.customer_set_loyalty_pin('4321')$q$) ->> 'ok')::boolean);
select pg_temp.chk_true('PIN not stored in clear',
  (select pin_hash <> '4321' and length(pin_hash) = 64 from public.loyalty_pins where firebase_uid = 'r-c1'));
select pg_temp.chk_true('change PIN needs the current one',
  (pg_temp.j('r-c1', $q$public.customer_set_loyalty_pin('1111', '0000')$q$) ->> 'ok')::boolean = false);
update public.loyalty_pins set failed_attempts = 0 where firebase_uid = 'r-c1';
select pg_temp.chk('customer cannot read PINs table', 'r-c1', 'select count(*) from public.loyalty_pins', 'error');

-- 6. POS quote and redeem ----------------------------------------------------------------
update public.loyalty_accounts set points_balance = 120, lifetime_points = 120 where firebase_uid = 'r-c1';
create function pg_temp.items(p_qty int) returns text language sql as $$
  select jsonb_build_array(jsonb_build_object('variant_id', pg_temp.f('var'), 'quantity', p_qty))::text $$;
grant execute on function pg_temp.items(int) to public;

insert into fx select 'q', pg_temp.j('r-sa', format($q$public.staff_pos_quote(%L::uuid, %L::jsonb, 'r-c1', true)$q$,
  pg_temp.f('ba'), pg_temp.items(2)))::text;
-- Subtotal 200, 50% cap = 100 pesos = 100 points (balance 120) -> total 100, earns 2.
select pg_temp.chk_true('quote uses the app''s rule (cap 50%, 1 pt = PHP 1)',
  (select (j ->> 'subtotal')::numeric = 200 and (j ->> 'points_used')::int = 100 and (j ->> 'loyalty_discount')::numeric = 100
      and (j ->> 'total')::numeric = 100 and (j ->> 'points_to_earn')::int = 2 and (j ->> 'pin_required')::boolean
   from (select pg_temp.f('q')::jsonb as j) t),
  pg_temp.f('q'));
select pg_temp.chk_true('quote helper = place_order formula (balance cap)',
  (public._loyalty_redeem_quote(30, 200, 0) ->> 'points_used')::int = 30
  and (public._loyalty_redeem_quote(500, 200, 150) ->> 'points_used')::int = 50);
select pg_temp.chk('quote: staff of another branch refused', 'r-sb',
  format($q$select public.staff_pos_quote(%L::uuid, %L::jsonb, 'r-c1', true)$q$, pg_temp.f('ba'), pg_temp.items(2)), 'error');
select pg_temp.chk('quote: customer refused', 'r-c1',
  format($q$select public.staff_pos_quote(%L::uuid, %L::jsonb, 'r-c1', true)$q$, pg_temp.f('ba'), pg_temp.items(2)), 'error');

select pg_temp.chk('redeem needs name confirmation', 'r-sa',
  format($q$select public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 200, 'r-c1', 'rdr-k0', true, '4321', false)$q$,
    pg_temp.f('ba'), pg_temp.items(2)), 'error');
select pg_temp.chk('redeem needs a customer', 'r-sa',
  format($q$select public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 200, null, 'rdr-k0b', true, null, true)$q$,
    pg_temp.f('ba'), pg_temp.items(2)), 'error');
insert into fx select 'wrongpin', pg_temp.j('r-sa', format(
  $q$public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 200, 'r-c1', 'rdr-k1', true, '9999', true)$q$,
  pg_temp.f('ba'), pg_temp.items(2)))::text;
select pg_temp.chk_true('wrong PIN: no sale, attempt counted',
  pg_temp.f('wrongpin')::jsonb ->> 'error' = 'pin_wrong'
  and not exists (select 1 from public.pos_sales where idempotency_key = 'rdr-k1')
  and (select failed_attempts = 1 from public.loyalty_pins where firebase_uid = 'r-c1')
  and (select points_balance = 120 from public.loyalty_accounts where firebase_uid = 'r-c1'),
  pg_temp.f('wrongpin'));

insert into fx select 'sale', pg_temp.j('r-sa', format(
  $q$public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 100, 'r-c1', 'rdr-k1', true, '4321', true)$q$,
  pg_temp.f('ba'), pg_temp.items(2)))::text;
insert into fx select 'oid', pg_temp.f('sale')::jsonb ->> 'order_id';
select pg_temp.chk_true('redeem sale: server totals (subtotal 200, -100, pay 100, cash 100 accepted)',
  (select (j ->> 'subtotal')::numeric = 200 and (j ->> 'loyalty_discount')::numeric = 100
      and (j ->> 'total')::numeric = 100 and (j ->> 'points_redeemed')::int = 100 and (j ->> 'change')::numeric = 0
   from (select pg_temp.f('sale')::jsonb as j) t), pg_temp.f('sale'));
select pg_temp.chk_true('balance: 120 - 100 redeemed + 2 earned = 22',
  (select points_balance = 22 from public.loyalty_accounts where firebase_uid = 'r-c1'),
  (select points_balance::text from public.loyalty_accounts where firebase_uid = 'r-c1'));
select pg_temp.chk_true('ledger rows carry order, staff and branch',
  (select count(*) = 2 and bool_and(staff_uid = 'r-sa' and branch_id = pg_temp.f('ba')::uuid)
      and count(*) filter (where source = 'order_redeem' and points = -100) = 1
      and count(*) filter (where source = 'order_earn' and points = 2) = 1
   from public.loyalty_transactions where order_id = pg_temp.f('oid')));
select pg_temp.chk_true('payment amount is the discounted total',
  (select amount = 100 and status = 'success' from public.payments where order_id = pg_temp.f('oid')));
select pg_temp.chk_true('PIN counter reset after a correct PIN',
  (select failed_attempts = 0 from public.loyalty_pins where firebase_uid = 'r-c1'));
select pg_temp.chk_true('retry with the same key: same sale, nothing applied twice',
  (select j ->> 'order_id' = pg_temp.f('oid') and (j ->> 'already_recorded')::boolean and (j ->> 'points_redeemed')::int = 100
   from (select pg_temp.j('r-sa', format(
     $q$public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 100, 'r-c1', 'rdr-k1', true, '4321', true)$q$,
     pg_temp.f('ba'), pg_temp.items(2))) as j) t)
  and (select points_balance = 22 from public.loyalty_accounts where firebase_uid = 'r-c1'));
select pg_temp.chk('same key without redeem = different sale: refused', 'r-sa',
  format($q$select public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 200, 'r-c1', 'rdr-k1')$q$,
    pg_temp.f('ba'), pg_temp.items(2)), 'error');
do $$ begin
  begin
    insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
    values ('r-c1', 'redeem', -1, 'second', pg_temp.f('oid'), 'order_redeem');
    insert into results(name, passed, detail) values ('second redemption row for one order refused', false, 'inserted');
  exception when unique_violation then
    insert into results(name, passed, detail) values ('second redemption row for one order refused', true, sqlerrm);
  end;
end $$;
select pg_temp.chk_true('customer history hides staff uid but shows the rows',
  pg_temp.call_as('r-c1', format($q$select count(*)::text from public.loyalty_transactions where order_id = %L$q$, pg_temp.f('oid'))) = '2');
select pg_temp.chk('customer cannot read staff_uid', 'r-c1', 'select staff_uid from public.loyalty_transactions', 'error');

-- Small balance: never negative, no PIN lock-out effects.
update public.loyalty_accounts set points_balance = 22 where firebase_uid = 'r-c1';
insert into fx select 'sale2', pg_temp.j('r-sa', format(
  $q$public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 100, 'r-c1', 'rdr-k2', true, '4321', true)$q$,
  pg_temp.f('ba'), pg_temp.items(1)))::text;
select pg_temp.chk_true('redeem capped at the balance (22 of 50 possible), balance 0 + earned',
  (pg_temp.f('sale2')::jsonb ->> 'points_redeemed')::int = 22
  and (pg_temp.f('sale2')::jsonb ->> 'total')::numeric = 78
  and (select points_balance = 1 from public.loyalty_accounts where firebase_uid = 'r-c1'),
  pg_temp.f('sale2'));
update public.loyalty_accounts set points_balance = 0 where firebase_uid = 'r-c1';
select pg_temp.chk('no points to redeem: refused, nothing sold', 'r-sa',
  format($q$select public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 100, 'r-c1', 'rdr-k3', true, '4321', true)$q$,
    pg_temp.f('ba'), pg_temp.items(1)), 'error');
select pg_temp.chk_true('refused redeem left no order', not exists (select 1 from public.pos_sales where idempotency_key = 'rdr-k3'));

-- PIN lock after 5 wrong tries.
update public.loyalty_accounts set points_balance = 50 where firebase_uid = 'r-c1';
do $$ declare i int; begin
  for i in 1..5 loop
    perform pg_temp.j('r-sa', format(
      $q$public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 100, 'r-c1', %L, true, '0000', true)$q$,
      pg_temp.f('ba'), pg_temp.items(1), 'rdr-lock-' || i));
  end loop;
end $$;
select pg_temp.chk_true('5 wrong PINs lock redemption, even with the right PIN',
  pg_temp.j('r-sa', format(
    $q$public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 100, 'r-c1', 'rdr-k4', true, '4321', true)$q$,
    pg_temp.f('ba'), pg_temp.items(1))) ->> 'error' = 'pin_locked'
  and (select points_balance = 50 from public.loyalty_accounts where firebase_uid = 'r-c1'));
select pg_temp.chk('earning still works while locked (no redeem)', 'r-sa',
  format($q$select public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 100, 'r-c1', 'rdr-k5')$q$,
    pg_temp.f('ba'), pg_temp.items(1)), 'ok');

-- Customer 2 has no PIN: redeem works with name confirmation only.
insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points) values ('r-c2', 10, 10)
  on conflict (firebase_uid) do update set points_balance = 10;
select pg_temp.chk_true('no PIN set: redeem with confirmation only',
  (pg_temp.j('r-sa', format(
    $q$public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'gcash', 'GC123456', null, 'r-c2', 'rdr-k6', true, null, true)$q$,
    pg_temp.f('ba'), pg_temp.items(1))) ->> 'points_redeemed')::int = 10);

-- Old 7-argument calls still work (website, tests).
select pg_temp.chk('positional 5-argument call still works', 'r-sa',
  format($q$select public.staff_create_pos_sale(%L::uuid, %L::jsonb, 'cash', null, 100)$q$, pg_temp.f('ba'), pg_temp.items(1)), 'ok');
select pg_temp.chk_true('only one staff_create_pos_sale function exists',
  (select count(*) = 1 from pg_proc where proname = 'staff_create_pos_sale' and pronamespace = 'public'::regnamespace));

-- 7. Owner view ------------------------------------------------------------------------
select pg_temp.chk_true('owner sees readers with activity',
  (select jsonb_array_length(j) = 2 from (select pg_temp.j('r-own', 'public.owner_list_rfid_devices()') as j) t));
select pg_temp.chk('staff cannot list readers', 'r-sa', 'select public.owner_list_rfid_devices()', 'error');
select pg_temp.chk_true('switched-off reader refused',
  (public.rfid_set_device_active(pg_temp.f('code1'), false) ->> 'is_active')::boolean = false
  and pg_temp.tap(pg_temp.f('code1'), pg_temp.f('key1'), 'A1B2C3D4') ->> 'result' = 'device_rejected');
select pg_temp.chk_true('rotated key: old key refused, new key works',
  (select pg_temp.tap(pg_temp.f('code2'), pg_temp.f('key2'), 'A1B2C3D4') ->> 'result' = 'device_rejected'
      and pg_temp.tap(pg_temp.f('code2'), j ->> 'device_key', 'A1B2C3D4') ->> 'result' = 'synced'
   from (select public.rfid_rotate_device_key(pg_temp.f('code2')) as j) t));

-- 8. Remove card -------------------------------------------------------------------------
select pg_temp.chk_true('remove my card: retired for good',
  pg_temp.j('r-c1', 'public.customer_remove_my_card()') ->> 'status' = 'replaced');
select pg_temp.chk_true('removed card: profile shows no card',
  (select rfid_card_number is null from public.customer_profiles where firebase_uid = 'r-c1'));
select pg_temp.chk('removed card cannot be re-registered by staff', 'r-sa',
  $q$select public.staff_register_loyalty_card('A1B2C3D4', 'r-c2')$q$, 'error');

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% reader / POS points check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
