-- Fix: orphaned `staff_members` row when account creation fails partway.
--
-- `AuthService.createManagedAccount` (lib/core/services/auth_service.dart) does,
-- in order: (1) create the Firebase Auth user, (2) upsert the `staff_members`
-- row via `owner_upsert_staff_member`, (3) write the Firestore profile
-- document. If step 3 throws, the code rolled back step 1 (deletes the Auth
-- user) but had no way to roll back step 2 — leaving a real `staff_members`
-- row (name/email/branch/role) permanently registered against a Firebase UID
-- whose Auth account no longer exists. That staff member could never sign in
-- again, but would still show up in staff lists/counts and occupy that email
-- in `staff_members`, blocking a retry with the same email.
--
-- This adds the missing rollback primitive: an owner-only RPC to remove a
-- staff_members row outright. Dart-side, `createManagedAccount` now calls
-- this when the Firestore write fails after the staff row was created.

create or replace function public.owner_delete_staff_member(p_firebase_uid text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller public.staff_members;
begin
  select * into v_caller from public.staff_members where firebase_uid = public.current_firebase_uid();
  if not found or v_caller.role <> 'owner' or v_caller.account_status <> 'active' then
    raise exception 'Only an active owner can remove a staff account.';
  end if;
  if p_firebase_uid = v_caller.firebase_uid then
    raise exception 'You cannot remove your own owner account.';
  end if;

  -- `staff_permission_grants` cascades on delete already. `deliveries.created_by`
  -- has no cascade (deliveries should outlive the staff member who created
  -- them), so this only succeeds for a staff member with no dependent rows —
  -- exactly the case this exists for: cleaning up a just-failed creation
  -- before anything else could have referenced it.
  delete from public.staff_members where firebase_uid = p_firebase_uid;
end;
$$;

revoke all on function public.owner_delete_staff_member(text) from public, anon;
grant execute on function public.owner_delete_staff_member(text) to authenticated;
