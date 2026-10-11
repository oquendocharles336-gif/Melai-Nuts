-- =============================================================================
-- Melai Nuts — Migration 20261012000000
-- admin_portal_stock(): say whether a branch actually carries each variant.
-- =============================================================================
-- RUN ORDER: after 20261009000000_admin_portal.sql. Safe to re-run.
--
-- WHY
--   admin_portal_stock() lists every active variant for every branch and shows
--   quantity 0 when the branch has no branch_inventory row. The app treats a
--   missing row as "not sold at this branch" (place_order refuses it), so the
--   admin dashboard counted products a branch never carries as "out of stock"
--   and "running low". Each item now has 'carried' (true when the branch has an
--   inventory row for it); the website ignores items that are not carried.
--   Nothing else changes: same caller checks, same shape, one extra key.
-- =============================================================================

begin;

create or replace function public.admin_portal_stock()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_staff();
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'branch_id', b.id, 'branch_name', b.name,
             'items', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'product_id', p.id, 'product_name', p.name,
                        'variant_id', pv.id, 'variant_label', pv.label, 'sku', pv.sku,
                        'quantity', coalesce(bi.quantity, 0), 'carried', (bi.branch_id is not null),
                        'restock_threshold', coalesce(th.restock_threshold, public._default_restock_threshold()))
                      order by p.name, pv.sort_order, pv.label), '[]'::jsonb)
               from public.products p
               join public.product_variants pv on pv.product_id = p.id
               left join public.branch_inventory bi on bi.branch_id = b.id and bi.variant_id = pv.id
               left join public.stock_thresholds th on th.branch_id = b.id and th.variant_id = pv.id
               where p.is_active)
           ) order by b.name), '[]'::jsonb)
    from public.branches b
    where b.id = any (public.staff_authorized_branch_ids())
  );
end;
$$;

revoke all on function public.admin_portal_stock() from public, anon;
grant execute on function public.admin_portal_stock() to authenticated;

commit;
