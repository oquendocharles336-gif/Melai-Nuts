-- =============================================================================
-- Every variant has a branch_inventory row at every branch (quantity 0 until
-- stock is received).
--
-- Why: place_order raises "<item> is not available at this branch." when no
-- row exists, and the app's live stock check read a missing row as 0, so a
-- newly added product/variant, or a brand-new branch, showed as "out of
-- stock" / "not sold here" for customers. With a row always present, "0" means
-- genuinely out of stock, and stock arrives only through the existing
-- inventory functions as before.
--
-- Inserting quantity 0 does not touch batches: the batch-sync triggers only
-- fire on UPDATE of quantity. Idempotent: safe to run more than once.
-- =============================================================================

-- New variant -> a zero row at every branch.
create or replace function public._seed_inventory_for_new_variant()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
  select b.id, new.product_id, new.id, 0
  from public.branches b
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists product_variants_seed_inventory on public.product_variants;
create trigger product_variants_seed_inventory
  after insert on public.product_variants
  for each row execute function public._seed_inventory_for_new_variant();

-- New branch -> a zero row for every existing variant.
create or replace function public._seed_inventory_for_new_branch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
  select new.id, pv.product_id, pv.id, 0
  from public.product_variants pv
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists branches_seed_inventory on public.branches;
create trigger branches_seed_inventory
  after insert on public.branches
  for each row execute function public._seed_inventory_for_new_branch();

-- Internal trigger functions: nobody calls them directly.
revoke all on function public._seed_inventory_for_new_variant() from public, anon, authenticated;
revoke all on function public._seed_inventory_for_new_branch() from public, anon, authenticated;

-- Backfill the gaps that already exist.
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select b.id, pv.product_id, pv.id, 0
from public.branches b
cross join public.product_variants pv
on conflict do nothing;
