-- =============================================================================
-- Melai Nuts — Migration 20261013000000
-- Admin portal: all-branch staff overview for owners + "is my email registered?"
-- =============================================================================
-- RUN ORDER: after 20261010000000_pos_shifts_voids_returns.sql. Safe to re-run.
--
-- WHY
--   1. The admin dashboard shows owners every branch AND every staff account:
--      who works where, their status, how much each cashier sold, their shifts
--      and when they were last active. The existing functions cannot return
--      that in one call (admin_portal_staff_directory has no activity, and
--      staff_cashier_daily_summary needs one branch and one day), so
--      owner_staff_overview() adds it. OWNER ONLY (_require_owner), read-only.
--
--   2. The website links a login to its app account automatically at sign-in,
--      by Firebase UID. When the UID has no staff row, the login page should say
--      precisely why. staff_registration_for_my_email() looks up the CALLER'S
--      OWN verified email (taken from the JWT, never from a parameter) and says
--      whether a staff row exists for it under another Firebase UID. It reveals
--      nothing about any other email and changes nothing.
--
--   3. The website links its own logins (the .env "Melai Admin" and staff logins) to their
--      staff_members row on the server, at every sign-in, without asking the person to link
--      anything. When ADMIN_STAFF_UID is not set and the login has no Firebase identity, the
--      website needs the UID of the active row with the login's e-mail: portal_staff_uid_for_email()
--      returns it. It is executable ONLY by the website's own database login (melai_admin_portal),
--      never by app users (anon / authenticated), and returns a UID, nothing else. The website then
--      VERIFIES that UID by calling get_my_staff_context() AS that UID (RLS and role checks apply)
--      before it saves the link. No data is read or written through this function.
--
--   No RLS change, no new table. melai_admin_portal gains EXECUTE on one function (3).
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. owner_staff_overview(from, to, branch)
--    One row per staff member (owners included), with activity in [from, to):
--      pos_transactions / pos_sales   paid POS sales rung up by that person
--      pos_refunds                    completed refunds on those sales, by completion time
--      shifts_opened / open_shift     cash drawer shifts in the window / open right now
--      last_activity_at               latest POS sale, shift open/close or stock movement (any time)
--    p_branch_id limits the activity to one branch and the list to the people
--    assigned to it or active in it.
-- -----------------------------------------------------------------------------
create or replace function public.owner_staff_overview(
  p_from timestamptz,
  p_to timestamptz,
  p_branch_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_owner();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Choose a valid date range.';
  end if;
  if p_to - p_from > interval '400 days' then
    raise exception 'Date range is too long (maximum 400 days).';
  end if;
  if p_branch_id is not null and not exists (select 1 from public.branches where id = p_branch_id) then
    raise exception 'That branch does not exist.';
  end if;

  return (
    with sales as (
      select ps.staff_uid, count(*) as tx, coalesce(sum(o.total), 0) as amount
      from public.pos_sales ps
      join public.orders o on o.id = ps.order_id
      where ps.created_at >= p_from and ps.created_at < p_to
        and (p_branch_id is null or ps.branch_id = p_branch_id)
        and exists (select 1 from public.payments p where p.order_id = o.id and p.status in ('success', 'refunded'))
      group by ps.staff_uid
    ),
    refunds as (
      select ps.staff_uid, coalesce(sum(r.amount), 0) as amount
      from public.refund_requests r
      join public.pos_sales ps on ps.order_id = r.order_id
      join lateral (
        select max(e.created_at) as done_at from public.refund_status_events e
        where e.refund_request_id = r.id and e.status = 'completed'
      ) d on true
      where r.status = 'completed' and d.done_at >= p_from and d.done_at < p_to
        and (p_branch_id is null or ps.branch_id = p_branch_id)
      group by ps.staff_uid
    ),
    shifts as (
      select s.staff_uid,
             count(*) filter (where s.opened_at >= p_from and s.opened_at < p_to) as opened,
             bool_or(s.status = 'open') as is_open
      from public.cash_drawer_sessions s
      where p_branch_id is null or s.branch_id = p_branch_id
      group by s.staff_uid
    ),
    activity as (
      select uid, max(at) as last_at from (
        select ps.staff_uid as uid, max(ps.created_at) as at from public.pos_sales ps group by 1
        union all
        select s.staff_uid, max(greatest(s.opened_at, coalesce(s.closed_at, s.opened_at))) from public.cash_drawer_sessions s group by 1
        union all
        select m.created_by, max(m.created_at) from public.stock_movements m where m.created_by is not null group by 1
      ) a
      group by uid
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'firebase_uid', sm.firebase_uid,
             'full_name', sm.full_name,
             'email', sm.email,
             'role', sm.role,
             'branch_id', sm.branch_id,
             'branch_name', b.name,
             'account_status', sm.account_status,
             'is_active', sm.is_active,
             'pos_transactions', coalesce(sa.tx, 0),
             'pos_sales', coalesce(sa.amount, 0),
             'pos_refunds', coalesce(rf.amount, 0),
             'pos_net_sales', coalesce(sa.amount, 0) - coalesce(rf.amount, 0),
             'shifts_opened', coalesce(sh.opened, 0),
             'open_shift', coalesce(sh.is_open, false),
             'last_activity_at', ac.last_at
           ) order by coalesce(sa.amount, 0) desc, sm.role desc, sm.full_name), '[]'::jsonb)
    from public.staff_members sm
    left join public.branches b on b.id = sm.branch_id
    left join sales sa on sa.staff_uid = sm.firebase_uid
    left join refunds rf on rf.staff_uid = sm.firebase_uid
    left join shifts sh on sh.staff_uid = sm.firebase_uid
    left join activity ac on ac.uid = sm.firebase_uid
    where p_branch_id is null
       or sm.branch_id = p_branch_id
       or sa.staff_uid is not null or rf.staff_uid is not null or coalesce(sh.opened, 0) > 0
  );
end;
$$;

revoke all on function public.owner_staff_overview(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.owner_staff_overview(timestamptz, timestamptz, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. staff_registration_for_my_email()
--    For a signed-in caller: is the email in MY token registered in the staff
--    registry, and under which kind of account? Only the caller's own email.
-- -----------------------------------------------------------------------------
create or replace function public.staff_registration_for_my_email()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_email text := nullif(lower(trim(coalesce(auth.jwt() ->> 'email', ''))), '');
  v public.staff_members;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if v_email is null then
    return jsonb_build_object('found', false);
  end if;

  select * into v from public.staff_members
  where lower(trim(email)) = v_email
  order by (firebase_uid = v_uid) desc, (account_status = 'active') desc, updated_at desc
  limit 1;
  if not found then
    return jsonb_build_object('found', false);
  end if;

  return jsonb_build_object(
    'found', true,
    'same_uid', v.firebase_uid = v_uid,
    'role', v.role,
    'account_status', v.account_status
  );
end;
$$;

revoke all on function public.staff_registration_for_my_email() from public, anon;
grant execute on function public.staff_registration_for_my_email() to authenticated;

-- -----------------------------------------------------------------------------
-- 3. portal_staff_uid_for_email(email, role)  -- website server only
--    {"status": "found", "firebase_uid": ..., "account_status": ...}
--    | {"status": "none"} | {"status": "ambiguous", "count": n}
-- -----------------------------------------------------------------------------
create or replace function public.portal_staff_uid_for_email(p_email text, p_role text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_count int;
  v public.staff_members;
begin
  if v_email is null or p_role not in ('owner', 'staff') then
    return jsonb_build_object('status', 'none');
  end if;
  select count(*) into v_count from public.staff_members
  where lower(trim(email)) = v_email and role = p_role;
  if v_count = 0 then
    return jsonb_build_object('status', 'none');
  end if;
  if v_count > 1 then
    return jsonb_build_object('status', 'ambiguous', 'count', v_count);
  end if;
  select * into v from public.staff_members where lower(trim(email)) = v_email and role = p_role;
  return jsonb_build_object('status', 'found', 'firebase_uid', v.firebase_uid, 'account_status', v.account_status);
end;
$$;

revoke all on function public.portal_staff_uid_for_email(text, text) from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'melai_admin_portal') then
    grant execute on function public.portal_staff_uid_for_email(text, text) to melai_admin_portal;
  end if;
end;
$$;

commit;
