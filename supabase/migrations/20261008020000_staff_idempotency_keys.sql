-- =============================================================================
-- Melai Nuts — idempotency keys for stock adjustments and transfer requests
-- =============================================================================
-- Problem: staff_adjust_batch (+/- delta) and staff_request_transfer are not
-- idempotent. If a response is lost (timeout, dropped connection) and the app
-- retries — or an offline queue replays — the change is applied twice.
-- Verified before this migration: the same adjustment sent twice was applied
-- 2x, and the same transfer request created 2 rows.
--
-- Fix: both RPCs accept an optional p_idempotency_key. With a key:
--   * first call  -> runs normally and stores (key, request hash, result)
--   * same key + same request     -> returns the ORIGINAL result, changes nothing
--   * same key + DIFFERENT request -> refused (a key identifies one request)
-- Keys are scoped per staff member. Without a key the behaviour is unchanged,
-- so existing callers keep working.
--
-- Safe to run more than once. Requires 20260930010000 (staff foundation).
-- =============================================================================

begin;

create table if not exists public.staff_request_keys (
  firebase_uid    text        not null,
  idempotency_key text        not null,
  operation       text        not null,
  request_hash    text        not null,
  result          jsonb       not null,
  created_at      timestamptz not null default now(),
  primary key (firebase_uid, idempotency_key),
  constraint staff_request_keys_key_length check (char_length(idempotency_key) between 8 and 100)
);

create index if not exists staff_request_keys_created_at_idx
  on public.staff_request_keys (created_at);

-- Internal bookkeeping: no client ever reads or writes this directly.
alter table public.staff_request_keys enable row level security;
revoke all on public.staff_request_keys from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Helpers (internal; not callable by clients)
-- -----------------------------------------------------------------------------

-- Returns the stored result when this exact request was already processed,
-- NULL when it is new. Raises when the key was used for a different request.
-- Takes a per-key advisory lock so two simultaneous duplicates serialize.
create or replace function public._idem_begin(
  p_uid text,
  p_key text,
  p_operation text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.staff_request_keys;
  v_hash text := encode(sha256(convert_to(p_request::text, 'UTF8')), 'hex');
begin
  if p_key is null then
    return null;
  end if;
  if char_length(p_key) < 8 or char_length(p_key) > 100 then
    raise exception 'The request key is not valid.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_uid || ':' || p_key, 0));

  select * into v_row
  from public.staff_request_keys
  where firebase_uid = p_uid and idempotency_key = p_key;

  if not found then
    -- Housekeeping: a few expired keys per call keeps the table small.
    delete from public.staff_request_keys
    where ctid in (
      select ctid from public.staff_request_keys
      where created_at < now() - interval '30 days'
      limit 20
    );
    return null;
  end if;

  if v_row.operation <> p_operation or v_row.request_hash <> v_hash then
    raise exception 'This request key was already used for a different request.';
  end if;
  return v_row.result;
end;
$$;

create or replace function public._idem_finish(
  p_uid text,
  p_key text,
  p_operation text,
  p_request jsonb,
  p_result jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_key is null then
    return;
  end if;
  insert into public.staff_request_keys (firebase_uid, idempotency_key, operation, request_hash, result)
  values (p_uid, p_key, p_operation,
          encode(sha256(convert_to(p_request::text, 'UTF8')), 'hex'), p_result);
end;
$$;

revoke all on function public._idem_begin(text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public._idem_finish(text, text, text, jsonb, jsonb) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- staff_adjust_batch: + p_idempotency_key
-- -----------------------------------------------------------------------------
drop function if exists public.staff_adjust_batch(uuid, int, text, text);

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

-- -----------------------------------------------------------------------------
-- staff_request_transfer: + p_idempotency_key
-- -----------------------------------------------------------------------------
drop function if exists public.staff_request_transfer(uuid, uuid, uuid, int, text);

create or replace function public.staff_request_transfer(
  p_from_branch_id uuid,
  p_to_branch_id uuid,
  p_variant_id uuid,
  p_quantity int,
  p_note text default null,
  p_idempotency_key text default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_product uuid;
  v_available int;
  v_id text;
  v_request jsonb;
  v_replay jsonb;
begin
  -- The requester works at the DESTINATION branch.
  v_staff := public._require_staff(p_to_branch_id, 'inventory');

  v_request := jsonb_build_object('from', p_from_branch_id, 'to', p_to_branch_id,
                                  'variant', p_variant_id, 'quantity', p_quantity,
                                  'note', coalesce(trim(p_note), ''));
  v_replay := public._idem_begin(v_staff.firebase_uid, p_idempotency_key, 'request_transfer', v_request);
  if v_replay is not null then
    return v_replay ->> 'transfer_id';
  end if;

  if p_from_branch_id is null or p_to_branch_id is null or p_from_branch_id = p_to_branch_id then
    raise exception 'Choose a different branch to transfer from.';
  end if;
  if not exists (select 1 from public.branches where id = p_from_branch_id) then
    raise exception 'That branch could not be found.';
  end if;
  if p_quantity is null or p_quantity <= 0 or p_quantity > 100000 then raise exception 'Quantity must be between 1 and 100000.'; end if;
  select pv.product_id into v_product
  from public.product_variants pv join public.products p on p.id = pv.product_id
  where pv.id = p_variant_id and p.is_active;
  if v_product is null then raise exception 'That product variant could not be found.'; end if;

  select coalesce(quantity, 0) into v_available from public.branch_inventory
  where branch_id = p_from_branch_id and variant_id = p_variant_id;
  if coalesce(v_available, 0) < p_quantity then
    raise exception 'The source branch only has % of this item.', coalesce(v_available, 0);
  end if;

  insert into public.stock_transfers
    (from_branch_id, to_branch_id, product_id, variant_id, quantity, note, requested_by)
  values (p_from_branch_id, p_to_branch_id, v_product, p_variant_id, p_quantity,
          left(coalesce(trim(p_note), ''), 300), v_staff.firebase_uid)
  returning id into v_id;

  perform public._idem_finish(v_staff.firebase_uid, p_idempotency_key, 'request_transfer', v_request,
                              jsonb_build_object('transfer_id', v_id));
  return v_id;
end;
$$;

revoke all on function public.staff_request_transfer(uuid, uuid, uuid, int, text, text) from public, anon;
grant execute on function public.staff_request_transfer(uuid, uuid, uuid, int, text, text) to authenticated;

commit;
