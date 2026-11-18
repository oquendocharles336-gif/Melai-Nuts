-- =============================================================================
-- Melai Nuts — Migration 20261118070000: staff offline sync
-- =============================================================================
-- Run after 20261118060000_expiry_alerts_on_by_default.sql. Idempotent, one
-- transaction.
--
-- The staff app now keeps working offline: products added and stock received
-- or adjusted without a connection are saved on the device (SQLite) and sent
-- here when the connection returns (lib/features/staff/staff_offline_sync.dart).
--
--   1. staff_create_product_offline(...): creates a product + its default
--      variant with ids MADE ON THE DEVICE. Sending the same product twice
--      (a retry after an unclear failure) returns the first one instead of
--      creating a duplicate, and stock received offline for the new variant
--      can reference the variant id before the product reached the server.
--   2. staff_adjust_batch: an adjustment with reason "Expired" is only accepted
--      for a batch that has reached its expiry date (Asia/Manila), and must
--      remove stock. Everything else is unchanged (same signature, same
--      idempotency key handling, still recorded in stock_movements with the
--      staff member and time).
--
-- Expiry is already stored per batch (inventory_batches.expiration_date, not
-- null since 20260930000000_staff_backend.sql), so no column is added.
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1. Idempotent product creation with client-generated ids
-- -----------------------------------------------------------------------------
create or replace function public.staff_create_product_offline(
  p_product_id uuid,
  p_variant_id uuid,
  p_name text,
  p_description text,
  p_category_id uuid,
  p_price numeric,
  p_cost_price numeric,
  p_is_active boolean,
  p_branch_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_name text := trim(coalesce(p_name, ''));
  v_branch uuid;
  v_existing_variant uuid;
begin
  v_staff := public._require_product_manager();
  if p_product_id is null or p_variant_id is null then
    raise exception 'The product could not be saved (missing id). Please add it again.';
  end if;

  -- Replay: this exact product was already created by an earlier attempt.
  if exists (select 1 from public.products where id = p_product_id) then
    select id into v_existing_variant from public.product_variants
     where product_id = p_product_id order by sort_order limit 1;
    return jsonb_build_object('product_id', p_product_id,
                              'variant_id', coalesce(v_existing_variant, p_variant_id),
                              'already_created', true);
  end if;
  if exists (select 1 from public.product_variants where id = p_variant_id) then
    raise exception 'The product could not be saved (id already in use). Please add it again.';
  end if;

  if v_name = '' or length(v_name) > 120 then raise exception 'Enter a product name (up to 120 characters).'; end if;
  if p_price is null or p_price < 0 or p_price > 1000000 then raise exception 'Enter a valid price.'; end if;
  if p_cost_price is not null and (p_cost_price < 0 or p_cost_price > 1000000) then
    raise exception 'Enter a valid cost.';
  end if;
  if p_category_id is not null and not exists (select 1 from public.product_categories where id = p_category_id) then
    raise exception 'That category no longer exists.';
  end if;
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

  insert into public.products (id, category_id, name, price, description, sku, images, is_active, is_featured)
  values (p_product_id, p_category_id, v_name, p_price, coalesce(p_description, ''), null,
          '{}', coalesce(p_is_active, true), false);

  insert into public.product_variants (id, product_id, label, price, cost_price, sku, badge, sort_order)
  values (p_variant_id, p_product_id, 'Standard', p_price, p_cost_price, null, null, 0);

  -- Zero-quantity rows so the variant shows in the branch's inventory; real
  -- stock only ever arrives through the inventory functions.
  if p_branch_ids is not null then
    perform set_config('app.inventory_managed', '1', true);
    foreach v_branch in array p_branch_ids loop
      insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
      values (v_branch, p_product_id, p_variant_id, 0)
      on conflict (branch_id, product_id, variant_id) do nothing;
    end loop;
  end if;

  perform public._write_audit(v_staff.firebase_uid, v_staff.branch_id, 'product_created',
    'product', p_product_id::text,
    jsonb_build_object('name', v_name, 'price', p_price, 'is_active', coalesce(p_is_active, true),
                       'created_offline', true), null);

  return jsonb_build_object('product_id', p_product_id, 'variant_id', p_variant_id, 'already_created', false);
end;
$$;

revoke all on function public.staff_create_product_offline(uuid, uuid, text, text, uuid, numeric, numeric, boolean, uuid[]) from public, anon;
grant execute on function public.staff_create_product_offline(uuid, uuid, text, text, uuid, numeric, numeric, boolean, uuid[]) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. staff_adjust_batch: "Expired" only for a batch that has expired
-- -----------------------------------------------------------------------------
create or replace function public.staff_adjust_batch(
  p_batch_id uuid,
  p_delta int,
  p_reason text,
  p_note text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  b public.inventory_batches;
  v_reason text := trim(coalesce(p_reason, ''));
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_new int;
  v_total int;
  v_request jsonb;
  v_replay jsonb;
  v_result jsonb;
begin
  select * into b from public.inventory_batches where id = p_batch_id for update;
  if not found then raise exception 'That batch could not be found.'; end if;
  v_staff := public._require_staff(b.branch_id, 'inventory');

  -- Idempotency: after authorization (only permitted staff reach the key table).
  v_request := jsonb_build_object('batch_id', p_batch_id, 'delta', p_delta,
                                  'reason', v_reason, 'note', coalesce(trim(p_note), ''));
  v_replay := public._idem_begin(v_staff.firebase_uid, p_idempotency_key, 'adjust_batch', v_request);
  if v_replay is not null then
    return v_replay;
  end if;

  if p_delta is null or p_delta = 0 or abs(p_delta) > 100000 then raise exception 'Enter an adjustment other than zero.'; end if;
  if v_reason = '' or length(v_reason) > 100 then raise exception 'Please choose a reason for this adjustment.'; end if;

  -- Expired stock: the batch must really have reached its expiry date, and an
  -- expiry write-off can only remove units.
  if lower(v_reason) in ('expired', 'expired / disposed') then
    if b.expiration_date > v_today then
      raise exception 'Batch % has not expired yet (expires %). It cannot be adjusted as Expired.',
        b.batch_code, to_char(b.expiration_date, 'Mon DD, YYYY');
    end if;
    if p_delta > 0 then
      raise exception 'An Expired adjustment can only remove stock.';
    end if;
  end if;

  v_new := b.quantity + p_delta;
  if v_new < 0 then raise exception 'Stock cannot go below 0. Reduce the adjustment.'; end if;

  perform set_config('app.inventory_managed', '1', true);
  select quantity into v_total from public.branch_inventory
  where branch_id = b.branch_id and product_id = b.product_id and variant_id = b.variant_id for update;
  if coalesce(v_total, 0) + p_delta < 0 then raise exception 'Stock cannot go below 0. Reduce the adjustment.'; end if;

  update public.inventory_batches
  set quantity = v_new,
      initial_quantity = greatest(1, v_new,
        case when p_delta < 0 then b.initial_quantity + p_delta else b.initial_quantity end)
  where id = b.id;
  update public.branch_inventory set quantity = quantity + p_delta
  where branch_id = b.branch_id and product_id = b.product_id and variant_id = b.variant_id;

  insert into public.stock_movements
    (branch_id, product_id, variant_id, batch_id, movement_type, quantity_change, batch_quantity_after, reason, created_by)
  values (b.branch_id, b.product_id, b.variant_id, b.id, 'adjust', p_delta, v_new,
          left(v_reason || case when nullif(trim(coalesce(p_note, '')), '') is null then '' else ': ' || trim(p_note) end, 300),
          v_staff.firebase_uid);

  v_result := jsonb_build_object('previous_quantity', b.quantity, 'new_quantity', v_new, 'adjustment', p_delta);
  perform public._idem_finish(v_staff.firebase_uid, p_idempotency_key, 'adjust_batch', v_request, v_result);
  return v_result;
end;
$$;

revoke all on function public.staff_adjust_batch(uuid, int, text, text, text) from public, anon;
grant execute on function public.staff_adjust_batch(uuid, int, text, text, text) to authenticated;

commit;
