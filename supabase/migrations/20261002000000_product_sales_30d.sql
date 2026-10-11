-- Fix: Product Performance / Pricing Hub screens showed fake numbers.
--
-- `Product.unitsSoldLast30Days` (and the `monthlyRevenue`/`marginPercent`
-- getters built on it) was always hardcoded to 0 in the app, because no
-- existing query returned real per-product trailing-30-day unit counts.
-- `get_popular_products` (schema.sql) only returns a top-N *ranking*, not a
-- per-product count for every active product, so it can't be reused here.
--
-- This adds a dedicated RPC, modeled on `get_popular_products`, that returns
-- every active product's real units sold in the trailing 30 days (0 for a
-- product with no recent sales, never omitted and never invented).

create or replace function public.get_product_sales_30d()
returns table (product_id uuid, units_sold bigint)
language sql
stable
security definer
set search_path = public
as $$
  select p.id as product_id,
         coalesce(sum(oi.quantity) filter (
           where o.id is not null
             and o.status <> 'cancelled'
             and o.created_at >= now() - interval '30 days'
         ), 0)::bigint as units_sold
  from public.products p
  left join public.order_items oi on oi.product_name = p.name
  left join public.orders o on o.id = oi.order_id
  where p.is_active
  group by p.id
$$;

grant execute on function public.get_product_sales_30d() to anon, authenticated;
