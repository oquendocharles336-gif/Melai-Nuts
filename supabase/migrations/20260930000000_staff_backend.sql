-- =============================================================================
-- Melai Nuts — Migration 20260930000000
-- Staff backend: access control, branch inventory batches (FEFO), stock
-- transfers, real POS sales, order/payment/refund handling, notifications and
-- the dashboard.
-- =============================================================================
-- RUN ORDER: schema.sql -> 20260928000000 -> 20260928010000 -> 20260929000000
--            -> 20260929010000 -> THIS FILE.
-- Safe to re-run (idempotent) and atomic (one transaction).
--
-- WHY A DATABASE-SIDE STAFF REGISTRY
--   Roles live in Firestore (`users/{uid}`), and Postgres cannot read Firestore.
--   Row Level Security only knows the Firebase UID (`auth.jwt() ->> 'sub'`).
--   `staff_members` is therefore the database's own record of who may act as
--   staff/owner, for which branch, and with which permissions. Every staff RPC
--   and policy checks it, so a modified client that skips the Flutter route
--   guards still cannot read or change anything it is not entitled to.
--   It is written ONLY by owner_upsert_staff_member / owner_set_staff_active.
--
--   ONE-TIME BOOTSTRAP (SQL editor, cannot be done from the app): register the
--   first owner, then owners register staff from the app (User Management):
--     insert into public.staff_members (firebase_uid, full_name, email, role)
--     values ('<owner firebase uid>', '<name>', '<email>', 'owner');
--   Staff created before this migration must be registered the same way:
--     insert into public.staff_members (firebase_uid, full_name, email, role, branch_id)
--     select '<staff firebase uid>', '<name>', '<email>', 'staff', b.id
--     from public.branches b where b.name = '<branch name>';
--
--   Roles: only the two that already exist in the app are used ('staff',
--   'owner'). Owner is a superset of staff, exactly as in firestore.rules.
--
-- WALK-IN SALES
--   POS sales are ordinary rows in `orders` (so reports, refunds, stock and the
--   order/payment state machines all apply unchanged). A sale with no loyalty
--   customer is attached to one system row, customer_profiles 'walk-in', which
--   earns no points and receives no notifications.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Staff registry + access helpers
-- -----------------------------------------------------------------------------
create table if not exists public.staff_members (
  firebase_uid text primary key,
  full_name text not null default '',
  email text not null default '',
  role text not null check (role in ('staff', 'owner')),
  branch_id uuid references public.branches(id) on delete restrict,
  is_active boolean not null default true,
  -- Receive / adjust / transfer stock in the staff member's OWN branch.
  can_manage_inventory boolean not null default true,
  -- Review (approve / reject / complete) refund requests for the own branch.
  can_review_refunds boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint staff_branch_required check (role = 'owner' or branch_id is not null)
);
drop trigger if exists staff_members_set_updated_at on public.staff_members;
create trigger staff_members_set_updated_at before update on public.staff_members
  for each row execute function public.set_updated_at();
alter table public.staff_members enable row level security;

create or replace function public._default_restock_threshold()
returns int language sql immutable as $$ select 20 $$;

-- The caller's active staff row, or a clear error. Every staff RPC starts here.
--   p_branch_id  : the branch being touched (staff may only use their own)
--   p_permission : 'inventory' | 'refunds' (owners always pass)
create or replace function public._require_staff(
  p_branch_id uuid default null,
  p_permission text default null
)
returns public.staff_members
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.staff_members;
begin
  select * into v from public.staff_members
  where firebase_uid = public.current_firebase_uid();
  if not found then
    raise exception 'Your staff account is not set up yet. Please contact the owner.';
  end if;
  if not v.is_active then
    raise exception 'Your staff account has been deactivated. Please contact the owner.';
  end if;
  if p_branch_id is not null and v.role <> 'owner' and v.branch_id is distinct from p_branch_id then
    raise exception 'You can only work in your assigned branch.';
  end if;
  if p_permission is not null and v.role <> 'owner' then
    if p_permission = 'inventory' and not v.can_manage_inventory then
      raise exception 'You do not have permission to manage inventory.';
    elsif p_permission = 'refunds' and not v.can_review_refunds then
      raise exception 'You do not have permission to review refunds.';
    end if;
  end if;
  return v;
end;
$$;

create or replace function public._require_owner()
returns public.staff_members
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.staff_members;
begin
  select * into v from public.staff_members
  where firebase_uid = public.current_firebase_uid() and is_active and role = 'owner';
  if not found then
    raise exception 'Only an active owner can do this.';
  end if;
  return v;
end;
$$;

-- Policy helpers (evaluated for the querying role, so they are granted below).
create or replace function public.staff_can_see_branch(p_branch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.staff_members s
    where s.firebase_uid = public.current_firebase_uid()
      and s.is_active
      and (s.role = 'owner' or s.branch_id = p_branch_id)
  )
$$;

create or replace function public.staff_is_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.staff_members s
    where s.firebase_uid = public.current_firebase_uid() and s.is_active and s.role = 'owner'
  )
$$;

create or replace function public.staff_has_permission(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.staff_members s
    where s.firebase_uid = public.current_firebase_uid()
      and s.is_active
      and (s.role = 'owner'
           or (p_permission = 'inventory' and s.can_manage_inventory)
           or (p_permission = 'refunds' and s.can_review_refunds))
  )
$$;

-- The signed-in staff member's own profile (drives the Profile tab, the branch
-- shown everywhere and which buttons appear).
create or replace function public.get_my_staff_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.staff_members;
  v_branch_name text;
begin
  v := public._require_staff();
  select name into v_branch_name from public.branches where id = v.branch_id;
  return jsonb_build_object(
    'firebase_uid', v.firebase_uid,
    'full_name', v.full_name,
    'email', v.email,
    'role', v.role,
    'branch_id', v.branch_id,
    'branch_name', v_branch_name,
    'is_active', v.is_active,
    'can_manage_inventory', (v.role = 'owner' or v.can_manage_inventory),
    'can_review_refunds', (v.role = 'owner' or v.can_review_refunds),
    'created_at', v.created_at
  );
end;
$$;

-- The ONE read the app makes after sign-in to decide whether a staff session may
-- exist at all. Unlike get_my_staff_profile() it never raises for "no row" or
-- "deactivated": it returns a status so the app can tell "not set up" and
-- "suspended" apart from network/auth trouble, and fail closed on the latter.
--
--   {"status": "not_provisioned"}          signed in, no staff_members row
--   {"status": "inactive"}                 row exists but was deactivated
--   {"status": "active", "profile": {...}} same fields as get_my_staff_profile()
--
-- Always about the caller and nobody else (identified by the verified Firebase
-- token, never by a client-sent value). No details are revealed for the two
-- non-active outcomes.
create or replace function public.get_my_staff_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v public.staff_members;
  v_branch_name text;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select * into v from public.staff_members where firebase_uid = v_uid;
  if not found then
    return jsonb_build_object('status', 'not_provisioned');
  end if;
  if not v.is_active then
    return jsonb_build_object('status', 'inactive');
  end if;

  select name into v_branch_name from public.branches where id = v.branch_id;
  return jsonb_build_object(
    'status', 'active',
    'profile', jsonb_build_object(
      'firebase_uid', v.firebase_uid,
      'full_name', v.full_name,
      'email', v.email,
      'role', v.role,
      'branch_id', v.branch_id,
      'branch_name', v_branch_name,
      'is_active', v.is_active,
      'can_manage_inventory', (v.role = 'owner' or v.can_manage_inventory),
      'can_review_refunds', (v.role = 'owner' or v.can_review_refunds),
      'created_at', v.created_at
    )
  );
end;
$$;

-- Owner-only provisioning (called by the app right after it creates the
-- Firebase account, and by the SQL bootstrap above for the first owner).
create or replace function public.owner_upsert_staff_member(
  p_firebase_uid text,
  p_full_name text,
  p_email text,
  p_role text,
  p_branch_name text default null,
  p_is_active boolean default true,
  p_can_manage_inventory boolean default true,
  p_can_review_refunds boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_branch_id uuid;
begin
  perform public._require_owner();
  if coalesce(trim(p_firebase_uid), '') = '' then raise exception 'A staff account id is required.'; end if;
  if p_role not in ('staff', 'owner') then raise exception 'Unsupported staff role.'; end if;
  if p_role = 'staff' then
    select id into v_branch_id from public.branches where name = p_branch_name;
    if v_branch_id is null then raise exception 'Please choose a valid branch for this staff member.'; end if;
  end if;

  insert into public.staff_members
    (firebase_uid, full_name, email, role, branch_id, is_active, can_manage_inventory, can_review_refunds)
  values
    (p_firebase_uid, left(coalesce(p_full_name, ''), 100), left(coalesce(p_email, ''), 254), p_role,
     v_branch_id, coalesce(p_is_active, true), coalesce(p_can_manage_inventory, true), coalesce(p_can_review_refunds, false))
  on conflict (firebase_uid) do update
    set full_name = excluded.full_name,
        email = excluded.email,
        role = excluded.role,
        branch_id = excluded.branch_id,
        is_active = excluded.is_active,
        can_manage_inventory = excluded.can_manage_inventory,
        can_review_refunds = excluded.can_review_refunds;
end;
$$;

create or replace function public.owner_set_staff_active(p_firebase_uid text, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_owner();
  if p_firebase_uid = public.current_firebase_uid() and not coalesce(p_is_active, true) then
    raise exception 'You cannot deactivate your own account.';
  end if;
  update public.staff_members set is_active = coalesce(p_is_active, true)
  where firebase_uid = p_firebase_uid;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Inventory batches (FEFO), thresholds and the stock ledger
-- -----------------------------------------------------------------------------
create table if not exists public.inventory_batches (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  variant_id uuid not null references public.product_variants(id) on delete cascade,
  batch_code text not null check (length(trim(batch_code)) between 1 and 40),
  received_date date not null default current_date,
  expiration_date date not null,
  quantity int not null default 0 check (quantity >= 0),
  initial_quantity int not null check (initial_quantity > 0),
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (branch_id, variant_id, batch_code),
  check (expiration_date >= received_date)
);
create index if not exists inventory_batches_branch_variant_idx
  on public.inventory_batches (branch_id, variant_id, expiration_date);
create index if not exists inventory_batches_expiry_idx
  on public.inventory_batches (branch_id, expiration_date) where quantity > 0;
drop trigger if exists inventory_batches_set_updated_at on public.inventory_batches;
create trigger inventory_batches_set_updated_at before update on public.inventory_batches
  for each row execute function public.set_updated_at();
alter table public.inventory_batches enable row level security;

create table if not exists public.stock_thresholds (
  branch_id uuid not null references public.branches(id) on delete cascade,
  variant_id uuid not null references public.product_variants(id) on delete cascade,
  restock_threshold int not null check (restock_threshold >= 0),
  updated_at timestamptz not null default now(),
  primary key (branch_id, variant_id)
);
alter table public.stock_thresholds enable row level security;

-- Append-only audit trail of every stock change.
create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  variant_id uuid references public.product_variants(id) on delete set null,
  batch_id uuid references public.inventory_batches(id) on delete set null,
  movement_type text not null check (movement_type in
    ('receive', 'assign', 'adjust', 'sale', 'sale_cancel', 'transfer_out', 'transfer_in')),
  quantity_change int not null,
  batch_quantity_after int,
  reason text,
  reference text,
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists stock_movements_branch_idx on public.stock_movements (branch_id, created_at desc);
alter table public.stock_movements enable row level security;

-- Batch-level FEFO consumption. p_strict = false consumes what exists (used for
-- customer orders, where branch_inventory may hold stock that was never
-- assigned a batch); p_strict = true refuses to over-consume (transfers).
create or replace function public._consume_batches_fefo(
  p_branch_id uuid, p_product_id uuid, p_variant_id uuid, p_qty int,
  p_type text, p_reference text, p_uid text, p_strict boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_remaining int := p_qty;
  v_take int;
  v_after int;
  v_lines jsonb := '[]'::jsonb;
  b record;
begin
  for b in
    select * from public.inventory_batches
    where branch_id = p_branch_id and variant_id = p_variant_id and quantity > 0
    order by expiration_date, received_date, created_at
    for update
  loop
    exit when v_remaining <= 0;
    v_take := least(b.quantity, v_remaining);
    update public.inventory_batches set quantity = quantity - v_take
    where id = b.id returning quantity into v_after;
    insert into public.stock_movements
      (branch_id, product_id, variant_id, batch_id, movement_type, quantity_change, batch_quantity_after, reference, created_by)
    values (p_branch_id, p_product_id, p_variant_id, b.id, p_type, -v_take, v_after, p_reference, p_uid);
    v_lines := v_lines || jsonb_build_object(
      'batch_code', b.batch_code, 'expiration_date', b.expiration_date,
      'received_date', b.received_date, 'quantity', v_take);
    v_remaining := v_remaining - v_take;
  end loop;
  if v_remaining > 0 and p_strict then
    raise exception 'Not enough batched stock at this branch. Assign batches to the remaining units first.';
  end if;
  return v_lines;
end;
$$;

-- Keeps batches consistent when branch_inventory changes WITHOUT going through
-- a staff inventory function — i.e. a customer order (deduct) or a cancelled
-- order (restore). Staff inventory functions set app.inventory_managed and
-- maintain both sides themselves.
create or replace function public._sync_batches_with_inventory()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_delta int;
  v_remaining int;
  v_take int;
  v_after int;
  b record;
  v_ref text := nullif(current_setting('app.stock_reference', true), '');
begin
  if coalesce(current_setting('app.inventory_managed', true), '') = '1' then return new; end if;
  if new.variant_id is null then return new; end if;
  v_delta := new.quantity - old.quantity;
  if v_delta = 0 then return new; end if;

  if v_delta < 0 then
    perform public._consume_batches_fefo(new.branch_id, new.product_id, new.variant_id, -v_delta,
                                         'sale', v_ref, null, false);
  else
    v_remaining := v_delta;
    for b in
      select id, quantity, initial_quantity from public.inventory_batches
      where branch_id = new.branch_id and variant_id = new.variant_id and quantity < initial_quantity
      order by expiration_date, received_date
      for update
    loop
      exit when v_remaining <= 0;
      v_take := least(b.initial_quantity - b.quantity, v_remaining);
      update public.inventory_batches set quantity = quantity + v_take
      where id = b.id returning quantity into v_after;
      insert into public.stock_movements
        (branch_id, product_id, variant_id, batch_id, movement_type, quantity_change, batch_quantity_after, reference)
      values (new.branch_id, new.product_id, new.variant_id, b.id, 'sale_cancel', v_take, v_after, v_ref);
      v_remaining := v_remaining - v_take;
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists branch_inventory_sync_batches on public.branch_inventory;
create trigger branch_inventory_sync_batches
  after update of quantity on public.branch_inventory
  for each row execute function public._sync_batches_with_inventory();

-- Receive a new batch (new stock), or — with p_assign_existing — give a batch
-- to units that are already counted in branch stock but have no batch yet.
create or replace function public.staff_receive_batch(
  p_branch_id uuid,
  p_variant_id uuid,
  p_batch_code text,
  p_quantity int,
  p_expiration_date date,
  p_received_date date default null,
  p_restock_threshold int default null,
  p_assign_existing boolean default false
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
begin
  v_staff := public._require_staff(p_branch_id, 'inventory');
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

  return v_batch_id;
end;
$$;

-- Adjust one batch up or down with a reason (damage, count correction, ...).
create or replace function public.staff_adjust_batch(
  p_batch_id uuid,
  p_delta int,
  p_reason text,
  p_note text default null
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
begin
  select * into b from public.inventory_batches where id = p_batch_id for update;
  if not found then raise exception 'That batch could not be found.'; end if;
  v_staff := public._require_staff(b.branch_id, 'inventory');
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

  return jsonb_build_object('previous_quantity', b.quantity, 'new_quantity', v_new, 'adjustment', p_delta);
end;
$$;

-- Read model for every inventory screen: one row per variant (with branch
-- totals, threshold and how much is not yet assigned to a batch) plus the
-- active batches. Staff always get their own branch; owners pass p_branch_id.
create or replace function public.staff_get_inventory(p_branch_id uuid default null)
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

  return jsonb_build_object(
    'branch_id', v_branch,
    'branch_name', (select name from public.branches where id = v_branch),
    'items', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.product_name, x.variant_label), '[]'::jsonb)
      from (
        select p.id as product_id, p.name as product_name, p.category_id,
               pv.id as variant_id, pv.label as variant_label, pv.sku, pv.price,
               coalesce(bi.quantity, 0) as quantity,
               coalesce(th.restock_threshold, public._default_restock_threshold()) as restock_threshold,
               coalesce((select sum(b.quantity) from public.inventory_batches b
                         where b.branch_id = v_branch and b.variant_id = pv.id), 0)::int as batched_quantity
        from public.products p
        join public.product_variants pv on pv.product_id = p.id
        left join public.branch_inventory bi on bi.branch_id = v_branch and bi.variant_id = pv.id
        left join public.stock_thresholds th on th.branch_id = v_branch and th.variant_id = pv.id
        where p.is_active
      ) x
    ),
    'batches', (
      select coalesce(jsonb_agg(to_jsonb(y) order by y.expiration_date, y.received_date), '[]'::jsonb)
      from (
        select b.id, b.branch_id, br.name as branch_name, b.product_id, b.variant_id,
               b.batch_code, b.received_date, b.expiration_date, b.quantity, b.initial_quantity
        from public.inventory_batches b
        join public.branches br on br.id = b.branch_id
        where b.branch_id = v_branch and b.quantity > 0
      ) y
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Stock transfers between branches
--    requested (by receiving branch) -> in_transit (source ships, FEFO batches
--    leave source stock) -> received (batches + quantity land at destination).
--    A request can also be rejected (source) or cancelled (requester).
-- -----------------------------------------------------------------------------
create sequence if not exists public.transfer_code_seq start 1001;

create table if not exists public.stock_transfers (
  id text primary key default ('TRF-' || nextval('public.transfer_code_seq')::text),
  from_branch_id uuid not null references public.branches(id),
  to_branch_id uuid not null references public.branches(id),
  product_id uuid not null references public.products(id),
  variant_id uuid not null references public.product_variants(id),
  quantity int not null check (quantity > 0),
  status text not null default 'requested'
    check (status in ('requested', 'in_transit', 'received', 'rejected', 'cancelled')),
  note text not null default '',
  requested_by text not null,
  requested_at timestamptz not null default now(),
  reviewed_by text,
  shipped_at timestamptz,
  received_by text,
  received_at timestamptz,
  updated_at timestamptz not null default now(),
  check (from_branch_id <> to_branch_id)
);
create index if not exists stock_transfers_from_idx on public.stock_transfers (from_branch_id, status);
create index if not exists stock_transfers_to_idx on public.stock_transfers (to_branch_id, status);
drop trigger if exists stock_transfers_set_updated_at on public.stock_transfers;
create trigger stock_transfers_set_updated_at before update on public.stock_transfers
  for each row execute function public.set_updated_at();
alter table public.stock_transfers enable row level security;

create table if not exists public.stock_transfer_batches (
  id uuid primary key default gen_random_uuid(),
  transfer_id text not null references public.stock_transfers(id) on delete cascade,
  batch_code text not null,
  received_date date not null,
  expiration_date date not null,
  quantity int not null check (quantity > 0)
);
alter table public.stock_transfer_batches enable row level security;

create or replace function public.staff_request_transfer(
  p_from_branch_id uuid,
  p_to_branch_id uuid,
  p_variant_id uuid,
  p_quantity int,
  p_note text default null
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
begin
  -- The requester works at the DESTINATION branch.
  v_staff := public._require_staff(p_to_branch_id, 'inventory');
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
  return v_id;
end;
$$;

-- p_action: 'ship' | 'reject' (source branch), 'cancel' | 'receive' (destination).
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
    if t.status <> 'requested' then raise exception 'This transfer is no longer waiting for approval.'; end if;
  elsif p_action in ('cancel', 'receive') then
    v_staff := public._require_staff(t.to_branch_id, 'inventory');
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

create or replace function public.staff_list_transfers(p_branch_id uuid default null)
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
  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at desc), '[]'::jsonb)
    from (
      select t.id, t.status, t.quantity, t.note, t.requested_at, t.shipped_at, t.received_at,
             t.from_branch_id, fb.name as from_branch_name,
             t.to_branch_id, tb.name as to_branch_name,
             t.product_id, p.name as product_name, t.variant_id, pv.label as variant_label,
             (select coalesce(jsonb_agg(jsonb_build_object(
                'batch_code', sb.batch_code, 'expiration_date', sb.expiration_date, 'quantity', sb.quantity)
                order by sb.expiration_date), '[]'::jsonb)
              from public.stock_transfer_batches sb where sb.transfer_id = t.id) as batches
      from public.stock_transfers t
      join public.branches fb on fb.id = t.from_branch_id
      join public.branches tb on tb.id = t.to_branch_id
      join public.products p on p.id = t.product_id
      join public.product_variants pv on pv.id = t.variant_id
      where (v_branch is null or t.from_branch_id = v_branch or t.to_branch_id = v_branch)
      order by t.requested_at desc
      limit 200
    ) x
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Staff notifications
-- -----------------------------------------------------------------------------
create table if not exists public.staff_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_uid text not null,
  branch_id uuid references public.branches(id) on delete cascade,
  category text not null check (category in ('order', 'inventory', 'transfer', 'refund', 'system')),
  title text not null,
  body text not null,
  reference text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists staff_notifications_recipient_idx
  on public.staff_notifications (recipient_uid, created_at desc);
alter table public.staff_notifications enable row level security;

create or replace function public._notify_staff(
  p_branch_id uuid, p_category text, p_title text, p_body text,
  p_reference text default null, p_permission text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.staff_notifications (recipient_uid, branch_id, category, title, body, reference)
  select s.firebase_uid, p_branch_id, p_category, p_title, p_body, p_reference
  from public.staff_members s
  where s.is_active and s.role = 'staff' and s.branch_id = p_branch_id
    and (p_permission is null
         or (p_permission = 'inventory' and s.can_manage_inventory)
         or (p_permission = 'refunds' and s.can_review_refunds));
end;
$$;

-- Non-critical side effects must never abort the transaction that caused them.
create or replace function public._trg_staff_notify_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if coalesce(current_setting('app.pos_sale', true), '') <> '1' then
      perform public._notify_staff(new.branch_id, 'order',
        'New ' || case when new.is_delivery then 'delivery' else 'pickup' end || ' order ' || new.id,
        'Total ₱' || to_char(new.total, 'FM999,999,990.00') || ' • ' || new.payment_method,
        new.id);
    end if;
  exception when others then
    raise warning 'staff order notification for % failed: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;
drop trigger if exists orders_notify_staff on public.orders;
create trigger orders_notify_staff after insert on public.orders
  for each row execute function public._trg_staff_notify_order();

create or replace function public._trg_staff_notify_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_thr int;
  v_name text;
begin
  begin
    if new.variant_id is null or new.quantity >= old.quantity then return new; end if;
    select coalesce(
             (select restock_threshold from public.stock_thresholds
              where branch_id = new.branch_id and variant_id = new.variant_id),
             public._default_restock_threshold()) into v_thr;
    select p.name || ' (' || pv.label || ')' into v_name
    from public.products p join public.product_variants pv on pv.product_id = p.id
    where pv.id = new.variant_id;
    if new.quantity = 0 then
      perform public._notify_staff(new.branch_id, 'inventory', 'Out of stock: ' || v_name,
        'This item has run out at your branch.', new.variant_id::text, 'inventory');
    elsif new.quantity <= v_thr and old.quantity > v_thr then
      perform public._notify_staff(new.branch_id, 'inventory', 'Low stock: ' || v_name,
        'Only ' || new.quantity || ' left (restock level ' || v_thr || ').', new.variant_id::text, 'inventory');
    end if;
  exception when others then
    raise warning 'staff stock notification failed: %', sqlerrm;
  end;
  return new;
end;
$$;
drop trigger if exists branch_inventory_notify_staff on public.branch_inventory;
create trigger branch_inventory_notify_staff after update of quantity on public.branch_inventory
  for each row execute function public._trg_staff_notify_stock();

create or replace function public._trg_staff_notify_transfer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_from text;
  v_to text;
begin
  begin
    select p.name || ' (' || pv.label || ')' into v_name
    from public.products p join public.product_variants pv on pv.product_id = p.id where pv.id = new.variant_id;
    select name into v_from from public.branches where id = new.from_branch_id;
    select name into v_to from public.branches where id = new.to_branch_id;
    if tg_op = 'INSERT' then
      perform public._notify_staff(new.from_branch_id, 'transfer', 'Transfer requested ' || new.id,
        v_to || ' requests ' || new.quantity || ' × ' || v_name || '.', new.id, 'inventory');
    elsif new.status is distinct from old.status then
      if new.status = 'in_transit' then
        perform public._notify_staff(new.to_branch_id, 'transfer', 'Transfer on its way ' || new.id,
          v_from || ' shipped ' || new.quantity || ' × ' || v_name || '. Receive it when it arrives.', new.id, 'inventory');
      elsif new.status = 'rejected' then
        perform public._notify_staff(new.to_branch_id, 'transfer', 'Transfer declined ' || new.id,
          v_from || ' declined your request for ' || v_name || '.', new.id, 'inventory');
      elsif new.status = 'received' then
        perform public._notify_staff(new.from_branch_id, 'transfer', 'Transfer received ' || new.id,
          v_to || ' received ' || new.quantity || ' × ' || v_name || '.', new.id, 'inventory');
      end if;
    end if;
  exception when others then
    raise warning 'staff transfer notification for % failed: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;
drop trigger if exists stock_transfers_notify_staff on public.stock_transfers;
create trigger stock_transfers_notify_staff after insert or update of status on public.stock_transfers
  for each row execute function public._trg_staff_notify_transfer();

create or replace function public._trg_staff_notify_refund()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_branch uuid;
begin
  begin
    select branch_id into v_branch from public.orders where id = new.order_id;
    if v_branch is not null then
      perform public._notify_staff(v_branch, 'refund', 'Refund requested ' || new.id,
        'Order ' || new.order_id || ' • ₱' || to_char(new.amount, 'FM999,999,990.00'), new.id, 'refunds');
    end if;
  exception when others then
    raise warning 'staff refund notification for % failed: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;
drop trigger if exists refund_requests_notify_staff on public.refund_requests;
create trigger refund_requests_notify_staff after insert on public.refund_requests
  for each row execute function public._trg_staff_notify_refund();

-- -----------------------------------------------------------------------------
-- 5. Walk-in sales (POS)
-- -----------------------------------------------------------------------------
insert into public.customer_profiles (firebase_uid, full_name)
values ('walk-in', 'Walk-in Customer')
on conflict (firebase_uid) do nothing;

-- Walk-ins never earn points and never get inbox notifications.
create or replace function public.compute_points_earned()
returns trigger
language plpgsql
as $$
begin
  if new.firebase_uid = 'walk-in' then
    new.points_earned := 0;
  else
    new.points_earned := greatest(0, floor(new.total / 50)::int);
  end if;
  return new;
end;
$$;

create or replace function public.notify_customer(
  p_uid text, p_category text, p_title text, p_body text
) returns void language plpgsql security definer set search_path = public as $$
begin
  if p_uid = 'walk-in' then return; end if;
  insert into public.notifications (firebase_uid, category, title, body)
  values (p_uid, p_category, p_title, p_body);
end;
$$;

create table if not exists public.pos_sales (
  order_id text primary key references public.orders(id) on delete cascade,
  branch_id uuid not null references public.branches(id),
  staff_uid text not null,
  staff_name text not null default '',
  payment_reference text,
  cash_received numeric(10, 2),
  change_given numeric(10, 2),
  created_at timestamptz not null default now()
);
create index if not exists pos_sales_branch_idx on public.pos_sales (branch_id, created_at desc);
alter table public.pos_sales enable row level security;

-- Finds a loyalty customer by RFID card number, phone or e-mail (EXACT match
-- only, so it cannot be used to browse customers). Returns just what the
-- cashier needs.
create or replace function public.staff_lookup_customer(p_query text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := trim(coalesce(p_query, ''));
begin
  perform public._require_staff();
  if length(v_q) < 4 then raise exception 'Enter at least 4 characters to look up a customer.'; end if;
  return (
    select coalesce(jsonb_agg(t.j), '[]'::jsonb)
    from (
      select jsonb_build_object(
        'firebase_uid', cp.firebase_uid,
        'full_name', cp.full_name,
        'points_balance', coalesce(la.points_balance, 0)) as j
      from public.customer_profiles cp
      left join public.loyalty_accounts la on la.firebase_uid = cp.firebase_uid
      where cp.firebase_uid <> 'walk-in'
        and (cp.rfid_card_number = v_q or cp.phone = v_q or lower(cp.email) = lower(v_q))
      limit 5
    ) t
  );
end;
$$;

-- Rings up a sale. Prices and stock are decided HERE from the catalog and
-- branch_inventory — the client only says which variants and how many.
-- p_items: [{"variant_id": "<uuid>", "quantity": 2}, ...]
-- p_payment_method: 'cash' | 'gcash' | 'card'. Cash needs p_cash_received;
-- GCash/card need the terminal / wallet reference number.
create or replace function public.staff_create_pos_sale(
  p_branch_id uuid,
  p_items jsonb,
  p_payment_method text,
  p_payment_reference text default null,
  p_cash_received numeric default null,
  p_customer_uid text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_uid text := coalesce(nullif(trim(coalesce(p_customer_uid, '')), ''), 'walk-in');
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_branch_name text;
  v_existing text;
  v_line record;
  v_var record;
  v_avail int;
  v_subtotal numeric := 0;
  v_order_id text;
  v_payment_id text;
  v_code text;
  v_label text;
  v_ref text := nullif(trim(coalesce(p_payment_reference, '')), '');
  v_change numeric := 0;
  v_count int;
begin
  v_staff := public._require_staff(p_branch_id);
  select name into v_branch_name from public.branches where id = p_branch_id;
  if v_branch_name is null then raise exception 'That branch could not be found.'; end if;

  if v_uid <> 'walk-in' and not exists (select 1 from public.customer_profiles where firebase_uid = v_uid) then
    raise exception 'That loyalty customer could not be found.';
  end if;

  if v_key is not null then
    if length(v_key) > 200 then raise exception 'Invalid checkout reference.'; end if;
    perform pg_advisory_xact_lock(hashtextextended('pos:' || v_uid || ':' || v_key, 0));
    select id into v_existing from public.orders where firebase_uid = v_uid and idempotency_key = v_key;
    if found then
      return (
        select jsonb_build_object('order_id', o.id, 'total', o.total, 'points_earned', o.points_earned,
                                  'payment_id', p.id, 'change', coalesce(ps.change_given, 0), 'already_recorded', true)
        from public.orders o
        left join public.payments p on p.order_id = o.id
        left join public.pos_sales ps on ps.order_id = o.id
        where o.id = v_existing
      );
    end if;
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'The sale has no items.';
  end if;
  if jsonb_array_length(p_items) > 100 then raise exception 'Too many lines in one sale.'; end if;

  select case p_payment_method when 'cash' then 'cash' when 'gcash' then 'gcash' when 'card' then 'card' end,
         case p_payment_method when 'cash' then 'Cash (In-store)' when 'gcash' then 'GCash (In-store)'
                               when 'card' then 'Card (In-store)' end
  into v_code, v_label;
  if v_code is null then raise exception 'Unsupported payment method.'; end if;
  if v_code <> 'cash' and (v_ref is null or length(v_ref) < 4) then
    raise exception 'Enter the payment reference number from the terminal or wallet.';
  end if;

  -- Validate every line and lock its stock row (variant order = lock order).
  for v_line in
    select (e ->> 'variant_id')::uuid as variant_id, sum((e ->> 'quantity')::int)::int as qty
    from jsonb_array_elements(p_items) e
    group by 1 order by 1
  loop
    if v_line.qty <= 0 or v_line.qty > 1000 then raise exception 'Invalid quantity in this sale.'; end if;
    select pv.id, pv.product_id, pv.label, pv.price, p.name into v_var
    from public.product_variants pv join public.products p on p.id = pv.product_id
    where pv.id = v_line.variant_id and p.is_active;
    if not found then raise exception 'A product in this sale is no longer available.'; end if;
    select quantity into v_avail from public.branch_inventory
    where branch_id = p_branch_id and variant_id = v_line.variant_id for update;
    if coalesce(v_avail, 0) < v_line.qty then
      raise exception 'Only % left of % (%) at this branch.', coalesce(v_avail, 0), v_var.name, v_var.label;
    end if;
    v_subtotal := v_subtotal + v_var.price * v_line.qty;
  end loop;

  if v_code = 'cash' then
    if p_cash_received is null or p_cash_received < v_subtotal then
      raise exception 'The cash received is less than the total.';
    end if;
    v_change := p_cash_received - v_subtotal;
  end if;

  perform set_config('app.pos_sale', '1', true);

  insert into public.orders
    (firebase_uid, branch_id, branch_name, is_delivery, subtotal, discount, delivery_fee, total,
     payment_method, idempotency_key)
  values (v_uid, p_branch_id, v_branch_name, false, v_subtotal, 0, 0, v_subtotal, v_label, v_key)
  returning id into v_order_id;

  perform set_config('app.stock_reference', v_order_id, true);

  for v_line in
    select (e ->> 'variant_id')::uuid as variant_id, sum((e ->> 'quantity')::int)::int as qty
    from jsonb_array_elements(p_items) e
    group by 1 order by 1
  loop
    select pv.product_id, pv.label, pv.price, p.name into v_var
    from public.product_variants pv join public.products p on p.id = pv.product_id
    where pv.id = v_line.variant_id;
    insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
    values (v_order_id, v_var.product_id, v_line.variant_id, v_var.name, v_var.label, v_line.qty, v_var.price);
    -- The sync trigger takes these units out of the soonest-expiring batches.
    update public.branch_inventory set quantity = quantity - v_line.qty
    where branch_id = p_branch_id and variant_id = v_line.variant_id;
  end loop;

  insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number)
  values (v_order_id, v_uid, v_code, 'pending', v_subtotal, coalesce(v_ref, v_order_id))
  returning id into v_payment_id;

  insert into public.pos_sales (order_id, branch_id, staff_uid, staff_name, payment_reference, cash_received, change_given)
  values (v_order_id, p_branch_id, v_staff.firebase_uid, v_staff.full_name, v_ref,
          case when v_code = 'cash' then p_cash_received end,
          case when v_code = 'cash' then v_change end);

  -- Money is taken at the counter, so the sale is paid and handed over now.
  update public.payments set status = 'success' where id = v_payment_id;
  update public.orders set status = 'completed' where id = v_order_id;

  select count(*) into v_count from public.order_items where order_id = v_order_id;
  return (
    select jsonb_build_object('order_id', o.id, 'total', o.total, 'points_earned', o.points_earned,
                              'payment_id', v_payment_id, 'change', v_change, 'line_count', v_count,
                              'already_recorded', false)
    from public.orders o where o.id = v_order_id
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Orders, payments and refunds for staff
-- -----------------------------------------------------------------------------
create or replace function public.staff_list_orders(
  p_branch_id uuid default null,
  p_statuses text[] default null,
  p_since timestamptz default null,
  p_limit int default 100,
  p_order_id text default null
)
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

  return (
    select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb)
    from (
      select o.created_at,
        jsonb_build_object(
          'id', o.id, 'created_at', o.created_at, 'status', o.status,
          'branch_id', o.branch_id, 'branch_name', o.branch_name, 'is_delivery', o.is_delivery,
          'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', o.total,
          'payment_method', o.payment_method, 'points_earned', o.points_earned,
          'customer_notes', o.customer_notes, 'contact_phone', o.contact_phone,
          'delivery_address_text', o.delivery_address_text,
          'rider_name', o.rider_name, 'eta_label', o.eta_label,
          'customer_name', case when o.firebase_uid = 'walk-in' then null else nullif(cp.full_name, '') end,
          'is_pos', (ps.order_id is not null),
          'cashier_name', nullif(ps.staff_name, ''),
          'cash_received', ps.cash_received, 'change_given', ps.change_given,
          'items', (select coalesce(jsonb_agg(jsonb_build_object(
                      'product_name', i.product_name, 'variant_label', i.variant_label,
                      'quantity', i.quantity, 'unit_price', i.unit_price)), '[]'::jsonb)
                    from public.order_items i where i.order_id = o.id),
          'payment', (select jsonb_build_object('id', pay.id, 'method', pay.method, 'status', pay.status,
                                                'reference_number', pay.reference_number, 'amount', pay.amount)
                      from public.payments pay where pay.order_id = o.id limit 1)
        ) as j
      from public.orders o
      left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
      left join public.pos_sales ps on ps.order_id = o.id
      where o.branch_id = v_branch
        and (p_statuses is null or o.status = any(p_statuses))
        and (p_since is null or o.created_at >= p_since)
        and (p_order_id is null or o.id = p_order_id)
      order by o.created_at desc
      limit least(greatest(coalesce(p_limit, 100), 1), 300)
    ) x
  );
end;
$$;

create or replace function public.staff_update_order_status(
  p_order_id text,
  p_status text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.orders;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'That order could not be found.'; end if;
  perform public._require_staff(o.branch_id);
  if p_status not in ('confirmed', 'preparing', 'readyForPickup', 'outForDelivery', 'completed', 'cancelled') then
    raise exception 'Staff cannot set an order to that status.';
  end if;
  -- The state machine trigger (enforce_order_transition) validates the move,
  -- including "completed needs a confirmed payment".
  update public.orders set status = p_status where id = p_order_id;
  if nullif(trim(coalesce(p_note, '')), '') is not null then
    update public.order_status_events set note = left(trim(p_note), 300)
    where id = (select id from public.order_status_events
                where order_id = p_order_id and status = p_status
                order by created_at desc limit 1);
  end if;
end;
$$;

create or replace function public.staff_confirm_payment(p_order_id text, p_reference text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.orders;
  pay public.payments;
  v_ref text := nullif(trim(coalesce(p_reference, '')), '');
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'That order could not be found.'; end if;
  perform public._require_staff(o.branch_id);
  if o.status in ('cancelled', 'refunded') then raise exception 'This order is % and cannot be paid.', o.status; end if;
  select * into pay from public.payments where order_id = p_order_id for update;
  if not found then raise exception 'This order has no payment record.'; end if;
  if pay.status not in ('pending', 'processing') then raise exception 'This payment is already %.', pay.status; end if;
  if pay.method <> 'cash' and (v_ref is null or length(v_ref) < 4) then
    raise exception 'Enter the payment reference number to confirm this payment.';
  end if;
  update public.payments
  set status = 'success', reference_number = coalesce(v_ref, reference_number)
  where id = pay.id;
  perform public.notify_customer(o.firebase_uid, 'payment', 'Payment received',
    'We received your payment for order ' || o.id || '.');
end;
$$;

create or replace function public.staff_list_refunds(
  p_branch_id uuid default null,
  p_statuses text[] default null
)
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
  v_staff := public._require_staff(null, 'refunds');
  v_branch := case when v_staff.role = 'owner' then p_branch_id else v_staff.branch_id end;
  if v_branch is null then raise exception 'Please choose a branch first.'; end if;
  return (
    select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb)
    from (
      select r.created_at,
        jsonb_build_object(
          'id', r.id, 'order_id', r.order_id, 'status', r.status, 'reason', r.reason, 'notes', r.notes,
          'amount', r.amount, 'payment_method', r.payment_method, 'created_at', r.created_at,
          'customer_name', nullif(cp.full_name, ''),
          'items', (select coalesce(jsonb_agg(jsonb_build_object(
                      'product_name', ri.product_name, 'variant_label', ri.variant_label,
                      'quantity', ri.quantity, 'unit_price', ri.unit_price)), '[]'::jsonb)
                    from public.refund_items ri where ri.refund_request_id = r.id)
        ) as j
      from public.refund_requests r
      join public.orders o on o.id = r.order_id
      left join public.customer_profiles cp on cp.firebase_uid = r.firebase_uid
      where o.branch_id = v_branch and (p_statuses is null or r.status = any(p_statuses))
      order by r.created_at desc
      limit 200
    ) x
  );
end;
$$;

-- p_action: 'approve' | 'reject' | 'process' | 'complete'.
create or replace function public.staff_review_refund(p_refund_id text, p_action text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.refund_requests;
  v_branch uuid;
  v_status text;
begin
  select * into r from public.refund_requests where id = p_refund_id for update;
  if not found then raise exception 'That refund request could not be found.'; end if;
  select branch_id into v_branch from public.orders where id = r.order_id;
  perform public._require_staff(v_branch, 'refunds');
  v_status := case p_action when 'approve' then 'approved' when 'reject' then 'rejected'
                            when 'process' then 'processing' when 'complete' then 'completed' end;
  if v_status is null then raise exception 'Unsupported refund action.'; end if;
  -- enforce_refund_transition validates the move; sync triggers update the order.
  update public.refund_requests set status = v_status where id = r.id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Dashboard
--    "Sales today" = completed orders (and completed orders with a refund
--    request pending) created today, Asia/Manila. Pending / preparing / ready
--    are LIVE counts of open orders regardless of the day they were placed.
-- -----------------------------------------------------------------------------
create or replace function public.staff_get_dashboard(p_branch_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branch uuid;
  v_day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Manila') at time zone 'Asia/Manila';
  v_today date := (now() at time zone 'Asia/Manila')::date;
  b record;
  o record;
  v_low int;
  v_out int;
  v_expiring int;
  v_await_approval int;
  v_await_receipt int;
  v_refunds int;
  v_unread int;
begin
  v_staff := public._require_staff();
  v_branch := case when v_staff.role = 'owner' then p_branch_id else v_staff.branch_id end;
  if v_branch is null then raise exception 'Please choose a branch first.'; end if;
  select * into b from public.branches where id = v_branch;
  if not found then raise exception 'That branch could not be found.'; end if;

  select
    coalesce(sum(total) filter (where created_at >= v_day_start and status in ('completed', 'refundRequested')), 0) as sales_today,
    count(*) filter (where created_at >= v_day_start) as orders_today,
    count(*) filter (where status in ('pending', 'confirmed')) as pending_orders,
    count(*) filter (where status = 'preparing') as preparing_orders,
    count(*) filter (where status in ('readyForPickup', 'outForDelivery')) as ready_orders,
    count(*) filter (where created_at >= v_day_start and status = 'completed') as completed_today,
    count(*) filter (where created_at >= v_day_start and status = 'cancelled') as cancelled_today
  into o
  from public.orders where branch_id = v_branch;

  with items as (
    select bi.quantity,
           coalesce(th.restock_threshold, public._default_restock_threshold()) as thr
    from public.branch_inventory bi
    join public.products p on p.id = bi.product_id and p.is_active
    left join public.stock_thresholds th on th.branch_id = bi.branch_id and th.variant_id = bi.variant_id
    where bi.branch_id = v_branch and bi.variant_id is not null
  )
  select count(*) filter (where quantity = 0), count(*) filter (where quantity > 0 and quantity <= thr)
  into v_out, v_low from items;

  select count(*) into v_expiring from public.inventory_batches
  where branch_id = v_branch and quantity > 0 and expiration_date <= v_today + 15;

  select count(*) into v_await_approval from public.stock_transfers
  where from_branch_id = v_branch and status = 'requested';
  select count(*) into v_await_receipt from public.stock_transfers
  where to_branch_id = v_branch and status = 'in_transit';

  if v_staff.role = 'owner' or v_staff.can_review_refunds then
    select count(*) into v_refunds
    from public.refund_requests r join public.orders ord on ord.id = r.order_id
    where ord.branch_id = v_branch and r.status in ('pending', 'approved', 'processing');
  end if;

  select count(*) into v_unread from public.staff_notifications
  where recipient_uid = v_staff.firebase_uid and not read;

  return jsonb_build_object(
    'branch', jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address, 'contact_phone', b.contact_phone,
      'operating_hours', b.operating_hours, 'is_active', b.is_active,
      'supports_delivery', b.supports_delivery, 'supports_pickup', b.supports_pickup),
    'sales_today', o.sales_today,
    'orders_today', o.orders_today,
    'pending_orders', o.pending_orders,
    'preparing_orders', o.preparing_orders,
    'ready_orders', o.ready_orders,
    'completed_today', o.completed_today,
    'cancelled_today', o.cancelled_today,
    'low_stock_count', v_low,
    'out_of_stock_count', v_out,
    'expiring_soon_count', v_expiring,
    'transfers_awaiting_approval', v_await_approval,
    'transfers_awaiting_receipt', v_await_receipt,
    'pending_refunds', v_refunds,          -- null when the caller may not review refunds
    'unread_notifications', v_unread,
    'generated_at', now()
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Privileges and policies (deny by default, then allow-list)
-- -----------------------------------------------------------------------------
grant select on
  public.staff_members, public.inventory_batches, public.stock_thresholds, public.stock_movements,
  public.stock_transfers, public.stock_transfer_batches, public.staff_notifications, public.pos_sales
to authenticated;
grant update (read) on public.staff_notifications to authenticated;
grant delete on public.staff_notifications to authenticated;

drop policy if exists "staff: read own registry row" on public.staff_members;
create policy "staff: read own registry row" on public.staff_members for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()) or public.staff_is_owner());

drop policy if exists "staff: read branch batches" on public.inventory_batches;
create policy "staff: read branch batches" on public.inventory_batches for select to authenticated
  using (public.staff_can_see_branch(branch_id));

drop policy if exists "staff: read branch thresholds" on public.stock_thresholds;
create policy "staff: read branch thresholds" on public.stock_thresholds for select to authenticated
  using (public.staff_can_see_branch(branch_id));

drop policy if exists "staff: read branch stock movements" on public.stock_movements;
create policy "staff: read branch stock movements" on public.stock_movements for select to authenticated
  using (public.staff_can_see_branch(branch_id));

drop policy if exists "staff: read branch transfers" on public.stock_transfers;
create policy "staff: read branch transfers" on public.stock_transfers for select to authenticated
  using (public.staff_can_see_branch(from_branch_id) or public.staff_can_see_branch(to_branch_id));

drop policy if exists "staff: read transfer batches" on public.stock_transfer_batches;
create policy "staff: read transfer batches" on public.stock_transfer_batches for select to authenticated
  using (exists (select 1 from public.stock_transfers t
                 where t.id = transfer_id
                   and (public.staff_can_see_branch(t.from_branch_id) or public.staff_can_see_branch(t.to_branch_id))));

drop policy if exists "staff: read own notifications" on public.staff_notifications;
create policy "staff: read own notifications" on public.staff_notifications for select to authenticated
  using (recipient_uid = (select public.current_firebase_uid()));
drop policy if exists "staff: update own notifications" on public.staff_notifications;
create policy "staff: update own notifications" on public.staff_notifications for update to authenticated
  using (recipient_uid = (select public.current_firebase_uid()))
  with check (recipient_uid = (select public.current_firebase_uid()));
drop policy if exists "staff: delete own notifications" on public.staff_notifications;
create policy "staff: delete own notifications" on public.staff_notifications for delete to authenticated
  using (recipient_uid = (select public.current_firebase_uid()));

drop policy if exists "staff: read branch pos sales" on public.pos_sales;
create policy "staff: read branch pos sales" on public.pos_sales for select to authenticated
  using (public.staff_can_see_branch(branch_id));

-- Additive policies on existing customer tables: staff may READ their branch's
-- orders (live dashboard / order list) and, with the refunds permission, that
-- branch's refund requests. Customers keep their own-rows-only policies.
drop policy if exists "staff: read branch orders" on public.orders;
create policy "staff: read branch orders" on public.orders for select to authenticated
  using (public.staff_can_see_branch(branch_id));

drop policy if exists "staff: read branch refunds" on public.refund_requests;
create policy "staff: read branch refunds" on public.refund_requests for select to authenticated
  using (public.staff_has_permission('refunds')
         and exists (select 1 from public.orders o
                     where o.id = order_id and public.staff_can_see_branch(o.branch_id)));

-- Functions: explicit allow-list (everything else stays private).
grant execute on function public.staff_can_see_branch(uuid) to authenticated;
grant execute on function public.staff_has_permission(text) to authenticated;
grant execute on function public.staff_is_owner() to authenticated;
grant execute on function public.get_my_staff_profile() to authenticated;
grant execute on function public.get_my_staff_context() to authenticated;
grant execute on function public.owner_upsert_staff_member(text, text, text, text, text, boolean, boolean, boolean) to authenticated;
grant execute on function public.owner_set_staff_active(text, boolean) to authenticated;
grant execute on function public.staff_receive_batch(uuid, uuid, text, int, date, date, int, boolean) to authenticated;
grant execute on function public.staff_adjust_batch(uuid, int, text, text) to authenticated;
grant execute on function public.staff_get_inventory(uuid) to authenticated;
grant execute on function public.staff_request_transfer(uuid, uuid, uuid, int, text) to authenticated;
grant execute on function public.staff_respond_transfer(text, text) to authenticated;
grant execute on function public.staff_list_transfers(uuid) to authenticated;
grant execute on function public.staff_lookup_customer(text) to authenticated;
grant execute on function public.staff_create_pos_sale(uuid, jsonb, text, text, numeric, text, text) to authenticated;
grant execute on function public.staff_list_orders(uuid, text[], timestamptz, int, text) to authenticated;
grant execute on function public.staff_update_order_status(text, text, text) to authenticated;
grant execute on function public.staff_confirm_payment(text, text) to authenticated;
grant execute on function public.staff_list_refunds(uuid, text[]) to authenticated;
grant execute on function public.staff_review_refund(text, text) to authenticated;
grant execute on function public.staff_get_dashboard(uuid) to authenticated;
-- Internal helpers/triggers (_require_*, _consume_batches_fefo, _notify_staff,
-- _sync_batches_with_inventory, _trg_*, notify_customer) are deliberately NOT
-- granted: default privileges already deny clients execute on new functions.
revoke all on function public._require_staff(uuid, text) from public, anon, authenticated;
revoke all on function public._require_owner() from public, anon, authenticated;
revoke all on function public._consume_batches_fefo(uuid, uuid, uuid, int, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public._notify_staff(uuid, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public._sync_batches_with_inventory() from public, anon, authenticated;
revoke all on function public._trg_staff_notify_order() from public, anon, authenticated;
revoke all on function public._trg_staff_notify_stock() from public, anon, authenticated;
revoke all on function public._trg_staff_notify_transfer() from public, anon, authenticated;
revoke all on function public._trg_staff_notify_refund() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 9. Realtime (enforces the SELECT policies above per subscriber)
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['orders', 'refund_requests', 'branch_inventory', 'inventory_batches',
                             'stock_transfers', 'staff_notifications'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

commit;
