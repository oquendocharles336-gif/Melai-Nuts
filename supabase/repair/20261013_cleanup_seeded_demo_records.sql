-- =============================================================================
-- Melai Nuts — CLEAN UP the records left by the old demo seed   (REVIEWED, NOT RUN)
-- =============================================================================
-- Companion to 20261010_review_seeded_demo_records.sql (SELECT only). That review
-- was run on the live project (Melai-Nuts-Retail) on 2026-10-13 and found:
--
--   A. 12 stock rows still at the seeded 50 units, never counted, never moved:
--        Calamba Branch    Chili Garlic Peanuts, Melai Nuts Gift Box, Mixed Nuts & Raisins,
--                          Roasted Cashew, Roasted Peanuts
--        Los Baños Branch  Chili Garlic Peanuts, Melai Nuts Gift Box, Mixed Nuts & Raisins,
--                          Roasted Cashew, Roasted Peanuts
--        Santa Cruz Branch Mixed Nuts & Raisins, Roasted Cashew
--   B. 5 seeded products with the seed's prices and descriptions (all active):
--        Roasted Peanuts ₱90 (in 3 order lines), Melai Nuts Gift Box ₱480 (1 order line),
--        Roasted Cashew ₱220, Mixed Nuts & Raisins ₱260, Chili Garlic Peanuts ₱110 (never sold)
--   C. 3 seeded rewards, all active, never redeemed (₱50 Off Voucher 200 pts,
--        Free 100g Roasted Cashew 350 pts, Free Delivery Voucher 150 pts) and the
--        promotion "Fresh Batch Every Friday" (active)
--   D. The 3 branches still carry the seed's address, phone and opening hours
--   E. Orders ORD-1001 to ORD-1004 (2026-10-01, Santa Cruz Branch, completed and
--        paid: ₱540 cash, ₱80 cash, ₱480 GCash, ₱90 cash) — FLAGGED for the owner only
--   F. Check what is left (SELECT only)
--
-- RUN ORDER (see docs/PRODUCTION_RUNBOOK.md, "Seeded demo records clean-up"):
--   1. STAGING FIRST: restore a copy of production to a staging project (or a
--      Supabase branch), run every section there with COMMIT, check the app and
--      the admin website, and run section F.
--   2. PRODUCTION: take a backup (or note the PITR timestamp), then run the same
--      sections in the same order: A, B, C, (C2 optional), D, F. Never E.
--
-- HOW TO USE: run ONE section at a time in the Supabase SQL editor. Every section is a
-- transaction that ends with ROLLBACK, so running it as it is only SHOWS what it would
-- do. When the result is what you want, change that section's ROLLBACK to COMMIT and
-- run it again. Nothing here deletes an order, a payment or a product that was sold.
-- Each section re-checks that the row is still exactly the seeded value, so a row you
-- already corrected by hand is left alone, and running a section twice changes nothing
-- the second time.
--
-- Tested by supabase/tests/cleanup_seeded_demo_records_test.sh on a local database
-- that reproduces the seeded rows: as shipped (ROLLBACK) it changes nothing; with
-- COMMIT it changes exactly the rows listed above and nothing else.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- A. Stock that was never counted: set to 0 (recorded as an 'adjust' stock movement)
--    Afterwards, count the shelves and record the real quantity with Receive Stock in
--    the staff app, so batches and expiry dates are right. (Branch staff get the usual
--    "out of stock" notifications when these rows go to 0.)
-- -----------------------------------------------------------------------------
begin;
-- Direct adjustment: do not let the batch trigger book this as a "sale".
select set_config('app.inventory_managed', '1', true);

with seeded as (
  select bi.id, bi.branch_id, bi.product_id, bi.variant_id, bi.quantity
  from public.branch_inventory bi
  join public.branches b on b.id = bi.branch_id
  join public.products p on p.id = bi.product_id
  join public.product_variants v on v.id = bi.variant_id
  where bi.quantity = 50
    and not exists (select 1 from public.stock_movements sm where sm.branch_id = bi.branch_id and sm.variant_id = bi.variant_id)
    and not exists (select 1 from public.inventory_batches ib where ib.branch_id = bi.branch_id and ib.variant_id = bi.variant_id)
    and (b.name, p.name) in (
      ('Calamba Branch', 'Chili Garlic Peanuts'), ('Calamba Branch', 'Melai Nuts Gift Box'),
      ('Calamba Branch', 'Mixed Nuts & Raisins'), ('Calamba Branch', 'Roasted Cashew'),
      ('Calamba Branch', 'Roasted Peanuts'),
      ('Los Baños Branch', 'Chili Garlic Peanuts'), ('Los Baños Branch', 'Melai Nuts Gift Box'),
      ('Los Baños Branch', 'Mixed Nuts & Raisins'), ('Los Baños Branch', 'Roasted Cashew'),
      ('Los Baños Branch', 'Roasted Peanuts'),
      ('Santa Cruz Branch', 'Mixed Nuts & Raisins'), ('Santa Cruz Branch', 'Roasted Cashew'))
),
zeroed as (
  update public.branch_inventory bi set quantity = 0
  from seeded s where bi.id = s.id
  returning bi.branch_id, bi.product_id, bi.variant_id, s.quantity as old_quantity
)
insert into public.stock_movements (branch_id, product_id, variant_id, movement_type, quantity_change, reason, reference)
select branch_id, product_id, variant_id, 'adjust', -old_quantity,
       'Seeded demo stock removed: the 50 units were never a real count', 'cleanup-seed-20261013'
from zeroed;

-- Expect 12 rows here:
select b.name as branch, p.name as product, sm.quantity_change
from public.stock_movements sm
join public.branches b on b.id = sm.branch_id
join public.products p on p.id = sm.product_id
where sm.reference = 'cleanup-seed-20261013'
order by 1, 2;

rollback;  -- change to COMMIT when the 12 rows above are right


-- -----------------------------------------------------------------------------
-- B. Seeded products that were NEVER sold: hide them from the app (reversible on the
--    Products page). Roasted Peanuts and the Gift Box are in real orders and stay; check
--    their price (₱90 / ₱480) and description on the Products page.
-- -----------------------------------------------------------------------------
begin;

update public.products p set is_active = false
where (p.name, p.description) in (
        ('Roasted Cashew', 'Slow-roasted Laguna cashews, lightly salted.'),
        ('Mixed Nuts & Raisins', 'Cashew, peanut, almond and raisin blend.'),
        ('Chili Garlic Peanuts', 'Peanuts tossed in chili and garlic seasoning.'))
  and p.is_active
  and not exists (select 1 from public.order_items oi where oi.product_id = p.id or oi.product_name = p.name)
returning p.name, p.price, p.is_active;   -- expect 3 rows

rollback;  -- change to COMMIT to hide them

-- B (review only): the 2 seeded products that WERE sold stay visible. Confirm or
-- correct their price and description on the admin website (Products) or in the app.
select p.name, p.price, p.description, p.is_active,
       (select count(*) from public.order_items oi where oi.product_id = p.id or oi.product_name = p.name) as order_lines
from public.products p
where (p.name, p.description) in (
        ('Roasted Peanuts', 'Crunchy roasted peanuts in shell.'),
        ('Melai Nuts Gift Box', 'Assorted nuts in a gift-ready box.'));


-- -----------------------------------------------------------------------------
-- C. Seeded rewards (never redeemed) and the seeded promotion: deactivate.
--    Keep any the business really offers by removing it from the lists below.
-- -----------------------------------------------------------------------------
begin;

update public.rewards r set is_active = false
where r.title in ('₱50 Off Voucher', 'Free 100g Roasted Cashew', 'Free Delivery Voucher')
  and r.is_active
  and not exists (select 1 from public.reward_redemptions rr where rr.reward_id = r.id)
returning r.title, r.points_required, r.is_active;   -- expect 3 rows

update public.promotions pr set is_active = false
where pr.title = 'Fresh Batch Every Friday' and pr.is_active
returning pr.title, pr.is_active;                   -- expect 1 row

rollback;  -- change to COMMIT to deactivate them


-- -----------------------------------------------------------------------------
-- C2. OPTIONAL, after C: permanently delete the seeded rewards that were never
--     redeemed and the seeded promotion, once you are sure the business does not
--     offer them. (C alone already hides them from customers.)
-- -----------------------------------------------------------------------------
begin;

delete from public.rewards r
where r.title in ('₱50 Off Voucher', 'Free 100g Roasted Cashew', 'Free Delivery Voucher')
  and not r.is_active
  and not exists (select 1 from public.reward_redemptions rr where rr.reward_id = r.id)
returning r.title;                                   -- expect 3 rows (0 if C was not committed)

delete from public.promotions pr
where pr.title = 'Fresh Batch Every Friday' and not pr.is_active
returning pr.title;                                  -- expect 1 row (0 if C was not committed)

rollback;  -- change to COMMIT to delete them for good


-- -----------------------------------------------------------------------------
-- D. Branch address / phone / hours written by the seed.
--    Type the REAL values in the list below. The block refuses to run while any value
--    still starts with "EDIT". To clear a value instead (shown as "—"), put null.
-- -----------------------------------------------------------------------------
begin;

do $$
declare
  r record;
  n int;
begin
  for r in
    select * from (values
      -- branch name          seeded address (must still match)                           real address        real phone        real hours
      ('Calamba Branch',    'Poblacion Terminal, National Hwy, Calamba City, Laguna', 'EDIT real address', 'EDIT real phone', 'EDIT real hours'),
      ('Los Baños Branch',  'Lopez Ave, Los Baños, Laguna',                           'EDIT real address', 'EDIT real phone', 'EDIT real hours'),
      ('Santa Cruz Branch', 'National Hwy, Santa Cruz, Laguna',                       'EDIT real address', 'EDIT real phone', 'EDIT real hours')
    ) as t(name, seeded_address, address, phone, hours)
  loop
    if coalesce(r.address, '') like 'EDIT%' or coalesce(r.phone, '') like 'EDIT%' or coalesce(r.hours, '') like 'EDIT%' then
      raise exception 'Section D: type the real address / phone / hours for % first (or null to clear).', r.name;
    end if;
    update public.branches
       set address = r.address, contact_phone = r.phone, operating_hours = r.hours
     where name = r.name and address = r.seeded_address;
    get diagnostics n = row_count;
    raise notice '% : % row(s) updated', r.name, n;
  end loop;
end;
$$;

select name, address, contact_phone, operating_hours from public.branches order by name;

rollback;  -- change to COMMIT when the values above are the real ones


-- -----------------------------------------------------------------------------
-- E. Orders ORD-1001 .. ORD-1004: FLAGGED FOR OWNER REVIEW — NO SQL CHANGE ON PURPOSE.
--    They went through the real checkout and payment, so stock, points, payments and
--    reports already count them. If they were tests, refund them through the app / the
--    website's Refunds page (that returns stock and points and keeps reports right).
--    Never delete them with SQL. This only shows who placed them:
-- -----------------------------------------------------------------------------
select o.id, o.created_at, o.total, o.branch_name, o.status,
       coalesce(nullif(cp.full_name, ''), o.firebase_uid) as customer,
       (select string_agg(oi.quantity || 'x ' || oi.product_name, ', ') from public.order_items oi where oi.order_id = o.id) as items
from public.orders o
left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
where o.id in ('ORD-1001', 'ORD-1002', 'ORD-1003', 'ORD-1004')
order by o.created_at;


-- -----------------------------------------------------------------------------
-- F. What is left of the seed (SELECT only). After A-D are committed, expect:
--    seeded_stock_rows 0, active_unsold_seed_products 0, active_seed_rewards 0,
--    active_seed_promotions 0, branches_with_seed_address 0. The 4 orders stay (E).
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.branch_inventory bi
     join public.branches b on b.id = bi.branch_id
    where bi.quantity = 50
      and b.name in ('Calamba Branch', 'Los Baños Branch', 'Santa Cruz Branch')
      and not exists (select 1 from public.stock_movements sm where sm.branch_id = bi.branch_id and sm.variant_id = bi.variant_id)
      and not exists (select 1 from public.inventory_batches ib where ib.branch_id = bi.branch_id and ib.variant_id = bi.variant_id)) as seeded_stock_rows,
  (select count(*) from public.products p
    where p.is_active and (p.name, p.description) in (
        ('Roasted Cashew', 'Slow-roasted Laguna cashews, lightly salted.'),
        ('Mixed Nuts & Raisins', 'Cashew, peanut, almond and raisin blend.'),
        ('Chili Garlic Peanuts', 'Peanuts tossed in chili and garlic seasoning.'))) as active_unsold_seed_products,
  (select count(*) from public.rewards r
    where r.is_active and r.title in ('₱50 Off Voucher', 'Free 100g Roasted Cashew', 'Free Delivery Voucher')) as active_seed_rewards,
  (select count(*) from public.promotions pr where pr.is_active and pr.title = 'Fresh Batch Every Friday') as active_seed_promotions,
  (select count(*) from public.branches b where (b.name, b.address) in (
        ('Calamba Branch', 'Poblacion Terminal, National Hwy, Calamba City, Laguna'),
        ('Los Baños Branch', 'Lopez Ave, Los Baños, Laguna'),
        ('Santa Cruz Branch', 'National Hwy, Santa Cruz, Laguna'))) as branches_with_seed_address,
  (select count(*) from public.orders o where o.id in ('ORD-1001', 'ORD-1002', 'ORD-1003', 'ORD-1004')) as flagged_orders_kept;
