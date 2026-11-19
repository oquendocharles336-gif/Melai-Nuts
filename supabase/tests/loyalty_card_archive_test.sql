-- =============================================================================
-- Melai Nuts — loyalty card archive (migration 20261120010000_loyalty_card_archive.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/loyalty_card_archive_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
-- =============================================================================
begin;
set local timezone = 'Asia/Manila';

create temp table results (id serial primary key, name text not null, passed boolean not null, detail text);
create temp table fx (k text primary key, v text);
grant select on fx to public;

create function pg_temp.act_as(p_uid text) returns void language plpgsql as $$
begin
  if p_uid is null then
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
  else
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', p_uid, 'role', 'authenticated',
      'email', p_uid || '@test.local', 'email_verified', true, 'phone_number', '+639' || lpad((abs(hashtext(p_uid)) % 1000000000)::text, 9, '0'))::text, true);
    execute 'set local role authenticated';
  end if;
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
create function pg_temp.call_as(p_uid text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.act_as(p_uid);
  begin execute p_sql into v;
  exception when others then perform pg_temp.back_to_admin(); raise; end;
  perform pg_temp.back_to_admin();
  return v;
end $$;
create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;
create function pg_temp.f(p_k text) returns text language sql as $$ select v from fx where k = p_k $$;
grant execute on function pg_temp.f(text) to public;
create function pg_temp.j(p_uid text, p_sql text) returns jsonb language sql as $$
  select pg_temp.call_as(p_uid, 'select (' || p_sql || ')::text')::jsonb $$;
create function pg_temp.days_left(p_card text) returns int language sql as $$
  select (e ->> 'days_left')::int
  from jsonb_array_elements(pg_temp.j('ar-own', 'public.owner_archived_loyalty_cards()')) e
  where e ->> 'id' = p_card $$;

-- Fixtures ---------------------------------------------------------------------
insert into public.branches (name, address, delivery_fee) values ('ARCH-TEST A', 'a', 0);
insert into fx select 'ba', id::text from public.branches where name = 'ARCH-TEST A';
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
values ('ar-sa',  'Cashier', 'ar-sa@test.local',  'staff', pg_temp.f('ba')::uuid, 'active'),
       ('ar-own', 'Owner',   'ar-own@test.local', 'owner', null, 'active');
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values
  ('ar-c1', 'Archive One', 'ar-c1@test.local', '09172220001'),
  ('ar-c2', 'Archive Two', 'ar-c2@test.local', '09172220002');
insert into public.loyalty_accounts (firebase_uid, points_balance) values ('ar-c1', 120), ('ar-c2', 40)
  on conflict (firebase_uid) do update set points_balance = excluded.points_balance;

insert into fx select 'c1a', pg_temp.call_as('ar-sa', $q$select public.staff_register_loyalty_card('A1A1A1A1', 'ar-c1', 'arch-reg-1') ->> 'id'$q$);
insert into fx select 'c2a', pg_temp.call_as('ar-sa', $q$select public.staff_register_loyalty_card('B2B2B2B2', 'ar-c2', 'arch-reg-2') ->> 'id'$q$);
insert into fx select 'c1lbl', card_label from public.loyalty_cards where id = pg_temp.f('c1a')::uuid;

-- 1. Active cards are not archived; nothing changes for them ---------------------------
select pg_temp.chk_true('an active card is not in the archive',
  (select archived_at is null from public.loyalty_cards where id = pg_temp.f('c1a')::uuid));
select pg_temp.chk_true('the archive starts empty',
  jsonb_array_length(pg_temp.j('ar-own', 'public.owner_archived_loyalty_cards()')) = 0);
select pg_temp.chk_true('an active card still taps as active',
  pg_temp.j('ar-sa', $q$public.staff_lookup_card('A1A1A1A1')$q$) ->> 'status' = 'active');

-- 2. Blocking / replacing moves a card into the archive ----------------------------------
select pg_temp.call_as('ar-sa', format($q$select public.staff_block_loyalty_card(%L::uuid, 'reported lost')::text$q$, pg_temp.f('c1a')));
select pg_temp.chk_true('a blocked card is archived now',
  (select archived_at between now() - interval '1 minute' and now() from public.loyalty_cards where id = pg_temp.f('c1a')::uuid));
insert into fx select 'c2b', pg_temp.call_as('ar-sa', $q$select public.staff_replace_loyalty_card('ar-c2', 'C3C3C3C3', 'damaged', 'arch-rep-1') ->> 'id'$q$);
select pg_temp.chk_true('a replaced (retired) card is archived, the new one is not',
  (select archived_at is not null from public.loyalty_cards where id = pg_temp.f('c2a')::uuid)
  and (select archived_at is null and status = 'active' from public.loyalty_cards where id = pg_temp.f('c2b')::uuid));
select pg_temp.chk_true('the archive lists both, each with 30 days left',
  jsonb_array_length(pg_temp.j('ar-own', 'public.owner_archived_loyalty_cards()')) = 2
  and pg_temp.days_left(pg_temp.f('c1a')) = 30 and pg_temp.days_left(pg_temp.f('c2a')) = 30);

-- 3. Rights --------------------------------------------------------------------------------
select pg_temp.chk('staff cannot list the archive', 'ar-sa', 'select public.owner_archived_loyalty_cards()', 'error');
select pg_temp.chk('a customer cannot list the archive', 'ar-c1', 'select public.owner_archived_loyalty_cards()', 'error');
select pg_temp.chk('anon cannot list the archive', null, 'select public.owner_archived_loyalty_cards()', 'error');
select pg_temp.chk('staff cannot delete an archived card', 'ar-sa',
  format($q$select public.owner_delete_archived_card(%L::uuid, %L)$q$, pg_temp.f('c1a'), pg_temp.f('c1lbl')), 'error');
select pg_temp.chk('staff cannot re-activate an archived card', 'ar-sa',
  format($q$select public.owner_reactivate_archived_card(%L::uuid)$q$, pg_temp.f('c1a')), 'error');
select pg_temp.chk('nobody may call the purge through the API', 'ar-own', 'select public.purge_expired_archived_loyalty_cards()', 'error');
do $$ begin
  begin
    delete from public.loyalty_card_events where card_id = (select v::uuid from fx where k = 'c1a');
    insert into results(name, passed, detail) values ('card history stays append-only (even for the admin)', false, 'deleted');
  exception when others then
    insert into results(name, passed, detail) values ('card history stays append-only (even for the admin)', true, sqlerrm);
  end;
end $$;

-- 4. Re-activate -----------------------------------------------------------------------------
select pg_temp.chk('a retired card cannot come back while the customer has another active card', 'ar-own',
  format($q$select public.owner_reactivate_archived_card(%L::uuid)$q$, pg_temp.f('c2a')), 'error');
select pg_temp.chk('the owner re-activates the blocked card', 'ar-own',
  format($q$select public.owner_reactivate_archived_card(%L::uuid)$q$, pg_temp.f('c1a')), 'ok');
select pg_temp.chk_true('re-activated: active, out of the archive, taps again',
  (select status = 'active' and archived_at is null and blocked_at is null from public.loyalty_cards where id = pg_temp.f('c1a')::uuid)
  and pg_temp.j('ar-sa', $q$public.staff_lookup_card('A1A1A1A1')$q$) ->> 'status' = 'active');
select pg_temp.chk_true('re-activation is in the card history and the audit log',
  exists (select 1 from public.loyalty_card_events where card_id = pg_temp.f('c1a')::uuid and event = 'unblocked' and note = 'Re-activated from the archive')
  and exists (select 1 from public.staff_audit_logs where action = 'loyalty.card_reactivate' and entity_id = pg_temp.f('c1a')));

-- 5. Delete with the confirm step -------------------------------------------------------------
select pg_temp.chk('an active card cannot be deleted', 'ar-own',
  format($q$select public.owner_delete_archived_card(%L::uuid, %L)$q$, pg_temp.f('c1a'), pg_temp.f('c1lbl')), 'error');
select pg_temp.chk('delete without the right label is refused', 'ar-own',
  format($q$select public.owner_delete_archived_card(%L::uuid, 'GK-0000-0000')$q$, pg_temp.f('c2a')), 'error');
select pg_temp.chk_true('the refused delete left the card',
  exists (select 1 from public.loyalty_cards where id = pg_temp.f('c2a')::uuid));
insert into fx select 'c2lbl', card_label from public.loyalty_cards where id = pg_temp.f('c2a')::uuid;
select pg_temp.chk('the owner deletes the retired card, label typed again', 'ar-own',
  format($q$select public.owner_delete_archived_card(%L::uuid, lower(%L))$q$, pg_temp.f('c2a'), pg_temp.f('c2lbl')), 'ok');
select pg_temp.chk_true('deleted: card and its history gone, audit kept',
  not exists (select 1 from public.loyalty_cards where id = pg_temp.f('c2a')::uuid)
  and not exists (select 1 from public.loyalty_card_events where card_id = pg_temp.f('c2a')::uuid)
  and exists (select 1 from public.staff_audit_logs where action = 'loyalty.card_deleted' and entity_id = pg_temp.f('c2a')));
select pg_temp.chk_true('points stay on the account; the new card still works',
  (select points_balance = 40 from public.loyalty_accounts where firebase_uid = 'ar-c2')
  and (select status = 'active' from public.loyalty_cards where id = pg_temp.f('c2b')::uuid)
  and pg_temp.j('ar-sa', $q$public.staff_lookup_card('C3C3C3C3')$q$) ->> 'status' = 'active');
select pg_temp.chk_true('the deleted card is simply unknown now',
  pg_temp.j('ar-sa', $q$public.staff_lookup_card('B2B2B2B2')$q$) ->> 'status' = 'unregistered');

-- 6. The 30-day clean-up ---------------------------------------------------------------------
select pg_temp.call_as('ar-sa', format($q$select public.staff_block_loyalty_card(%L::uuid, 'lost again')::text$q$, pg_temp.f('c1a')));
select pg_temp.chk_true('blocked again: a fresh 30 days', pg_temp.days_left(pg_temp.f('c1a')) = 30);
select pg_temp.chk_true('the purge leaves a card archived for less than 30 days',
  public.purge_expired_archived_loyalty_cards() = 0 and exists (select 1 from public.loyalty_cards where id = pg_temp.f('c1a')::uuid));
update public.loyalty_cards set archived_at = now() - interval '29 days 23 hours' where id = pg_temp.f('c1a')::uuid;
select pg_temp.chk_true('one day left is shown as 1', pg_temp.days_left(pg_temp.f('c1a')) = 1);
update public.loyalty_cards set archived_at = now() - interval '30 days 1 minute' where id = pg_temp.f('c1a')::uuid;
insert into fx select 'purged', public.purge_expired_archived_loyalty_cards()::text;
select pg_temp.chk_true('after 30 days the purge deletes it',
  pg_temp.f('purged') = '1' and not exists (select 1 from public.loyalty_cards where id = pg_temp.f('c1a')::uuid));
select pg_temp.chk_true('purged: points kept, profile shows no card, audit says why',
  (select points_balance = 120 from public.loyalty_accounts where firebase_uid = 'ar-c1')
  and (select rfid_card_number is null from public.customer_profiles where firebase_uid = 'ar-c1')
  and exists (select 1 from public.staff_audit_logs where action = 'loyalty.card_deleted' and entity_id = pg_temp.f('c1a')
              and metadata ->> 'why' = 'archived for 30 days'));

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% card archive check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
