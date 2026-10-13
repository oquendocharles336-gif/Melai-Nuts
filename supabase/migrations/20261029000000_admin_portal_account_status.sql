-- =============================================================================
-- Admin website: the owner can disable / enable a CUSTOMER account
-- (All users page). Staff accounts already have owner_set_staff_active().
--
-- Blocking the sign-in itself is done the same way as the app's User
-- Management (AuthService.setAccountActive): the website also sets the
-- Firestore profile users/{uid}.isActive, which the beforeUserSignedIn
-- function and firestore.rules enforce. This column is the database's own
-- record of that decision, so the website can show who is disabled without
-- reading Firestore, and the audit log records who changed it.
--
-- Safe to run more than once.
-- =============================================================================
begin;

alter table public.customer_profiles add column if not exists is_active boolean not null default true;

-- Owner only. Returns {firebase_uid, is_active}. Writes the staff audit log.
create or replace function public.owner_set_customer_active(p_firebase_uid text, p_is_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_active boolean := coalesce(p_is_active, true);
  v_uid text;
begin
  perform public._require_owner();
  if p_firebase_uid is null or p_firebase_uid = 'walk-in' then
    raise exception 'Customer account not found.';
  end if;
  if p_firebase_uid = public.current_firebase_uid() then
    raise exception 'You cannot disable your own account.';
  end if;

  update public.customer_profiles set is_active = v_active
   where firebase_uid = p_firebase_uid
  returning firebase_uid into v_uid;
  if v_uid is null then
    raise exception 'Customer account not found.';
  end if;

  perform public._write_audit(public.current_firebase_uid(), null,
    case when v_active then 'customer_enabled' else 'customer_disabled' end,
    'customer', v_uid, jsonb_build_object('is_active', v_active));

  return jsonb_build_object('firebase_uid', v_uid, 'is_active', v_active);
end;
$$;

-- Owner only: the UIDs of disabled customers (a short list), for the All users page.
create or replace function public.owner_disabled_customers()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_owner();
  return (select coalesce(jsonb_agg(firebase_uid order by firebase_uid), '[]'::jsonb)
            from public.customer_profiles where not is_active);
end;
$$;

revoke all on function public.owner_set_customer_active(text, boolean) from public, anon;
revoke all on function public.owner_disabled_customers() from public, anon;
grant execute on function public.owner_set_customer_active(text, boolean) to authenticated;
grant execute on function public.owner_disabled_customers() to authenticated;

commit;
