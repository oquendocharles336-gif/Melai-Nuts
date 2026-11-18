-- =============================================================================
-- Melai Nuts — single-use links for password reset / e-mail change
-- (migration 20261118050000_account_email_actions.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/account_email_actions_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
-- The Edge Function (hashing, Firebase Admin, e-mails) is tested with Deno.
-- =============================================================================
begin;

create temp table results (id serial primary key, name text not null, passed boolean not null, detail text);
create function pg_temp.chk_true(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into results(name, passed, detail) values (p_name, coalesce(p_cond, false), p_detail);
$$;
create function pg_temp.denied(p_role text, p_sql text) returns boolean language plpgsql as $$
declare v_ok boolean := false;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', 'attacker', 'role', p_role)::text, true);
  execute format('set local role %I', p_role);
  begin execute p_sql; exception when others then v_ok := true; end;
  execute 'reset role';
  return v_ok;
end $$;

-- Only the service role ---------------------------------------------------------------
select pg_temp.chk_true('anon cannot read tokens', pg_temp.denied('anon', 'select count(*) from public.auth_action_tokens'));
select pg_temp.chk_true('authenticated cannot read tokens', pg_temp.denied('authenticated', 'select count(*) from public.auth_action_tokens'));
select pg_temp.chk_true('authenticated cannot issue', pg_temp.denied('authenticated',
  $q$select public.auth_action_issue('password_reset', 'attacker', 'a@x.test', null, 'e:a', null, '[]'::jsonb)$q$));
select pg_temp.chk_true('anon cannot consume', pg_temp.denied('anon', $q$select public.auth_action_consume('password_reset', 'h')$q$));
select pg_temp.chk_true('anon cannot change e-mails', pg_temp.denied('anon', $q$select public.auth_action_apply_email('u', 'x@x.test')$q$));

-- Password reset ---------------------------------------------------------------------
select pg_temp.chk_true('reset issued',
  (public.auth_action_issue('password_reset', 'uid-1', 'one@x.test', null, 'e:one', 'ip:1',
    '[{"kind":"password_reset","hash":"h-reset-1"}]'::jsonb) ->> 'ok')::boolean);
select pg_temp.chk_true('only the hash is stored',
  (select token_hash = 'h-reset-1' and expires_at between now() + interval '29 minutes' and now() + interval '31 minutes'
     from public.auth_action_tokens where token_hash = 'h-reset-1'));
select pg_temp.chk_true('a second request within 60 s: cooldown',
  (public.auth_action_issue('password_reset', 'uid-1', 'one@x.test', null, 'e:one', 'ip:1',
    '[{"kind":"password_reset","hash":"h-reset-2"}]'::jsonb) ->> 'reason') = 'cooldown');
select pg_temp.chk_true('peek does not use the link',
  (public.auth_action_peek('password_reset', 'h-reset-1') ->> 'status') = 'ok'
  and (public.auth_action_peek('password_reset', 'h-reset-1') ->> 'status') = 'ok');
select pg_temp.chk_true('a link of another kind does not match',
  (public.auth_action_peek('email_change', 'h-reset-1') ->> 'status') = 'invalid');
update public.auth_action_sends set created_at = now() - interval '2 minutes' where email_hash = 'e:one';
select public.auth_action_issue('password_reset', 'uid-1', 'one@x.test', null, 'e:one', 'ip:1',
  '[{"kind":"password_reset","hash":"h-reset-3"}]'::jsonb);
select pg_temp.chk_true('a newer reset e-mail makes the older link unusable',
  (public.auth_action_peek('password_reset', 'h-reset-1') ->> 'status') = 'used');
select pg_temp.chk_true('consume: ok once, with the account',
  (public.auth_action_consume('password_reset', 'h-reset-3') ->> 'uid') = 'uid-1');
select pg_temp.chk_true('consume twice: used',
  (public.auth_action_consume('password_reset', 'h-reset-3') ->> 'status') = 'used');
insert into public.auth_action_tokens (request_id, kind, firebase_uid, email, token_hash, expires_at)
  values (gen_random_uuid(), 'password_reset', 'uid-9', 'n@x.test', 'h-old', now() - interval '1 minute');
select pg_temp.chk_true('an expired link: expired',
  (public.auth_action_consume('password_reset', 'h-old') ->> 'status') = 'expired');
select pg_temp.chk_true('an unknown link: invalid',
  (public.auth_action_consume('password_reset', 'nope') ->> 'status') = 'invalid');

-- No account: counted, nothing stored (same answer as for a real account) -------------
select pg_temp.chk_true('an address without an account gets ok too',
  (public.auth_action_issue('password_reset', null, 'ghost@x.test', null, 'e:ghost', 'ip:2', null) ->> 'ok')::boolean);
select pg_temp.chk_true('...and no token is stored for it',
  not exists (select 1 from public.auth_action_tokens where email = 'ghost@x.test'));
select pg_temp.chk_true('...but it counts for the cooldown',
  (public.auth_action_issue('password_reset', null, 'ghost@x.test', null, 'e:ghost', 'ip:2', null) ->> 'reason') = 'cooldown');

-- Hourly limits ---------------------------------------------------------------------
do $$ begin
  for i in 1..5 loop
    insert into public.auth_action_sends (kind, email_hash, ip_hash, created_at) values ('k' || i, 'e:busy', null, now() - interval '10 minutes');
  end loop;
  for i in 1..20 loop
    insert into public.auth_action_sends (kind, email_hash, ip_hash, created_at) values ('password_reset', 'e:ip' || i, 'ip:busy', now() - interval '10 minutes');
  end loop;
end $$;
select pg_temp.chk_true('5 e-mails an hour per address',
  (public.auth_action_issue('password_reset', null, 'b@x.test', null, 'e:busy', null, null) ->> 'reason') = 'hourly_limit');
select pg_temp.chk_true('20 requests an hour per IP',
  (public.auth_action_issue('password_reset', null, 'c@x.test', null, 'e:fresh', 'ip:busy', null) ->> 'reason') = 'hourly_limit');

-- E-mail change: confirm link (new address) + cancel link (old address) -----------------
insert into public.customer_profiles (firebase_uid, full_name, email) values ('uid-2', 'Two', 'old@x.test');
select public.auth_action_issue('email_change', 'uid-2', 'old@x.test', 'new@x.test', 'e:old', 'ip:3',
  '[{"kind":"email_change","hash":"h-chg"},{"kind":"email_change_cancel","hash":"h-cancel"}]'::jsonb);
select pg_temp.chk_true('both links of the request are open',
  (select count(*) from public.auth_action_tokens where firebase_uid = 'uid-2' and used_at is null) = 2);
select pg_temp.chk_true('confirm gives the new address',
  (public.auth_action_consume('email_change', 'h-chg') ->> 'new_email') = 'new@x.test');
select pg_temp.chk_true('after confirming, the cancel link is closed',
  (public.auth_action_peek('email_change_cancel', 'h-cancel') ->> 'status') = 'used');
select public.auth_action_apply_email('uid-2', 'new@x.test');
select pg_temp.chk_true('the profile copy follows the new address',
  (select email from public.customer_profiles where firebase_uid = 'uid-2') = 'new@x.test');
update public.auth_action_sends set created_at = now() - interval '2 minutes' where email_hash = 'e:new';
select public.auth_action_issue('email_change', 'uid-2', 'new@x.test', 'third@x.test', 'e:new', 'ip:3',
  '[{"kind":"email_change","hash":"h-chg2"},{"kind":"email_change_cancel","hash":"h-cancel2"}]'::jsonb);
select pg_temp.chk_true('cancel from the old address closes the confirm link',
  (public.auth_action_consume('email_change_cancel', 'h-cancel2') ->> 'status') = 'ok'
  and (public.auth_action_peek('email_change', 'h-chg2') ->> 'status') = 'used');

-- MFA notice: only right after two-step sign-in was confirmed ------------------------
select pg_temp.chk_true('anon cannot ask for the MFA check', pg_temp.denied('anon', $q$select public.auth_action_mfa_recent('uid-x')$q$));
insert into public.staff_members (firebase_uid, full_name, email, role, account_status)
  values ('uid-mfa', 'Mia Owner', 'mia@x.test', 'owner', 'active') on conflict (firebase_uid) do nothing;
insert into public.staff_two_factor (firebase_uid, secret, confirmed_at) values ('uid-mfa', '\x00', now() - interval '2 minutes');
select pg_temp.chk_true('just confirmed: the staff e-mail', public.auth_action_mfa_recent('uid-mfa') = 'mia@x.test');
update public.staff_two_factor set confirmed_at = now() - interval '1 hour' where firebase_uid = 'uid-mfa';
select pg_temp.chk_true('confirmed long ago: nothing', public.auth_action_mfa_recent('uid-mfa') is null);

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% account e-mail check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
