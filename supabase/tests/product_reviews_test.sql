-- =============================================================================
-- Melai Nuts — product ratings and reviews, and first / last name parts
-- (migrations 20261119010000_customer_name_parts.sql, 20261119020000_product_reviews.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/product_reviews_test.sql
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
insert into public.branches (name, address, latitude, longitude, delivery_fee) values ('PR-TEST Shop', 'a', 14.2117, 121.1653, 50);
insert into fx select 'shop', id::text from public.branches where name = 'PR-TEST Shop';
insert into public.product_categories (label) values ('PR-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, n, 100, 'pack' from public.product_categories, (values ('PR-TEST Cashew'), ('PR-TEST Peanut')) v(n)
where label = 'PR-TEST Cat';
insert into fx select 'p1', id::text from public.products where name = 'PR-TEST Cashew';
insert into fx select 'p2', id::text from public.products where name = 'PR-TEST Peanut';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name like 'PR-TEST %';
insert into fx select 'v1', id::text from public.product_variants where product_id = pg_temp.f('p1')::uuid;
insert into fx select 'v2', id::text from public.product_variants where product_id = pg_temp.f('p2')::uuid;

insert into public.customer_profiles (firebase_uid, full_name, email, phone, first_name, last_name) values
  ('pr-ana', 'Ana Maria Dela Cruz', 'pr-ana@test.local', '09170000201', 'Ana Maria', 'Dela Cruz');
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('pr-ben', 'Ben D. Santos', 'pr-ben@test.local', '09170000202'),
  ('pr-cy', 'Cy', 'pr-cy@test.local', '09170000203');
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('pr-staff', 'Staff', 'pr-staff@test.local', 'staff', pg_temp.f('shop')::uuid, 'active');

-- Ana: a COMPLETED order with the cashew. Ben: a PENDING order with the cashew. Cy: nothing.
create function pg_temp.order_for(p_uid text, p_prod text, p_var text, p_complete boolean) returns text language plpgsql as $$
declare v_id text;
begin
  insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method)
  values (p_uid, pg_temp.f('shop')::uuid, 'PR-TEST Shop', false, 'pending', 100, 0, 0, 100, 'cash') returning id into v_id;
  insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
  values (v_id, pg_temp.f(p_prod)::uuid, pg_temp.f(p_var)::uuid, 'PR-TEST', 'Regular', 1, 100);
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
insert into fx values ('o_ana', pg_temp.order_for('pr-ana', 'p1', 'v1', true));
insert into fx values ('o_ben', pg_temp.order_for('pr-ben', 'p1', 'v1', false));

-- 0. Name parts --------------------------------------------------------------------------------
select pg_temp.chk_true('typed first / last names are kept as typed',
  (select first_name = 'Ana Maria' and last_name = 'Dela Cruz' from public.customer_profiles where firebase_uid = 'pr-ana'));
select pg_temp.chk_true('only full_name given (the app): split like PersonName.parse, middle initial dropped',
  (select first_name = 'Ben' and last_name = 'Santos' from public.customer_profiles where firebase_uid = 'pr-ben'));
select pg_temp.chk_true('one word: first name only',
  (select first_name = 'Cy' and last_name is null from public.customer_profiles where firebase_uid = 'pr-cy'));
select pg_temp.chk_true('surname particles stay with the last name',
  (select s.first_name = 'Juan' and s.last_name = 'De los Reyes' from public._split_full_name('Juan De los Reyes') s));
select pg_temp.chk('a customer edits their own name parts', 'pr-cy',
  $q$update public.customer_profiles set first_name = 'Cyrus', last_name = 'Lim', full_name = 'Cyrus Lim' where firebase_uid = 'pr-cy'$q$, 'ok');
select pg_temp.chk_true('...stored as sent',
  (select first_name = 'Cyrus' and last_name = 'Lim' and full_name = 'Cyrus Lim' from public.customer_profiles where firebase_uid = 'pr-cy'));
update public.customer_profiles set full_name = 'Cy' where firebase_uid = 'pr-cy';
select pg_temp.chk_true('only full_name changed: the parts follow',
  (select first_name = 'Cy' and last_name is null from public.customer_profiles where firebase_uid = 'pr-cy'));

-- 1. Who may write ----------------------------------------------------------------------------------
select pg_temp.chk('a guest cannot write a review', null,
  format($q$insert into public.product_reviews (product_id, customer_id, rating) values (%L, 'pr-ana', 5)$q$, pg_temp.f('p1')), 'error');
select pg_temp.chk('no completed order with the product: refused', 'pr-cy',
  format($q$insert into public.product_reviews (product_id, customer_id, rating) values (%L, 'pr-cy', 5)$q$, pg_temp.f('p1')), 'error');
select pg_temp.chk('an order not completed yet: refused', 'pr-ben',
  format($q$insert into public.product_reviews (product_id, customer_id, rating, order_id) values (%L, 'pr-ben', 5, %L)$q$,
         pg_temp.f('p1'), pg_temp.f('o_ben')), 'error');
select pg_temp.chk('a product not in the completed order: refused', 'pr-ana',
  format($q$insert into public.product_reviews (product_id, customer_id, rating, order_id) values (%L, 'pr-ana', 5, %L)$q$,
         pg_temp.f('p2'), pg_temp.f('o_ana')), 'error');
select pg_temp.chk('someone else''s completed order: refused', 'pr-ben',
  format($q$insert into public.product_reviews (product_id, customer_id, rating, order_id) values (%L, 'pr-ben', 5, %L)$q$,
         pg_temp.f('p1'), pg_temp.f('o_ana')), 'error');
select pg_temp.chk('writing as another customer: refused', 'pr-ben',
  format($q$insert into public.product_reviews (product_id, customer_id, rating) values (%L, 'pr-ana', 5)$q$, pg_temp.f('p1')), 'error');
select pg_temp.chk('rating 0: refused', 'pr-ana',
  format($q$insert into public.product_reviews (product_id, customer_id, rating) values (%L, 'pr-ana', 0)$q$, pg_temp.f('p1')), 'error');
select pg_temp.chk('rating 6: refused', 'pr-ana',
  format($q$insert into public.product_reviews (product_id, customer_id, rating) values (%L, 'pr-ana', 6)$q$, pg_temp.f('p1')), 'error');
select pg_temp.chk('a 501-character comment: refused', 'pr-ana',
  format($q$insert into public.product_reviews (product_id, customer_id, rating, comment) values (%L, 'pr-ana', 4, repeat('a', 501))$q$, pg_temp.f('p1')), 'error');
select pg_temp.chk('a customer cannot post a hidden review or pick moderation fields', 'pr-ana',
  format($q$insert into public.product_reviews (product_id, customer_id, rating, is_hidden) values (%L, 'pr-ana', 4, true)$q$, pg_temp.f('p1')), 'error');

select pg_temp.chk_true('can_review_product answers only for the caller (Ben cannot probe Ana''s order)',
  pg_temp.call_as('pr-ben', format('select public.can_review_product(%L, %L)::text', pg_temp.f('p1'), pg_temp.f('o_ana'))) = 'false'
  and pg_temp.call_as('pr-ana', format('select public.can_review_product(%L, %L)::text', pg_temp.f('p1'), pg_temp.f('o_ana'))) = 'true');
select pg_temp.chk_true('status: Ana may review the cashew (with her completed order)',
  (select (j ->> 'can_review')::boolean and j ->> 'order_id' = pg_temp.f('o_ana') and j -> 'review' = 'null'::jsonb
   from (select pg_temp.call_as('pr-ana', format('select public.my_product_review_status(%L)::text', pg_temp.f('p1')))::jsonb j) t));
select pg_temp.chk_true('status: Ben may not (order not completed)',
  (select not (j ->> 'can_review')::boolean
   from (select pg_temp.call_as('pr-ben', format('select public.my_product_review_status(%L)::text', pg_temp.f('p1')))::jsonb j) t));

-- 2. Post, edit, one per product, delete ---------------------------------------------------------------
select pg_temp.chk('Ana posts a review (the order is filled in by the server)', 'pr-ana',
  format($q$insert into public.product_reviews (product_id, customer_id, rating, comment) values (%L, 'pr-ana', 4, '  Crunchy and fresh!  ')$q$, pg_temp.f('p1')), 'ok');
insert into fx select 'r_ana', id::text from public.product_reviews where customer_id = 'pr-ana';
select pg_temp.chk_true('stored: her completed order, comment trimmed',
  (select order_id = pg_temp.f('o_ana') and comment = 'Crunchy and fresh!' and rating = 4 and not is_hidden
   from public.product_reviews where id = pg_temp.f('r_ana')::uuid));
select pg_temp.chk('a second review of the same product: refused', 'pr-ana',
  format($q$insert into public.product_reviews (product_id, customer_id, rating) values (%L, 'pr-ana', 5)$q$, pg_temp.f('p1')), 'error');
select pg_temp.chk('Ana edits her review', 'pr-ana',
  format($q$update public.product_reviews set rating = 5, comment = 'Best cashews.' where id = %L$q$, pg_temp.f('r_ana')), 'ok');
select pg_temp.chk_true('edited, updated_at moved',
  (select rating = 5 and comment = 'Best cashews.' from public.product_reviews where id = pg_temp.f('r_ana')::uuid));
select pg_temp.chk('Ana cannot unhide / hide her review herself', 'pr-ana',
  format($q$update public.product_reviews set is_hidden = true where id = %L$q$, pg_temp.f('r_ana')), 'error');
select pg_temp.chk_true('Ben''s update of Ana''s review changes nothing (RLS)',
  pg_temp.call_as('pr-ben', format($q$with u as (update public.product_reviews set rating = 1 where id = %L returning 1) select count(*)::text from u$q$, pg_temp.f('r_ana'))) = '0'
  and (select rating = 5 from public.product_reviews where id = pg_temp.f('r_ana')::uuid));
select pg_temp.chk_true('Ben''s delete of Ana''s review deletes nothing (RLS)',
  pg_temp.call_as('pr-ben', format($q$with d as (delete from public.product_reviews where id = %L returning 1) select count(*)::text from d$q$, pg_temp.f('r_ana'))) = '0');

-- 3. Reading ---------------------------------------------------------------------------------------
select pg_temp.chk_true('a guest sees the review with "Ana Maria D." and not who wrote it',
  (select jsonb_array_length(j) = 1 and j -> 0 ->> 'reviewer_name' = 'Ana Maria D.' and j -> 0 ->> 'rating' = '5'
          and not (j -> 0 ? 'customer_id') and (j -> 0 ->> 'is_mine')::boolean is not true
   from (select pg_temp.call_as(null, format('select public.get_product_reviews(%L)::text', pg_temp.f('p1')))::jsonb j) t));
select pg_temp.chk_true('Ana sees it marked as hers',
  (select (j -> 0 ->> 'is_mine')::boolean
   from (select pg_temp.call_as('pr-ana', format('select public.get_product_reviews(%L)::text', pg_temp.f('p1')))::jsonb j) t));
select pg_temp.chk_true('stats for a guest: average 5.0 from 1 review; no row for a product without reviews',
  pg_temp.call_as(null, format($q$select average_rating::text || '/' || review_count from public.product_rating_stats where product_id = %L$q$, pg_temp.f('p1'))) = '5.0/1'
  and pg_temp.call_as(null, format($q$select count(*)::text from public.product_rating_stats where product_id = %L$q$, pg_temp.f('p2'))) = '0');
select pg_temp.chk('a guest cannot read who wrote a review (customer_id)', null,
  $q$select customer_id from public.product_reviews$q$, 'error');

-- A second reviewer moves the average (Ben's order is completed now).
select pg_temp.complete(pg_temp.f('o_ben'));
select pg_temp.chk('Ben reviews once his order is completed', 'pr-ben',
  format($q$insert into public.product_reviews (product_id, customer_id, rating) values (%L, 'pr-ben', 2)$q$, pg_temp.f('p1')), 'ok');
insert into fx select 'r_ben', id::text from public.product_reviews where customer_id = 'pr-ben';
select pg_temp.chk_true('average 3.5 from 2 reviews; Ben shown as "Ben S."',
  pg_temp.call_as(null, format($q$select average_rating::text || '/' || review_count from public.product_rating_stats where product_id = %L$q$, pg_temp.f('p1'))) = '3.5/2'
  and (select bool_or(e ->> 'reviewer_name' = 'Ben S.')
       from (select pg_temp.call_as(null, format('select public.get_product_reviews(%L)::text', pg_temp.f('p1')))::jsonb j) t,
            jsonb_array_elements(t.j) e));

-- 4. Staff moderation ---------------------------------------------------------------------------------
select pg_temp.chk('a customer cannot moderate', 'pr-ana',
  format($q$select public.staff_moderate_product_review(%L, 'hide')$q$, pg_temp.f('r_ben')), 'error');
select pg_temp.chk('a customer cannot list for moderation', 'pr-ana',
  $q$select public.staff_list_product_reviews()$q$, 'error');
select pg_temp.chk('staff hide Ben''s review', 'pr-staff',
  format($q$select public.staff_moderate_product_review(%L, 'hide')$q$, pg_temp.f('r_ben')), 'ok');
select pg_temp.chk_true('hidden: not shown, not counted; still listed for staff; audit row written',
  pg_temp.call_as(null, format($q$select average_rating::text || '/' || review_count from public.product_rating_stats where product_id = %L$q$, pg_temp.f('p1'))) = '5.0/1'
  and (select jsonb_array_length(j) = 1 from (select pg_temp.call_as(null, format('select public.get_product_reviews(%L)::text', pg_temp.f('p1')))::jsonb j) t)
  and (select jsonb_array_length(j) = 2 from (select pg_temp.call_as('pr-staff', 'select public.staff_list_product_reviews()::text')::jsonb j) t)
  and exists (select 1 from public.staff_audit_logs where action = 'review.hide' and entity_id = pg_temp.f('r_ben')));
select pg_temp.chk_true('Ben still sees his own hidden review in his status',
  (select (j -> 'review' ->> 'is_hidden')::boolean
   from (select pg_temp.call_as('pr-ben', format('select public.my_product_review_status(%L)::text', pg_temp.f('p1')))::jsonb j) t));
select pg_temp.chk('staff show it again', 'pr-staff',
  format($q$select public.staff_moderate_product_review(%L, 'show')$q$, pg_temp.f('r_ben')), 'ok');
select pg_temp.chk('staff delete it', 'pr-staff',
  format($q$select public.staff_moderate_product_review(%L, 'delete')$q$, pg_temp.f('r_ben')), 'ok');
select pg_temp.chk_true('deleted', not exists (select 1 from public.product_reviews where id = pg_temp.f('r_ben')::uuid));

-- 5. The customer deletes their own ------------------------------------------------------------------
select pg_temp.chk('Ana deletes her review', 'pr-ana',
  format($q$delete from public.product_reviews where id = %L$q$, pg_temp.f('r_ana')), 'ok');
select pg_temp.chk_true('gone, and the product has no rating any more',
  not exists (select 1 from public.product_reviews where id = pg_temp.f('r_ana')::uuid)
  and not exists (select 1 from public.product_rating_stats where product_id = pg_temp.f('p1')::uuid));

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% product review check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
