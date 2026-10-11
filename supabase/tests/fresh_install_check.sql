-- =============================================================================
-- Melai Nuts — a NEW project built from schema.sql + every migration holds NO
-- business data (owner decision: no hardcoded data). Run by scripts/run-sql-tests.sh
-- right after building the database, before any other suite.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fresh_install_check.sql
-- Read-only. Raises if any table that must start empty has rows.
-- =============================================================================
do $$
declare
  t text;
  n bigint;
  bad text := '';
  must_be_empty text[] := array[
    'branches', 'product_categories', 'products', 'product_variants', 'product_variant_costs',
    'branch_inventory', 'inventory_batches', 'stock_movements', 'stock_thresholds',
    'rewards', 'reward_redemptions', 'promotions', 'vouchers',
    'orders', 'order_items', 'payments', 'refund_requests',
    'loyalty_cart_settings', 'loyalty_accounts', 'loyalty_transactions', 'business_settings',
    'staff_members', 'customer_profiles', 'customer_addresses', 'deliveries', 'suppliers'];
begin
  foreach t in array must_be_empty loop
    if to_regclass('public.' || t) is null then continue; end if;   -- table not in this version
    if t = 'customer_profiles' then
      -- 'walk-in' is the POS's technical sentinel for anonymous counter sales (not a person).
      select count(*) into n from public.customer_profiles where firebase_uid <> 'walk-in';
    else
      execute format('select count(*) from public.%I', t) into n;
    end if;
    if n > 0 then bad := bad || format(' %s=%s', t, n); end if;
  end loop;
  if bad <> '' then
    raise exception 'A fresh database must hold no business data, but found:%', bad;
  end if;
  -- The only seeded row allowed: the online-payment switch, OFF (owner decision).
  if (select count(*) from public.payment_settings) <> 1 or public.online_payment_enabled() then
    raise exception 'payment_settings must hold exactly one row with online payment OFF.';
  end if;
  if public.get_loyalty_earn_rate() is not null or public._default_restock_threshold() is not null then
    raise exception 'Earn rate and restock threshold must be "Not set" (NULL) on a fresh database.';
  end if;
  raise notice 'fresh install: 0 rows in % business tables; online payment OFF; settings Not set — passed',
    array_length(must_be_empty, 1);
end $$;
