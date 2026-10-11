-- =============================================================================
-- Melai Nuts — Migration 20261002010000
-- Delivery module: real dispatches built from real orders.
--
-- Replaces the Delivery feature's frontend-only simulation with a real
-- `deliveries` / `delivery_stops` backend. There is still no GPS/routing
-- provider wired in anywhere in this app, so per-leg distance/time here is
-- a simple, honestly-labeled heuristic (not real routing) — see
-- `staff_create_delivery` below.
--
-- RUN ORDER: ... -> 20261002000000_product_sales_30d.sql -> THIS FILE.
-- Safe to re-run (idempotent) and atomic (one transaction).
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 0. Order state machine: allow a cancelled delivery to return its order to
--    'confirmed' so it can be redispatched. Every other rule from
--    `enforce_order_transition` (20260928010000_order_integrity.sql) is kept
--    verbatim; this just adds one explicit backward edge.
-- -----------------------------------------------------------------------------
create or replace function public.enforce_order_transition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old int;
  v_new int;
begin
  if new.status = old.status then return new; end if;

  if old.status in ('cancelled', 'refunded') then
    raise exception 'Order % is % and can no longer change status.', old.id, old.status;
  end if;

  if old.status = 'completed' then
    if new.status <> 'refundRequested' then
      raise exception 'A completed order can only move to refundRequested (not %).', new.status;
    end if;
    return new;
  end if;

  if old.status = 'refundRequested' then
    if new.status not in ('refunded', 'completed') then
      raise exception 'A refund-requested order can only become refunded or return to completed (not %).', new.status;
    end if;
    return new;
  end if;

  -- From here `old` is an active (unfulfilled) status.
  if new.status in ('refundRequested', 'refunded') then
    raise exception 'Only a completed order can be refunded.';
  end if;
  if new.status = 'cancelled' then return new; end if;

  -- A delivery dispatch was cancelled: the order returns to the kitchen
  -- queue so staff can redispatch it on a new delivery. The only backward
  -- edge in this state machine, and only this one.
  if old.status = 'outForDelivery' and new.status = 'confirmed' then
    return new;
  end if;

  if new.status = 'readyForPickup' and new.is_delivery then
    raise exception 'A delivery order cannot be ready for pickup.';
  end if;
  if new.status = 'outForDelivery' and not new.is_delivery then
    raise exception 'A pickup order cannot be out for delivery.';
  end if;

  v_old := case old.status when 'pending' then 1 when 'confirmed' then 2 when 'preparing' then 3
                           when 'readyForPickup' then 4 when 'outForDelivery' then 4 end;
  v_new := case new.status when 'pending' then 1 when 'confirmed' then 2 when 'preparing' then 3
                           when 'readyForPickup' then 4 when 'outForDelivery' then 4 when 'completed' then 5 end;
  if v_new is null or v_new <= v_old then
    raise exception 'Order status cannot move from % to %.', old.status, new.status;
  end if;

  if new.status = 'completed' and new.total > 0 and not exists (
       select 1 from public.payments p where p.order_id = new.id and p.status = 'success') then
    raise exception 'Order % cannot be completed until its payment is confirmed.', new.id;
  end if;

  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 1. Tables
-- -----------------------------------------------------------------------------
create sequence if not exists public.delivery_code_seq start 1001;

create table if not exists public.deliveries (
  id text primary key default ('DEL-' || nextval('public.delivery_code_seq')::text),
  branch_id uuid not null references public.branches(id),
  branch_name text not null,
  vehicle text not null,
  rider_name text not null,
  status text not null default 'optimized'
    check (status in ('pending', 'optimized', 'dispatched', 'inTransit', 'completed', 'cancelled')),
  created_by text references public.staff_members(firebase_uid),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists deliveries_set_updated_at on public.deliveries;
create trigger deliveries_set_updated_at before update on public.deliveries
  for each row execute function public.set_updated_at();
create index if not exists deliveries_branch_time_idx on public.deliveries (branch_id, created_at desc);

create table if not exists public.delivery_stops (
  id uuid primary key default gen_random_uuid(),
  delivery_id text not null references public.deliveries(id) on delete cascade,
  order_id text not null references public.orders(id),
  sequence_index int not null,
  distance_from_previous_km numeric(6, 2) not null default 0,
  travel_minutes_from_previous int not null default 0,
  eta_label text,
  status text not null default 'pending'
    check (status in ('pending', 'enRoute', 'delivered', 'delayed', 'skipped')),
  issue_reason text,
  proof_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists delivery_stops_set_updated_at on public.delivery_stops;
create trigger delivery_stops_set_updated_at before update on public.delivery_stops
  for each row execute function public.set_updated_at();
create index if not exists delivery_stops_delivery_idx on public.delivery_stops (delivery_id, sequence_index);
create index if not exists delivery_stops_order_idx on public.delivery_stops (order_id);

-- -----------------------------------------------------------------------------
-- 2. RLS: deny direct table access; everything goes through the RPCs below
--    (same pattern as `staff_audit_logs` / other operational tables).
-- -----------------------------------------------------------------------------
alter table public.deliveries enable row level security;
alter table public.delivery_stops enable row level security;
revoke all on public.deliveries from anon, authenticated;
revoke all on public.delivery_stops from anon, authenticated;

drop policy if exists "no direct access" on public.deliveries;
create policy "no direct access" on public.deliveries for all to authenticated using (false) with check (false);
drop policy if exists "no direct access" on public.delivery_stops;
create policy "no direct access" on public.delivery_stops for all to authenticated using (false) with check (false);

-- -----------------------------------------------------------------------------
-- 3. Shared jsonb read model for one delivery (used by create + list)
-- -----------------------------------------------------------------------------
create or replace function public._delivery_to_jsonb(p_delivery_id text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', d.id,
    'branch', d.branch_name,
    'branch_id', d.branch_id,
    'vehicle', d.vehicle,
    'rider_name', d.rider_name,
    'status', d.status,
    'created_at', d.created_at,
    'stops', (
      select coalesce(jsonb_agg(to_jsonb(s) order by s.sequence_index), '[]'::jsonb)
      from (
        select
          ds.id,
          o.id as order_id,
          coalesce(nullif(cp.full_name, ''), 'Customer') as customer_name,
          coalesce(o.delivery_address_text, 'Address not provided') as address,
          ds.sequence_index,
          ds.distance_from_previous_km,
          ds.travel_minutes_from_previous,
          ds.eta_label as eta,
          ds.status,
          ds.issue_reason,
          ds.proof_note,
          (select coalesce(jsonb_agg(
                     oi.quantity::text || 'x ' || oi.product_name ||
                     case when oi.variant_label is null or oi.variant_label = '' or oi.variant_label = 'Regular'
                          then '' else ' (' || oi.variant_label || ')' end
                   ), '[]'::jsonb)
           from public.order_items oi where oi.order_id = o.id) as items
        from public.delivery_stops ds
        join public.orders o on o.id = ds.order_id
        left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
        where ds.delivery_id = d.id
      ) s
    )
  )
  from public.deliveries d
  where d.id = p_delivery_id
$$;

-- -----------------------------------------------------------------------------
-- 4. Orders eligible to become delivery stops
-- -----------------------------------------------------------------------------
create or replace function public.staff_list_deliverable_orders(p_branch_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branch uuid;
begin
  v_staff := public._require_staff();
  v_branch := case when v_staff.role = 'owner' then p_branch_id else v_staff.branch_id end;
  if v_branch is null then raise exception 'Please choose a branch first.'; end if;
  if not (v_branch = any (public.staff_authorized_branch_ids())) then
    raise exception 'You can only work in your assigned branch.';
  end if;

  return (
    select coalesce(jsonb_agg(x.j order by x.created_at), '[]'::jsonb)
    from (
      select o.created_at,
        jsonb_build_object(
          'order_id', o.id,
          'customer_name', coalesce(nullif(cp.full_name, ''), 'Customer'),
          'address', coalesce(o.delivery_address_text, 'Address not provided'),
          'created_at', o.created_at,
          'items', (select coalesce(jsonb_agg(
                       oi.quantity::text || 'x ' || oi.product_name ||
                       case when oi.variant_label is null or oi.variant_label = '' or oi.variant_label = 'Regular'
                            then '' else ' (' || oi.variant_label || ')' end
                     ), '[]'::jsonb)
                   from public.order_items oi where oi.order_id = o.id)
        ) as j
      from public.orders o
      left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
      where o.branch_id = v_branch
        and o.is_delivery
        and o.status in ('confirmed', 'preparing')
        and not exists (
          select 1 from public.delivery_stops ds
          join public.deliveries d on d.id = ds.delivery_id
          where ds.order_id = o.id and d.status not in ('cancelled', 'completed')
        )
      order by o.created_at
    ) x
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Create a delivery from a chosen set of real orders
--
--    No geocoding/routing API is available in this project, so the
--    per-stop distance/time below is a simple, clearly-labeled estimate
--    (a fixed per-stop increment, like a delivery person working down a
--    short local route) — NOT real GPS/turn-by-turn routing.
-- -----------------------------------------------------------------------------
create or replace function public.staff_create_delivery(
  p_branch_id uuid,
  p_vehicle text,
  p_rider_name text,
  p_order_ids text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branch_name text;
  v_delivery_id text;
  v_order_id text;
  v_order public.orders;
  v_idx int := 0;
  v_distance numeric(6, 2);
  v_minutes int;
  v_eta_minutes int := 0;
  v_now timestamptz := now();
  v_eta timestamptz;
begin
  v_staff := public._require_staff(p_branch_id);
  if coalesce(trim(p_vehicle), '') = '' then raise exception 'Please enter a vehicle.'; end if;
  if coalesce(trim(p_rider_name), '') = '' then raise exception 'Please enter a rider name.'; end if;
  if p_order_ids is null or array_length(p_order_ids, 1) is null then
    raise exception 'Please choose at least one order for this delivery.';
  end if;

  select name into v_branch_name from public.branches where id = p_branch_id;
  if v_branch_name is null then raise exception 'Please choose a valid branch.'; end if;

  insert into public.deliveries (branch_id, branch_name, vehicle, rider_name, status, created_by)
  values (p_branch_id, v_branch_name, trim(p_vehicle), trim(p_rider_name), 'optimized', v_staff.firebase_uid)
  returning id into v_delivery_id;

  foreach v_order_id in array p_order_ids loop
    select * into v_order from public.orders where id = v_order_id for update;
    if not found then
      raise exception 'Order % could not be found.', v_order_id;
    end if;
    if v_order.branch_id is distinct from p_branch_id then
      raise exception 'Order % does not belong to the chosen branch.', v_order_id;
    end if;
    if not v_order.is_delivery then
      raise exception 'Order % is not a delivery order.', v_order_id;
    end if;
    if v_order.status not in ('confirmed', 'preparing') then
      raise exception 'Order % is % and can no longer be dispatched.', v_order_id, v_order.status;
    end if;
    if exists (
      select 1 from public.delivery_stops ds
      join public.deliveries d on d.id = ds.delivery_id
      where ds.order_id = v_order_id and d.status not in ('cancelled', 'completed')
    ) then
      raise exception 'Order % is already part of another active delivery.', v_order_id;
    end if;

    -- Honest, simple per-stop estimate: a fixed base distance/time per leg
    -- (no real geocoding/routing is available to this app).
    v_distance := round((1.5 + v_idx * 1.2)::numeric, 1);
    v_minutes := round(v_distance / 20.0 * 60.0)::int; -- ~20 km/h average local delivery speed
    v_eta_minutes := v_eta_minutes + v_minutes;
    v_eta := v_now + make_interval(mins => v_eta_minutes);

    insert into public.delivery_stops (
      delivery_id, order_id, sequence_index, distance_from_previous_km,
      travel_minutes_from_previous, eta_label, status
    ) values (
      v_delivery_id, v_order_id, v_idx, v_distance, v_minutes,
      to_char(v_eta, 'FMHH12:MI AM'), 'pending'
    );

    update public.orders set status = 'outForDelivery', rider_name = trim(p_rider_name) where id = v_order_id;

    v_idx := v_idx + 1;
  end loop;

  return public._delivery_to_jsonb(v_delivery_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. List deliveries the caller may see
-- -----------------------------------------------------------------------------
create or replace function public.staff_get_deliveries(p_branch_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branches uuid[];
begin
  v_staff := public._require_staff();
  v_branches := public.staff_authorized_branch_ids();
  if p_branch_id is not null then
    if not (p_branch_id = any (v_branches)) then
      raise exception 'You can only work in your assigned branch.';
    end if;
    v_branches := array[p_branch_id];
  end if;

  return (
    select coalesce(jsonb_agg(public._delivery_to_jsonb(d.id) order by d.created_at desc), '[]'::jsonb)
    from public.deliveries d
    where d.branch_id = any (v_branches)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 6b. Mark a delivery as dispatched (handed off to the rider) before any
--     stop has moved. A stop moving to 'enRoute'/'delivered'/etc. also
--     advances status past this automatically (see staff_update_delivery_stop
--     below), so this only matters for the brief "handed off, not yet moving"
--     window.
-- -----------------------------------------------------------------------------
create or replace function public.staff_dispatch_delivery(p_delivery_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_delivery public.deliveries;
begin
  select * into v_delivery from public.deliveries where id = p_delivery_id for update;
  if not found then raise exception 'That delivery could not be found.'; end if;
  perform public._require_staff(v_delivery.branch_id);

  if v_delivery.status not in ('pending', 'optimized') then
    raise exception 'This delivery is already %.', v_delivery.status;
  end if;

  update public.deliveries set status = 'dispatched' where id = p_delivery_id;
  return public._delivery_to_jsonb(p_delivery_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Update one stop's status (delivered / delayed / skipped / enRoute) and
--    roll the parent delivery's status forward to match.
-- -----------------------------------------------------------------------------
create or replace function public.staff_update_delivery_stop(
  p_stop_id uuid,
  p_status text,
  p_issue_reason text default null,
  p_proof_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stop public.delivery_stops;
  v_delivery public.deliveries;
  v_total int;
  v_done int;
  v_enroute int;
  v_moved int;
  v_new_status text;
begin
  if p_status not in ('pending', 'enRoute', 'delivered', 'delayed', 'skipped') then
    raise exception 'Unsupported stop status.';
  end if;

  select * into v_stop from public.delivery_stops where id = p_stop_id for update;
  if not found then raise exception 'That delivery stop could not be found.'; end if;
  select * into v_delivery from public.deliveries where id = v_stop.delivery_id for update;
  if not found then raise exception 'That delivery could not be found.'; end if;
  perform public._require_staff(v_delivery.branch_id);

  if v_delivery.status in ('completed', 'cancelled') then
    raise exception 'This delivery is % and its stops can no longer be changed.', v_delivery.status;
  end if;

  update public.delivery_stops
     set status = p_status,
         issue_reason = case when p_status in ('delayed', 'skipped') then coalesce(p_issue_reason, v_stop.issue_reason) else v_stop.issue_reason end,
         proof_note = coalesce(p_proof_note, v_stop.proof_note)
   where id = p_stop_id;

  if p_status = 'delivered' then
    update public.orders set status = 'completed' where id = v_stop.order_id;
  end if;

  select count(*), count(*) filter (where status in ('delivered', 'skipped')),
         count(*) filter (where status = 'enRoute'), count(*) filter (where status <> 'pending')
    into v_total, v_done, v_enroute, v_moved
    from public.delivery_stops where delivery_id = v_delivery.id;

  if v_total > 0 and v_done = v_total then
    v_new_status := 'completed';
  elsif v_enroute > 0 then
    v_new_status := 'inTransit';
  elsif v_moved > 0 then
    v_new_status := 'dispatched';
  else
    v_new_status := v_delivery.status;
  end if;

  if v_new_status is distinct from v_delivery.status then
    update public.deliveries set status = v_new_status where id = v_delivery.id;
  end if;

  return public._delivery_to_jsonb(v_delivery.id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Cancel a whole delivery
-- -----------------------------------------------------------------------------
create or replace function public.staff_cancel_delivery(p_delivery_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_delivery public.deliveries;
  v_stop record;
begin
  select * into v_delivery from public.deliveries where id = p_delivery_id for update;
  if not found then raise exception 'That delivery could not be found.'; end if;
  perform public._require_staff(v_delivery.branch_id);

  if v_delivery.status in ('completed', 'cancelled') then
    raise exception 'This delivery is already %.', v_delivery.status;
  end if;

  for v_stop in
    select * from public.delivery_stops where delivery_id = p_delivery_id and status not in ('delivered', 'skipped')
  loop
    update public.orders set status = 'confirmed', rider_name = null
     where id = v_stop.order_id and status = 'outForDelivery';
  end loop;

  update public.deliveries set status = 'cancelled' where id = p_delivery_id;
  return public._delivery_to_jsonb(p_delivery_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 9. Grants (staff-only — never anon)
-- -----------------------------------------------------------------------------
revoke all on function public._delivery_to_jsonb(text) from public, anon, authenticated;
grant execute on function public.staff_list_deliverable_orders(uuid) to authenticated;
grant execute on function public.staff_create_delivery(uuid, text, text, text[]) to authenticated;
grant execute on function public.staff_get_deliveries(uuid) to authenticated;
grant execute on function public.staff_dispatch_delivery(text) to authenticated;
grant execute on function public.staff_update_delivery_stop(uuid, text, text, text) to authenticated;
grant execute on function public.staff_cancel_delivery(text) to authenticated;

commit;
