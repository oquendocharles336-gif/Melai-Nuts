-- =============================================================================
-- Melai Nuts — Migration 20261016000000: delivery pins (app only)
-- =============================================================================
-- Run after 20261015000000_refunds_in_analytics.sql. Idempotent (create or
-- replace / if not exists), one transaction. No table is dropped and no
-- existing function changes its arguments or its JSON keys.
--
-- Delivery now lives only in the Melai Nuts app (the admin website has no
-- delivery pages any more). The app shows a map wherever a delivery location
-- matters: the customer pins it, staff / owner see it when handling the order
-- and when building a run, the rider sees it for each stop. This migration
-- makes those maps trustworthy:
--
--   1. orders.delivery_latitude / delivery_longitude: the pin is SNAPSHOT on
--      the order when it is placed (a BEFORE INSERT trigger copies it from the
--      customer's saved address, so place_order() itself is unchanged). Staff
--      and the rider therefore see exactly the point the customer confirmed at
--      checkout, even if the customer later edits or deletes that saved
--      address. The address TEXT was already snapshot (delivery_address_text).
--      Once set, the order's pin cannot be changed. Open delivery orders that
--      exist today are backfilled from their saved address; finished orders
--      are left alone (no new personal data is written for them).
--   2. A pin at 0,0 ("null island", what a broken GPS fix returns) is refused
--      for new and edited saved addresses (NOT VALID: old rows are untouched)
--      and never snapshot onto an order.
--   3. _delivery_to_jsonb (stops of a run), staff_list_deliverable_orders
--      (orders to put on a run) and customer_get_delivery_tracking read the
--      order's snapshot first and fall back to the saved address only for
--      orders placed before this migration. staff_list_deliverable_orders also
--      returns latitude / longitude so staff can see every candidate's pin.
--   4. _delivery_for_driver is STRICTER, never weaker: besides hiding address,
--      coordinates, phone and notes once the run is completed / cancelled (as
--      before), a stop's details are now also hidden as soon as THAT stop is
--      delivered, failed or skipped.
--   5. NEW staff_order_delivery_pins(order_ids): the customer's pin, address,
--      contact and the branch position for delivery orders, for the staff
--      order screen. Staff: only orders of their own branch (others are left
--      out); owner: every branch; riders, customers and anon: refused.
--
-- Who can read a pin (enforced here and by the existing RLS):
--   customer  their own saved addresses (RLS "customer: own addresses") and
--             their own orders (RLS "customer: read own orders")
--   rider     only stops of runs assigned to them, only while the stop and the
--             run are still open (_delivery_for_driver)
--   staff     orders / runs of their own branch (RLS "staff: read branch
--             orders", _require_staff + branch checks in every RPC)
--   owner     every branch
--   anon      nothing
-- The admin website reads none of this: admin_portal_orders() has no address
-- or coordinates, and the website no longer calls any delivery function.
-- Coordinates are personal data: nothing here logs them.
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1. Snapshot columns on the order
-- -----------------------------------------------------------------------------
alter table public.orders add column if not exists delivery_latitude double precision;
alter table public.orders add column if not exists delivery_longitude double precision;
alter table public.orders drop constraint if exists orders_delivery_pin_valid;
alter table public.orders add constraint orders_delivery_pin_valid check (
  (delivery_latitude is null and delivery_longitude is null)
  or (delivery_latitude between -90 and 90 and delivery_longitude between -180 and 180
      and not (delivery_latitude = 0 and delivery_longitude = 0))
);

-- A saved address may not be pinned at exactly 0,0 (a failed GPS fix, never a
-- Melai Nuts customer). NOT VALID: rows that already exist are not re-checked.
alter table public.customer_addresses drop constraint if exists customer_addresses_not_null_island;
alter table public.customer_addresses add constraint customer_addresses_not_null_island check (
  latitude is null or longitude is null or not (latitude = 0 and longitude = 0)
) not valid;

-- Copies the customer's pin onto a new delivery order. Only the customer's OWN
-- address is ever read (place_order already refuses someone else's address).
create or replace function public._trg_order_snapshot_delivery_pin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lat double precision;
  v_lng double precision;
begin
  if new.is_delivery and new.delivery_address_id is not null and new.delivery_latitude is null then
    select latitude, longitude into v_lat, v_lng
    from public.customer_addresses
    where id = new.delivery_address_id and firebase_uid = new.firebase_uid;
    if v_lat is not null and v_lng is not null and not (v_lat = 0 and v_lng = 0) then
      new.delivery_latitude := v_lat;
      new.delivery_longitude := v_lng;
    end if;
  end if;
  if not coalesce(new.is_delivery, false) then
    new.delivery_latitude := null;
    new.delivery_longitude := null;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_snapshot_delivery_pin on public.orders;
create trigger orders_snapshot_delivery_pin
  before insert on public.orders
  for each row execute function public._trg_order_snapshot_delivery_pin();

-- The pin is part of what the customer confirmed: once set it never moves.
create or replace function public._trg_order_pin_immutable()
returns trigger
language plpgsql
as $$
begin
  if old.delivery_latitude is not null
     and (new.delivery_latitude, new.delivery_longitude) is distinct from (old.delivery_latitude, old.delivery_longitude) then
    raise exception 'The delivery pin of order % cannot be changed after it is placed.', old.id;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_pin_immutable on public.orders;
create trigger orders_pin_immutable
  before update of delivery_latitude, delivery_longitude on public.orders
  for each row execute function public._trg_order_pin_immutable();

-- Backfill: open delivery orders only (they may still be put on a run).
update public.orders o
set delivery_latitude = ca.latitude, delivery_longitude = ca.longitude
from public.customer_addresses ca
where ca.id = o.delivery_address_id
  and ca.firebase_uid = o.firebase_uid
  and o.is_delivery
  and o.delivery_latitude is null
  and o.status in ('pending', 'confirmed', 'preparing', 'readyForPickup', 'outForDelivery')
  and ca.latitude is not null and ca.longitude is not null
  and not (ca.latitude = 0 and ca.longitude = 0);

-- -----------------------------------------------------------------------------
-- 2. Read model of a run: the order's snapshot first (same keys as before)
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
    'driver_uid', d.driver_uid,
    'driver_status', d.driver_status,
    'driver_phone', dr.phone,
    'assigned_at', d.assigned_at,
    'accepted_at', d.accepted_at,
    'picked_up_at', d.picked_up_at,
    'completed_at', d.completed_at,
    'tracking_active', d.tracking_active,
    'branch_latitude', b.latitude,
    'branch_longitude', b.longitude,
    'stops', (
      select coalesce(jsonb_agg(to_jsonb(s) order by s.sequence_index), '[]'::jsonb)
      from (
        select
          ds.id,
          o.id as order_id,
          coalesce(nullif(cp.full_name, ''), 'Customer') as customer_name,
          coalesce(o.delivery_address_text, 'Address not provided') as address,
          case when o.delivery_latitude is not null then o.delivery_latitude
               when ca.latitude = 0 and ca.longitude = 0 then null else ca.latitude end as latitude,
          case when o.delivery_latitude is not null then o.delivery_longitude
               when ca.latitude = 0 and ca.longitude = 0 then null else ca.longitude end as longitude,
          o.contact_phone,
          o.customer_notes,
          o.total as order_total,
          p.method as payment_method,
          p.status as payment_status,
          ds.sequence_index,
          ds.distance_from_previous_km,
          ds.travel_minutes_from_previous,
          ds.eta_label as eta,
          ds.status,
          ds.issue_reason,
          ds.proof_note,
          ds.proof_photo_path,
          ds.recipient_name,
          ds.delivered_at,
          ds.failed_at,
          (select coalesce(jsonb_agg(
                     oi.quantity::text || 'x ' || oi.product_name ||
                     case when oi.variant_label is null or oi.variant_label = '' or oi.variant_label = 'Regular'
                          then '' else ' (' || oi.variant_label || ')' end
                   ), '[]'::jsonb)
           from public.order_items oi where oi.order_id = o.id) as items
        from public.delivery_stops ds
        join public.orders o on o.id = ds.order_id
        left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
        left join public.customer_addresses ca on ca.id = o.delivery_address_id and ca.firebase_uid = o.firebase_uid
        left join public.payments p on p.order_id = o.id
        where ds.delivery_id = d.id
      ) s
    )
  )
  from public.deliveries d
  join public.branches b on b.id = d.branch_id
  left join public.drivers dr on dr.firebase_uid = d.driver_uid
  where d.id = p_delivery_id
$$;

-- The rider's view: contact details, address and pin only while the run AND
-- that stop are still open (stricter than 20261010010000, never weaker).
create or replace function public._delivery_for_driver(p_delivery_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb := public._delivery_to_jsonb(p_delivery_id);
  v_status text := v ->> 'status';
  v_run_over boolean := v_status in ('completed', 'cancelled');
begin
  if v is null then
    return null;
  end if;
  v := jsonb_set(v, '{stops}', (
    select coalesce(jsonb_agg(
             case when v_run_over or (s ->> 'status') in ('delivered', 'failed', 'skipped')
                  then s - 'address' - 'latitude' - 'longitude' - 'contact_phone' - 'customer_notes'
                       || jsonb_build_object('address', 'Hidden after delivery', 'latitude', null, 'longitude', null)
                  else s end
             order by (s ->> 'sequence_index')::int), '[]'::jsonb)
    from jsonb_array_elements(v -> 'stops') s));
  return v;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Orders that can go on a run, with their pins
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
          'latitude', pin.lat,
          'longitude', pin.lng,
          'contact_phone', o.contact_phone,
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
      left join public.customer_addresses ca on ca.id = o.delivery_address_id and ca.firebase_uid = o.firebase_uid
      cross join lateral (
        select case when o.delivery_latitude is not null then o.delivery_latitude
                    when ca.latitude = 0 and ca.longitude = 0 then null else ca.latitude end as lat,
               case when o.delivery_latitude is not null then o.delivery_longitude
                    when ca.latitude = 0 and ca.longitude = 0 then null else ca.longitude end as lng
      ) pin
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
-- 4. Staff order screen: where did the customer pin it?
-- -----------------------------------------------------------------------------
create or replace function public.staff_order_delivery_pins(p_order_ids text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
begin
  v_staff := public._require_staff();   -- riders, customers and anon are refused here
  if p_order_ids is null or cardinality(p_order_ids) = 0 then
    return '[]'::jsonb;
  end if;
  if cardinality(p_order_ids) > 300 then
    raise exception 'Ask for at most 300 orders at a time.';
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'order_id', o.id,
             'branch_id', o.branch_id,
             'branch_name', b.name,
             'branch_latitude', b.latitude,
             'branch_longitude', b.longitude,
             'address', o.delivery_address_text,
             'recipient_name', coalesce(nullif(ca.recipient_name, ''), nullif(cp.full_name, '')),
             'contact_phone', o.contact_phone,
             'latitude', pin.lat,
             'longitude', pin.lng,
             'pin_snapshot', o.delivery_latitude is not null,
             'distance_km', case when pin.lat is not null and b.latitude is not null and b.longitude is not null
                              then round((6371 * 2 * asin(sqrt(
                                     power(sin(radians(pin.lat - b.latitude) / 2), 2)
                                     + cos(radians(b.latitude)) * cos(radians(pin.lat))
                                       * power(sin(radians(pin.lng - b.longitude) / 2), 2))))::numeric, 2)
                              end
           ) order by o.created_at desc), '[]'::jsonb)
    from public.orders o
    join public.branches b on b.id = o.branch_id
    left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
    left join public.customer_addresses ca on ca.id = o.delivery_address_id and ca.firebase_uid = o.firebase_uid
    cross join lateral (
      select case when o.delivery_latitude is not null then o.delivery_latitude
                  when ca.latitude = 0 and ca.longitude = 0 then null else ca.latitude end as lat,
             case when o.delivery_latitude is not null then o.delivery_longitude
                  when ca.latitude = 0 and ca.longitude = 0 then null else ca.longitude end as lng
    ) pin
    where o.id = any (p_order_ids)
      and o.is_delivery
      and (v_staff.role = 'owner' or o.branch_id = v_staff.branch_id)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Customer tracking: destination = the pin confirmed on the order
-- -----------------------------------------------------------------------------
create or replace function public.customer_get_delivery_tracking(p_order_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_order public.orders;
  v_stop public.delivery_stops;
  v_delivery public.deliveries;
  v_branch public.branches;
  v_dest_lat double precision;
  v_dest_lng double precision;
  v_loc_lat double precision;
  v_loc_lng double precision;
  v_loc_at timestamptz;
  v_ahead int;
  v_live boolean;
begin
  if v_uid is null then raise exception 'Please sign in.'; end if;
  select * into v_order from public.orders where id = p_order_id and firebase_uid = v_uid;
  if not found then raise exception 'Order not found.'; end if;
  select * into v_branch from public.branches where id = v_order.branch_id;

  select ds.* into v_stop from public.delivery_stops ds
  join public.deliveries d on d.id = ds.delivery_id
  where ds.order_id = v_order.id and d.status <> 'cancelled'
  order by ds.created_at desc limit 1;
  if v_stop.id is not null then
    select * into v_delivery from public.deliveries where id = v_stop.delivery_id;
  end if;

  if v_order.delivery_latitude is not null then
    v_dest_lat := v_order.delivery_latitude;
    v_dest_lng := v_order.delivery_longitude;
  else
    select latitude, longitude into v_dest_lat, v_dest_lng from public.customer_addresses
    where id = v_order.delivery_address_id and firebase_uid = v_uid
      and not (latitude = 0 and longitude = 0);
  end if;

  v_live := coalesce(v_delivery.id is not null and v_order.status = 'outForDelivery' and v_delivery.tracking_active
                     and v_stop.status in ('pending', 'enRoute', 'delayed'), false);
  if v_live then
    select latitude, longitude, recorded_at into v_loc_lat, v_loc_lng, v_loc_at from public.driver_locations
    where delivery_id = v_delivery.id and recorded_at > now() - interval '10 minutes'
    order by recorded_at desc limit 1;
    select count(*) into v_ahead from public.delivery_stops
    where delivery_id = v_delivery.id and sequence_index < v_stop.sequence_index
      and status not in ('delivered', 'failed', 'skipped');
  end if;

  return jsonb_build_object(
    'order_id', v_order.id,
    'order_status', v_order.status,
    'stop_status', v_stop.status,
    'driver_status', v_delivery.driver_status,
    'driver_name', case when v_live then split_part(coalesce(v_delivery.rider_name, ''), ' ', 1) end,
    'driver_phone', case when v_live then v_order.rider_phone end,
    'eta', v_stop.eta_label,
    'stops_before_you', v_ahead,
    'branch', jsonb_build_object('name', v_branch.name, 'lat', v_branch.latitude, 'lng', v_branch.longitude),
    'destination', jsonb_build_object('lat', v_dest_lat, 'lng', v_dest_lng),
    'driver_location', case when v_loc_at is not null then
        jsonb_build_object('lat', v_loc_lat, 'lng', v_loc_lng, 'recorded_at', v_loc_at) end,
    'tracking_available', v_live and v_loc_at is not null,
    'delivered_at', v_stop.delivered_at
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Grants
-- -----------------------------------------------------------------------------
revoke all on function public._trg_order_snapshot_delivery_pin() from public, anon, authenticated;
revoke all on function public._trg_order_pin_immutable() from public, anon, authenticated;
revoke all on function public._delivery_to_jsonb(text) from public, anon, authenticated;
revoke all on function public._delivery_for_driver(text) from public, anon, authenticated;

do $g$
declare f text;
begin
  foreach f in array array[
    'public.staff_list_deliverable_orders(uuid)',
    'public.staff_order_delivery_pins(text[])',
    'public.customer_get_delivery_tracking(text)'
  ] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end
$g$;

commit;
