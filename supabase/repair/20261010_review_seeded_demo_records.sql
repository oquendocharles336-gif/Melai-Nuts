-- =============================================================================
-- Melai Nuts — REVIEW of records that came from the old demo seed (read-only)
-- =============================================================================
-- Until 2026-10-10 supabase/schema.sql ended with a "starter seed" (since removed
-- from the project entirely). On the live project
-- every one of these rows has created_at = 2026-09-26 15:08:47 UTC (the moment
-- schema.sql was run) and exactly the seed's values, so their origin is certain:
--
--   * 3 branches        – the seed also WROTE their address, phone and opening
--                          hours (and re-wrote them each time schema.sql ran)
--   * 4 categories, 5 products and their 5 "Regular (...)" variants, with the
--     seed's invented prices and descriptions
--   * branch_inventory   – 50 units of every variant at every branch: a made-up
--                          number, not a stock count
--   * 3 rewards and 1 promotion ("Fresh Batch Every Friday")
--
-- NOTHING IS DELETED OR CHANGED BY THIS FILE. The seeded products already appear
-- in real orders (Roasted Peanuts, Melai Nuts Gift Box) and staff have moved stock,
-- so deleting them would break order history. The owner should instead CONFIRM or
-- CORRECT each value in the app / admin website:
--   1. Branch address, phone, hours: correct them if they are not the real ones.
--   2. Products, prices, descriptions: keep, edit, or hide (Products page).
--   3. Stock: count the shelves and record the real quantity (Receive Stock /
--      stock adjustment in the staff app). Rows still at exactly 50 with no stock
--      movement have never been counted.
--   4. Rewards and the promotion: keep only the ones the business really offers
--      (deactivate the rest; rewards that were never redeemed can be deleted).
--
-- Also for review (left untouched): 4 orders from 2026-10-01 (ORD-1001 to
-- ORD-1004) placed by project members' accounts. They went through the real
-- checkout and payment flow, so they are treated as genuine; if they were tests,
-- cancel/refund them through the app so stock, points and reports stay consistent.
--
-- Run in the Supabase SQL editor. Only SELECT statements.
-- To clean up what it finds: 20261013_cleanup_seeded_demo_records.sql (reviewed; every
-- section ends with ROLLBACK until you change it to COMMIT).
-- =============================================================================

-- 1. Branch details the seed wrote (compare with the real ones)
select name, address, contact_phone, operating_hours, supports_delivery, supports_pickup, created_at
from public.branches
where (name, address, contact_phone) in (
  ('Calamba Branch', 'Poblacion Terminal, National Hwy, Calamba City, Laguna', '(049) 502-1187'),
  ('Los Baños Branch', 'Lopez Ave, Los Baños, Laguna', '(049) 536-4420'),
  ('Santa Cruz Branch', 'National Hwy, Santa Cruz, Laguna', '(049) 501-7765'));

-- 2. Seeded products still carrying the seed's price and description, and whether they were sold
select p.name, p.price, p.description, p.is_active,
       (select count(*) from public.order_items oi where oi.product_id = p.id or oi.product_name = p.name) as order_lines
from public.products p
where (p.name, p.description) in (
  ('Roasted Cashew', 'Slow-roasted Laguna cashews, lightly salted.'),
  ('Roasted Peanuts', 'Crunchy roasted peanuts in shell.'),
  ('Chili Garlic Peanuts', 'Peanuts tossed in chili and garlic seasoning.'),
  ('Mixed Nuts & Raisins', 'Cashew, peanut, almond and raisin blend.'),
  ('Melai Nuts Gift Box', 'Assorted nuts in a gift-ready box.'));

-- 3. Stock rows that still hold the seeded 50 units and were never moved or batched
select b.name as branch, p.name as product, v.label as variant, bi.quantity
from public.branch_inventory bi
join public.branches b on b.id = bi.branch_id
join public.products p on p.id = bi.product_id
join public.product_variants v on v.id = bi.variant_id
where bi.quantity = 50
  and not exists (select 1 from public.stock_movements sm where sm.branch_id = bi.branch_id and sm.variant_id = bi.variant_id)
  and not exists (select 1 from public.inventory_batches ib where ib.branch_id = bi.branch_id and ib.variant_id = bi.variant_id)
order by 1, 2;

-- 4. Seeded rewards / promotion and whether anyone used them
select 'reward' as kind, r.title, r.points_required::text as detail, r.is_active,
       (select count(*) from public.reward_redemptions rr where rr.reward_id = r.id) as times_used
from public.rewards r
where r.title in ('₱50 Off Voucher', 'Free 100g Roasted Cashew', 'Free Delivery Voucher')
union all
select 'promotion', pr.title, pr.subtitle, pr.is_active, null
from public.promotions pr
where pr.title = 'Fresh Batch Every Friday';

-- 5. Orders placed during project testing (review; nothing is changed here)
select o.id, o.created_at, o.status, o.total, o.branch_name, p.method, p.status as payment_status
from public.orders o
left join public.payments p on p.order_id = o.id
where o.id in ('ORD-1001', 'ORD-1002', 'ORD-1003', 'ORD-1004')
order by o.created_at;
