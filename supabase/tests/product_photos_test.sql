-- =============================================================================
-- Melai Nuts — product photo management (migration 20261117000000)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/product_photos_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
-- =============================================================================
begin;

create temp table results (id serial primary key, name text not null, passed boolean not null, detail text);
grant all on results to public;
grant all on sequence results_id_seq to public;
create temp table fx (k text primary key, v text);
grant all on fx to public;

create function pg_temp.act_as(p_uid text) returns void language plpgsql as $$
begin
  if p_uid is null then
    perform set_config('request.jwt.claims', jsonb_build_object('role', 'anon')::text, true);
    execute 'set local role anon';
  else
    perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
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
create function pg_temp.upload(p_name text) returns text language sql as $$
  select format($q$insert into storage.objects (bucket_id, name, owner_id, metadata) values ('product-images', %L, 'x', '{}'::jsonb)$q$, p_name)
$$;
create function pg_temp.url(p_product text, p_file text) returns text language sql as $$
  select 'https://demo.supabase.co/storage/v1/object/public/product-images/' || (select v from fx where k = p_product) || '/' || p_file
$$;
create function pg_temp.images(p_product text) returns text[] language sql as $$
  select images from public.products where id = (select v from fx where k = p_product)::uuid
$$;

-- Fixtures ------------------------------------------------------------------------
insert into public.branches (name, address, delivery_fee) values ('PP-TEST A', 'a', 0);
insert into fx select 'ba', id::text from public.branches where name = 'PP-TEST A';
insert into public.product_categories (label) values ('PP-TEST Cat');
insert into public.products (category_id, name, price, unit)
select id, 'PP-TEST Nut', 100, 'pack' from public.product_categories where label = 'PP-TEST Cat';
insert into public.products (category_id, name, price, unit)
select id, 'PP-TEST Other', 50, 'pack' from public.product_categories where label = 'PP-TEST Cat';
insert into fx select 'p1', id::text from public.products where name = 'PP-TEST Nut';
insert into fx select 'p2', id::text from public.products where name = 'PP-TEST Other';
insert into public.product_variants (product_id, label, price)
select (select v from fx where k = 'p1')::uuid, 'Regular', 100;
insert into fx select 'v1', id::text from public.product_variants where product_id = (select v from fx where k = 'p1')::uuid;

insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
select 'pp-own', 'Owner', 'pp-own@test.local', 'owner', null::uuid, 'active'
union all select 'pp-off', 'Former owner', 'pp-off@test.local', 'owner', null, 'suspended'
union all select 'pp-st', 'Staff', 'pp-st@test.local', 'staff', (select v from fx where k = 'ba')::uuid, 'active';
update public.staff_members set can_manage_inventory = true where firebase_uid = 'pp-st';

-- Storage: who may write files ----------------------------------------------------
select pg_temp.chk('owner uploads into a product''s folder', 'pp-own',
  pg_temp.upload((select v from fx where k = 'p1') || '/a1.webp'), 'ok');
select pg_temp.chk('not into a folder of a product that does not exist', 'pp-own',
  pg_temp.upload(gen_random_uuid()::text || '/a1.webp'), 'error');
select pg_temp.chk('not with an unsafe file name', 'pp-own',
  pg_temp.upload((select v from fx where k = 'p1') || '/../x.webp'), 'error');
select pg_temp.chk('not a non-image file', 'pp-own',
  pg_temp.upload((select v from fx where k = 'p1') || '/a1.svg'), 'error');
select pg_temp.chk('staff cannot upload product photos', 'pp-st',
  pg_temp.upload((select v from fx where k = 'p1') || '/s1.jpg'), 'error');
select pg_temp.chk('a suspended owner cannot', 'pp-off',
  pg_temp.upload((select v from fx where k = 'p1') || '/o1.jpg'), 'error');
select pg_temp.chk('a customer cannot', 'pp-cust',
  pg_temp.upload((select v from fx where k = 'p1') || '/c1.jpg'), 'error');
select pg_temp.chk('a guest cannot', null,
  pg_temp.upload((select v from fx where k = 'p1') || '/g1.jpg'), 'error');

insert into results(name, passed, detail)
select 'customers and guests can view product photos',
  pg_temp.call_as('pp-cust', $q$select count(*)::text from storage.objects where bucket_id = 'product-images'$q$)::int >= 1
  and pg_temp.call_as(null, $q$select count(*)::text from storage.objects where bucket_id = 'product-images'$q$)::int >= 1, '';

select pg_temp.chk('staff cannot delete a product photo file', 'pp-st',
  $q$delete from storage.objects where bucket_id = 'product-images' and name like '%/a1.webp' returning 1$q$, 'ok');
select pg_temp.chk_true('… and the file is still there',
  exists (select 1 from storage.objects where bucket_id = 'product-images' and name = (select v from fx where k = 'p1') || '/a1.webp'));
select pg_temp.chk('the owner deletes it', 'pp-own',
  $q$delete from storage.objects where bucket_id = 'product-images' and name like '%/a1.webp'$q$, 'ok');
select pg_temp.chk_true('… and it is gone',
  not exists (select 1 from storage.objects where bucket_id = 'product-images' and name = (select v from fx where k = 'p1') || '/a1.webp'));

-- Database: the owner functions ---------------------------------------------------
select pg_temp.chk('owner adds photo 1', 'pp-own',
  format('select public.owner_add_product_image(%L, %L)', (select v from fx where k = 'p1'), pg_temp.url('p1', 'one.webp')), 'ok');
select pg_temp.chk('owner adds photo 2', 'pp-own',
  format('select public.owner_add_product_image(%L, %L)', (select v from fx where k = 'p1'), pg_temp.url('p1', 'two.jpg')), 'ok');
select pg_temp.chk('owner adds photo 3', 'pp-own',
  format('select public.owner_add_product_image(%L, %L)', (select v from fx where k = 'p1'), pg_temp.url('p1', 'three.png')), 'ok');
select pg_temp.chk_true('three photos saved in order',
  pg_temp.images('p1') = array[pg_temp.url('p1', 'one.webp'), pg_temp.url('p1', 'two.jpg'), pg_temp.url('p1', 'three.png')],
  array_to_string(pg_temp.images('p1'), ', '));
select pg_temp.chk('a 4th photo is refused', 'pp-own',
  format('select public.owner_add_product_image(%L, %L)', (select v from fx where k = 'p1'), pg_temp.url('p1', 'four.jpg')), 'error');
select pg_temp.chk('the same photo twice is refused', 'pp-own',
  format('select public.owner_add_product_image(%L, %L, %L)', (select v from fx where k = 'p1'), pg_temp.url('p1', 'one.webp'), pg_temp.url('p1', 'two.jpg')), 'error');
select pg_temp.chk('a URL from another product''s folder is refused', 'pp-own',
  format('select public.owner_add_product_image(%L, %L)', (select v from fx where k = 'p2'), pg_temp.url('p1', 'x.jpg')), 'error');
select pg_temp.chk('an outside URL is refused', 'pp-own',
  format('select public.owner_add_product_image(%L, %L)', (select v from fx where k = 'p2'), 'https://example.com/fake.jpg'), 'error');

insert into fx values ('replaced', pg_temp.call_as('pp-own',
  format('select public.owner_add_product_image(%L, %L, %L)::text', (select v from fx where k = 'p1'), pg_temp.url('p1', 'two-new.jpg'), pg_temp.url('p1', 'two.jpg'))));
select pg_temp.chk_true('replacing keeps the position',
  pg_temp.images('p1') = array[pg_temp.url('p1', 'one.webp'), pg_temp.url('p1', 'two-new.jpg'), pg_temp.url('p1', 'three.png')],
  array_to_string(pg_temp.images('p1'), ', '));
select pg_temp.chk_true('… and reports the old URL as removed',
  (select v from fx where k = 'replaced')::jsonb -> 'removed' = jsonb_build_array(pg_temp.url('p1', 'two.jpg')),
  (select v from fx where k = 'replaced'));
select pg_temp.chk('replacing a photo that is no longer there is refused', 'pp-own',
  format('select public.owner_add_product_image(%L, %L, %L)', (select v from fx where k = 'p1'), pg_temp.url('p1', 'five.jpg'), pg_temp.url('p1', 'two.jpg')), 'error');

select pg_temp.chk('reorder (main photo last -> first)', 'pp-own',
  format('select public.owner_set_product_image_order(%L, %L::text[])', (select v from fx where k = 'p1'),
    array[pg_temp.url('p1', 'three.png'), pg_temp.url('p1', 'one.webp'), pg_temp.url('p1', 'two-new.jpg')]), 'ok');
select pg_temp.chk_true('new order saved', (pg_temp.images('p1'))[1] = pg_temp.url('p1', 'three.png'));
select pg_temp.chk('a reorder with a different set is refused', 'pp-own',
  format('select public.owner_set_product_image_order(%L, %L::text[])', (select v from fx where k = 'p1'),
    array[pg_temp.url('p1', 'three.png'), pg_temp.url('p1', 'one.webp')]), 'error');

select pg_temp.chk('staff cannot add photos', 'pp-st',
  format('select public.owner_add_product_image(%L, %L)', (select v from fx where k = 'p2'), pg_temp.url('p2', 's.jpg')), 'error');
select pg_temp.chk('staff cannot remove photos', 'pp-st',
  format('select public.owner_remove_product_image(%L, %L)', (select v from fx where k = 'p1'), pg_temp.url('p1', 'one.webp')), 'error');
select pg_temp.chk('a customer cannot add photos', 'pp-cust',
  format('select public.owner_add_product_image(%L, %L)', (select v from fx where k = 'p2'), pg_temp.url('p2', 'c.jpg')), 'error');
select pg_temp.chk('a suspended owner cannot add photos', 'pp-off',
  format('select public.owner_add_product_image(%L, %L)', (select v from fx where k = 'p2'), pg_temp.url('p2', 'o.jpg')), 'error');
insert into results(name, passed, detail)
select 'guests cannot call the photo functions',
  not has_function_privilege('anon', 'public.owner_add_product_image(uuid, text, text)', 'execute')
  and not has_function_privilege('anon', 'public.owner_remove_product_image(uuid, text)', 'execute')
  and not has_function_privilege('anon', 'public.owner_set_product_image_order(uuid, text[])', 'execute'), '';
select pg_temp.chk('app users cannot write products.images directly', 'pp-st',
  format('update public.products set images = %L::text[] where id = %L', array['https://example.com/x.jpg'], (select v from fx where k = 'p1')), 'error');

-- Other product edits keep the photos ---------------------------------------------
-- staff_save_product runs as its owner with the app user's JWT; the guard sees the same thing here.
-- (Not called directly: on a fresh database it still writes product_variants.cost_price,
-- which 20260928000000 moved to product_variant_costs — unrelated to photos.)
select set_config('request.jwt.claims', jsonb_build_object('sub', 'pp-own', 'role', 'authenticated')::text, true);
update public.products set price = 120, images = '{}' where id = (select v from fx where k = 'p1')::uuid;
select set_config('request.jwt.claims', '', true);
select pg_temp.chk_true('an app save with a stale empty photo list still saves the price',
  (select price from public.products where id = (select v from fx where k = 'p1')::uuid) = 120);
select pg_temp.chk_true('… photos kept', cardinality(pg_temp.images('p1')) = 3, array_to_string(pg_temp.images('p1'), ', '));
select pg_temp.chk('hide / show still works', 'pp-own',
  format('select public.staff_set_product_active(%L, false)', (select v from fx where k = 'p1')), 'ok');
select pg_temp.chk_true('… photos kept after hiding', cardinality(pg_temp.images('p1')) = 3);
select pg_temp.chk('show again', 'pp-own', format('select public.staff_set_product_active(%L, true)', (select v from fx where k = 'p1')), 'ok');

insert into fx values ('keep', array_to_string(pg_temp.images('p2'), ','));
update public.products set images = array['https://example.com/editor.jpg'] where id = (select v from fx where k = 'p2')::uuid;
select pg_temp.chk_true('the SQL editor (no app sign-in) can still set photos', pg_temp.images('p2') = array['https://example.com/editor.jpg']);
update public.products set images = '{}' where id = (select v from fx where k = 'p2')::uuid;

-- Reading -------------------------------------------------------------------------
insert into results(name, passed, detail)
select 'customers read the photos with the product',
  pg_temp.call_as('pp-cust', format('select array_length(images, 1)::text from public.products where id = %L', (select v from fx where k = 'p1')))::int = 3, '';
insert into results(name, passed, detail)
select 'guests read the photos with the product',
  pg_temp.call_as(null, format('select array_length(images, 1)::text from public.products where id = %L', (select v from fx where k = 'p1')))::int = 3, '';
insert into fx values ('portal', pg_temp.call_as('pp-own', 'select public.admin_portal_products()::text'));
select pg_temp.chk_true('admin_portal_products returns the photos',
  (select jsonb_array_length(e -> 'images') from jsonb_array_elements((select v from fx where k = 'portal')::jsonb) e
   where e ->> 'id' = (select v from fx where k = 'p1')) = 3);

-- Removing ------------------------------------------------------------------------
select pg_temp.chk('owner removes a photo', 'pp-own',
  format('select public.owner_remove_product_image(%L, %L)', (select v from fx where k = 'p1'), pg_temp.url('p1', 'one.webp')), 'ok');
select pg_temp.chk_true('two photos left', cardinality(pg_temp.images('p1')) = 2);
select pg_temp.chk('removing it again is harmless', 'pp-own',
  format('select public.owner_remove_product_image(%L, %L)', (select v from fx where k = 'p1'), pg_temp.url('p1', 'one.webp')), 'ok');
select pg_temp.chk_true('audit log has the photo changes',
  (select count(*) from public.staff_audit_logs where entity_id = (select v from fx where k = 'p1') and action like 'product_photo%') >= 5);

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% product photo check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
