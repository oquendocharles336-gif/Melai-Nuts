-- =============================================================================
-- Melai Nuts — Migration 20260929000000
-- search_customer_products(): the storefront search RPC
-- =============================================================================
-- RUN ORDER: schema.sql -> 20260928000000 -> 20260928010000 -> this file.
-- Idempotent and atomic.
--
-- Why this exists: ProductsRepository.searchProducts() calls this RPC, but no
-- earlier SQL defined it, and migration 20260928000000 revokes EXECUTE on every
-- public function that is not on its allow-list. Search would therefore fail
-- for every customer and guest.
--
-- SECURITY INVOKER (not definer): the query runs with the caller's own
-- privileges, so the storefront RLS policies still apply. Inactive products,
-- inactive categories and variants of inactive products stay invisible, and no
-- cost data or private table is reachable from here.
--
-- Matches (case-insensitive, partial): product name, category label, product
-- SKU, any variant SKU, and any tag. Optional category filter and price bounds
-- (a product matches a bound when its base price or any variant price does).
-- Returns full `products` rows because the client hydrates variants/stock itself.
-- =============================================================================

begin;

create or replace function public.search_customer_products(
  p_query text default '',
  p_category_ids uuid[] default null,
  p_min_price numeric default null,
  p_max_price numeric default null,
  p_limit int default 100
)
returns setof public.products
language sql
stable
security invoker
set search_path = public
as $$
  with q as (
    -- Escape LIKE wildcards so a customer typing "%" or "_" searches literally.
    select '%' || replace(replace(replace(lower(trim(coalesce(p_query, ''))),
             '\', '\\'), '%', '\%'), '_', '\_') || '%' as pattern,
           lower(trim(coalesce(p_query, ''))) as raw
  )
  select p.*
  from public.products p
  left join public.product_categories c on c.id = p.category_id
  cross join q
  where p.is_active
    and (p_category_ids is null or p.category_id = any (p_category_ids))
    and (
      q.raw = ''
      or lower(p.name) like q.pattern escape '\'
      or lower(coalesce(c.label, '')) like q.pattern escape '\'
      or lower(coalesce(p.sku, '')) like q.pattern escape '\'
      or exists (select 1 from unnest(p.tags) t where lower(t) like q.pattern escape '\')
      or exists (select 1 from public.product_variants v
                 where v.product_id = p.id and lower(coalesce(v.sku, '')) like q.pattern escape '\')
    )
    and (
      (p_min_price is null and p_max_price is null)
      or (    (p_min_price is null or p.price >= p_min_price)
          and (p_max_price is null or p.price <= p_max_price))
      or exists (select 1 from public.product_variants v
                 where v.product_id = p.id
                   and (p_min_price is null or v.price >= p_min_price)
                   and (p_max_price is null or v.price <= p_max_price))
    )
  order by
    (q.raw <> '' and lower(p.name) like q.raw || '%') desc,  -- names starting with the query first
    p.name
  limit least(greatest(coalesce(p_limit, 100), 1), 200)
$$;

revoke all on function public.search_customer_products(text, uuid[], numeric, numeric, int)
  from public, anon, authenticated;
grant execute on function public.search_customer_products(text, uuid[], numeric, numeric, int)
  to anon, authenticated;

commit;
