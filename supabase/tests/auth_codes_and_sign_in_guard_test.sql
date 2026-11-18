-- =============================================================================
-- Melai Nuts — e-mail codes and the sign-in captcha gate
-- (migration 20261118015111_auth_email_codes_and_sign_in_guard.sql)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/auth_codes_and_sign_in_guard_test.sql
-- DEV / staging only. One transaction, rolled back. Raises if any check fails.
-- The Edge Functions themselves (token checks, hashing, captcha) are tested with Deno.
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
create function pg_temp.rows_as(p_role text, p_sql text) returns bigint language plpgsql as $$
declare v bigint;
begin
  execute format('set local role %I', p_role);
  begin execute p_sql into v; exception when insufficient_privilege then v := -1; end;
  execute 'reset role';
  return v;
end $$;
create function pg_temp.issue(p_uid text, p_email text, p_ip text, p_hash text) returns jsonb language sql as $$
  select public.auth_email_code_issue(p_uid, p_email, 'e:' || lower(p_email), p_ip, p_hash) $$;

-- 0. Nobody but the service role --------------------------------------------------
select public.auth_email_code_issue('u-seed', 'seed@test.local', 'e:seed', 'ip:seed', 'h-seed');
select pg_temp.chk_true('anon cannot read the code table',
  pg_temp.rows_as('anon', 'select count(*) from public.auth_email_codes') <= 0);
select pg_temp.chk_true('a signed-in customer cannot read the code table',
  pg_temp.rows_as('authenticated', 'select count(*) from public.auth_email_codes') <= 0);
select pg_temp.chk_true('a customer cannot read the sign-in attempts',
  pg_temp.rows_as('authenticated', 'select count(*) from public.auth_sign_in_attempts') <= 0);
select pg_temp.chk_true('a customer cannot write a code',
  pg_temp.denied('authenticated', $q$insert into public.auth_email_codes (firebase_uid, email, code_hash, expires_at) values ('attacker', 'a@b.c', 'x', now() + interval '1 hour')$q$));
select pg_temp.chk_true('a customer cannot clear sign-in attempts',
  pg_temp.denied('authenticated', $q$delete from public.auth_sign_in_attempts$q$)
  or pg_temp.rows_as('authenticated', 'select count(*) from public.auth_sign_in_attempts') <= 0);
select pg_temp.chk_true('a customer cannot call the code functions',
  pg_temp.denied('authenticated', $q$select public.auth_email_code_begin_verify('u-seed')$q$)
  and pg_temp.denied('authenticated', $q$select public.auth_email_code_issue('x', 'x@y.z', 'e', null, 'h')$q$)
  and pg_temp.denied('anon', $q$select public.auth_email_code_consume('u-seed', 'h-seed')$q$));
select pg_temp.chk_true('a customer cannot call the sign-in gate',
  pg_temp.denied('authenticated', $q$select public.auth_sign_in_succeeded('e:victim', null)$q$)
  and pg_temp.denied('anon', $q$select public.auth_sign_in_attempt('e:victim', null, null, true)$q$));
select pg_temp.chk_true('a customer cannot redeem captcha tokens',
  pg_temp.denied('anon', $q$select public.auth_captcha_redeem('x')$q$));

-- 1. Issue, cooldown, one active code ----------------------------------------------
select pg_temp.chk_true('first send is accepted, 600 s', (pg_temp.issue('u1', 'A@Test.local', 'ip1', 'h1') ->> 'expires_in')::int = 600);
select pg_temp.chk_true('the address is stored normalized, the code only as its hash',
  (select email = 'a@test.local' and code_hash = 'h1' and attempts = 0 from public.auth_email_codes where firebase_uid = 'u1'));
select pg_temp.chk_true('resend within 60 s: cooldown with a wait',
  (select j ->> 'reason' = 'cooldown' and (j ->> 'retry_after')::int between 1 and 60
   from (select pg_temp.issue('u1', 'a@test.local', 'ip1', 'h1b') j) t));
update public.auth_email_codes set created_at = now() - interval '61 seconds' where firebase_uid = 'u1';
select pg_temp.chk_true('after 60 s a new code is accepted', (pg_temp.issue('u1', 'a@test.local', 'ip1', 'h2') ->> 'ok')::boolean);
select pg_temp.chk_true('...and replaces the old one (one active code)',
  (select count(*) = 1 and min(code_hash) = 'h2' from public.auth_email_codes where firebase_uid = 'u1'));
select pg_temp.chk_true('the old code no longer works', not public.auth_email_code_consume('u1', 'h1'));

-- 2. Hourly limits ------------------------------------------------------------------
do $$ begin
  for i in 1..3 loop
    update public.auth_email_codes set created_at = now() - interval '61 seconds' where firebase_uid = 'u1';
    perform pg_temp.issue('u1', 'a@test.local', 'ip1', 'hx' || i);
  end loop;
end $$;
update public.auth_email_codes set created_at = now() - interval '61 seconds' where firebase_uid = 'u1';
select pg_temp.chk_true('6th send in an hour for one account: hourly limit',
  (select j ->> 'reason' = 'hourly_limit' and (j ->> 'retry_after')::int > 0
   from (select pg_temp.issue('u1', 'a@test.local', 'ip1', 'h-over') j) t));
select pg_temp.chk_true('another account, same address: also limited (per e-mail)',
  pg_temp.issue('u1-other', 'a@test.local', 'ip9', 'h-o') ->> 'reason' = 'hourly_limit');
do $$ begin
  for i in 1..20 loop perform pg_temp.issue('ipacct' || i, 'ip' || i || '@test.local', 'ip-shared', 'hi' || i); end loop;
end $$;
select pg_temp.chk_true('21st send from one IP in an hour: limited (per IP)',
  pg_temp.issue('ipacct21', 'ip21@test.local', 'ip-shared', 'hi21') ->> 'reason' = 'hourly_limit');

-- 3. Verify: attempts counted first, max 5, single use, expiry ---------------------------
select pg_temp.issue('u2', 'b@test.local', 'ip2', 'good');
select pg_temp.chk_true('a try returns the stored hash and counts it',
  (select j ->> 'status' = 'ok' and j ->> 'code_hash' = 'good' and (j ->> 'attempts_left')::int = 4
   from (select public.auth_email_code_begin_verify('u2') j) t));
do $$ begin for i in 1..4 loop perform public.auth_email_code_begin_verify('u2'); end loop; end $$;
select pg_temp.chk_true('after 5 tries the code is locked', public.auth_email_code_begin_verify('u2') ->> 'status' = 'locked');
select pg_temp.chk_true('a locked code still cannot be consumed by a 6th guess... (attempts never exceed 5)',
  (select attempts = 5 from public.auth_email_codes where firebase_uid = 'u2'));
update public.auth_email_codes set created_at = now() - interval '61 seconds' where firebase_uid = 'u2';
select pg_temp.issue('u2', 'b@test.local', 'ip2', 'good2');
select pg_temp.chk_true('a new code starts with 5 tries again', public.auth_email_code_begin_verify('u2') ->> 'status' = 'ok');
select pg_temp.chk_true('the right code is consumed once', public.auth_email_code_consume('u2', 'good2'));
select pg_temp.chk_true('replay: the same code a second time is refused', not public.auth_email_code_consume('u2', 'good2'));
select pg_temp.chk_true('replay: a used code reports used', public.auth_email_code_begin_verify('u2') ->> 'status' = 'used');
select pg_temp.issue('u3', 'c@test.local', 'ip3', 'h3');
update public.auth_email_codes set expires_at = now() - interval '1 second' where firebase_uid = 'u3';
select pg_temp.chk_true('expired: reported as expired', public.auth_email_code_begin_verify('u3') ->> 'status' = 'expired');
select pg_temp.chk_true('expired: cannot be consumed', not public.auth_email_code_consume('u3', 'h3'));
select pg_temp.chk_true('no code at all: none', public.auth_email_code_begin_verify('nobody') ->> 'status' = 'none');
select pg_temp.issue('u4', 'd@test.local', 'ip4', 'h4');
select public.auth_email_code_discard('u4', 'h4');
select pg_temp.chk_true('a code whose e-mail failed is discarded: a resend is allowed at once',
  (pg_temp.issue('u4', 'd@test.local', 'ip4', 'h4b') ->> 'ok')::boolean);

-- 4. Captcha tokens are accepted once --------------------------------------------------
select pg_temp.chk_true('a captcha token is accepted once', public.auth_captcha_redeem('tok-1'));
select pg_temp.chk_true('the same captcha token again is refused', not public.auth_captcha_redeem('tok-1'));
select pg_temp.chk_true('an empty token is refused', not public.auth_captcha_redeem(''));

-- 5. Sign-in gate ----------------------------------------------------------------------
do $$ begin
  for i in 1..14 loop perform public.auth_sign_in_attempt('e:victim', 'ip:' || i, 'dev:' || i, false); end loop;
end $$;
select pg_temp.chk_true('14 attempts: the 15th still needs no captcha',
  (public.auth_sign_in_attempt('e:victim', 'ip:x', 'dev:x', false) ->> 'allowed')::boolean);
select pg_temp.chk_true('after 15 attempts on the e-mail: captcha required, nothing recorded',
  (select (j ->> 'allowed')::boolean = false and (j ->> 'captcha_required')::boolean
   from (select public.auth_sign_in_attempt('e:victim', 'ip:fresh', 'dev:fresh', false) j) t)
  and not exists (select 1 from public.auth_sign_in_attempts where key_hash = 'ip:fresh'));
select pg_temp.chk_true('a gate, not a lockout: with a verified captcha the attempt goes through',
  (select (j ->> 'allowed')::boolean and (j ->> 'captcha_required')::boolean
   from (select public.auth_sign_in_attempt('e:victim', 'ip:fresh', 'dev:fresh', true) j) t));
select pg_temp.chk_true('another e-mail from fresh keys is not affected',
  (select (j ->> 'allowed')::boolean and not (j ->> 'captcha_required')::boolean
   from (select public.auth_sign_in_attempt('e:someone', 'ip:other', 'dev:other', false) j) t));
do $$ begin
  for i in 1..15 loop perform public.auth_sign_in_attempt('e:spray' || i, 'ip:spray', null, false); end loop;
end $$;
select pg_temp.chk_true('15 attempts from one IP over many e-mails: captcha for that IP',
  (public.auth_sign_in_attempt('e:spray-next', 'ip:spray', null, false) ->> 'captcha_required')::boolean);
do $$ begin
  for i in 1..15 loop perform public.auth_sign_in_attempt('e:dev' || i, 'ip:dev' || i, 'dev:same', false); end loop;
end $$;
select pg_temp.chk_true('15 attempts from one device id: captcha for that device',
  (public.auth_sign_in_attempt('e:dev-next', 'ip:dev-next', 'dev:same', false) ->> 'captcha_required')::boolean);
select public.auth_sign_in_succeeded('e:victim', 'dev:fresh');
select pg_temp.chk_true('a successful sign-in clears the e-mail counter',
  not (public.auth_sign_in_attempt('e:victim', 'ip:after', 'dev:after', false) ->> 'captcha_required')::boolean);
select public.auth_sign_in_succeeded('e:spray1', null);
select pg_temp.chk_true('...but not the IP counter (no spray reset)',
  (public.auth_sign_in_attempt('e:spray-again', 'ip:spray', null, false) ->> 'captcha_required')::boolean);
update public.auth_sign_in_attempts set created_at = now() - interval '31 minutes' where key_hash = 'ip:spray';
select pg_temp.chk_true('rolling 30 minutes: older attempts no longer count',
  not (public.auth_sign_in_attempt('e:spray-later', 'ip:spray', null, false) ->> 'captcha_required')::boolean);

-- Report -------------------------------------------------------------------------
select id, case when passed then 'PASS' else 'FAIL' end as result, name, detail from results order by id;
select count(*) filter (where not passed) as failed, count(*) filter (where passed) as passed, count(*) as total from results;
do $$
declare n int;
begin
  select count(*) into n from results where not passed;
  if n > 0 then raise exception '% auth check(s) FAILED — see the report above.', n; end if;
end $$;
rollback;
