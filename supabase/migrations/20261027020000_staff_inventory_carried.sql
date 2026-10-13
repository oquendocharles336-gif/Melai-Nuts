-- =============================================================================
-- Melai Nuts — Migration 20261027020000: staff inventory says "not sold here"
-- =============================================================================
-- Run after 20261027000000_review_fixes.sql (adds branch_inventory.is_carried).
-- Idempotent, one transaction.
--
-- staff_get_inventory lists every active product option for the branch, so
-- staff can receive stock for any of them. Items the branch doesn't sell came
-- back as quantity 0 and the staff app showed them as "Out of stock". Each item
-- now has 'carried' (false = no stock row, or a row marked not carried); the app
-- shows those as "Not sold here" and leaves them out of the low / out-of-stock
-- counts. Receiving stock still works for every item and makes it carried.
--
-- Latest definition (20260930000000_staff_backend.sql) with ONLY the extra key.
-- =============================================================================
begin;

create or replace function public.staff_get_inventory(p_branch_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branch uuid;
begin
  v_staff := public._require_staff();
  v_branch := case when v_staff.role = 'owner' then p_branch_id else v_staff.branch_id end;
  if v_branch is null then raise exception 'Please choose a branch first.'; end if;

  return jsonb_build_object(
    'branch_id', v_branch,
    'branch_name', (select name from public.branches where id = v_branch),
    'items', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.product_name, x.variant_label), '[]'::jsonb)
      from (
        select p.id as product_id, p.name as product_name, p.category_id,
               pv.id as variant_id, pv.label as variant_label, pv.sku, pv.price,
               coalesce(bi.quantity, 0) as quantity,
               -- Does this branch sell it? No row, or a row marked not carried = "not sold here".
               (bi.branch_id is not null and bi.is_carried) as carried,
               coalesce(th.restock_threshold, public._default_restock_threshold()) as restock_threshold,
               coalesce((select sum(b.quantity) from public.inventory_batches b
                         where b.branch_id = v_branch and b.variant_id = pv.id), 0)::int as batched_quantity
        from public.products p
        join public.product_variants pv on pv.product_id = p.id
        left join public.branch_inventory bi on bi.branch_id = v_branch and bi.variant_id = pv.id
        left join public.stock_thresholds th on th.branch_id = v_branch and th.variant_id = pv.id
        where p.is_active
      ) x
    ),
    'batches', (
      select coalesce(jsonb_agg(to_jsonb(y) order by y.expiration_date, y.received_date), '[]'::jsonb)
      from (
        select b.id, b.branch_id, br.name as branch_name, b.product_id, b.variant_id,
               b.batch_code, b.received_date, b.expiration_date, b.quantity, b.initial_quantity
        from public.inventory_batches b
        join public.branches br on br.id = b.branch_id
        where b.branch_id = v_branch and b.quantity > 0
      ) y
    )
  );
end;
$$;
revoke all on function public.staff_get_inventory(uuid) from public, anon;
grant execute on function public.staff_get_inventory(uuid) to authenticated;

commit;
