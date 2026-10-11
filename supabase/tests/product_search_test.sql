-- Melai Nuts — search_customer_products() test. DEV/STAGING ONLY; rolls back.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/product_search_test.sql
-- Prerequisites: schema.sql, all migrations in supabase/migrations/.
begin;

insert into public.product_categories (label) values ('SRCH-TEST Category');
insert into public.products (category_id, name, price, unit, sku, tags, is_active)
select id, p.n, p.pr, 'pack', p.sku, p.tags, p.act
from public.product_categories,
     (values ('SRCH-TEST Cashew', 100, 'SRCH-SKU-1', array['heritage'], true),
             ('SRCH-TEST Peanut', 500, 'SRCH-SKU-2', array[]::text[], true),
             ('SRCH-TEST Hidden', 100, 'SRCH-SKU-3', array[]::text[], false)) p(n, pr, sku, tags, act)
where label = 'SRCH-TEST Category';

create temp table results (id serial, name text, passed boolean, detail text);
create function pg_temp.cnt(p_role text, p_query text, p_min numeric default null, p_max numeric default null)
returns int language plpgsql as $$
declare v int;
begin
  execute format('set local role %I', p_role);
  select count(*) into v from public.search_customer_products(p_query, null, p_min, p_max, 100);
  execute 'reset role';
  return v;
end $$;
grant execute on function pg_temp.cnt(text, text, numeric, numeric) to public;

insert into results(name, passed, detail) values
 ('anon finds by name (case-insensitive, partial)', pg_temp.cnt('anon', 'srch-test cash') = 1, ''),
 ('finds by category label', pg_temp.cnt('anon', 'SRCH-TEST Category') = 2, ''),
 ('finds by product SKU', pg_temp.cnt('authenticated', 'srch-sku-2') = 1, ''),
 ('finds by tag', pg_temp.cnt('anon', 'heritag') = 1, ''),
 ('inactive product is never returned', pg_temp.cnt('anon', 'SRCH-TEST Hidden') = 0, ''),
 ('max price filter', pg_temp.cnt('anon', 'SRCH-TEST', null, 200) = 1, ''),
 ('min price filter', pg_temp.cnt('anon', 'SRCH-TEST', 300, null) = 1, ''),
 ('wildcards are literal (% matches nothing here)', pg_temp.cnt('anon', '%') = 0
    or pg_temp.cnt('anon', '%') < (select count(*) from public.products where is_active), ''),
 ('anon and authenticated may execute',
    has_function_privilege('anon', 'public.search_customer_products(text,uuid[],numeric,numeric,int)', 'execute')
    and has_function_privilege('authenticated', 'public.search_customer_products(text,uuid[],numeric,numeric,int)', 'execute'), '');

select id, case when passed then 'PASS' else 'FAIL' end as result, name from results order by id;
do $$
declare f int; begin
  select count(*) into f from results where not passed;
  if f > 0 then raise exception '% search check(s) FAILED', f; end if;
end $$;
rollback;
