-- =============================================================================
-- Melai Nuts — staff foundation test suite (Batch 1)
-- =============================================================================
-- Verifies 20260930010000_staff_foundation.sql: account status (incl.
-- suspended), permission keys, authorized branches, the append-only audit log
-- and the email sync — as the `anon` / `authenticated` roles carrying a
-- Firebase-shaped JWT.
--
-- HOW TO RUN (DEV / staging database only):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/staff_foundation_test.sql
-- One transaction, rolled back at the end. Raises if any check fails.
-- =============================================================================

begin;

create temp table results (
  id serial primary key,
  name text not null,
  passed boolean not null,
  detail text
);

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


-- Fixtures ------------------------------------------------------------------
insert into public.branches (name, address) values ('FOUND-TEST A', 'a'), ('FOUND-TEST B', 'b');
create temp table fx as
select (select id from public.branches where name = 'FOUND-TEST A') as branch_a,
       (select id from public.branches where name = 'FOUND-TEST B') as branch_b;
grant select on fx to public;

insert into public.staff_members
  (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
select 'f-a',   'A',   'old-a@test.local', 'staff', branch_a, 'active',    true,  false from fx
union all select 'f-b',   'B',   'b@test.local',     'staff', branch_b, 'active',    false, true  from fx
union all select 'f-sus', 'Sus', 's@test.local',     'staff', branch_a, 'suspended', true,  true  from fx
union all select 'f-off', 'Off', 'o@test.local',     'staff', branch_a, 'inactive',  true,  true  from fx
union all select 'f-own', 'Own', 'ow@test.local',    'owner', null,     'active',    false, false from fx;
insert into public.staff_permission_grants (firebase_uid, permission) values
  ('f-a', 'view_reports'), ('f-sus', 'view_reports');

-- 1. Account status ------------------------------------------------------------
select pg_temp.chk_true('suspended -> status suspended, nothing else revealed',
  pg_temp.scalar_as('f-sus', $$select public.get_my_staff_context()::text$$) = '{"status": "suspended"}');
select pg_temp.chk_true('inactive -> status inactive',
  pg_temp.scalar_as('f-off', $$select public.get_my_staff_context() ->> 'status'$$) = 'inactive');
select pg_temp.chk('suspended staff cannot use staff RPCs', 'f-sus',
  format($$select public.staff_get_inventory(%L)$$, (select branch_a from fx)), 'error');
do $$
declare v_msg text;
begin
  perform pg_temp.act_as('f-sus');
  begin
    perform public.staff_get_inventory((select branch_a from fx));
  exception when others then v_msg := sqlerrm;
  end;
  perform pg_temp.back_to_admin();
  perform pg_temp.chk_true('suspended error says suspended (not deactivated)', v_msg like '%suspended%', coalesce(v_msg, 'no error'));
end $$;
select pg_temp.chk_true('is_active is derived from account_status',
  (select bool_and(is_active = (account_status = 'active')) from public.staff_members));
do $$
begin
  begin
    insert into public.staff_members (firebase_uid, role, account_status) values ('f-bad', 'owner', 'banned');
    perform pg_temp.chk_true('unknown account_status rejected', false, 'insert succeeded');
  exception when check_violation then
    perform pg_temp.chk_true('unknown account_status rejected', true, 'check_violation');
  end;
  begin
    insert into public.staff_members (firebase_uid, role, is_active) values ('f-bad2', 'owner', true);
    perform pg_temp.chk_true('is_active cannot be written directly', false, 'insert succeeded');
  exception when generated_always then
    perform pg_temp.chk_true('is_active cannot be written directly', true, 'generated_always');
  end;
end $$;

-- 2. Context now carries permissions + authorized branches ----------------------
select pg_temp.chk_true('context lists A''s permissions: baseline + inventory flag + grant, no refunds',
  (select array(select jsonb_array_elements_text(
       pg_temp.scalar_as('f-a', $$select (public.get_my_staff_context() -> 'permissions')::text$$)::jsonb) order by 1)::text)
  = '{manage_inventory,manage_stock_transfers,view_dashboard,view_inventory,view_notifications,view_orders,view_products,view_reports}');
select pg_temp.chk_true('B has manage_refunds and not manage_inventory',
  pg_temp.scalar_as('f-b', $$select ((public.get_my_staff_context() -> 'permissions') ? 'manage_refunds')::text
      || '/' || ((public.get_my_staff_context() -> 'permissions') ? 'manage_inventory')::text$$) = 'true/false');
select pg_temp.chk_true('owner holds the whole catalog',
  pg_temp.scalar_as('f-own', $$select jsonb_array_length(public.get_my_staff_context() -> 'permissions')::text$$)
    = array_length(public.staff_permission_catalog(), 1)::text);
select pg_temp.chk_true('staff_permission_keys is empty for a suspended account with grants',
  pg_temp.scalar_as('f-sus', $$select cardinality(public.staff_permission_keys())::text$$) = '0');
select pg_temp.chk_true('staff: authorized branches = exactly the assigned one',
  pg_temp.scalar_as('f-a', $$select (public.get_my_staff_context() -> 'authorized_branches' -> 0 ->> 'name')
      || '/' || jsonb_array_length(public.get_my_staff_context() -> 'authorized_branches')::text$$) = 'FOUND-TEST A/1');
select pg_temp.chk_true('owner: authorized branches include every branch',
  pg_temp.scalar_as('f-own', $$select (jsonb_array_length(public.get_my_staff_context() -> 'authorized_branches')
      = (select count(*) from public.branches))::text$$) = 'true');
select pg_temp.chk_true('suspended staff have no authorized branches',
  pg_temp.scalar_as('f-sus', $$select cardinality(public.staff_authorized_branch_ids())::text$$) = '0');
select pg_temp.chk_true('staff_has_permission understands catalog keys',
  pg_temp.scalar_as('f-a', $$select public.staff_has_permission('view_reports')::text
      || '/' || public.staff_has_permission('manage_refunds')::text$$) = 'true/false');
select pg_temp.chk_true('staff_has_permission is false for suspended even with a grant',
  pg_temp.scalar_as('f-sus', $$select public.staff_has_permission('view_reports')::text$$) = 'false');

-- 3. Grants are not client-writable ---------------------------------------------
select pg_temp.chk('staff cannot grant themselves a permission', 'f-a',
  $$insert into public.staff_permission_grants (firebase_uid, permission) values ('f-a', 'manage_products')$$, 'error');
select pg_temp.chk('staff cannot delete a grant', 'f-a', $$delete from public.staff_permission_grants$$, 'error');
select pg_temp.chk_true('staff only read their own grants',
  pg_temp.scalar_as('f-a', $$select count(*)::text from public.staff_permission_grants$$) = '1');
do $$
begin
  begin
    insert into public.staff_permission_grants (firebase_uid, permission) values ('f-a', 'not_a_permission');
    perform pg_temp.chk_true('grant outside the catalog rejected', false, 'insert succeeded');
  exception when check_violation then
    perform pg_temp.chk_true('grant outside the catalog rejected', true, 'check_violation');
  end;
end $$;

-- 4. Owner status management ------------------------------------------------------
select pg_temp.chk('staff cannot call owner_set_staff_status', 'f-a',
  $$select public.owner_set_staff_status('f-b', 'suspended')$$, 'error');
select pg_temp.chk('owner can suspend staff', 'f-own',
  $$select public.owner_set_staff_status('f-b', 'suspended')$$, 'ok');
select pg_temp.chk_true('...and it takes effect at once',
  pg_temp.scalar_as('f-b', $$select public.get_my_staff_context() ->> 'status'$$) = 'suspended');
select pg_temp.chk('owner cannot change own status', 'f-own',
  $$select public.owner_set_staff_status('f-own', 'suspended')$$, 'error');
select pg_temp.chk('unknown status refused', 'f-own',
  $$select public.owner_set_staff_status('f-a', 'banned')$$, 'error');
select pg_temp.chk('re-provisioning as active does not lift a suspension', 'f-own',
  $$select public.owner_upsert_staff_member('f-sus', 'Sus', 's@test.local', 'staff', 'FOUND-TEST A', true)$$, 'ok');
select pg_temp.chk_true('...suspension still in force',
  pg_temp.scalar_as('f-sus', $$select public.get_my_staff_context() ->> 'status'$$) = 'suspended');

-- 5. Email sync comes from the verified token ----------------------------------------
select pg_temp.chk('staff can sync own identity', 'f-a', $$select public.staff_sync_my_identity()$$, 'ok');
select pg_temp.chk_true('email now equals the JWT email (f-a@test.local), not the stale one',
  (select email from public.staff_members where firebase_uid = 'f-a') = 'f-a@test.local');
select pg_temp.chk_true('sync touched nobody else',
  (select email from public.staff_members where firebase_uid = 'f-b') = 'b@test.local');
select pg_temp.chk('anon cannot sync identity', null, $$select public.staff_sync_my_identity()$$, 'error');
select pg_temp.chk_true('sync takes no client-supplied email argument',
  (select pronargs from pg_proc where oid = 'public.staff_sync_my_identity()'::regprocedure) = 0);

-- 6. Audit log -----------------------------------------------------------------------
select pg_temp.chk('staff can record an audit entry', 'f-a',
  $$select public.staff_log_audit('inventory.adjust', 'inventory_batch', 'b-1', '{"delta": -2}', 'op-1')$$, 'ok');
select pg_temp.chk_true('actor and branch were derived on the server',
  (select staff_firebase_uid || '/' || branch_id::text from public.staff_audit_logs where client_operation_id = 'op-1')
    = 'f-a/' || (select branch_a::text from fx));
select pg_temp.chk('replaying the same client operation id is accepted...', 'f-a',
  $$select public.staff_log_audit('inventory.adjust', 'inventory_batch', 'b-1', '{"delta": -2}', 'op-1')$$, 'ok');
select pg_temp.chk_true('...but stored once',
  (select count(*) from public.staff_audit_logs where client_operation_id = 'op-1') = 1);
select pg_temp.chk('staff cannot insert audit rows directly', 'f-a',
  $$insert into public.staff_audit_logs (staff_firebase_uid, action, entity_type) values ('f-b', 'x.y', 'z')$$, 'error');
select pg_temp.chk('staff cannot update audit rows', 'f-a', $$update public.staff_audit_logs set action = 'a.b'$$, 'error');
select pg_temp.chk('staff cannot delete audit rows', 'f-a', $$delete from public.staff_audit_logs$$, 'error');
select pg_temp.chk('staff cannot truncate audit rows', 'f-a', $$truncate public.staff_audit_logs$$, 'error');
select pg_temp.chk('suspended staff cannot record audit entries', 'f-sus',
  $$select public.staff_log_audit('a.b', 'thing')$$, 'error');
select pg_temp.chk('anon cannot record audit entries', null, $$select public.staff_log_audit('a.b', 'thing')$$, 'error');
select pg_temp.chk('malformed action refused', 'f-a', $$select public.staff_log_audit('DROP TABLE;', 'thing')$$, 'error');
select pg_temp.chk('oversized metadata refused', 'f-a',
  $$select public.staff_log_audit('a.b', 'thing', null, jsonb_build_object('x', repeat('y', 9000)))$$, 'error');
select pg_temp.chk('non-object metadata refused', 'f-a', $$select public.staff_log_audit('a.b', 'thing', null, '[1]'::jsonb)$$, 'error');
select pg_temp.chk('owner records an entry too (a second actor exists)', 'f-own',
  $$select public.staff_log_audit('refund.review', 'refund', 'r-1')$$, 'ok');
select pg_temp.chk_true('two actors now have rows',
  (select count(distinct staff_firebase_uid) from public.staff_audit_logs) = 2);
select pg_temp.chk_true('owner reads every actor''s audit rows',
  pg_temp.scalar_as('f-own', $$select count(distinct staff_firebase_uid)::text from public.staff_audit_logs$$) = '2');
select pg_temp.chk_true('staff read only their own audit trail',
  pg_temp.scalar_as('f-a', $$select count(distinct staff_firebase_uid)::text from public.staff_audit_logs$$) = '1');
do $$
begin
  begin
    update public.staff_audit_logs set action = 'tampered.x';
    perform pg_temp.chk_true('audit trigger blocks updates for privileged roles', false, 'update succeeded');
  exception when others then
    perform pg_temp.chk_true('audit trigger blocks updates for privileged roles', sqlerrm like 'Audit records cannot%', sqlerrm);
  end;
end $$;
select pg_temp.chk_true('_write_audit is not callable by clients',
  not has_function_privilege('authenticated', 'public._write_audit(text, uuid, text, text, text, jsonb, text)', 'execute'));
select pg_temp.chk_true('RLS on audit and grants tables',
  (select bool_and(relrowsecurity) from pg_class where oid in ('public.staff_audit_logs'::regclass, 'public.staff_permission_grants'::regclass)));

select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where passed) as passed, count(*) filter (where not passed) as failed, count(*) as total from results;
do $$
declare v_failed int;
begin
  select count(*) into v_failed from results where not passed;
  if v_failed > 0 then raise exception '% staff foundation check(s) FAILED — see the report above.', v_failed; end if;
end $$;
rollback;
