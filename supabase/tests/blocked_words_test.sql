-- =============================================================================
-- Melai Nuts — no offensive words in reviews / special instructions, and the admin reviews page
-- (migrations 20261119030000_blocked_words.sql, 20261119040000_admin_product_reviews.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/blocked_words_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
-- The text cases are moderation/test_cases.json (the same cases as the PHP, JS and Dart copies).
-- =============================================================================
begin;

set local timezone = 'Asia/Manila';

create temp table results (id serial primary key, name text not null, passed boolean not null, detail text);
create temp table fx (k text primary key, v text);
grant select on fx to public;

create function pg_temp.act_as(p_uid text) returns void language plpgsql as $$
begin
  if p_uid is null then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    execute 'set local role anon';
  else
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', p_uid, 'role', 'authenticated', 'email', p_uid || '@test.local', 'email_verified', true)::text, true);
    execute 'set local role authenticated';
  end if;
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
create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;
create function pg_temp.f(p_k text) returns text language sql as $$ select v from fx where k = p_k $$;
grant execute on function pg_temp.f(text) to public;

-- Fixtures --------------------------------------------------------------------------------
insert into public.branches (name, address, latitude, longitude, delivery_fee) values ('BW-TEST Shop', 'a', 14.2117, 121.1653, 50);
insert into fx select 'shop', id::text from public.branches where name = 'BW-TEST Shop';
insert into public.product_categories (label) values ('BW-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, n, 100, 'pack' from public.product_categories, (values ('BW-TEST Cashew'), ('BW-TEST Peanut')) v(n)
where label = 'BW-TEST Cat';
insert into fx select 'p1', id::text from public.products where name = 'BW-TEST Cashew';
insert into fx select 'p2', id::text from public.products where name = 'BW-TEST Peanut';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name like 'BW-TEST %';
insert into fx select 'v1', id::text from public.product_variants where product_id = pg_temp.f('p1')::uuid;
insert into fx select 'v2', id::text from public.product_variants where product_id = pg_temp.f('p2')::uuid;

insert into public.customer_profiles (firebase_uid, full_name, email, phone, first_name, last_name) values
  ('bw-ana', 'Ana Maria Dela Cruz', 'bw-ana@test.local', '09170000201', 'Ana Maria', 'Dela Cruz');
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('bw-ben', 'Ben D. Santos', 'bw-ben@test.local', '09170000202'),
  ('bw-cy', 'Cy', 'bw-cy@test.local', '09170000203');
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('bw-staff', 'Staff', 'bw-staff@test.local', 'staff', pg_temp.f('shop')::uuid, 'active');

-- Ana: a COMPLETED order with the cashew. Ben: a PENDING order with the cashew. Cy: nothing.
create function pg_temp.order_for(p_uid text, p_prod text, p_var text, p_complete boolean) returns text language plpgsql as $$
declare v_id text;
begin
  insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method)
  values (p_uid, pg_temp.f('shop')::uuid, 'BW-TEST Shop', false, 'pending', 100, 0, 0, 100, 'cash') returning id into v_id;
  insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
  values (v_id, pg_temp.f(p_prod)::uuid, pg_temp.f(p_var)::uuid, 'BW-TEST', 'Regular', 1, 100);
  insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number)
  values (v_id, p_uid, 'cash', 'pending', 100, v_id);
  if p_complete then perform pg_temp.complete(v_id); end if;
  return v_id;
end $$;
create function pg_temp.complete(v_id text) returns void language plpgsql as $$
begin
  update public.payments set status = 'success' where order_id = v_id;
  begin
    update public.orders set status = 'confirmed' where id = v_id;
    update public.orders set status = 'preparing' where id = v_id;
    update public.orders set status = 'readyForPickup' where id = v_id;
    update public.orders set status = 'completed' where id = v_id;
  end;
end $$;
insert into fx values ('o_ana', pg_temp.order_for('bw-ana', 'p1', 'v1', true));
insert into fx values ('o_ben', pg_temp.order_for('bw-ben', 'p1', 'v1', false));


insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('bw-owner', 'Owner', 'bw-owner@test.local', 'owner', pg_temp.f('shop')::uuid, 'active');

-- 1. The shared test cases ---------------------------------------------------------------------
create temp table bw_blocked (t text);
create temp table bw_allowed (t text);
insert into bw_blocked values
  ('fuck'),
  ('FUCK this'),
  ('Fuuuuuck'),
  ('f u c k'),
  ('f.u.c.k'),
  ('f-u-c-k you'),
  ('f*u*c*k'),
  ('fvck'),
  ('motherfucker'),
  ('fucking slow delivery'),
  ('this is shit'),
  ('sh1t'),
  ('$hit'),
  ('5h1t'),
  ('S H I T'),
  ('shiiiit'),
  ('bullsh1t'),
  ('you are an ass'),
  ('a$$'),
  ('@ss'),
  ('a55hole'),
  ('asshole'),
  ('dumb ass'),
  ('bitch'),
  ('b1tch'),
  ('biiitch'),
  ('son of a bitch'),
  ('what the wtf'),
  ('stfu'),
  ('dick'),
  ('d1ck'),
  ('cunt'),
  ('putangina'),
  ('putang ina mo'),
  ('PUTANG INA'),
  ('put@ng ina'),
  ('tangina'),
  ('tang1na'),
  ('tang ina'),
  ('t a n g i n a'),
  ('gago'),
  ('gagoooo'),
  ('g@go'),
  ('gago!'),
  ('ulol'),
  ('ul0l'),
  ('bobo ka'),
  ('b0b0'),
  ('tanga'),
  ('tarantado'),
  ('punyeta'),
  ('puñeta'),
  ('pakyu'),
  ('kupal'),
  ('leche ka gago'),
  ('anak ng puta'),
  ('puta'),
  ('p u t a'),
  ('kingina mo'),
  ('hinayupak'),
  ('olol');
insert into bw_allowed values
  ('Great nuts, will order again!'),
  ('Please pack as pasalubong for my mom.'),
  ('Pickup at 3pm please'),
  ('Order #455 please add 5 packs'),
  ('4 5 5'),
  ('I will assess the taste later'),
  ('First class packaging'),
  ('Bass guitar'),
  ('Pass the cashews'),
  ('Dickens would love these'),
  ('The cocktail mix is great'),
  ('Shiitake chips next time?'),
  ('Delivered to Batangas'),
  ('Computation of the total was wrong'),
  ('Great reputation'),
  ('Pistachio is my favorite'),
  ('Scunthorpe'),
  ('spice level'),
  ('ang sarap!'),
  ('Salamat po'),
  ('leche flan flavor please'),
  ('Ina, please call me'),
  ('The hoe-down party'),
  ('Its a must try'),
  ('I am happy'),
  ('a b c'),
  ('assessment'),
  ('tangan ko na'),
  ('massage chair'),
  ('shut up and take my money'),
  (''),
  ('   '),
  ('Dear Ma''am, pa-wrap po as gift. Thanks!'),
  ('Inamoy ko, ang bango'),
  ('classic garlic'),
  ('Bob''s order'),
  ('has'),
  ('as is');
select pg_temp.chk_true('every blocked case is caught',
  not exists (select 1 from bw_blocked where not public.contains_blocked_words(t)),
  (select string_agg(t, ' | ') from bw_blocked where not public.contains_blocked_words(t)));
select pg_temp.chk_true('innocent text is never blocked',
  not exists (select 1 from bw_allowed where public.contains_blocked_words(t)),
  (select string_agg(t, ' | ') from bw_allowed where public.contains_blocked_words(t)));
select pg_temp.chk_true('null and empty are fine', not public.contains_blocked_words(null) and not public.contains_blocked_words(''));
select pg_temp.chk_true('the message', public.blocked_words_message() = 'Please keep your message respectful.');
select pg_temp.chk('customers cannot read or change the list', 'bw-ana', 'select count(*) from public.moderation_blocked_terms', 'error');
select pg_temp.chk('customers cannot add to the list', 'bw-ana',
  $q$insert into public.moderation_blocked_terms (kind, term) values ('allow', 'gago')$q$, 'error');
select pg_temp.chk('anyone may ask the yes / no check', null, $q$select public.contains_blocked_words('hello')$q$, 'ok');

-- 2. Reviews: the database refuses, whatever client sends it ----------------------------------------
select pg_temp.chk('a review with a curse word is refused', 'bw-ana',
  format($q$insert into public.product_reviews (product_id, customer_id, rating, comment) values (%L, 'bw-ana', 1, 'ang p@ngit, g a g o')$q$, pg_temp.f('p1')),
  'error', 'Please keep your message respectful.');
select pg_temp.chk_true('...nothing saved', not exists (select 1 from public.product_reviews where customer_id = 'bw-ana'));
select pg_temp.chk('a respectful review is saved', 'bw-ana',
  format($q$insert into public.product_reviews (product_id, customer_id, rating, comment) values (%L, 'bw-ana', 4, 'Masarap, will order again')$q$, pg_temp.f('p1')), 'ok');
insert into fx select 'r_ana', id::text from public.product_reviews where customer_id = 'bw-ana';
select pg_temp.chk('editing it into a curse word is refused', 'bw-ana',
  format($q$update public.product_reviews set comment = 'TANGINA' where id = %L$q$, pg_temp.f('r_ana')), 'error', 'Please keep your message respectful.');
select pg_temp.chk_true('...the old comment stays',
  (select comment = 'Masarap, will order again' from public.product_reviews where id = pg_temp.f('r_ana')::uuid));
-- An old review written before this check: changing only the rating (or a staff hide) still works.
set local session_replication_role = replica;   -- writes as if before the migration (no triggers)
update public.product_reviews set comment = 'old shit' where id = pg_temp.f('r_ana')::uuid;
set local session_replication_role = origin;
select pg_temp.chk('an old comment: changing only the rating works', 'bw-ana',
  format($q$update public.product_reviews set rating = 2 where id = %L$q$, pg_temp.f('r_ana')), 'ok');
select pg_temp.chk('staff can still hide it', 'bw-staff',
  format($q$select public.staff_moderate_product_review(%L, 'hide')$q$, pg_temp.f('r_ana')), 'ok');

-- 3. Special instructions on orders -----------------------------------------------------------------
do $$
begin
  begin
    insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method, customer_notes)
    values ('bw-ben', (select v::uuid from fx where k = 'shop'), 'BW-TEST Shop', false, 'pending', 100, 0, 0, 100, 'cash', 'bilisan nyo put@ng ina');
    insert into results(name, passed, detail) values ('an order with a curse word in the notes is refused (insert)', false, 'was saved');
  exception when others then
    insert into results(name, passed, detail) values ('an order with a curse word in the notes is refused (insert)',
      sqlerrm = 'Please keep your message respectful.', sqlerrm);
  end;
end $$;
with o as (insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method, customer_notes)
    values ('bw-ben', pg_temp.f('shop')::uuid, 'BW-TEST Shop', false, 'pending', 100, 0, 0, 100, 'cash', 'Pasalubong packing please') returning id)
insert into fx select 'o_notes', id from o;
select pg_temp.chk_true('respectful notes are saved', (select customer_notes = 'Pasalubong packing please' from public.orders where id = pg_temp.f('o_notes')));
do $$
begin
  begin
    update public.orders set customer_notes = 'f u c k' where id = (select v from fx where k = 'o_notes');
    insert into results(name, passed, detail) values ('changing the notes to a curse word is refused (update)', false, 'was saved');
  exception when others then
    insert into results(name, passed, detail) values ('changing the notes to a curse word is refused (update)',
      sqlerrm = 'Please keep your message respectful.', sqlerrm);
  end;
end $$;
-- An order saved before this check: a status change never re-checks its notes.
set local session_replication_role = replica;   -- writes as if before the migration (no triggers)
update public.orders set customer_notes = 'old gago note' where id = pg_temp.f('o_notes');
set local session_replication_role = origin;
update public.orders set status = 'cancelled' where id = pg_temp.f('o_notes');
select pg_temp.chk_true('an old order: a status change does not re-check the notes',
  (select status = 'cancelled' from public.orders where id = pg_temp.f('o_notes')));

-- 4. The admin reviews page --------------------------------------------------------------------------
select pg_temp.chk('a customer cannot list every review', 'bw-ana', 'select public.admin_list_product_reviews()', 'error');
select pg_temp.chk('a guest cannot list every review', null, 'select public.admin_list_product_reviews()', 'error');
select pg_temp.chk_true('the owner sees every review, hidden ones included, with the customer''s full name', (
  select (j ->> 'total')::int = 1
     and j -> 'rows' -> 0 ->> 'customer_name' = 'Ana Maria Dela Cruz'
     and j -> 'rows' -> 0 ->> 'product_name' = 'BW-TEST Cashew'
     and (j -> 'rows' -> 0 ->> 'is_hidden')::boolean
     and (j -> 'rows' -> 0 ->> 'rating')::int = 2
     and j -> 'rows' -> 0 ? 'created_at'
     and (j -> 'summary' ->> 'hidden')::int = 1
     and jsonb_array_length(j -> 'products') = 1
  from (select pg_temp.call_as('bw-owner', 'select public.admin_list_product_reviews()::text')::jsonb j) t));
select pg_temp.chk_true('filter: visible only (none)', (
  select (pg_temp.call_as('bw-owner', $q$select public.admin_list_product_reviews(null, null, 'visible')::text$q$)::jsonb ->> 'total')::int = 0));
select pg_temp.chk_true('filter: another product (none)', (
  select (pg_temp.call_as('bw-owner', format($q$select public.admin_list_product_reviews(null, %L)::text$q$, pg_temp.f('p2')))::jsonb ->> 'total')::int = 0));
select pg_temp.chk_true('search by customer name', (
  select (pg_temp.call_as('bw-owner', $q$select public.admin_list_product_reviews('dela cruz')::text$q$)::jsonb ->> 'total')::int = 1));
select pg_temp.chk_true('search by product name', (
  select (pg_temp.call_as('bw-owner', $q$select public.admin_list_product_reviews('cashew')::text$q$)::jsonb ->> 'total')::int = 1));
select pg_temp.chk_true('search wildcards are plain text', (
  select (pg_temp.call_as('bw-owner', $q$select public.admin_list_product_reviews('%')::text$q$)::jsonb ->> 'total')::int = 0));
-- A second review (Ben, completed order now) to check the sort.
insert into fx values ('o_ben2', pg_temp.order_for('bw-ben', 'p2', 'v2', true));
select pg_temp.chk('Ben reviews the peanut', 'bw-ben',
  format($q$insert into public.product_reviews (product_id, customer_id, rating, comment) values (%L, 'bw-ben', 5, 'Crunchy')$q$, pg_temp.f('p2')), 'ok');
set local session_replication_role = replica;   -- the trigger keeps created_at fixed
update public.product_reviews set created_at = now() - interval '2 days' where customer_id = 'bw-ana';
set local session_replication_role = origin;
select pg_temp.chk_true('newest first', (
  select j -> 'rows' -> 0 ->> 'comment' = 'Crunchy'
  from (select pg_temp.call_as('bw-owner', 'select public.admin_list_product_reviews()::text')::jsonb j) t));
select pg_temp.chk_true('oldest first', (
  select j -> 'rows' -> 0 ->> 'customer_name' = 'Ana Maria Dela Cruz'
  from (select pg_temp.call_as('bw-owner', $q$select public.admin_list_product_reviews(null, null, 'all', 'oldest')::text$q$)::jsonb j) t));
select pg_temp.chk_true('lowest rating first', (
  select (j -> 'rows' -> 0 ->> 'rating')::int = 2
  from (select pg_temp.call_as('bw-owner', $q$select public.admin_list_product_reviews(null, null, 'all', 'rating_low')::text$q$)::jsonb j) t));
select pg_temp.chk_true('limit and offset', (
  select jsonb_array_length(j -> 'rows') = 1 and (j ->> 'total')::int = 2
  from (select pg_temp.call_as('bw-owner', $q$select public.admin_list_product_reviews(null, null, 'all', 'newest', 1, 1)::text$q$)::jsonb j) t));
select pg_temp.chk('the owner deletes a review', 'bw-owner',
  format($q$select public.staff_moderate_product_review(%L, 'delete')$q$, pg_temp.f('r_ana')), 'ok');
select pg_temp.chk_true('...gone from the list, and logged', (
  select (pg_temp.call_as('bw-owner', 'select public.admin_list_product_reviews()::text')::jsonb ->> 'total')::int = 1)
  and exists (select 1 from public.staff_audit_logs where action = 'review.delete' and entity_id = pg_temp.f('r_ana')));

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% blocked words / admin review check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
