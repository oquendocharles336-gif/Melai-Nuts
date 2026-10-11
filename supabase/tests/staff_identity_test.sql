-- =============================================================================
-- Melai Nuts — staff identity test suite
-- =============================================================================
-- Verifies 20260930000000_staff_backend.sql + 20260930010000_staff_foundation.sql
-- (staff_members registry + get_my_staff_context) the way a hostile
-- client would: as the `anon` / `authenticated` Postgres roles carrying a
-- Firebase-shaped JWT (`request.jwt.claims`).
--
-- HOW TO RUN (against a DEV / staging database, never production):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/staff_identity_test.sql
--
-- Self-contained: everything happens inside ONE transaction that is rolled back
-- at the end. Prerequisites: supabase/schema.sql and all migrations up to and
-- including 20260930000000_staff_backend.sql.
--
-- Output: one PASS/FAIL row per check; raises an error if any check failed so
-- it can gate CI.
-- =============================================================================

begin;

create temp table results (
  id serial primary key,
  name text not null,
  passed boolean not null,
  detail text
);

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------

create function pg_temp.act_as(p_uid text) returns void language plpgsql as $$
begin
  if p_uid is null then
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
  else
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', p_uid, 'role', 'authenticated',
      'email', p_uid || '@test.local', 'email_verified', true)::text, true);
    execute 'set local role authenticated';
  end if;
end $$;

create function pg_temp.back_to_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
grant execute on function pg_temp.back_to_admin() to public;

-- Runs p_sql as p_uid. p_expect: 'error' (must raise) | 'ok' (must succeed).
create function pg_temp.chk(p_name text, p_uid text, p_sql text, p_expect text)
returns void language plpgsql as $$
declare v_err text;
begin
  perform pg_temp.act_as(p_uid);
  begin
    execute p_sql;
  exception when others then
    v_err := sqlerrm;
  end;
  perform pg_temp.back_to_admin();
  insert into results(name, passed, detail) values (
    p_name,
    case p_expect when 'error' then v_err is not null else v_err is null end,
    'expected ' || p_expect || ' -> ' || coalesce('error: ' || v_err, 'no error'));
end $$;

-- Runs a scalar query as p_uid and returns it as text (errors propagate).
create function pg_temp.scalar_as(p_uid text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.act_as(p_uid);
  begin
    execute p_sql into v;
  exception when others then
    perform pg_temp.back_to_admin();
    raise;
  end;
  perform pg_temp.back_to_admin();
  return v;
end $$;

create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '')
returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (created as the table owner; rolled back at the end)
-- ---------------------------------------------------------------------------

insert into public.branches (name, address) values
  ('STAFF-TEST Branch A', 'a'), ('STAFF-TEST Branch B', 'b');

create temp table fx as
select
  (select id from public.branches where name = 'STAFF-TEST Branch A') as branch_a,
  (select id from public.branches where name = 'STAFF-TEST Branch B') as branch_b;
grant select on fx to public;

insert into public.staff_members
  (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
select 'staff-a',   'Staff A',   'a@test.local',   'staff', branch_a, 'active',   true,  false from fx
union all
select 'staff-b',   'Staff B',   'b@test.local',   'staff', branch_b, 'active',   false, true  from fx
union all
select 'staff-off', 'Staff Off', 'off@test.local', 'staff', branch_a, 'inactive', true,  true  from fx
union all
select 'owner-1',   'Owner One', 'o@test.local',   'owner', null,     'active',   false, false from fx;
-- 'staff-none' has NO registry row at all (a customer's or unprovisioned Firebase account).

-- ===========================================================================
-- 1. Context RPC: right person, right branch, right permissions
-- ===========================================================================

select pg_temp.chk_true('A: context status is active',
  pg_temp.scalar_as('staff-a', $$select public.get_my_staff_context() ->> 'status'$$) = 'active');

select pg_temp.chk_true('A: context carries A''s own uid',
  pg_temp.scalar_as('staff-a', $$select public.get_my_staff_context() -> 'profile' ->> 'firebase_uid'$$) = 'staff-a');

select pg_temp.chk_true('A: context branch is A''s branch',
  pg_temp.scalar_as('staff-a', $$select public.get_my_staff_context() -> 'profile' ->> 'branch_name'$$) = 'STAFF-TEST Branch A');

select pg_temp.chk_true('A: flags are exactly A''s (inventory yes, refunds no)',
  pg_temp.scalar_as('staff-a', $$select (public.get_my_staff_context() -> 'profile' ->> 'can_manage_inventory')
                                     || '/' || (public.get_my_staff_context() -> 'profile' ->> 'can_review_refunds')$$)
    = 'true/false');

select pg_temp.chk_true('B: branch and flags are B''s — nothing leaks from A',
  pg_temp.scalar_as('staff-b', $$select (public.get_my_staff_context() -> 'profile' ->> 'branch_name')
                                     || '/' || (public.get_my_staff_context() -> 'profile' ->> 'can_manage_inventory')
                                     || '/' || (public.get_my_staff_context() -> 'profile' ->> 'can_review_refunds')$$)
    = 'STAFF-TEST Branch B/false/true');

select pg_temp.chk_true('Owner: context is active with role owner, no branch, all flags on',
  pg_temp.scalar_as('owner-1', $$select (public.get_my_staff_context() -> 'profile' ->> 'role')
                                     || '/' || coalesce(public.get_my_staff_context() -> 'profile' ->> 'branch_id', 'none')
                                     || '/' || (public.get_my_staff_context() -> 'profile' ->> 'can_manage_inventory')
                                     || '/' || (public.get_my_staff_context() -> 'profile' ->> 'can_review_refunds')$$)
    = 'owner/none/true/true');

select pg_temp.chk_true('Unprovisioned account -> not_provisioned',
  pg_temp.scalar_as('staff-none', $$select public.get_my_staff_context() ->> 'status'$$) = 'not_provisioned');

select pg_temp.chk_true('Unprovisioned account learns nothing else',
  pg_temp.scalar_as('staff-none', $$select (public.get_my_staff_context() - 'status')::text$$) = '{}');

select pg_temp.chk_true('Deactivated account -> inactive',
  pg_temp.scalar_as('staff-off', $$select public.get_my_staff_context() ->> 'status'$$) = 'inactive');

select pg_temp.chk_true('Deactivated account gets no branch or flags',
  pg_temp.scalar_as('staff-off', $$select (public.get_my_staff_context() - 'status')::text$$) = '{}');

select pg_temp.chk('Signed-out (anon) cannot call the context RPC',
  null, $$select public.get_my_staff_context()$$, 'error');

-- ===========================================================================
-- 2. Clients cannot write the registry or read other people's rows
-- ===========================================================================

select pg_temp.chk_true('Staff sees only their own registry row',
  pg_temp.scalar_as('staff-a', $$select count(*)::text from public.staff_members$$) = '1');
select pg_temp.chk_true('Owner sees the whole registry',
  pg_temp.scalar_as('owner-1', $$select (count(*) >= 4)::text from public.staff_members$$) = 'true');
select pg_temp.chk('Anon cannot SELECT staff_members', null, $$select * from public.staff_members$$, 'error');
select pg_temp.chk('Staff cannot grant self inventory rights', 'staff-b',
  $$update public.staff_members set can_manage_inventory = true where firebase_uid = 'staff-b'$$, 'error');
select pg_temp.chk('Staff cannot promote self to owner', 'staff-a',
  $$update public.staff_members set role = 'owner' where firebase_uid = 'staff-a'$$, 'error');
select pg_temp.chk('Staff cannot move self to another branch', 'staff-a',
  format($$update public.staff_members set branch_id = %L where firebase_uid = 'staff-a'$$, (select branch_b from fx)), 'error');
select pg_temp.chk('Staff cannot reactivate self', 'staff-off',
  $$update public.staff_members set account_status = 'active' where firebase_uid = 'staff-off'$$, 'error');
select pg_temp.chk('Stranger cannot mint a registry row for self', 'staff-none',
  $$insert into public.staff_members (firebase_uid, role, branch_id) values ('staff-none', 'owner', null)$$, 'error');
select pg_temp.chk('Staff cannot delete a registry row', 'staff-a',
  $$delete from public.staff_members where firebase_uid = 'staff-b'$$, 'error');
select pg_temp.chk('Staff cannot call owner_upsert_staff_member', 'staff-a',
  $$select public.owner_upsert_staff_member('x', 'X', 'x@test.local', 'owner')$$, 'error');
select pg_temp.chk('Staff cannot call owner_set_staff_active', 'staff-a',
  $$select public.owner_set_staff_active('staff-b', false)$$, 'error');
select pg_temp.chk('Owner can provision a staff member', 'owner-1',
  $$select public.owner_upsert_staff_member('staff-new', 'New', 'n@test.local', 'staff', 'STAFF-TEST Branch A')$$, 'ok');
select pg_temp.chk('Owner cannot deactivate self', 'owner-1',
  $$select public.owner_set_staff_active('owner-1', false)$$, 'error');

-- ===========================================================================
-- 3. Access helpers used by policies and RPCs
-- ===========================================================================

select pg_temp.chk_true('staff_has_permission: A holds inventory',
  pg_temp.scalar_as('staff-a', $$select public.staff_has_permission('inventory')::text$$) = 'true');
select pg_temp.chk_true('staff_has_permission: A lacks refunds (B''s)',
  pg_temp.scalar_as('staff-a', $$select public.staff_has_permission('refunds')::text$$) = 'false');
select pg_temp.chk_true('staff_has_permission: deactivated holds nothing even though a row exists',
  pg_temp.scalar_as('staff-off', $$select public.staff_has_permission('inventory')::text$$) = 'false');
select pg_temp.chk_true('staff_has_permission: unprovisioned holds nothing',
  pg_temp.scalar_as('staff-none', $$select public.staff_has_permission('inventory')::text$$) = 'false');
select pg_temp.chk_true('staff_can_see_branch: A -> own branch true, other false',
  pg_temp.scalar_as('staff-a', format($$select (public.staff_can_see_branch(%L))::text || '/' || (public.staff_can_see_branch(%L))::text$$,
    (select branch_a from fx), (select branch_b from fx))) = 'true/false');
select pg_temp.chk_true('staff_can_see_branch: owner sees every branch',
  pg_temp.scalar_as('owner-1', format($$select public.staff_can_see_branch(%L)::text$$, (select branch_b from fx))) = 'true');
select pg_temp.chk_true('staff_is_owner: owner true, staff false',
  pg_temp.scalar_as('owner-1', $$select public.staff_is_owner()::text$$) = 'true'
  and pg_temp.scalar_as('staff-a', $$select public.staff_is_owner()::text$$) = 'false');

-- ===========================================================================
-- 4. Deactivation and reassignment take effect immediately (same token)
-- ===========================================================================

update public.staff_members set account_status = 'inactive' where firebase_uid = 'staff-a';
select pg_temp.chk_true('Deactivating A flips context to inactive at once',
  pg_temp.scalar_as('staff-a', $$select public.get_my_staff_context() ->> 'status'$$) = 'inactive');
select pg_temp.chk_true('Deactivating A revokes helper access at once',
  pg_temp.scalar_as('staff-a', $$select public.staff_has_permission('inventory')::text$$) = 'false');
select pg_temp.chk('Deactivated A can no longer read inventory', 'staff-a',
  format($$select public.staff_get_inventory(%L)$$, (select branch_a from fx)), 'error');

update public.staff_members set account_status = 'active', branch_id = (select branch_b from fx) where firebase_uid = 'staff-a';
select pg_temp.chk_true('Reassigning A to branch B is reflected at once',
  pg_temp.scalar_as('staff-a', $$select public.get_my_staff_context() -> 'profile' ->> 'branch_name'$$) = 'STAFF-TEST Branch B');
-- staff_get_inventory ignores a staff member's requested branch and serves
-- their assigned one, so after the move asking for branch A returns branch B.
select pg_temp.chk_true('A asking for branch A''s inventory after the move gets branch B, never A',
  pg_temp.scalar_as('staff-a', format($$select public.staff_get_inventory(%L) ->> 'branch_id'$$, (select branch_a from fx)))
    = (select branch_b::text from fx));

update public.staff_members set can_manage_inventory = false where firebase_uid = 'staff-a';
select pg_temp.chk_true('Revoking a flag is reflected at once',
  pg_temp.scalar_as('staff-a', $$select (public.get_my_staff_context() -> 'profile' ->> 'can_manage_inventory')$$) = 'false');

-- ===========================================================================
-- 5. Data integrity + privileges
-- ===========================================================================

do $$
begin
  begin
    insert into public.staff_members (firebase_uid, role, branch_id) values ('staff-x', 'staff', null);
    perform pg_temp.chk_true('Staff without a branch rejected', false, 'insert succeeded');
  exception when check_violation then
    perform pg_temp.chk_true('Staff without a branch rejected', true, 'check_violation');
  end;
  begin
    insert into public.staff_members (firebase_uid, role, branch_id) values ('staff-y', 'admin', null);
    perform pg_temp.chk_true('Unknown role rejected', false, 'insert succeeded');
  exception when check_violation then
    perform pg_temp.chk_true('Unknown role rejected', true, 'check_violation');
  end;
  begin
    insert into public.staff_members (firebase_uid, role, branch_id) values ('staff-z', 'staff', gen_random_uuid());
    perform pg_temp.chk_true('Registry row with a non-existent branch rejected', false, 'insert succeeded');
  exception when foreign_key_violation then
    perform pg_temp.chk_true('Registry row with a non-existent branch rejected', true, 'foreign_key_violation');
  end;
  begin
    delete from public.branches where id = (select branch_b from fx);
    perform pg_temp.chk_true('Branch with staff cannot be deleted', false, 'delete succeeded');
  exception when foreign_key_violation then
    perform pg_temp.chk_true('Branch with staff cannot be deleted', true, 'foreign_key_violation');
  end;
end $$;

select pg_temp.chk_true('authenticated has EXECUTE on the context RPC and the policy helpers',
  has_function_privilege('authenticated', 'public.get_my_staff_context()', 'execute')
  and has_function_privilege('authenticated', 'public.staff_has_permission(text)', 'execute')
  and has_function_privilege('authenticated', 'public.staff_can_see_branch(uuid)', 'execute')
  and has_function_privilege('authenticated', 'public.staff_is_owner()', 'execute'));
select pg_temp.chk_true('Internal helpers are not callable by clients',
  not has_function_privilege('authenticated', 'public._require_staff(uuid, text)', 'execute')
  and not has_function_privilege('anon', 'public._require_staff(uuid, text)', 'execute')
  and not has_function_privilege('authenticated', 'public._require_owner()', 'execute'));
select pg_temp.chk_true('RLS is enabled on staff_members',
  (select relrowsecurity from pg_class where oid = 'public.staff_members'::regclass));

-- ===========================================================================
-- Report
-- ===========================================================================
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail
from results order by id;

select count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed,
       count(*) as total
from results;

do $$
declare v_failed int;
begin
  select count(*) into v_failed from results where not passed;
  if v_failed > 0 then
    raise exception '% staff identity check(s) FAILED — see the report above.', v_failed;
  end if;
end $$;

rollback;
