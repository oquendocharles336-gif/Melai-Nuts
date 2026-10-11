-- =============================================================================
-- Driver module: driver accounts, assignment, driver workflow, live location,
-- proof of delivery, failed-delivery hand-back, customer tracking.
-- =============================================================================
-- Run after 20261010000000_pos_shifts_voids_returns.sql. Idempotent, additive.
--
-- Before this migration a "delivery" account existed only in Firebase: the
-- database did not know riders, so a rider who signed in could read nothing,
-- and a delivery run only carried a free-text rider name.
--
-- Identity: a driver is a Firebase UID registered in public.drivers (owner
-- only). Drivers are deliberately NOT staff_members, so no existing staff RPC
-- or policy (which all start from staff_members) can ever be reached by a
-- driver. One Firebase UID is either staff or driver, never both.
--
-- Run workflow (deliveries.driver_status)
--   null -> assigned (staff) -> accepted | rejected->null (driver)
--        -> picked_up (driver, at the branch) -> in_transit (first stop en route)
--        -> completed (every stop delivered / failed / skipped)
-- Stop outcomes (driver): enRoute, delivered (proof required; COD cash must be
-- collected in full), failed (reason required; the order goes back to the
-- branch as 'confirmed' so it can be re-dispatched).
--
-- Location privacy
--   * Points are accepted only from the run's driver, only between pickup and
--     completion, with plausible coordinates and timestamps, and throttled.
--   * When a run completes or is cancelled, tracking switches off and EVERY
--     stored point for that run is deleted (trigger), so nothing is kept after
--     the delivery. A driver's own client is told to stop sending.
--   * A customer sees only the latest point, only for their own order, only
--     while that order is out for delivery and not yet delivered, and only if
--     the point is fresh (10 minutes).
--   * Customer addresses are shown to the driver only for runs assigned to
--     them and not yet finished.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Coordinates for branches and customer addresses (optional, for maps)
-- -----------------------------------------------------------------------------
alter table public.branches add column if not exists latitude double precision;
alter table public.branches add column if not exists longitude double precision;
alter table public.branches drop constraint if exists branches_coordinates_valid;
alter table public.branches add constraint branches_coordinates_valid check (
  (latitude is null and longitude is null)
  or (latitude between -90 and 90 and longitude between -180 and 180));

alter table public.customer_addresses add column if not exists latitude double precision;
alter table public.customer_addresses add column if not exists longitude double precision;
alter table public.customer_addresses drop constraint if exists customer_addresses_coordinates_valid;
alter table public.customer_addresses add constraint customer_addresses_coordinates_valid check (
  (latitude is null and longitude is null)
  or (latitude between -90 and 90 and longitude between -180 and 180));

-- -----------------------------------------------------------------------------
-- 2. Drivers
-- -----------------------------------------------------------------------------
create table if not exists public.drivers (
  firebase_uid text primary key,
  full_name text not null check (char_length(full_name) between 1 and 120),
  email text not null default '',
  phone text check (phone is null or char_length(phone) <= 32),
  branch_id uuid not null references public.branches(id) on delete restrict,
  vehicle text check (vehicle is null or char_length(vehicle) <= 80),
  account_status text not null default 'active' check (account_status in ('active', 'inactive', 'suspended')),
  is_available boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists drivers_set_updated_at on public.drivers;
create trigger drivers_set_updated_at before update on public.drivers
  for each row execute function public.set_updated_at();
create index if not exists drivers_branch_idx on public.drivers (branch_id);
alter table public.drivers enable row level security;

drop policy if exists "driver reads own row" on public.drivers;
create policy "driver reads own row" on public.drivers for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));
drop policy if exists "staff read branch drivers" on public.drivers;
create policy "staff read branch drivers" on public.drivers for select to authenticated
  using (public.staff_can_see_branch(branch_id));
revoke all on public.drivers from anon;
revoke insert, update, delete, truncate on public.drivers from authenticated;
grant select on public.drivers to authenticated;

-- A UID is staff OR driver.
create or replace function public._trg_staff_not_driver()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.drivers where firebase_uid = new.firebase_uid) then
    raise exception 'This account is registered as a driver and cannot also be staff.';
  end if;
  return new;
end $$;
drop trigger if exists staff_members_not_driver on public.staff_members;
create trigger staff_members_not_driver before insert on public.staff_members
  for each row execute function public._trg_staff_not_driver();

create or replace function public._require_driver()
returns public.drivers
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.drivers;
begin
  select * into v from public.drivers where firebase_uid = public.current_firebase_uid();
  if not found then raise exception 'Your driver account is not set up yet. Please contact the owner.'; end if;
  if v.account_status = 'suspended' then raise exception 'Your driver account has been suspended. Please contact the owner.'; end if;
  if v.account_status <> 'active' then raise exception 'Your driver account has been deactivated. Please contact the owner.'; end if;
  return v;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Runs and stops: driver columns
-- -----------------------------------------------------------------------------
alter table public.deliveries add column if not exists driver_uid text references public.drivers(firebase_uid) on delete restrict;
alter table public.deliveries add column if not exists driver_status text;
alter table public.deliveries add column if not exists assigned_at timestamptz;
alter table public.deliveries add column if not exists accepted_at timestamptz;
alter table public.deliveries add column if not exists picked_up_at timestamptz;
alter table public.deliveries add column if not exists completed_at timestamptz;
alter table public.deliveries add column if not exists tracking_active boolean not null default false;
alter table public.deliveries drop constraint if exists deliveries_driver_status_valid;
alter table public.deliveries add constraint deliveries_driver_status_valid check (
  driver_status is null or driver_status in ('assigned', 'accepted', 'picked_up', 'in_transit', 'completed'));
alter table public.deliveries drop constraint if exists deliveries_driver_status_needs_driver;
alter table public.deliveries add constraint deliveries_driver_status_needs_driver check (
  driver_status is null or driver_uid is not null);
create index if not exists deliveries_driver_idx on public.deliveries (driver_uid, created_at desc);

alter table public.delivery_stops drop constraint if exists delivery_stops_status_check;
alter table public.delivery_stops add constraint delivery_stops_status_check
  check (status in ('pending', 'enRoute', 'delivered', 'delayed', 'skipped', 'failed'));
alter table public.delivery_stops add column if not exists proof_photo_path text;
alter table public.delivery_stops add column if not exists recipient_name text;
alter table public.delivery_stops add column if not exists delivered_at timestamptz;
alter table public.delivery_stops add column if not exists failed_at timestamptz;
alter table public.delivery_stops drop constraint if exists delivery_stops_proof_lengths;
alter table public.delivery_stops add constraint delivery_stops_proof_lengths check (
  (proof_photo_path is null or char_length(proof_photo_path) <= 300)
  and (recipient_name is null or char_length(recipient_name) <= 120));

create table if not exists public.delivery_assignment_events (
  id uuid primary key default gen_random_uuid(),
  delivery_id text not null references public.deliveries(id) on delete cascade,
  driver_uid text,
  event text not null check (event in ('assigned', 'unassigned', 'accepted', 'rejected', 'picked_up', 'completed')),
  reason text check (reason is null or char_length(reason) <= 300),
  actor_uid text not null,
  created_at timestamptz not null default now()
);
create index if not exists delivery_assignment_events_delivery_idx on public.delivery_assignment_events (delivery_id, created_at);
alter table public.delivery_assignment_events enable row level security;
revoke all on public.delivery_assignment_events from anon, authenticated;

create table if not exists public.driver_locations (
  id bigserial primary key,
  delivery_id text not null references public.deliveries(id) on delete cascade,
  driver_uid text not null references public.drivers(firebase_uid) on delete cascade,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_m real check (accuracy_m is null or (accuracy_m >= 0 and accuracy_m <= 10000)),
  heading real check (heading is null or (heading >= 0 and heading < 360)),
  speed_mps real check (speed_mps is null or (speed_mps >= 0 and speed_mps <= 100)),
  recorded_at timestamptz not null,
  received_at timestamptz not null default now()
);
create index if not exists driver_locations_delivery_idx on public.driver_locations (delivery_id, recorded_at desc);
alter table public.driver_locations enable row level security;
revoke all on public.driver_locations from anon, authenticated;

-- Tracking switches off and stored points are erased when a run ends.
create or replace function public._trg_delivery_tracking_cleanup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('completed', 'cancelled') and old.status is distinct from new.status then
    new.tracking_active := false;
    new.completed_at := coalesce(new.completed_at, now());
    if new.driver_uid is not null and new.status = 'completed' then
      new.driver_status := 'completed';
    end if;
    delete from public.driver_locations where delivery_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists deliveries_tracking_cleanup on public.deliveries;
create trigger deliveries_tracking_cleanup before update of status on public.deliveries
  for each row execute function public._trg_delivery_tracking_cleanup();

-- -----------------------------------------------------------------------------
-- 4. Read model (extends the existing one with driver fields; old keys kept)
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
          ca.latitude, ca.longitude,
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
        left join public.customer_addresses ca on ca.id = o.delivery_address_id
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

-- Same view for a driver: contact details and addresses only while the run is
-- theirs and unfinished.
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
begin
  if v_status in ('completed', 'cancelled') then
    v := jsonb_set(v, '{stops}', (
      select coalesce(jsonb_agg(s - 'address' - 'latitude' - 'longitude' - 'contact_phone' - 'customer_notes'
                                  || jsonb_build_object('address', 'Hidden after delivery')
                                order by (s ->> 'sequence_index')::int), '[]'::jsonb)
      from jsonb_array_elements(v -> 'stops') s));
  end if;
  return v;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Owner: manage drivers
-- -----------------------------------------------------------------------------
create or replace function public.owner_upsert_driver(
  p_firebase_uid text,
  p_full_name text,
  p_email text,
  p_branch_id uuid,
  p_phone text default null,
  p_vehicle text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
  v_uid text := nullif(trim(coalesce(p_firebase_uid, '')), '');
begin
  v_owner := public._require_owner();
  if v_uid is null or char_length(v_uid) > 128 then raise exception 'A valid account id is required.'; end if;
  if char_length(trim(coalesce(p_full_name, ''))) = 0 then raise exception 'Enter the driver''s name.'; end if;
  if p_branch_id is null or not exists (select 1 from public.branches where id = p_branch_id) then
    raise exception 'Choose the driver''s branch.';
  end if;
  if exists (select 1 from public.staff_members where firebase_uid = v_uid) then
    raise exception 'This account is already registered as staff.';
  end if;

  insert into public.drivers (firebase_uid, full_name, email, phone, branch_id, vehicle)
  values (v_uid, trim(p_full_name), trim(coalesce(p_email, '')), nullif(trim(coalesce(p_phone, '')), ''),
          p_branch_id, nullif(trim(coalesce(p_vehicle, '')), ''))
  on conflict (firebase_uid) do update
    set full_name = excluded.full_name, email = excluded.email, phone = excluded.phone,
        branch_id = excluded.branch_id, vehicle = excluded.vehicle;

  perform public._write_audit(v_owner.firebase_uid, p_branch_id, 'driver.upsert', 'driver', v_uid,
                              jsonb_build_object('full_name', trim(p_full_name)));
  return (select to_jsonb(d) from public.drivers d where firebase_uid = v_uid);
end;
$$;

create or replace function public.owner_set_driver_status(p_firebase_uid text, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
  v_driver public.drivers;
begin
  v_owner := public._require_owner();
  if p_status not in ('active', 'inactive', 'suspended') then raise exception 'Unsupported status.'; end if;
  update public.drivers set account_status = p_status,
         is_available = case when p_status = 'active' then is_available else false end
   where firebase_uid = p_firebase_uid returning * into v_driver;
  if not found then raise exception 'That driver could not be found.'; end if;
  perform public._write_audit(v_owner.firebase_uid, v_driver.branch_id, 'driver.status', 'driver', p_firebase_uid,
                              jsonb_build_object('status', p_status));
  return to_jsonb(v_driver);
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Staff: drivers list, assign / unassign, tracking view
-- -----------------------------------------------------------------------------
create or replace function public.staff_list_drivers(p_branch_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
begin
  v_staff := public._require_staff(p_branch_id);
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'firebase_uid', d.firebase_uid, 'full_name', d.full_name, 'phone', d.phone,
             'branch_id', d.branch_id, 'vehicle', d.vehicle, 'account_status', d.account_status,
             'is_available', d.is_available,
             'active_runs', (select count(*) from public.deliveries x
                             where x.driver_uid = d.firebase_uid and x.status not in ('completed', 'cancelled')))
           order by d.full_name), '[]'::jsonb)
    from public.drivers d
    where case when v_staff.role = 'owner' then p_branch_id is null or d.branch_id = p_branch_id
               else d.branch_id = v_staff.branch_id end
  );
end;
$$;

create or replace function public.staff_assign_driver(p_delivery_id text, p_driver_uid text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_delivery public.deliveries;
  v_staff public.staff_members;
  v_driver public.drivers;
begin
  select * into v_delivery from public.deliveries where id = p_delivery_id for update;
  if not found then raise exception 'That delivery could not be found.'; end if;
  v_staff := public._require_staff(v_delivery.branch_id);
  if v_delivery.status in ('completed', 'cancelled') then raise exception 'This delivery is already %.', v_delivery.status; end if;
  if v_delivery.driver_status in ('accepted', 'picked_up', 'in_transit') then
    raise exception 'The driver has already accepted this delivery. Unassign is no longer possible.';
  end if;

  select * into v_driver from public.drivers where firebase_uid = p_driver_uid;
  if not found then raise exception 'That driver could not be found.'; end if;
  if v_driver.account_status <> 'active' then raise exception 'That driver account is not active.'; end if;
  if v_driver.branch_id <> v_delivery.branch_id then raise exception 'That driver belongs to another branch.'; end if;

  update public.deliveries
     set driver_uid = v_driver.firebase_uid, driver_status = 'assigned', assigned_at = now(), accepted_at = null,
         rider_name = v_driver.full_name, vehicle = coalesce(v_driver.vehicle, vehicle)
   where id = v_delivery.id;
  update public.orders o set rider_name = v_driver.full_name, rider_phone = v_driver.phone
   from public.delivery_stops ds
   where ds.delivery_id = v_delivery.id and ds.order_id = o.id and o.status = 'outForDelivery';

  insert into public.delivery_assignment_events (delivery_id, driver_uid, event, actor_uid)
  values (v_delivery.id, v_driver.firebase_uid, 'assigned', v_staff.firebase_uid);
  insert into public.staff_notifications (recipient_uid, branch_id, category, title, body, reference)
  values (v_driver.firebase_uid, v_delivery.branch_id, 'order', 'New delivery assigned',
          'Delivery ' || v_delivery.id || ' is waiting for you to accept.', v_delivery.id);
  perform public._write_audit(v_staff.firebase_uid, v_delivery.branch_id, 'delivery.assign', 'delivery', v_delivery.id,
                              jsonb_build_object('driver_uid', v_driver.firebase_uid));
  return public._delivery_to_jsonb(v_delivery.id);
end;
$$;

create or replace function public.staff_unassign_driver(p_delivery_id text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_delivery public.deliveries;
  v_staff public.staff_members;
begin
  select * into v_delivery from public.deliveries where id = p_delivery_id for update;
  if not found then raise exception 'That delivery could not be found.'; end if;
  v_staff := public._require_staff(v_delivery.branch_id);
  if v_delivery.driver_uid is null then raise exception 'No driver is assigned.'; end if;
  if v_delivery.driver_status in ('picked_up', 'in_transit', 'completed') then
    raise exception 'The driver already has the parcels. Cancel the delivery instead.';
  end if;
  update public.deliveries set driver_uid = null, driver_status = null, assigned_at = null, accepted_at = null
   where id = v_delivery.id;
  insert into public.delivery_assignment_events (delivery_id, driver_uid, event, reason, actor_uid)
  values (v_delivery.id, v_delivery.driver_uid, 'unassigned', left(p_reason, 300), v_staff.firebase_uid);
  insert into public.staff_notifications (recipient_uid, branch_id, category, title, body, reference)
  values (v_delivery.driver_uid, v_delivery.branch_id, 'order', 'Delivery removed',
          'Delivery ' || v_delivery.id || ' is no longer assigned to you.', v_delivery.id);
  perform public._write_audit(v_staff.firebase_uid, v_delivery.branch_id, 'delivery.unassign', 'delivery', v_delivery.id,
                              jsonb_build_object('driver_uid', v_delivery.driver_uid, 'reason', p_reason));
  return public._delivery_to_jsonb(v_delivery.id);
end;
$$;

create or replace function public.staff_get_delivery_tracking(p_delivery_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_delivery public.deliveries;
begin
  select * into v_delivery from public.deliveries where id = p_delivery_id;
  if not found then raise exception 'That delivery could not be found.'; end if;
  perform public._require_staff(v_delivery.branch_id);
  return jsonb_build_object(
    'delivery', public._delivery_to_jsonb(v_delivery.id),
    'trail', (
      select coalesce(jsonb_agg(jsonb_build_object('lat', latitude, 'lng', longitude, 'accuracy_m', accuracy_m,
                                                   'recorded_at', recorded_at) order by recorded_at), '[]'::jsonb)
      from (select * from public.driver_locations where delivery_id = v_delivery.id
            order by recorded_at desc limit 200) t)
  );
end;
$$;

-- Latest point of every active run the caller may see (admin map, owner map).
create or replace function public.staff_active_driver_positions(p_branch_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
begin
  v_staff := public._require_staff(p_branch_id);
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'delivery_id', d.id, 'branch_id', d.branch_id, 'branch', d.branch_name,
             'driver_uid', d.driver_uid, 'driver_name', d.rider_name, 'driver_status', d.driver_status,
             'lat', l.latitude, 'lng', l.longitude, 'recorded_at', l.recorded_at)), '[]'::jsonb)
    from public.deliveries d
    join lateral (
      select latitude, longitude, recorded_at from public.driver_locations
      where delivery_id = d.id order by recorded_at desc limit 1
    ) l on true
    where d.tracking_active
      and case when v_staff.role = 'owner' then p_branch_id is null or d.branch_id = p_branch_id
               else d.branch_id = v_staff.branch_id end
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Driver RPCs
-- -----------------------------------------------------------------------------
-- Never raises for "not a driver": answers a status like get_my_staff_context.
create or replace function public.get_my_driver_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v public.drivers;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  select * into v from public.drivers where firebase_uid = v_uid;
  if not found then return jsonb_build_object('status', 'not_provisioned'); end if;
  if v.account_status <> 'active' then return jsonb_build_object('status', v.account_status); end if;
  return jsonb_build_object('status', 'active', 'profile', jsonb_build_object(
    'firebase_uid', v.firebase_uid, 'full_name', v.full_name, 'email', v.email, 'phone', v.phone,
    'branch_id', v.branch_id, 'branch', (select name from public.branches where id = v.branch_id),
    'vehicle', v.vehicle, 'is_available', v.is_available));
end;
$$;

create or replace function public.driver_set_availability(p_available boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.drivers;
begin
  v := public._require_driver();
  update public.drivers set is_available = coalesce(p_available, false) where firebase_uid = v.firebase_uid;
  return public.get_my_driver_context();
end;
$$;

create or replace function public.driver_list_my_deliveries(p_include_finished boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.drivers;
begin
  v := public._require_driver();
  return (
    select coalesce(jsonb_agg(public._delivery_for_driver(d.id) order by d.created_at desc), '[]'::jsonb)
    from (
      select id, created_at from public.deliveries
      where driver_uid = v.firebase_uid
        and (coalesce(p_include_finished, false) or status not in ('completed', 'cancelled'))
      order by created_at desc
      limit 100
    ) d
  );
end;
$$;

create or replace function public._lock_my_run(p_delivery_id text, p_driver public.drivers)
returns public.deliveries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_delivery public.deliveries;
begin
  select * into v_delivery from public.deliveries where id = p_delivery_id for update;
  -- Same message for "missing" and "someone else's", so ids cannot be probed.
  if not found or v_delivery.driver_uid is distinct from p_driver.firebase_uid then
    raise exception 'That delivery is not assigned to you.';
  end if;
  return v_delivery;
end;
$$;

create or replace function public.driver_respond_assignment(p_delivery_id text, p_action text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.drivers;
  v_delivery public.deliveries;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  v := public._require_driver();
  v_delivery := public._lock_my_run(p_delivery_id, v);
  if v_delivery.status in ('completed', 'cancelled') then raise exception 'This delivery is already %.', v_delivery.status; end if;

  if p_action = 'accept' then
    if v_delivery.driver_status = 'accepted' then return public._delivery_for_driver(v_delivery.id); end if;
    if v_delivery.driver_status <> 'assigned' then raise exception 'This delivery cannot be accepted now.'; end if;
    update public.deliveries set driver_status = 'accepted', accepted_at = now() where id = v_delivery.id;
    insert into public.delivery_assignment_events (delivery_id, driver_uid, event, actor_uid)
    values (v_delivery.id, v.firebase_uid, 'accepted', v.firebase_uid);
  elsif p_action = 'reject' then
    if v_delivery.driver_status not in ('assigned', 'accepted') then
      raise exception 'You already have the parcels for this delivery and cannot reject it.';
    end if;
    if v_reason is null then raise exception 'Please give a reason for rejecting.'; end if;
    update public.deliveries set driver_uid = null, driver_status = null, assigned_at = null, accepted_at = null
     where id = v_delivery.id;
    insert into public.delivery_assignment_events (delivery_id, driver_uid, event, reason, actor_uid)
    values (v_delivery.id, v.firebase_uid, 'rejected', left(v_reason, 300), v.firebase_uid);
    perform public._notify_staff(v_delivery.branch_id, 'order', 'Delivery rejected by driver',
      v.full_name || ' rejected ' || v_delivery.id || ': ' || left(v_reason, 120), v_delivery.id, null);
    return jsonb_build_object('id', v_delivery.id, 'rejected', true);
  else
    raise exception 'Unsupported action.';
  end if;
  return public._delivery_for_driver(v_delivery.id);
end;
$$;

create or replace function public.driver_mark_picked_up(p_delivery_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.drivers;
  v_delivery public.deliveries;
begin
  v := public._require_driver();
  v_delivery := public._lock_my_run(p_delivery_id, v);
  if v_delivery.status in ('completed', 'cancelled') then raise exception 'This delivery is already %.', v_delivery.status; end if;
  if v_delivery.driver_status in ('picked_up', 'in_transit') then return public._delivery_for_driver(v_delivery.id); end if;
  if v_delivery.driver_status <> 'accepted' then raise exception 'Accept the delivery before picking it up.'; end if;

  update public.deliveries
     set driver_status = 'picked_up', picked_up_at = now(), tracking_active = true,
         status = case when status in ('pending', 'optimized') then 'dispatched' else status end
   where id = v_delivery.id;
  insert into public.delivery_assignment_events (delivery_id, driver_uid, event, actor_uid)
  values (v_delivery.id, v.firebase_uid, 'picked_up', v.firebase_uid);
  perform public._write_audit(v.firebase_uid, v_delivery.branch_id, 'delivery.picked_up', 'delivery', v_delivery.id, '{}'::jsonb);
  return public._delivery_for_driver(v_delivery.id);
end;
$$;

-- p_status: 'enRoute' | 'delivered' | 'failed'
-- delivered: proof = a photo path (uploaded to the private 'delivery-proofs'
--   bucket under '<delivery id>/') and/or the recipient's name.
--   Cash on delivery: p_cash_collected must equal the order total; the
--   payment is then confirmed here (the rider is the one taking the cash).
--   Online payments must already be confirmed by the gateway.
-- failed: p_reason required; the order returns to the branch ('confirmed').
create or replace function public.driver_update_stop(
  p_stop_id uuid,
  p_status text,
  p_reason text default null,
  p_proof_note text default null,
  p_proof_photo_path text default null,
  p_recipient_name text default null,
  p_cash_collected numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.drivers;
  v_stop public.delivery_stops;
  v_delivery public.deliveries;
  v_order public.orders;
  v_pay public.payments;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_photo text := nullif(trim(coalesce(p_proof_photo_path, '')), '');
  v_recipient text := nullif(trim(coalesce(p_recipient_name, '')), '');
  v_open int;
begin
  v := public._require_driver();
  if p_status not in ('enRoute', 'delivered', 'failed') then raise exception 'Unsupported stop status.'; end if;
  select * into v_stop from public.delivery_stops where id = p_stop_id;
  if not found then raise exception 'That delivery is not assigned to you.'; end if;
  v_delivery := public._lock_my_run(v_stop.delivery_id, v);
  select * into v_stop from public.delivery_stops where id = p_stop_id for update;

  -- A repeated tap (or an app retry) for an outcome already recorded is a
  -- no-op, even when that outcome finished the whole run.
  if v_stop.status in ('delivered', 'failed', 'skipped') then
    if v_stop.status = p_status then return public._delivery_for_driver(v_delivery.id); end if;
    raise exception 'This stop is already %.', v_stop.status;
  end if;
  if v_delivery.status in ('completed', 'cancelled') then raise exception 'This delivery is already %.', v_delivery.status; end if;
  if v_delivery.driver_status not in ('picked_up', 'in_transit') then
    raise exception 'Mark the delivery as picked up first.';
  end if;

  select * into v_order from public.orders where id = v_stop.order_id for update;
  select * into v_pay from public.payments where order_id = v_order.id for update;

  if p_status = 'enRoute' then
    update public.delivery_stops set status = 'enRoute' where id = v_stop.id;
    update public.deliveries set driver_status = 'in_transit',
           status = case when status in ('pending', 'optimized', 'dispatched') then 'inTransit' else status end
     where id = v_delivery.id;
    perform public.notify_customer(v_order.firebase_uid, 'order', 'Your order is on the way',
      v.full_name || ' is heading to you with order ' || v_order.id || '.');

  elsif p_status = 'delivered' then
    if v_photo is null and v_recipient is null then
      raise exception 'Add a proof of delivery: a photo or the name of the person who received it.';
    end if;
    if v_photo is not null and v_photo not like v_delivery.id || '/%' then
      raise exception 'The proof photo must be uploaded under this delivery''s folder.';
    end if;
    if v_order.total > 0 and coalesce(v_pay.status, '') <> 'success' then
      if v_pay.method = 'cash' then
        if p_cash_collected is null or round(p_cash_collected, 2) <> round(v_pay.amount, 2) then
          raise exception 'Collect the full cash amount of % before completing.', v_pay.amount;
        end if;
        update public.payments set status = 'success', reference_number = 'COD-' || v_order.id || '-' || left(v.firebase_uid, 8)
         where id = v_pay.id;
        perform public._write_audit(v.firebase_uid, v_delivery.branch_id, 'payment.cod_collected', 'order', v_order.id,
                                    jsonb_build_object('amount', v_pay.amount, 'delivery_id', v_delivery.id));
      else
        raise exception 'The online payment for % is not confirmed yet. Contact the branch before handing it over.', v_order.id;
      end if;
    end if;
    update public.delivery_stops
       set status = 'delivered', delivered_at = now(), proof_photo_path = v_photo, recipient_name = v_recipient,
           proof_note = coalesce(nullif(trim(coalesce(p_proof_note, '')), ''), proof_note)
     where id = v_stop.id;
    update public.orders set status = 'completed' where id = v_order.id;

  else -- failed
    if v_reason is null then raise exception 'Please give the reason the delivery failed.'; end if;
    update public.delivery_stops
       set status = 'failed', failed_at = now(), issue_reason = left(v_reason, 300),
           proof_note = coalesce(nullif(trim(coalesce(p_proof_note, '')), ''), proof_note)
     where id = v_stop.id;
    -- Return to branch: the order goes back to the dispatch queue.
    update public.orders set status = 'confirmed', rider_name = null, rider_phone = null
     where id = v_order.id and status = 'outForDelivery';
    perform public._notify_staff(v_delivery.branch_id, 'order', 'Failed delivery: ' || v_order.id,
      'Returning to branch. Reason: ' || left(v_reason, 150), v_order.id, null);
    perform public.notify_customer(v_order.firebase_uid, 'order', 'Delivery attempt failed',
      'We could not deliver order ' || v_order.id || ' (' || left(v_reason, 120) || '). The branch will contact you.');
    perform public._write_audit(v.firebase_uid, v_delivery.branch_id, 'delivery.failed', 'order', v_order.id,
                                jsonb_build_object('delivery_id', v_delivery.id, 'reason', v_reason));
  end if;

  select count(*) into v_open from public.delivery_stops
  where delivery_id = v_delivery.id and status not in ('delivered', 'failed', 'skipped');
  if v_open = 0 then
    update public.deliveries set status = 'completed' where id = v_delivery.id;
    insert into public.delivery_assignment_events (delivery_id, driver_uid, event, actor_uid)
    values (v_delivery.id, v.firebase_uid, 'completed', v.firebase_uid);
  end if;
  return public._delivery_for_driver(v_delivery.id);
end;
$$;

-- Returns {"accepted": bool, "tracking": bool}. tracking=false tells the
-- client to stop collecting location for this run.
create or replace function public.driver_post_location(
  p_delivery_id text,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_m real default null,
  p_recorded_at timestamptz default null,
  p_heading real default null,
  p_speed_mps real default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.drivers;
  v_delivery public.deliveries;
  v_at timestamptz := coalesce(p_recorded_at, now());
  v_last timestamptz;
begin
  v := public._require_driver();
  select * into v_delivery from public.deliveries where id = p_delivery_id;
  if not found or v_delivery.driver_uid is distinct from v.firebase_uid then
    raise exception 'That delivery is not assigned to you.';
  end if;
  if not v_delivery.tracking_active or v_delivery.driver_status not in ('picked_up', 'in_transit') then
    return jsonb_build_object('accepted', false, 'tracking', false);
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'Invalid coordinates.';
  end if;
  if v_at > now() + interval '2 minutes' or v_at < now() - interval '10 minutes' then
    raise exception 'The location timestamp is not current.';
  end if;

  select max(recorded_at) into v_last from public.driver_locations where delivery_id = v_delivery.id;
  if v_last is not null and v_at < v_last + interval '5 seconds' then
    return jsonb_build_object('accepted', false, 'tracking', true);
  end if;

  insert into public.driver_locations (delivery_id, driver_uid, latitude, longitude, accuracy_m, heading, speed_mps, recorded_at)
  values (v_delivery.id, v.firebase_uid, p_latitude, p_longitude, p_accuracy_m,
          case when p_heading >= 0 and p_heading < 360 then p_heading end,
          case when p_speed_mps >= 0 and p_speed_mps <= 100 then p_speed_mps end, v_at);
  -- Keep the trail short.
  delete from public.driver_locations
   where delivery_id = v_delivery.id
     and id < (select id from public.driver_locations where delivery_id = v_delivery.id
               order by id desc offset 499 limit 1);
  return jsonb_build_object('accepted', true, 'tracking', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Customer: tracking for their own order
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

  select latitude, longitude into v_dest_lat, v_dest_lng from public.customer_addresses
  where id = v_order.delivery_address_id and firebase_uid = v_uid;

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
-- 9. Proof-of-delivery photos (Supabase Storage). Skipped on databases
--    without the storage schema (local test databases).
--    Bucket 'delivery-proofs' is private. A driver may upload only under a
--    folder named after a run assigned to them; branch staff and the owner may
--    read; nobody else.
-- -----------------------------------------------------------------------------
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage')
     and exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public) values ('delivery-proofs', 'delivery-proofs', false)
    on conflict (id) do nothing;

    execute $p$drop policy if exists "driver uploads own proof" on storage.objects$p$;
    execute $p$create policy "driver uploads own proof" on storage.objects for insert to authenticated
      with check (bucket_id = 'delivery-proofs' and exists (
        select 1 from public.deliveries d
        where d.id = split_part(name, '/', 1)
          and d.driver_uid = public.current_firebase_uid()
          and d.driver_status in ('picked_up', 'in_transit')))$p$;
    execute $p$drop policy if exists "staff and driver read proof" on storage.objects$p$;
    execute $p$create policy "staff and driver read proof" on storage.objects for select to authenticated
      using (bucket_id = 'delivery-proofs' and exists (
        select 1 from public.deliveries d
        where d.id = split_part(name, '/', 1)
          and (public.staff_can_see_branch(d.branch_id) or d.driver_uid = public.current_firebase_uid())))$p$;
  end if;
end
$do$;

-- -----------------------------------------------------------------------------
-- 10. Grants
-- -----------------------------------------------------------------------------
revoke all on function public._trg_staff_not_driver() from public, anon, authenticated;
revoke all on function public._trg_delivery_tracking_cleanup() from public, anon, authenticated;
revoke all on function public._require_driver() from public, anon, authenticated;
revoke all on function public._delivery_for_driver(text) from public, anon, authenticated;
revoke all on function public._lock_my_run(text, public.drivers) from public, anon, authenticated;

do $g$
declare f text;
begin
  foreach f in array array[
    'public.owner_upsert_driver(text, text, text, uuid, text, text)',
    'public.owner_set_driver_status(text, text)',
    'public.staff_list_drivers(uuid)',
    'public.staff_assign_driver(text, text)',
    'public.staff_unassign_driver(text, text)',
    'public.staff_get_delivery_tracking(text)',
    'public.staff_active_driver_positions(uuid)',
    'public.get_my_driver_context()',
    'public.driver_set_availability(boolean)',
    'public.driver_list_my_deliveries(boolean)',
    'public.driver_respond_assignment(text, text, text)',
    'public.driver_mark_picked_up(text)',
    'public.driver_update_stop(uuid, text, text, text, text, text, numeric)',
    'public.driver_post_location(text, double precision, double precision, real, timestamptz, real, real)',
    'public.customer_get_delivery_tracking(text)'
  ] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end
$g$;

commit;
