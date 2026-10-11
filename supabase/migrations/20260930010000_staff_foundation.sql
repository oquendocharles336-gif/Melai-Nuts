-- =============================================================================
-- Melai Nuts — Migration 20260930010000
-- Staff foundation (Batch 1): account status, profile fields, permission
-- catalog + grants, authorized-branch resolution, append-only audit log and
-- email sync from the verified Firebase token.
-- =============================================================================
-- RUN ORDER: ... -> 20260930000000_staff_backend.sql -> THIS FILE.
-- Safe to re-run (idempotent) and atomic (one transaction).
--
-- DESIGN NOTES
--   * `staff_members` stays the ONE registry (see 20260930000000). Nothing here
--     creates a second table of staff.
--   * Identity is the Firebase UID (`staff_members.firebase_uid`), taken from
--     the verified JWT (`current_firebase_uid()`), never from a client value.
--   * account_status ('active' | 'inactive' | 'suspended') is the single source
--     of truth. `is_active` is now a GENERATED column (account_status='active'),
--     so every existing `where is_active` / `v.is_active` keeps working and can
--     never disagree with the status.
--   * Permissions: the two legacy flags (can_manage_inventory,
--     can_review_refunds) keep working for every existing RPC. The catalog +
--     `staff_permission_grants` table are the foundation later batches use to
--     enforce finer permissions. `staff_permission_keys()` is the one place that
--     computes what a caller may do; the app displays exactly that list.
--   * Branches: a staff member has ONE assigned branch (existing requirement);
--     owners may access every branch. `staff_authorized_branch_ids()` is the one
--     place that answers "which branches may this caller access?" so a later
--     multi-branch model only changes this function.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Account status, phone, profile image
-- -----------------------------------------------------------------------------
alter table public.staff_members add column if not exists account_status text;
alter table public.staff_members add column if not exists phone text;
alter table public.staff_members add column if not exists profile_image text;

do $$
begin
  -- First run only: derive the status from the old boolean, then replace the
  -- boolean with a generated column so the two can never drift apart.
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'staff_members'
      and column_name = 'is_active' and is_generated = 'NEVER'
  ) then
    update public.staff_members
       set account_status = case when is_active then 'active' else 'inactive' end
     where account_status is null;
    alter table public.staff_members drop column is_active;
  end if;
end $$;

update public.staff_members set account_status = 'active' where account_status is null;
alter table public.staff_members alter column account_status set default 'active';
alter table public.staff_members alter column account_status set not null;

alter table public.staff_members drop constraint if exists staff_account_status_valid;
alter table public.staff_members
  add constraint staff_account_status_valid
  check (account_status in ('active', 'inactive', 'suspended'));

alter table public.staff_members drop constraint if exists staff_phone_length;
alter table public.staff_members
  add constraint staff_phone_length check (phone is null or char_length(phone) <= 32);
alter table public.staff_members drop constraint if exists staff_profile_image_length;
alter table public.staff_members
  add constraint staff_profile_image_length check (profile_image is null or char_length(profile_image) <= 1024);

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'staff_members' and column_name = 'is_active'
  ) then
    alter table public.staff_members
      add column is_active boolean generated always as (account_status = 'active') stored;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 2. Permission catalog + grants
-- -----------------------------------------------------------------------------
create or replace function public.staff_permission_catalog()
returns text[]
language sql
immutable
as $$
  select array[
    'view_dashboard',
    'view_products',    'manage_products',
    'view_inventory',   'manage_inventory',
    'view_orders',      'manage_orders',
    'view_payments',
    'manage_refunds',
    'view_reports',
    'manage_stock_transfers',
    'view_notifications'
  ]
$$;

create table if not exists public.staff_permission_grants (
  firebase_uid text not null references public.staff_members(firebase_uid) on delete cascade,
  permission text not null,
  granted_by text,
  granted_at timestamptz not null default now(),
  primary key (firebase_uid, permission),
  constraint staff_permission_in_catalog check (permission = any (public.staff_permission_catalog()))
);
alter table public.staff_permission_grants enable row level security;

-- What the caller may do, computed on the server:
--   * owner            -> the whole catalog
--   * active staff     -> baseline read access every active staff member already
--                         has through the existing RPCs
--                         + implied by the legacy flags
--                         + explicit grants
--   * anyone else      -> nothing
-- The 'suspended' / 'inactive' accounts get an EMPTY list: a stale grant can
-- never outlive the account status.
create or replace function public.staff_permission_keys()
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.staff_members;
  v_keys text[];
begin
  select * into v from public.staff_members where firebase_uid = public.current_firebase_uid();
  if not found or v.account_status <> 'active' then
    return array[]::text[];
  end if;
  if v.role = 'owner' then
    return public.staff_permission_catalog();
  end if;

  v_keys := array['view_dashboard', 'view_products', 'view_inventory', 'view_orders', 'view_notifications'];
  if v.can_manage_inventory then
    v_keys := v_keys || array['manage_inventory', 'manage_stock_transfers'];
  end if;
  if v.can_review_refunds then
    v_keys := v_keys || array['manage_refunds'];
  end if;
  select coalesce(array_agg(g.permission), array[]::text[]) into v_keys
  from (
    select unnest(v_keys) as permission
    union
    select permission from public.staff_permission_grants where firebase_uid = v.firebase_uid
  ) g;
  return v_keys;
end;
$$;

-- Which branches may the caller access? Owner: all. Staff: their assigned one.
create or replace function public.staff_authorized_branch_ids()
returns uuid[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.staff_members;
begin
  select * into v from public.staff_members where firebase_uid = public.current_firebase_uid();
  if not found or v.account_status <> 'active' then
    return array[]::uuid[];
  end if;
  if v.role = 'owner' then
    return coalesce((select array_agg(id order by name) from public.branches), array[]::uuid[]);
  end if;
  if v.branch_id is null then
    return array[]::uuid[];
  end if;
  return array[v.branch_id];
end;
$$;

-- Generic permission check for RPCs and policies. Understands the two legacy
-- keys ('inventory', 'refunds') used by the existing functions AND the catalog.
create or replace function public.staff_has_permission(p_permission text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.staff_members;
begin
  select * into v from public.staff_members where firebase_uid = public.current_firebase_uid();
  if not found or v.account_status <> 'active' then
    return false;
  end if;
  if v.role = 'owner' then
    return true;
  end if;
  if p_permission = 'inventory' then return v.can_manage_inventory; end if;
  if p_permission = 'refunds' then return v.can_review_refunds; end if;
  return p_permission = any (public.staff_permission_keys());
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Access helpers that now understand 'suspended'
-- -----------------------------------------------------------------------------
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
  if v.account_status = 'suspended' then
    raise exception 'Your staff account has been suspended. Please contact the owner.';
  end if;
  if v.account_status <> 'active' then
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

-- -----------------------------------------------------------------------------
-- 4. The one read the app makes after sign-in (extended, still status-style)
--
--   {"status": "not_provisioned"}
--   {"status": "inactive"}
--   {"status": "suspended"}
--   {"status": "invalid_branch"}      staff row without a usable branch
--   {"status": "active", "profile": {...}, "permissions": [...],
--    "authorized_branches": [{"id": "...", "name": "..."}]}
--
-- Never raises for "no row" / "not active", never reveals more for the
-- non-active outcomes.
-- -----------------------------------------------------------------------------
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
  if v.account_status = 'suspended' then
    return jsonb_build_object('status', 'suspended');
  end if;
  if v.account_status <> 'active' then
    return jsonb_build_object('status', 'inactive');
  end if;

  select name into v_branch_name from public.branches where id = v.branch_id;
  if v.role = 'staff' and (v.branch_id is null or v_branch_name is null) then
    return jsonb_build_object('status', 'invalid_branch');
  end if;

  return jsonb_build_object(
    'status', 'active',
    'profile', jsonb_build_object(
      'firebase_uid', v.firebase_uid,
      'full_name', v.full_name,
      'email', v.email,
      'phone', v.phone,
      'profile_image', v.profile_image,
      'role', v.role,
      'branch_id', v.branch_id,
      'branch_name', v_branch_name,
      'account_status', v.account_status,
      'is_active', v.is_active,
      'can_manage_inventory', (v.role = 'owner' or v.can_manage_inventory),
      'can_review_refunds', (v.role = 'owner' or v.can_review_refunds),
      'created_at', v.created_at
    ),
    'permissions', to_jsonb(public.staff_permission_keys()),
    'authorized_branches', coalesce((
      select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name) order by b.name)
      from public.branches b
      where b.id = any (public.staff_authorized_branch_ids())
    ), '[]'::jsonb)
  );
end;
$$;

-- Keeps the registry email in step with the VERIFIED Firebase token. The value
-- comes from the JWT, never from a parameter, so a client cannot choose it.
-- Email is a display/contact field; the identity remains the Firebase UID.
create or replace function public.staff_sync_my_identity()
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_email text := nullif(lower(trim(coalesce(auth.jwt() ->> 'email', ''))), '');
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if v_email is null then
    return;
  end if;
  update public.staff_members
     set email = left(v_email, 254)
   where firebase_uid = v_uid
     and account_status = 'active'
     and email is distinct from left(v_email, 254);
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Owner provisioning: same signatures as before, now status-aware
-- -----------------------------------------------------------------------------
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
  v_status text := case when coalesce(p_is_active, true) then 'active' else 'inactive' end;
begin
  perform public._require_owner();
  if coalesce(trim(p_firebase_uid), '') = '' then raise exception 'A staff account id is required.'; end if;
  if p_role not in ('staff', 'owner') then raise exception 'Unsupported staff role.'; end if;
  if p_role = 'staff' then
    select id into v_branch_id from public.branches where name = p_branch_name;
    if v_branch_id is null then raise exception 'Please choose a valid branch for this staff member.'; end if;
  end if;

  insert into public.staff_members
    (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
  values
    (p_firebase_uid, left(coalesce(p_full_name, ''), 100), left(coalesce(p_email, ''), 254), p_role,
     v_branch_id, v_status, coalesce(p_can_manage_inventory, true), coalesce(p_can_review_refunds, false))
  on conflict (firebase_uid) do update
    set full_name = excluded.full_name,
        email = excluded.email,
        role = excluded.role,
        branch_id = excluded.branch_id,
        -- Re-provisioning must not silently lift a suspension.
        account_status = case
          when public.staff_members.account_status = 'suspended' and excluded.account_status = 'active'
            then 'suspended' else excluded.account_status end,
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
  update public.staff_members
     set account_status = case when coalesce(p_is_active, true) then 'active' else 'inactive' end
   where firebase_uid = p_firebase_uid;
end;
$$;

create or replace function public.owner_set_staff_status(p_firebase_uid text, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_owner();
  if p_status not in ('active', 'inactive', 'suspended') then
    raise exception 'Unsupported account status.';
  end if;
  if p_firebase_uid = public.current_firebase_uid() and p_status <> 'active' then
    raise exception 'You cannot change your own account status.';
  end if;
  update public.staff_members set account_status = p_status where firebase_uid = p_firebase_uid;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Audit log (append-only)
-- -----------------------------------------------------------------------------
create table if not exists public.staff_audit_logs (
  id uuid primary key default gen_random_uuid(),
  staff_firebase_uid text not null,
  branch_id uuid references public.branches(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id text,
  metadata jsonb not null default '{}'::jsonb,
  -- Set by the app for actions recorded offline, so a retried sync of the same
  -- operation is stored once.
  client_operation_id text,
  created_at timestamptz not null default now(),
  constraint audit_action_format check (action ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$' and char_length(action) <= 80),
  constraint audit_entity_type_format check (entity_type ~ '^[a-z][a-z0-9_]*$' and char_length(entity_type) <= 60),
  constraint audit_entity_id_length check (entity_id is null or char_length(entity_id) <= 128),
  constraint audit_metadata_object check (jsonb_typeof(metadata) = 'object'),
  constraint audit_metadata_size check (octet_length(metadata::text) <= 8192)
);
create unique index if not exists staff_audit_logs_client_op_uq
  on public.staff_audit_logs (staff_firebase_uid, client_operation_id)
  where client_operation_id is not null;
create index if not exists staff_audit_logs_branch_time_idx
  on public.staff_audit_logs (branch_id, created_at desc);
create index if not exists staff_audit_logs_actor_time_idx
  on public.staff_audit_logs (staff_firebase_uid, created_at desc);
alter table public.staff_audit_logs enable row level security;

-- Append-only, even for roles that hold table privileges.
create or replace function public._audit_logs_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Audit records cannot be changed or deleted.';
end;
$$;
drop trigger if exists staff_audit_logs_no_update on public.staff_audit_logs;
create trigger staff_audit_logs_no_update
  before update or delete on public.staff_audit_logs
  for each row execute function public._audit_logs_immutable();
drop trigger if exists staff_audit_logs_no_truncate on public.staff_audit_logs;
create trigger staff_audit_logs_no_truncate
  before truncate on public.staff_audit_logs
  for each statement execute function public._audit_logs_immutable();

-- Internal writer for later server-side RPCs (inventory, refunds, transfers...).
-- NOT granted to clients.
create or replace function public._write_audit(
  p_staff_uid text,
  p_branch_id uuid,
  p_action text,
  p_entity_type text,
  p_entity_id text,
  p_metadata jsonb default '{}'::jsonb,
  p_client_operation_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.staff_audit_logs
    (staff_firebase_uid, branch_id, action, entity_type, entity_id, metadata, client_operation_id)
  values
    (p_staff_uid, p_branch_id, p_action, p_entity_type, p_entity_id,
     coalesce(p_metadata, '{}'::jsonb), p_client_operation_id)
  on conflict (staff_firebase_uid, client_operation_id) where client_operation_id is not null
  do nothing
  returning id into v_id;
  return v_id;
end;
$$;

-- Client entry point. Who did it and in which branch are derived on the server
-- from the verified token and the registry; the caller cannot claim either.
create or replace function public.staff_log_audit(
  p_action text,
  p_entity_type text,
  p_entity_id text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_operation_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.staff_members;
begin
  v := public._require_staff();
  if p_client_operation_id is not null and char_length(p_client_operation_id) > 64 then
    raise exception 'Invalid operation id.';
  end if;
  return public._write_audit(
    v.firebase_uid, v.branch_id, p_action, p_entity_type, p_entity_id,
    coalesce(p_metadata, '{}'::jsonb), p_client_operation_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Privileges and policies (deny by default, then allow-list)
-- -----------------------------------------------------------------------------
revoke all on public.staff_permission_grants from anon, authenticated;
revoke all on public.staff_audit_logs from anon, authenticated;
grant select on public.staff_permission_grants to authenticated;
grant select on public.staff_audit_logs to authenticated;

drop policy if exists "staff: read own permission grants" on public.staff_permission_grants;
create policy "staff: read own permission grants" on public.staff_permission_grants
  for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()) or public.staff_is_owner());

-- Staff read their own audit trail; owners read everything. Nobody writes
-- through the API: inserts only happen inside staff_log_audit / _write_audit.
drop policy if exists "staff: read own audit records" on public.staff_audit_logs;
create policy "staff: read own audit records" on public.staff_audit_logs
  for select to authenticated
  using (staff_firebase_uid = (select public.current_firebase_uid()) or public.staff_is_owner());

grant execute on function public.staff_permission_catalog() to authenticated;
grant execute on function public.staff_permission_keys() to authenticated;
grant execute on function public.staff_authorized_branch_ids() to authenticated;
grant execute on function public.staff_has_permission(text) to authenticated;
grant execute on function public.get_my_staff_context() to authenticated;
grant execute on function public.staff_sync_my_identity() to authenticated;
grant execute on function public.owner_upsert_staff_member(text, text, text, text, text, boolean, boolean, boolean) to authenticated;
grant execute on function public.owner_set_staff_active(text, boolean) to authenticated;
grant execute on function public.owner_set_staff_status(text, text) to authenticated;
grant execute on function public.staff_log_audit(text, text, text, jsonb, text) to authenticated;

revoke all on function public._require_staff(uuid, text) from public, anon, authenticated;
revoke all on function public._write_audit(text, uuid, text, text, text, jsonb, text) from public, anon, authenticated;
revoke all on function public._audit_logs_immutable() from public, anon, authenticated;

commit;
