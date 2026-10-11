-- =============================================================================
-- Melai Nuts — RFID loyalty card registry (migration 20261011000000_loyalty_cards.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/loyalty_cards_test.sql
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
insert into public.branches (name, address, delivery_fee) values ('CARD-TEST A', 'a', 0), ('CARD-TEST B', 'b', 0);
-- Test fixture: an earn rate, so a sale earns points (a new database has none).
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point)
values ('default', 1, 50, 50)
  on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;
insert into fx select 'ba', id::text from public.branches where name = 'CARD-TEST A';
insert into fx select 'bb', id::text from public.branches where name = 'CARD-TEST B';
insert into public.product_categories (label) values ('CARD-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'CARD-TEST Nut', 100, 'pack' from public.product_categories where label = 'CARD-TEST Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'CARD-TEST Nut';
insert into fx select 'prod', id::text from public.products where name = 'CARD-TEST Nut';
insert into fx select 'var', id::text from public.product_variants where product_id = pg_temp.f('prod')::uuid;
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select pg_temp.f('ba')::uuid, pg_temp.f('prod')::uuid, pg_temp.f('var')::uuid, 0;

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('k-sa',  'Cashier A', 'k-sa@test.local',  'staff', pg_temp.f('ba')::uuid, 'active'),
       ('k-sb',  'Cashier B', 'k-sb@test.local',  'staff', pg_temp.f('bb')::uuid, 'active'),
       ('k-off', 'Inactive',  'k-off@test.local', 'staff', pg_temp.f('ba')::uuid, 'inactive'),
       ('k-own', 'Owner',     'k-own@test.local', 'owner', null, 'active');
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('k-c1', 'Card Customer One', 'k-c1@test.local', '09171110001'),
  ('k-c2', 'Card Customer Two', 'k-c2@test.local', '09171110002'),
  -- a legacy card number written straight into the profile before the registry
  ('k-c3', 'Legacy Card Holder', 'k-c3@test.local', '09171110003');
update public.customer_profiles set rfid_card_number = 'de:ad:be:ef' where firebase_uid = 'k-c3';

select pg_temp.call_as('k-own', format($q$select public.staff_receive_batch(%L::uuid, %L::uuid, 'CARD-A1', 50, current_date + 90)::text$q$,
  pg_temp.f('ba'), pg_temp.f('var')));
select set_config('app.inventory_managed', '', true);

-- 0. Normalisation -----------------------------------------------------------------
select pg_temp.chk_true('UID normalised: separators and case',
  public._normalize_card_uid(' 04:a1 b2-c3 ') = '04A1B2C3');
select pg_temp.chk_true('7-byte UID accepted', public._normalize_card_uid('04 11 22 33 44 55 66') = '04112233445566');
select pg_temp.chk_true('too short / non-hex rejected',
  public._normalize_card_uid('12AB') is null and public._normalize_card_uid('ZZZZZZZZ') is null
  and public._normalize_card_uid('juan@x.com') is null);
select pg_temp.chk_true('label is stable and derived from hash',
  public._card_label(public._card_uid_hash('04A1B2C3')) ~ '^GK-[0-9A-F]{4}-[0-9A-F]{4}$');

-- 1. Legacy migration ---------------------------------------------------------------
insert into fx select 'migrated', public._migrate_legacy_rfid_cards()::text;
select pg_temp.chk_true('legacy rfid_card_number moved into registry',
  pg_temp.f('migrated') = '1'
  and exists (select 1 from public.loyalty_cards where firebase_uid = 'k-c3' and status = 'active'
              and card_uid_hash = public._card_uid_hash('DEADBEEF')));
select pg_temp.chk_true('legacy profile now shows the label, not the raw UID',
  (select rfid_card_number from public.customer_profiles where firebase_uid = 'k-c3') ~ '^GK-');
select pg_temp.chk_true('migration is idempotent', public._migrate_legacy_rfid_cards() = 0);
select pg_temp.chk_true('legacy card still found by tap',
  pg_temp.j('k-sa', $q$public.staff_lookup_card('DEADBEEF')$q$) #>> '{customer,firebase_uid}' = 'k-c3');

-- 2. Access --------------------------------------------------------------------------
select pg_temp.chk('anon cannot look up a card', null, $q$select public.staff_lookup_card('04A1B2C3')$q$, 'error');
select pg_temp.chk('customer cannot look up a card', 'k-c1', $q$select public.staff_lookup_card('04A1B2C3')$q$, 'error');
select pg_temp.chk('inactive staff cannot look up a card', 'k-off', $q$select public.staff_lookup_card('04A1B2C3')$q$, 'error');
select pg_temp.chk('customer cannot register a card', 'k-c1',
  $q$select public.staff_register_loyalty_card('04A1B2C3', 'k-c1')$q$, 'error');
select pg_temp.chk('customer cannot read the table directly', 'k-c1', 'select count(*) from public.loyalty_cards', 'error');
select pg_temp.chk('staff cannot read the table directly', 'k-sa', 'select count(*) from public.loyalty_cards', 'error');
select pg_temp.chk('staff cannot list all cards', 'k-sa', 'select public.owner_list_loyalty_cards()', 'error');
select pg_temp.chk('owner can list all cards', 'k-own', 'select public.owner_list_loyalty_cards()', 'ok');

-- 3. Register ------------------------------------------------------------------------
select pg_temp.chk_true('unknown card -> unregistered',
  pg_temp.j('k-sa', $q$public.staff_lookup_card('04A1B2C3')$q$) ->> 'status' = 'unregistered');
select pg_temp.chk('garbage UID refused by lookup', 'k-sa', $q$select public.staff_lookup_card('hello')$q$, 'error');
select pg_temp.chk('register needs a real customer', 'k-sa',
  $q$select public.staff_register_loyalty_card('04A1B2C3', 'nobody')$q$, 'error');
select pg_temp.chk('register refuses walk-in', 'k-sa',
  $q$select public.staff_register_loyalty_card('04A1B2C3', 'walk-in')$q$, 'error');
insert into fx select 'card1', pg_temp.j('k-sa',
  $q$public.staff_register_loyalty_card('04:A1:B2:C3', 'k-c1', 'card-reg-0001')$q$) ->> 'id';
select pg_temp.chk_true('card registered, active, issued at cashier''s branch',
  (select status = 'active' and issued_branch_id = pg_temp.f('ba')::uuid and issued_by = 'k-sa'
   from public.loyalty_cards where id = pg_temp.f('card1')::uuid));
select pg_temp.chk_true('raw UID is not stored anywhere',
  not exists (select 1 from public.loyalty_cards where card_uid_hash ilike '%04A1B2C3%' or card_label ilike '%04A1B2C3%')
  and (select rfid_card_number from public.customer_profiles where firebase_uid = 'k-c1') ~ '^GK-');
select pg_temp.chk_true('replay with same key returns same card',
  pg_temp.j('k-sa', $q$public.staff_register_loyalty_card('04:A1:B2:C3', 'k-c1', 'card-reg-0001')$q$) ->> 'id' = pg_temp.f('card1'));
select pg_temp.chk_true('double tap without key is a no-op (same card back)',
  pg_temp.j('k-sb', $q$public.staff_register_loyalty_card('04a1b2c3', 'k-c1')$q$) ->> 'id' = pg_temp.f('card1')
  and (select count(*) = 1 from public.loyalty_cards where firebase_uid = 'k-c1'));
select pg_temp.chk('same card to another customer refused', 'k-sa',
  $q$select public.staff_register_loyalty_card('04A1B2C3', 'k-c2')$q$, 'error');
select pg_temp.chk('second card for same customer refused (use replace)', 'k-sa',
  $q$select public.staff_register_loyalty_card('04A1B2C4', 'k-c1')$q$, 'error');
select pg_temp.chk_true('customer notified on link',
  exists (select 1 from public.notifications where firebase_uid = 'k-c1' and title = 'Loyalty card linked'));
select pg_temp.chk_true('audit row written',
  exists (select 1 from public.staff_audit_logs where action = 'loyalty.card_register' and entity_id = pg_temp.f('card1')));

-- 4. Tap at POS ----------------------------------------------------------------------
select pg_temp.chk_true('tap finds customer with points (any branch)',
  (select j ->> 'status' = 'active' and j #>> '{customer,firebase_uid}' = 'k-c1'
   from (select pg_temp.j('k-sb', $q$public.staff_lookup_card('04 A1 B2 C3')$q$) as j) t));
select pg_temp.chk_true('POS lookup box accepts a tapped card',
  pg_temp.j('k-sa', $q$public.staff_lookup_customer('04A1B2C3')$q$) -> 0 ->> 'firebase_uid' = 'k-c1');
select pg_temp.chk_true('POS lookup box accepts the printed label',
  pg_temp.j('k-sa', format($q$public.staff_lookup_customer(%L)$q$,
    lower((select card_label from public.loyalty_cards where id = pg_temp.f('card1')::uuid)))) -> 0 ->> 'firebase_uid' = 'k-c1');
select pg_temp.chk_true('phone lookup still works',
  pg_temp.j('k-sa', $q$public.staff_lookup_customer('09171110002')$q$) -> 0 ->> 'firebase_uid' = 'k-c2');
select pg_temp.chk_true('partial phone does not browse customers',
  jsonb_array_length(pg_temp.j('k-sa', $q$public.staff_lookup_customer('0917111')$q$)) = 0);

-- Sale attached to the card holder earns points.
select pg_temp.call_as('k-sa', format(
  $q$select public.staff_create_pos_sale(%L::uuid, jsonb_build_array(jsonb_build_object('variant_id', %L, 'quantity', 2)),
       'cash', null, 1000, %L, 'card-sale-0001')::text$q$,
  pg_temp.f('ba'), pg_temp.f('var'),
  pg_temp.j('k-sa', $q$public.staff_lookup_card('04A1B2C3')$q$) #>> '{customer,firebase_uid}'));
select pg_temp.chk_true('sale via card earned points for that customer',
  (select coalesce(points_balance, 0) > 0 from public.loyalty_accounts where firebase_uid = 'k-c1'));
insert into fx select 'pts', points_balance::text from public.loyalty_accounts where firebase_uid = 'k-c1';

-- 5. Block ---------------------------------------------------------------------------
select pg_temp.chk('block needs a reason', 'k-sb',
  format($q$select public.staff_block_loyalty_card(%L::uuid, '')$q$, pg_temp.f('card1')), 'error');
select pg_temp.chk('customer cannot block', 'k-c1',
  format($q$select public.staff_block_loyalty_card(%L::uuid, 'lost card')$q$, pg_temp.f('card1')), 'error');
select pg_temp.chk('staff of another branch can block (customer reports lost card anywhere)', 'k-sb',
  format($q$select public.staff_block_loyalty_card(%L::uuid, 'reported lost')$q$, pg_temp.f('card1')), 'ok');
select pg_temp.chk('blocking twice is a no-op', 'k-sb',
  format($q$select public.staff_block_loyalty_card(%L::uuid, 'reported lost')$q$, pg_temp.f('card1')), 'ok');
select pg_temp.chk_true('blocked card tap returns blocked and no customer data',
  (select j ->> 'status' = 'blocked' and j -> 'customer' is null
   from (select pg_temp.j('k-sa', $q$public.staff_lookup_card('04A1B2C3')$q$) as j) t));
select pg_temp.chk('blocked card refused by POS lookup box', 'k-sa',
  $q$select public.staff_lookup_customer('04A1B2C3')$q$, 'error');
select pg_temp.chk_true('profile label cleared while blocked',
  (select rfid_card_number is null from public.customer_profiles where firebase_uid = 'k-c1'));
select pg_temp.chk_true('blocked label no longer finds the customer',
  jsonb_array_length(pg_temp.j('k-sa', format($q$public.staff_lookup_customer(%L)$q$,
    (select card_label from public.loyalty_cards where id = pg_temp.f('card1')::uuid)))) = 0);
select pg_temp.chk('blocked card cannot be registered again', 'k-sa',
  $q$select public.staff_register_loyalty_card('04A1B2C3', 'k-c1')$q$, 'error');
select pg_temp.chk_true('points untouched by block',
  (select points_balance::text = pg_temp.f('pts') from public.loyalty_accounts where firebase_uid = 'k-c1'));

-- 6. Unblock (owner) ----------------------------------------------------------------
select pg_temp.chk('staff cannot unblock', 'k-sa',
  format($q$select public.owner_unblock_loyalty_card(%L::uuid)$q$, pg_temp.f('card1')), 'error');
select pg_temp.chk('owner unblocks', 'k-own',
  format($q$select public.owner_unblock_loyalty_card(%L::uuid)$q$, pg_temp.f('card1')), 'ok');
select pg_temp.chk_true('unblocked card works again',
  pg_temp.j('k-sa', $q$public.staff_lookup_card('04A1B2C3')$q$) ->> 'status' = 'active'
  and (select rfid_card_number ~ '^GK-' from public.customer_profiles where firebase_uid = 'k-c1'));

-- 7. Replace -------------------------------------------------------------------------
select pg_temp.chk('replace needs a reason', 'k-sa',
  $q$select public.staff_replace_loyalty_card('k-c1', '04A1B2C9', '')$q$, 'error');
select pg_temp.chk('replace with the same card refused', 'k-sa',
  $q$select public.staff_replace_loyalty_card('k-c1', '04A1B2C3', 'damaged')$q$, 'error');
select pg_temp.chk('replace with another customer''s card refused', 'k-sa',
  $q$select public.staff_replace_loyalty_card('k-c1', 'DEADBEEF', 'damaged')$q$, 'error');
select pg_temp.chk('replace for a customer with no card refused', 'k-sa',
  $q$select public.staff_replace_loyalty_card('k-c2', '04A1B2C9', 'lost')$q$, 'error');
insert into fx select 'card2', pg_temp.j('k-sa',
  $q$public.staff_replace_loyalty_card('k-c1', '04A1B2C9', 'damaged', 'card-rep-0001')$q$) ->> 'id';
select pg_temp.chk_true('replay of replace returns same new card',
  pg_temp.j('k-sa', $q$public.staff_replace_loyalty_card('k-c1', '04A1B2C9', 'damaged', 'card-rep-0001')$q$) ->> 'id' = pg_temp.f('card2'));
select pg_temp.chk_true('old card replaced and linked to new',
  (select status = 'replaced' and replaced_by = pg_temp.f('card2')::uuid from public.loyalty_cards where id = pg_temp.f('card1')::uuid));
select pg_temp.chk_true('exactly one active card for the customer',
  (select count(*) = 1 from public.loyalty_cards where firebase_uid = 'k-c1' and status = 'active'));
select pg_temp.chk_true('old card tap -> replaced',
  pg_temp.j('k-sa', $q$public.staff_lookup_card('04A1B2C3')$q$) ->> 'status' = 'replaced');
select pg_temp.chk_true('new card tap -> same customer, same points',
  (select j #>> '{customer,firebase_uid}' = 'k-c1' and j #>> '{customer,points_balance}' = pg_temp.f('pts')
   from (select pg_temp.j('k-sb', $q$public.staff_lookup_card('04A1B2C9')$q$) as j) t));
select pg_temp.chk('replaced card cannot be unblocked', 'k-own',
  format($q$select public.owner_unblock_loyalty_card(%L::uuid)$q$, pg_temp.f('card1')), 'error');
select pg_temp.chk('replaced card cannot be blocked', 'k-sa',
  format($q$select public.staff_block_loyalty_card(%L::uuid, 'test')$q$, pg_temp.f('card1')), 'error');

-- Lost card: block first, then replace the blocked card.
insert into fx select 'card3', pg_temp.j('k-sa', $q$public.staff_register_loyalty_card('A0B0C0D0', 'k-c2')$q$) ->> 'id';
select pg_temp.call_as('k-sa', format($q$select public.staff_block_loyalty_card(%L::uuid, 'lost')::text$q$, pg_temp.f('card3')));
select pg_temp.chk('a blocked card can be replaced', 'k-sb',
  $q$select public.staff_replace_loyalty_card('k-c2', 'A0B0C0D1', 'lost')$q$, 'ok');
select pg_temp.chk('the found card cannot be unblocked once replaced', 'k-own',
  format($q$select public.owner_unblock_loyalty_card(%L::uuid)$q$, pg_temp.f('card3')), 'error');

-- 8. History + reads ------------------------------------------------------------------
select pg_temp.chk_true('history: registered, blocked, unblocked, replaced in order',
  (select array_agg(event order by created_at, id) = array['registered','blocked','unblocked','replaced']
   from public.loyalty_card_events where card_id = pg_temp.f('card1')::uuid));
select pg_temp.chk('history cannot be edited (even as admin)', 'k-own',
  'update public.loyalty_card_events set note = ''x''', 'error');
do $$ begin
  begin
    delete from public.loyalty_card_events;
    insert into results(name, passed, detail) values ('history cannot be deleted by superuser', false, 'delete succeeded');
  exception when others then
    insert into results(name, passed, detail) values ('history cannot be deleted by superuser', true, sqlerrm);
  end;
end $$;
select pg_temp.chk_true('staff_customer_cards returns both cards with events',
  (select jsonb_array_length(j) = 2
          and (select jsonb_array_length(e -> 'events') from jsonb_array_elements(j) e where e ->> 'id' = pg_temp.f('card1')) = 4
   from (select pg_temp.j('k-sb', $q$public.staff_customer_cards('k-c1')$q$) as j) t));
select pg_temp.chk_true('owner list counts',
  (select (j #>> '{counts,active}')::int >= 3 and (j #>> '{counts,replaced}')::int >= 2
   from (select pg_temp.j('k-own', $q$public.owner_list_loyalty_cards()$q$) as j) t));
select pg_temp.chk_true('owner list search by name',
  (select jsonb_array_length(j -> 'cards') = 2
   from (select pg_temp.j('k-own', $q$public.owner_list_loyalty_cards('card customer one')$q$) as j) t));
select pg_temp.chk_true('customer sees own active card label',
  (select j ->> 'status' = 'active' and j ->> 'label' = (select card_label from public.loyalty_cards where id = pg_temp.f('card2')::uuid)
   from (select pg_temp.j('k-c1', 'public.get_my_loyalty_card()') as j) t));
select pg_temp.chk_true('customer without card gets null',
  pg_temp.call_as('k-own', 'select public.get_my_loyalty_card()::text') is null);
select pg_temp.chk('anon cannot read get_my_loyalty_card', null, 'select public.get_my_loyalty_card()', 'error');

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% loyalty card check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
