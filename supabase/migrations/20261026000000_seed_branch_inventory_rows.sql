-- =============================================================================
-- One-time backfill: every existing variant gets a branch_inventory row at
-- every existing branch (quantity 0 until stock is received).
--
-- Why: place_order raises "<item> is not available at this branch." when no
-- row exists, and customers saw existing products as "not sold here". With a
-- row present, "0" means genuinely out of stock. Stock still arrives only
-- through the existing inventory functions.
--
-- Deliberately NO triggers on product_variants / branches: the app, the staff
-- functions and the test fixtures create a variant and then INSERT its
-- inventory row themselves. An auto-created zero row made those inserts fail
-- with a unique violation on (branch_id, product_id, variant_id). Rows that
-- are still missing later are shown to customers as "not sold at this branch"
-- by the app, which is accurate.
--
-- Inserting quantity 0 does not touch batches (the batch-sync triggers only
-- fire on UPDATE of quantity). Idempotent: safe to run more than once.
-- =============================================================================

-- Remove the auto-seed triggers if an earlier version of this migration
-- already created them.
drop trigger if exists product_variants_seed_inventory on public.product_variants;
drop trigger if exists branches_seed_inventory on public.branches;
drop function if exists public._seed_inventory_for_new_variant();
drop function if exists public._seed_inventory_for_new_branch();

insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select b.id, pv.product_id, pv.id, 0
from public.branches b
cross join public.product_variants pv
on conflict do nothing;
