-- Fix: column "updated_at" of relation "cart_items" does not exist
--
-- schema.sql creates cart_items / carts with `create table if not exists`, so
-- databases that already had the older prototype tables never received the
-- created_at / updated_at columns. get_customer_cart, checkout and the
-- cart_items_set_updated_at trigger all write updated_at, so every cart load
-- and sync failed, leaving the app stuck on
-- "Your cart changes haven't synced to your account yet."
--
-- Idempotent: safe to run on databases that already have the columns.

alter table public.cart_items add column if not exists created_at timestamptz not null default now();
alter table public.cart_items add column if not exists updated_at timestamptz not null default now();

alter table public.carts add column if not exists created_at timestamptz not null default now();
alter table public.carts add column if not exists updated_at timestamptz not null default now();

drop trigger if exists cart_items_set_updated_at on public.cart_items;
create trigger cart_items_set_updated_at before update on public.cart_items
  for each row execute function public.set_updated_at();

drop trigger if exists carts_set_updated_at on public.carts;
create trigger carts_set_updated_at before update on public.carts
  for each row execute function public.set_updated_at();

-- Make PostgREST pick up the new columns immediately.
notify pgrst, 'reload schema';
