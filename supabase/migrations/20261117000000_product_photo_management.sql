-- =============================================================================
-- Melai Nuts — Migration 20261117000000: product photo management
-- =============================================================================
-- Run after 20261107120000_refund_request_window.sql. Idempotent.
--
-- The owner adds, replaces, reorders and removes up to 3 photos per product from
-- the admin website (Products tab). The photos are what every customer sees in
-- the app and on the web shop, for every branch.
--
--  * Files: the existing public bucket 'product-images' (Supabase Storage).
--    One folder per product:  product-images/<product id>/<random name>.<ext>
--    A new upload always gets a new name, so a replaced photo has a new URL
--    and no phone or browser can keep showing the old picture from its cache.
--  * Database: the existing column products.images (ordered public URLs).
--    The first URL is the product's main photo (catalog card). No new table.
--  * Who: only an ACTIVE OWNER may add, replace, reorder or delete photos —
--    in Storage (policies below) and in the database (owner_* functions below).
--    Everyone, signed in or not, can view them (public bucket).
--
-- What changes:
--  1. Bucket: 5 MB limit (the website shrinks large photos before uploading;
--     the limit is for the rare browser that cannot), JPEG / PNG / WEBP only.
--  2. Storage policies: the old "owners manage product images" rule read
--     public.staff_members directly (the same trap 20261101150000 fixed for
--     delivery proofs). It is replaced by insert / update / delete rules that
--     ask security-definer helpers instead, and that only accept files inside
--     the folder of a product that exists.
--  3. owner_add_product_image / owner_remove_product_image /
--     owner_set_product_image_order: the only way to change products.images
--     from the app or the website. Each locks the product row, so two owners
--     editing at once cannot lose a photo or go past 3.
--  4. staff_save_product (the app's Edit Product / Pricing / Variants screens)
--     sends back the photo list it loaded earlier. A guard trigger keeps the
--     stored photos when an app user's save would change them, so editing a
--     price in the app can never undo photos the owner just uploaded on the
--     website. (Those screens already say photos are not edited there.)
--     The Supabase dashboard / SQL editor are not affected by the guard.
--  5. admin_portal_products() also returns each product's photos.
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1 + 2. Bucket and Storage policies
-- -----------------------------------------------------------------------------

-- Caller is an active owner (security definer: app users cannot read
-- staff_members rows other than their own, and Storage evaluates these rules for
-- every request on storage.objects).
create or replace function public.can_manage_product_images()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.staff_members s
    where s.firebase_uid = public.current_firebase_uid()
      and s.account_status = 'active'
      and s.role = 'owner')
$$;
revoke all on function public.can_manage_product_images() from public, anon;
grant execute on function public.can_manage_product_images() to authenticated;

-- A file name an owner may write: "<existing product id>/<safe name>.<image ext>".
create or replace function public.can_write_product_image(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_name is null
     or p_name !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$' then
    return false;
  end if;
  return public.can_manage_product_images()
     and exists (select 1 from public.products p where p.id = split_part(p_name, '/', 1)::uuid);
end;
$$;
revoke all on function public.can_write_product_image(text) from public, anon;
grant execute on function public.can_write_product_image(text) to authenticated;

do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('product-images', 'product-images', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
    on conflict (id) do update
      set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
  end if;

  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'objects') then
    -- Viewing: anyone (customers, guests, staff). Unchanged.
    execute $p$drop policy if exists "anyone reads product images" on storage.objects$p$;
    execute $p$create policy "anyone reads product images" on storage.objects for select
      using (bucket_id = 'product-images')$p$;

    -- The old single rule read staff_members directly; replaced below.
    execute $p$drop policy if exists "owners manage product images" on storage.objects$p$;

    execute $p$drop policy if exists "owners add product images" on storage.objects$p$;
    execute $p$create policy "owners add product images" on storage.objects for insert to authenticated
      with check (bucket_id = 'product-images' and public.can_write_product_image(name))$p$;

    execute $p$drop policy if exists "owners update product images" on storage.objects$p$;
    execute $p$create policy "owners update product images" on storage.objects for update to authenticated
      using (bucket_id = 'product-images' and public.can_manage_product_images())
      with check (bucket_id = 'product-images' and public.can_write_product_image(name))$p$;

    execute $p$drop policy if exists "owners delete product images" on storage.objects$p$;
    execute $p$create policy "owners delete product images" on storage.objects for delete to authenticated
      using (bucket_id = 'product-images' and public.can_manage_product_images())$p$;
  end if;
end
$do$;

-- -----------------------------------------------------------------------------
-- 3. The owner's photo functions
-- -----------------------------------------------------------------------------

-- Public URL of a file in this product's folder of the product-images bucket.
create or replace function public._product_image_url_ok(p_product_id uuid, p_url text)
returns boolean
language sql
immutable
as $$
  select p_url is not null
     and char_length(p_url) <= 500
     and p_url ~ ('^https?://[^/[:space:]]+/storage/v1/object/public/product-images/'
                  || p_product_id::text || '/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$')
$$;

-- Writes products.images for the owner functions below (lets the guard trigger through).
create or replace function public._store_product_images(p_product_id uuid, p_images text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('melai.product_images_write', 'on', true);
  update public.products set images = p_images, updated_at = now() where id = p_product_id;
  perform set_config('melai.product_images_write', '', true);
end;
$$;
revoke all on function public._product_image_url_ok(uuid, text) from public, anon, authenticated;
revoke all on function public._store_product_images(uuid, text[]) from public, anon, authenticated;

-- Add a photo (p_replace_url null) or put it in place of an existing one.
-- Returns {product_id, images, removed}: `removed` are the URLs no longer used,
-- whose files the caller deletes from Storage.
create or replace function public.owner_add_product_image(
  p_product_id uuid,
  p_url text,
  p_replace_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
  v_old text[];
  v_new text[];
  v_pos int;
  v_removed text[] := '{}';
begin
  v_owner := public._require_owner();
  select coalesce(images, '{}') into v_old from public.products where id = p_product_id for update;
  if not found then raise exception 'That product could not be found.'; end if;
  if not public._product_image_url_ok(p_product_id, p_url) then
    raise exception 'That photo was not uploaded to this product''s folder.';
  end if;
  if p_url = any (v_old) then
    raise exception 'That photo is already saved for this product.';
  end if;

  if p_replace_url is not null then
    v_pos := array_position(v_old, p_replace_url);
    if v_pos is null then
      raise exception 'The photo you are replacing was changed in the meantime. Reload the page and try again.';
    end if;
    v_new := v_old;
    v_new[v_pos] := p_url;
    v_removed := array[p_replace_url];
  else
    if cardinality(v_old) >= 3 then
      raise exception 'A product can have at most 3 photos. Replace or remove one first.';
    end if;
    v_new := v_old || p_url;
  end if;

  perform public._store_product_images(p_product_id, v_new);
  perform public._write_audit(v_owner.firebase_uid, v_owner.branch_id,
    case when p_replace_url is null then 'product_photo_added' else 'product_photo_replaced' end,
    'product', p_product_id::text, jsonb_build_object('url', p_url, 'replaced', p_replace_url, 'count', cardinality(v_new)), null);

  return jsonb_build_object('product_id', p_product_id, 'images', to_jsonb(v_new), 'removed', to_jsonb(v_removed));
end;
$$;

-- Remove one photo. Removing a photo that is already gone is not an error
-- (the answer then has an empty `removed`).
create or replace function public.owner_remove_product_image(p_product_id uuid, p_url text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
  v_old text[];
  v_new text[];
begin
  v_owner := public._require_owner();
  select coalesce(images, '{}') into v_old from public.products where id = p_product_id for update;
  if not found then raise exception 'That product could not be found.'; end if;
  if p_url is null or not (p_url = any (v_old)) then
    return jsonb_build_object('product_id', p_product_id, 'images', to_jsonb(v_old), 'removed', '[]'::jsonb);
  end if;

  v_new := array_remove(v_old, p_url);
  perform public._store_product_images(p_product_id, v_new);
  perform public._write_audit(v_owner.firebase_uid, v_owner.branch_id, 'product_photo_removed',
    'product', p_product_id::text, jsonb_build_object('url', p_url, 'count', cardinality(v_new)), null);

  return jsonb_build_object('product_id', p_product_id, 'images', to_jsonb(v_new), 'removed', jsonb_build_array(p_url));
end;
$$;

-- New order of the SAME photos (the first one is the main photo).
create or replace function public.owner_set_product_image_order(p_product_id uuid, p_images text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
  v_old text[];
begin
  v_owner := public._require_owner();
  select coalesce(images, '{}') into v_old from public.products where id = p_product_id for update;
  if not found then raise exception 'That product could not be found.'; end if;
  if p_images is null
     or cardinality(p_images) <> cardinality(v_old)
     or not (p_images @> v_old and v_old @> p_images)
     or (select count(distinct u) from unnest(p_images) u) <> cardinality(p_images) then
    raise exception 'The photos were changed in the meantime. Reload the page and try again.';
  end if;

  if p_images is distinct from v_old then
    perform public._store_product_images(p_product_id, p_images);
    perform public._write_audit(v_owner.firebase_uid, v_owner.branch_id, 'product_photos_reordered',
      'product', p_product_id::text, jsonb_build_object('main', p_images[1]), null);
  end if;

  return jsonb_build_object('product_id', p_product_id, 'images', to_jsonb(p_images), 'removed', '[]'::jsonb);
end;
$$;

revoke all on function public.owner_add_product_image(uuid, text, text) from public, anon;
revoke all on function public.owner_remove_product_image(uuid, text) from public, anon;
revoke all on function public.owner_set_product_image_order(uuid, text[]) from public, anon;
grant execute on function public.owner_add_product_image(uuid, text, text) to authenticated;
grant execute on function public.owner_remove_product_image(uuid, text) to authenticated;
grant execute on function public.owner_set_product_image_order(uuid, text[]) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. Keep photos when the app saves a product
-- -----------------------------------------------------------------------------
-- App and website users act with role "authenticated" (or "anon"). For them,
-- products.images only changes through the owner functions above. Anything
-- else (the Supabase dashboard, SQL editor, service role) is left alone.
create or replace function public._guard_product_images()
returns trigger
language plpgsql
as $$
begin
  if new.images is distinct from old.images
     and coalesce(current_setting('melai.product_images_write', true), '') <> 'on'
     and coalesce(auth.jwt() ->> 'role', '') in ('authenticated', 'anon') then
    new.images := old.images;
  end if;
  return new;
end;
$$;
revoke all on function public._guard_product_images() from public, anon, authenticated;

drop trigger if exists products_guard_images on public.products;
create trigger products_guard_images before update on public.products
  for each row execute function public._guard_product_images();

-- -----------------------------------------------------------------------------
-- 5. admin_portal_products(): same as 20261009000000, plus `images`
-- -----------------------------------------------------------------------------
create or replace function public.admin_portal_products()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_branches uuid[];
begin
  perform public._require_staff();
  v_branches := public.staff_authorized_branch_ids();
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', p.id, 'name', p.name, 'sku', p.sku, 'unit', p.unit, 'price', p.price,
             'is_active', p.is_active, 'is_featured', p.is_featured,
             'category', nullif(c.label, ''),
             'images', to_jsonb(coalesce(p.images, '{}')),
             'updated_at', p.updated_at,
             'variants', (select coalesce(jsonb_agg(jsonb_build_object(
                             'id', pv.id, 'label', pv.label, 'sku', pv.sku, 'price', pv.price,
                             'stock', coalesce((select sum(bi.quantity) from public.branch_inventory bi
                                                where bi.variant_id = pv.id and bi.branch_id = any (v_branches)), 0))
                           order by pv.sort_order, pv.label), '[]'::jsonb)
                          from public.product_variants pv where pv.product_id = p.id)
           ) order by p.is_active desc, p.name), '[]'::jsonb)
    from public.products p
    left join public.product_categories c on c.id = p.category_id
  );
end;
$$;
revoke all on function public.admin_portal_products() from public, anon;
grant execute on function public.admin_portal_products() to authenticated;

-- Customers' open screens pick up new photos at once (already set up by
-- 20261001000000; repeated here so this migration stands on its own).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'products') then
    execute 'alter publication supabase_realtime add table public.products';
  end if;
end $$;

commit;
