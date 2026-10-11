-- Staff product management: real writes for the staff Add/Edit Product and
-- Category screens. Customers read the same products / product_variants /
-- product_categories / branch_inventory tables, so every change here is what
-- the customer app sees. Prices, active state and stock are enforced by the
-- database, not by the client.
--
-- Idempotent: safe to re-run. Requires 20260930000000 + 20260930010000.

begin;

-- Active staff (any role) may read inactive products too, so a deactivated
-- product stays editable. Customers still only see is_active products.
create or replace function public.is_active_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.staff_members s
    where s.firebase_uid = public.current_firebase_uid() and s.account_status = 'active'
  )
$$;
revoke all on function public.is_active_staff() from public;
grant execute on function public.is_active_staff() to authenticated;

drop policy if exists "staff read all products" on public.products;
create policy "staff read all products" on public.products
  for select using (public.is_active_staff());

-- Caller must be an active staff member holding manage_products (owners hold
-- everything). Raises a staff-readable message otherwise.
create or replace function public._require_product_manager()
returns public.staff_members
language plpgsql
stable
security definer
set search_path = public
as $$
declare v public.staff_members;
begin
  v := public._require_staff();
  if not public.staff_has_permission('manage_products') then
    raise exception 'You do not have permission to manage products.';
  end if;
  return v;
end;
$$;

-- Create (p_product_id null) or update a product, its variants and the
-- branches it is stocked in. p_variants: [{id?, label, price, cost_price?, sku?, badge?}]
-- Variants omitted from the list are removed only if they have no stock rows
-- or order history; otherwise the call fails rather than orphaning data.
create or replace function public.staff_save_product(
  p_product_id uuid,
  p_name text,
  p_description text,
  p_category_id uuid,
  p_price numeric,
  p_sku text,
  p_images text[],
  p_is_active boolean,
  p_is_featured boolean,
  p_variants jsonb,
  p_branch_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_id uuid := p_product_id;
  v_name text := trim(coalesce(p_name, ''));
  v jsonb;
  v_vid uuid;
  v_keep uuid[] := '{}';
  v_branch uuid;
  v_sort int := 0;
begin
  v_staff := public._require_product_manager();
  if v_name = '' or length(v_name) > 120 then raise exception 'Enter a product name (up to 120 characters).'; end if;
  if p_price is null or p_price < 0 or p_price > 1000000 then raise exception 'Enter a valid price.'; end if;
  if p_category_id is not null and not exists (select 1 from public.product_categories where id = p_category_id) then
    raise exception 'That category no longer exists.';
  end if;

  -- Branch availability: staff may only touch their own branch.
  if p_branch_ids is not null then
    foreach v_branch in array p_branch_ids loop
      if v_staff.role <> 'owner' and v_staff.branch_id is distinct from v_branch then
        raise exception 'You can only make products available in your assigned branch.';
      end if;
      if not exists (select 1 from public.branches where id = v_branch) then
        raise exception 'A selected branch no longer exists.';
      end if;
    end loop;
  end if;

  if v_id is null then
    insert into public.products (category_id, name, price, description, sku, images, is_active, is_featured)
    values (p_category_id, v_name, p_price, coalesce(p_description, ''), nullif(trim(coalesce(p_sku, '')), ''),
            coalesce(p_images, '{}'), coalesce(p_is_active, true), coalesce(p_is_featured, false))
    returning id into v_id;
  else
    update public.products set
      category_id = p_category_id, name = v_name, price = p_price,
      description = coalesce(p_description, ''), sku = nullif(trim(coalesce(p_sku, '')), ''),
      images = coalesce(p_images, '{}'), is_active = coalesce(p_is_active, true),
      is_featured = coalesce(p_is_featured, false), updated_at = now()
    where id = v_id;
    if not found then raise exception 'That product could not be found.'; end if;
  end if;

  -- Variants (always keep at least a default one so the product is purchasable).
  if p_variants is null or jsonb_typeof(p_variants) <> 'array' or jsonb_array_length(p_variants) = 0 then
    p_variants := jsonb_build_array(jsonb_build_object('label', 'Standard', 'price', p_price));
  end if;
  for v in select * from jsonb_array_elements(p_variants) loop
    if coalesce(trim(v->>'label'), '') = '' then raise exception 'Every variant needs a label.'; end if;
    if (v->>'price') is null or (v->>'price')::numeric < 0 then raise exception 'Every variant needs a valid price.'; end if;
    v_vid := nullif(v->>'id', '')::uuid;
    if v_vid is not null and exists (select 1 from public.product_variants where id = v_vid and product_id = v_id) then
      update public.product_variants set
        label = trim(v->>'label'), price = (v->>'price')::numeric,
        cost_price = nullif(v->>'cost_price', '')::numeric,
        sku = nullif(trim(coalesce(v->>'sku', '')), ''), badge = nullif(trim(coalesce(v->>'badge', '')), ''),
        sort_order = v_sort
      where id = v_vid;
    else
      insert into public.product_variants (product_id, label, price, cost_price, sku, badge, sort_order)
      values (v_id, trim(v->>'label'), (v->>'price')::numeric, nullif(v->>'cost_price', '')::numeric,
              nullif(trim(coalesce(v->>'sku', '')), ''), nullif(trim(coalesce(v->>'badge', '')), ''), v_sort)
      returning id into v_vid;
    end if;
    v_keep := v_keep || v_vid;
    v_sort := v_sort + 1;
  end loop;

  begin
    delete from public.product_variants where product_id = v_id and id <> all (v_keep);
  exception when foreign_key_violation then
    raise exception 'A variant that has stock or order history cannot be removed. Deactivate the product instead.';
  end;

  -- Zero-quantity rows make the variant appear in the branch's inventory
  -- screens; real stock only ever arrives through the inventory functions.
  if p_branch_ids is not null then
    perform set_config('app.inventory_managed', '1', true);
    foreach v_branch in array p_branch_ids loop
      insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
      select v_branch, v_id, pv.id, 0 from public.product_variants pv where pv.product_id = v_id
      on conflict (branch_id, product_id, variant_id) do nothing;
    end loop;
  end if;

  perform public._write_audit(v_staff.firebase_uid, v_staff.branch_id,
    case when p_product_id is null then 'product_created' else 'product_updated' end,
    'product', v_id::text, jsonb_build_object('name', v_name, 'price', p_price, 'is_active', coalesce(p_is_active, true)), null);
  return v_id;
end;
$$;

create or replace function public.staff_set_product_active(p_product_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_staff public.staff_members;
begin
  v_staff := public._require_product_manager();
  update public.products set is_active = coalesce(p_is_active, false), updated_at = now() where id = p_product_id;
  if not found then raise exception 'That product could not be found.'; end if;
  perform public._write_audit(v_staff.firebase_uid, v_staff.branch_id, 'product_active_changed',
    'product', p_product_id::text, jsonb_build_object('is_active', p_is_active), null);
end;
$$;

create or replace function public.staff_save_category(p_category_id uuid, p_label text, p_icon_name text, p_sort_order int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_id uuid := p_category_id;
  v_label text := trim(coalesce(p_label, ''));
begin
  v_staff := public._require_product_manager();
  if v_label = '' or length(v_label) > 60 then raise exception 'Enter a category name (up to 60 characters).'; end if;
  if v_id is null then
    insert into public.product_categories (label, icon_name, sort_order)
    values (v_label, coalesce(nullif(trim(coalesce(p_icon_name, '')), ''), 'category'), coalesce(p_sort_order, 0))
    returning id into v_id;
  else
    update public.product_categories set label = v_label,
      icon_name = coalesce(nullif(trim(coalesce(p_icon_name, '')), ''), icon_name),
      sort_order = coalesce(p_sort_order, sort_order)
    where id = v_id;
    if not found then raise exception 'That category could not be found.'; end if;
  end if;
  perform public._write_audit(v_staff.firebase_uid, v_staff.branch_id, 'category_saved', 'category', v_id::text,
    jsonb_build_object('label', v_label), null);
  return v_id;
end;
$$;

revoke all on function public._require_product_manager() from public, anon;
revoke all on function public.staff_save_product(uuid, text, text, uuid, numeric, text, text[], boolean, boolean, jsonb, uuid[]) from public, anon;
revoke all on function public.staff_set_product_active(uuid, boolean) from public, anon;
revoke all on function public.staff_save_category(uuid, text, text, int) from public, anon;
grant execute on function public.staff_save_product(uuid, text, text, uuid, numeric, text, text[], boolean, boolean, jsonb, uuid[]) to authenticated;
grant execute on function public.staff_set_product_active(uuid, boolean) to authenticated;
grant execute on function public.staff_save_category(uuid, text, text, int) to authenticated;

-- Customer realtime: catalog + stock changes reach open customer screens.
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['products', 'product_variants', 'branch_inventory'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

commit;
