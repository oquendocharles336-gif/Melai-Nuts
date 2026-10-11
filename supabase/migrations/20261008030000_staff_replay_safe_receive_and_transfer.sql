-- =============================================================================
-- Melai Nuts — replay-safe receive-batch and transfer responses
-- =============================================================================
-- Follows 20261008020000 (idempotency keys for adjustments / transfer requests).
--
-- staff_respond_transfer (ship | reject | cancel | receive)
--   Already a guarded state machine, so it never double-applied — but a REPLAY
--   (lost response, double tap, queued retry) failed with "no longer waiting".
--   It is now idempotent by OUTCOME: asking for the state the transfer is
--   already in (ship on in_transit, reject on rejected, cancel on cancelled,
--   receive on received) succeeds as a no-op. Authorization still runs first,
--   and a genuinely conflicting action (e.g. ship a rejected transfer) still
--   raises. No key needed, so it also covers plain double taps.
--
-- staff_receive_batch
--   Could never double-apply (unique batch code rolls the call back) but a
--   replay raised "Batch code already exists". It now accepts the optional
--   p_idempotency_key from 20261008020000: same key + same request returns the
--   ORIGINAL batch id; same key + different request is refused.
--
-- Safe to run more than once. Requires 20261008020000.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- staff_respond_transfer: replay of an already-applied action is a no-op
-- -----------------------------------------------------------------------------
create or replace function public.staff_respond_transfer(p_transfer_id text, p_action text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  t public.stock_transfers;
  v_lines jsonb;
  l jsonb;
  v_new int;
  v_from_stock int;
  v_code text;
begin
  select * into t from public.stock_transfers where id = p_transfer_id for update;
  if not found then raise exception 'That transfer could not be found.'; end if;

  if p_action in ('ship', 'reject') then
    v_staff := public._require_staff(t.from_branch_id, 'inventory');
    -- Replay: the transfer is already in the state this action produces.
    if (p_action = 'ship' and t.status = 'in_transit')
       or (p_action = 'reject' and t.status = 'rejected') then
      return;
    end if;
    if t.status <> 'requested' then raise exception 'This transfer is no longer waiting for approval.'; end if;
  elsif p_action in ('cancel', 'receive') then
    v_staff := public._require_staff(t.to_branch_id, 'inventory');
    if (p_action = 'cancel' and t.status = 'cancelled')
       or (p_action = 'receive' and t.status = 'received') then
      return;
    end if;
    if p_action = 'cancel' and t.status <> 'requested' then raise exception 'Only a pending request can be cancelled.'; end if;
    if p_action = 'receive' and t.status <> 'in_transit' then raise exception 'This transfer is not on its way.'; end if;
  else
    raise exception 'Unsupported transfer action.';
  end if;

  perform set_config('app.inventory_managed', '1', true);

  if p_action = 'reject' then
    update public.stock_transfers set status = 'rejected', reviewed_by = v_staff.firebase_uid where id = t.id;

  elsif p_action = 'cancel' then
    update public.stock_transfers set status = 'cancelled' where id = t.id;

  elsif p_action = 'ship' then
    select quantity into v_from_stock from public.branch_inventory
    where branch_id = t.from_branch_id and product_id = t.product_id and variant_id = t.variant_id for update;
    if coalesce(v_from_stock, 0) < t.quantity then
      raise exception 'Not enough stock at your branch to ship this transfer.';
    end if;
    v_lines := public._consume_batches_fefo(t.from_branch_id, t.product_id, t.variant_id, t.quantity,
                                            'transfer_out', t.id, v_staff.firebase_uid, true);
    update public.branch_inventory set quantity = quantity - t.quantity
    where branch_id = t.from_branch_id and product_id = t.product_id and variant_id = t.variant_id;
    for l in select * from jsonb_array_elements(v_lines) loop
      insert into public.stock_transfer_batches (transfer_id, batch_code, received_date, expiration_date, quantity)
      values (t.id, l ->> 'batch_code', (l ->> 'received_date')::date, (l ->> 'expiration_date')::date, (l ->> 'quantity')::int);
    end loop;
    update public.stock_transfers
    set status = 'in_transit', reviewed_by = v_staff.firebase_uid, shipped_at = now()
    where id = t.id;

  else -- receive
    insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
    values (t.to_branch_id, t.product_id, t.variant_id, 0)
    on conflict (branch_id, product_id, variant_id) do nothing;
    update public.branch_inventory set quantity = quantity + t.quantity
    where branch_id = t.to_branch_id and product_id = t.product_id and variant_id = t.variant_id;

    for l in
      select to_jsonb(sb) from public.stock_transfer_batches sb where sb.transfer_id = t.id
    loop
      v_code := l ->> 'batch_code';
      insert into public.inventory_batches
        (branch_id, product_id, variant_id, batch_code, received_date, expiration_date, quantity, initial_quantity, created_by)
      values (t.to_branch_id, t.product_id, t.variant_id, v_code,
              (l ->> 'received_date')::date, (l ->> 'expiration_date')::date,
              (l ->> 'quantity')::int, (l ->> 'quantity')::int, v_staff.firebase_uid)
      on conflict (branch_id, variant_id, batch_code) do update
        set quantity = public.inventory_batches.quantity + excluded.quantity,
            initial_quantity = public.inventory_batches.initial_quantity + excluded.initial_quantity,
            expiration_date = least(public.inventory_batches.expiration_date, excluded.expiration_date)
      returning quantity into v_new;
      insert into public.stock_movements
        (branch_id, product_id, variant_id, movement_type, quantity_change, batch_quantity_after, reference, created_by)
      values (t.to_branch_id, t.product_id, t.variant_id, 'transfer_in', (l ->> 'quantity')::int, v_new, t.id, v_staff.firebase_uid);
    end loop;

    update public.stock_transfers
    set status = 'received', received_by = v_staff.firebase_uid, received_at = now()
    where id = t.id;
  end if;
end;
$$;

revoke all on function public.staff_respond_transfer(text, text) from public, anon;
grant execute on function public.staff_respond_transfer(text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- staff_receive_batch: + p_idempotency_key
-- -----------------------------------------------------------------------------
drop function if exists public.staff_receive_batch(uuid, uuid, text, int, date, date, int, boolean);

create or replace function public.staff_receive_batch(
  p_branch_id uuid,
  p_variant_id uuid,
  p_batch_code text,
  p_quantity int,
  p_expiration_date date,
  p_received_date date default null,
  p_restock_threshold int default null,
  p_assign_existing boolean default false,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_variant record;
  v_code text := trim(coalesce(p_batch_code, ''));
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_received date;
  v_batch_id uuid;
  v_current int;
  v_batched int;
  v_request jsonb;
  v_replay jsonb;
begin
  v_staff := public._require_staff(p_branch_id, 'inventory');

  -- Idempotency: after authorization, before validation, so a replay made after
  -- the expiry date has passed still returns the original batch.
  v_request := jsonb_build_object('branch', p_branch_id, 'variant', p_variant_id, 'code', v_code,
                                  'quantity', p_quantity, 'expiration', p_expiration_date,
                                  'received', p_received_date, 'threshold', p_restock_threshold,
                                  'assign_existing', coalesce(p_assign_existing, false));
  v_replay := public._idem_begin(v_staff.firebase_uid, p_idempotency_key, 'receive_batch', v_request);
  if v_replay is not null then
    return (v_replay ->> 'batch_id')::uuid;
  end if;

  if v_code = '' or length(v_code) > 40 then raise exception 'Please enter a batch code (up to 40 characters).'; end if;
  if p_quantity is null or p_quantity <= 0 or p_quantity > 100000 then raise exception 'Quantity must be between 1 and 100000.'; end if;
  v_received := coalesce(p_received_date, v_today);
  if v_received > v_today then raise exception 'The received date cannot be in the future.'; end if;
  if p_expiration_date is null or p_expiration_date <= v_today then
    raise exception 'The expiration date must be in the future.';
  end if;
  if p_expiration_date < v_received then raise exception 'The expiration date cannot be before the received date.'; end if;

  select pv.id, pv.product_id into v_variant
  from public.product_variants pv join public.products p on p.id = pv.product_id
  where pv.id = p_variant_id and p.is_active;
  if not found then raise exception 'That product variant could not be found.'; end if;

  perform set_config('app.inventory_managed', '1', true);

  insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
  values (p_branch_id, v_variant.product_id, p_variant_id, 0)
  on conflict (branch_id, product_id, variant_id) do nothing;
  select quantity into v_current from public.branch_inventory
  where branch_id = p_branch_id and product_id = v_variant.product_id and variant_id = p_variant_id
  for update;

  if p_assign_existing then
    select coalesce(sum(quantity), 0) into v_batched from public.inventory_batches
    where branch_id = p_branch_id and variant_id = p_variant_id;
    if p_quantity > v_current - v_batched then
      raise exception 'Only % unit(s) at this branch are not yet assigned to a batch.', greatest(v_current - v_batched, 0);
    end if;
  else
    update public.branch_inventory set quantity = quantity + p_quantity
    where branch_id = p_branch_id and product_id = v_variant.product_id and variant_id = p_variant_id;
  end if;

  begin
    insert into public.inventory_batches
      (branch_id, product_id, variant_id, batch_code, received_date, expiration_date, quantity, initial_quantity, created_by)
    values (p_branch_id, v_variant.product_id, p_variant_id, v_code, v_received, p_expiration_date,
            p_quantity, p_quantity, v_staff.firebase_uid)
    returning id into v_batch_id;
  exception when unique_violation then
    raise exception 'Batch code % already exists for this product at this branch.', v_code;
  end;

  insert into public.stock_movements
    (branch_id, product_id, variant_id, batch_id, movement_type, quantity_change, batch_quantity_after, reason, created_by)
  values (p_branch_id, v_variant.product_id, p_variant_id, v_batch_id,
          case when p_assign_existing then 'assign' else 'receive' end,
          case when p_assign_existing then 0 else p_quantity end, p_quantity,
          case when p_assign_existing then 'Assigned existing stock to a batch' else 'Batch received' end,
          v_staff.firebase_uid);

  if p_restock_threshold is not null then
    if p_restock_threshold < 0 or p_restock_threshold > 100000 then raise exception 'Invalid restock threshold.'; end if;
    insert into public.stock_thresholds (branch_id, variant_id, restock_threshold)
    values (p_branch_id, p_variant_id, p_restock_threshold)
    on conflict (branch_id, variant_id) do update
      set restock_threshold = excluded.restock_threshold, updated_at = now();
  end if;

  perform public._idem_finish(v_staff.firebase_uid, p_idempotency_key, 'receive_batch', v_request,
                              jsonb_build_object('batch_id', v_batch_id));
  return v_batch_id;
end;
$$;

revoke all on function public.staff_receive_batch(uuid, uuid, text, int, date, date, int, boolean, text) from public, anon;
grant execute on function public.staff_receive_batch(uuid, uuid, text, int, date, date, int, boolean, text) to authenticated;

commit;
