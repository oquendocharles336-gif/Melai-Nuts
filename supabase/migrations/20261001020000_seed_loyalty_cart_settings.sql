-- Fix: "Loyalty point redemption is not configured yet."
--
-- The cart pricing function reads the single `default` row of
-- public.loyalty_cart_settings when a customer turns on "Redeem Golden Kernel
-- Points". schema.sql creates the table but (deliberately) never seeds it, so
-- the row was missing and redemption always raised that error.
--
-- STARTER VALUES - change them to match your actual loyalty policy:
--   points_per_peso      = 1   -> 1 point is worth PHP 1 off  (points earn at
--                                 1 pt per PHP 50 spent, so this is ~2% back)
--   max_discount_percent = 50  -> points can cover at most 50% of an order
--
-- `on conflict do nothing` means this never overwrites values you've already set.

insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent)
values ('default', 1, 50)
on conflict (id) do nothing;

-- To change later (SQL editor):
--   update public.loyalty_cart_settings
--   set points_per_peso = 1, max_discount_percent = 50, updated_at = now()
--   where id = 'default';
