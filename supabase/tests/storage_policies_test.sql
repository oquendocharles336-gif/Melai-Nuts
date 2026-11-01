-- =============================================================================
-- Melai Nuts — who may upload and read files (migration 20261101150000)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/storage_policies_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
-- =============================================================================
begin;

create temp table results (id serial primary key, name text not null, passed boolean not null, detail text);
grant all on results to public;
grant all on sequence results_id_seq to public;

create function pg_temp.act_as(p_uid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.back_to_admin() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on function pg_temp.back_to_admin() to public;

create function pg_temp.chk(p_name text, p_uid text, p_sql text, p_expect text) returns void language plpgsql as $$
declare v_err text;
begin
  perform pg_temp.act_as(p_uid);
  begin execute p_sql; exception when others then v_err := sqlerrm; end;
  perform pg_temp.back_to_admin();
  insert into results(name, passed, detail) values (p_name,
    case p_expect when 'error' then v_err is not null else v_err is null end,
    'expected ' || p_expect || ' -> ' || coalesce('error: ' || v_err, 'no error'));
end $$;
create function pg_temp.seen(p_name text, p_uid text, p_bucket text, p_expect bigint) returns void language plpgsql as $$
declare v bigint; v_err text;
begin
  perform pg_temp.act_as(p_uid);
  begin
    execute format('select count(*) from storage.objects where bucket_id = %L', p_bucket) into v;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.back_to_admin();
  insert into results(name, passed, detail) values (p_name, v_err is null and v = p_expect,
    'expected ' || p_expect || ' -> ' || coalesce('error: ' || v_err, v::text));
end $$;
create function pg_temp.upload(p_bucket text, p_name text) returns text language sql as $$
  select format($q$insert into storage.objects (bucket_id, name, owner_id, metadata) values (%L, %L, 'x', '{}'::jsonb)$q$, p_bucket, p_name)
$$;

-- Fixtures ------------------------------------------------------------------------
insert into public.branches (name, address, delivery_fee) values ('ST-TEST A', 'a', 0), ('ST-TEST B', 'b', 0);
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
select 'st-a', 'Staff A', 'st-a@test.local', 'staff', id, 'active' from public.branches where name = 'ST-TEST A';
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
select 'st-b', 'Staff B', 'st-b@test.local', 'staff', id, 'active' from public.branches where name = 'ST-TEST B';
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
select 'st-off', 'Former', 'st-off@test.local', 'staff', id, 'suspended' from public.branches where name = 'ST-TEST A';
insert into public.drivers (firebase_uid, full_name, branch_id)
select 'dr-a', 'Driver A', id from public.branches where name = 'ST-TEST A';
insert into public.drivers (firebase_uid, full_name, branch_id)
select 'dr-b', 'Driver B', id from public.branches where name = 'ST-TEST A';
insert into public.deliveries (id, branch_id, branch_name, vehicle, rider_name, driver_uid, driver_status)
select 'DEL-ST-OUT', id, name, 'Van', 'Driver A', 'dr-a', 'in_transit' from public.branches where name = 'ST-TEST A';
insert into public.deliveries (id, branch_id, branch_name, vehicle, rider_name, driver_uid, driver_status)
select 'DEL-ST-NEW', id, name, 'Van', 'Driver A', 'dr-a', 'assigned' from public.branches where name = 'ST-TEST A';

-- The bug: a staff photo failed because of the delivery rule on the same table ------
select pg_temp.chk('staff add a photo to their own folder', 'st-a', pg_temp.upload('staff-photos', 'st-a/1.jpg'), 'ok');
select pg_temp.chk('not to someone else''s folder', 'st-a', pg_temp.upload('staff-photos', 'st-b/1.jpg'), 'error');
select pg_temp.chk('a customer cannot add a staff photo', 'cu-1', pg_temp.upload('staff-photos', 'cu-1/1.jpg'), 'error');
select pg_temp.chk('former staff cannot add a photo', 'st-off', pg_temp.upload('staff-photos', 'st-off/1.jpg'), 'error');
select pg_temp.seen('active staff can read staff photos', 'st-b', 'staff-photos', 1);
select pg_temp.seen('a customer sees none, without an error', 'cu-1', 'staff-photos', 0);

-- The delivery rules keep their meaning ---------------------------------------------
select pg_temp.chk('a driver uploads proof to their own run under way', 'dr-a', pg_temp.upload('delivery-proofs', 'DEL-ST-OUT/1.jpg'), 'ok');
select pg_temp.chk('not before the run has started', 'dr-a', pg_temp.upload('delivery-proofs', 'DEL-ST-NEW/1.jpg'), 'error');
select pg_temp.chk('not to another driver''s run', 'dr-b', pg_temp.upload('delivery-proofs', 'DEL-ST-OUT/2.jpg'), 'error');
select pg_temp.chk('staff cannot upload proof', 'st-a', pg_temp.upload('delivery-proofs', 'DEL-ST-OUT/3.jpg'), 'error');
select pg_temp.seen('the driver reads their proof', 'dr-a', 'delivery-proofs', 1);
select pg_temp.seen('staff of that branch read it', 'st-a', 'delivery-proofs', 1);
select pg_temp.seen('staff of another branch do not', 'st-b', 'delivery-proofs', 0);
select pg_temp.seen('another driver does not', 'dr-b', 'delivery-proofs', 0);
select pg_temp.seen('a customer does not', 'cu-1', 'delivery-proofs', 0);

-- App users still cannot read the table itself ---------------------------------------
select pg_temp.chk('app users cannot read deliveries directly', 'st-a', 'select 1 from public.deliveries', 'error');
insert into results(name, passed, detail)
select 'anon cannot use the proof checks',
  not has_function_privilege('anon', 'public._can_read_delivery_proof(text)', 'execute')
    and not has_function_privilege('anon', 'public._can_upload_delivery_proof(text)', 'execute'),
  '';

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% storage check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
