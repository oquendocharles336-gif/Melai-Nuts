-- =============================================================================
-- Melai Nuts — Migration 20261118010000: e-mail verification codes + sign-in captcha gate
-- =============================================================================
-- Run after 20261118000000_first_order_prepayment.sql. Idempotent, one transaction.
--
-- Backing store for two Edge Functions (supabase/functions/email-verification and
-- supabase/functions/auth-guard). Identity stays in Firebase; these tables only hold
-- short-lived security state.
--
-- 1. auth_email_codes: the 6-digit sign-up code. One active code per Firebase account,
--    stored as an HMAC (the Edge Function's secret pepper), never in plain text. 10 minutes,
--    at most 5 tries, single use, 60 s between sends, hourly send limits per account, per
--    e-mail address and per IP (auth_email_code_sends).
-- 2. auth_sign_in_attempts: sign-in attempts per normalized e-mail, per IP and per device id
--    (all as HMACs) in a rolling 30-minute window. A successful sign-in clears the e-mail's
--    and the device's attempts. From 15 attempts on either key the next sign-in needs a
--    captcha. A captcha is a gate, never a lockout: a solved captcha always lets the
--    attempt through, so nobody can lock someone else out by failing on purpose.
-- 3. auth_captcha_redemptions: every captcha token accepted once (Cloudflare's own reuse
--    check is eventually consistent; this one is not).
--
-- SECURITY. RLS is on and anon / authenticated have no privileges on any of these tables
-- or functions: only the service role (the Edge Functions) can use them.
-- The numbers live in one function, public._auth_limits().
-- =============================================================================
begin;

-- 1. Tables ---------------------------------------------------------------------------
create table if not exists public.auth_email_codes (
  firebase_uid text primary key,
  email text not null,
  code_hash text not null,
  attempts int not null default 0 check (attempts >= 0),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz
);

create table if not exists public.auth_email_code_sends (
  id bigserial primary key,
  firebase_uid text not null,
  email_hash text not null,
  ip_hash text,
  created_at timestamptz not null default now()
);
create index if not exists auth_email_code_sends_uid_idx on public.auth_email_code_sends (firebase_uid, created_at desc);
create index if not exists auth_email_code_sends_email_idx on public.auth_email_code_sends (email_hash, created_at desc);
create index if not exists auth_email_code_sends_ip_idx on public.auth_email_code_sends (ip_hash, created_at desc) where ip_hash is not null;

create table if not exists public.auth_sign_in_attempts (
  id bigserial primary key,
  key_type text not null check (key_type in ('email', 'ip', 'device')),
  key_hash text not null,
  created_at timestamptz not null default now()
);
create index if not exists auth_sign_in_attempts_key_idx on public.auth_sign_in_attempts (key_type, key_hash, created_at desc);

create table if not exists public.auth_captcha_redemptions (
  token_hash text primary key,
  used_at timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['auth_email_codes', 'auth_email_code_sends', 'auth_sign_in_attempts', 'auth_captcha_redemptions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end $$;
revoke all on sequence public.auth_email_code_sends_id_seq, public.auth_sign_in_attempts_id_seq from public, anon, authenticated;
grant usage on sequence public.auth_email_code_sends_id_seq, public.auth_sign_in_attempts_id_seq to service_role;
-- No policies: with RLS on and no policy, even a mistaken grant shows nothing to
-- anon / authenticated. The functions below are security definer (run as the owner).

-- 2. Limits -----------------------------------------------------------------------------
create or replace function public._auth_limits()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'code_ttl_seconds', 600,
    'code_max_attempts', 5,
    'resend_cooldown_seconds', 60,
    'sends_per_hour_account', 5,
    'sends_per_hour_email', 5,
    'sends_per_hour_ip', 20,
    'sign_in_window_minutes', 30,
    'sign_in_captcha_after', 15)
$$;
revoke all on function public._auth_limits() from public, anon, authenticated;
grant execute on function public._auth_limits() to service_role;

-- 3. E-mail codes -------------------------------------------------------------------------
-- Stores a new code (replacing any older one: one active code at a time), unless the
-- cooldown or an hourly limit says no. The caller sends the e-mail only after {ok: true}.
create or replace function public.auth_email_code_issue(
  p_uid text,
  p_email text,
  p_email_hash text,
  p_ip_hash text,
  p_code_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l jsonb := public._auth_limits();
  v_row public.auth_email_codes;
  v_wait int;
  v_oldest timestamptz;
begin
  if coalesce(p_uid, '') = '' or coalesce(p_email, '') = '' or coalesce(p_email_hash, '') = ''
     or coalesce(p_code_hash, '') = '' then
    raise exception 'auth_email_code_issue: missing argument';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('melai:auth:code:' || p_uid, 0));

  select * into v_row from public.auth_email_codes where firebase_uid = p_uid;
  if found and v_row.consumed_at is null
     and v_row.created_at > now() - make_interval(secs => (l ->> 'resend_cooldown_seconds')::int) then
    v_wait := ceil(extract(epoch from (v_row.created_at + make_interval(secs => (l ->> 'resend_cooldown_seconds')::int) - now())))::int;
    return jsonb_build_object('ok', false, 'reason', 'cooldown', 'retry_after', greatest(v_wait, 1));
  end if;

  select min(created_at) into v_oldest from (
    select created_at from public.auth_email_code_sends
     where firebase_uid = p_uid and created_at > now() - interval '1 hour'
     order by created_at desc limit (l ->> 'sends_per_hour_account')::int) s
  having count(*) >= (l ->> 'sends_per_hour_account')::int;
  if v_oldest is null then
    select min(created_at) into v_oldest from (
      select created_at from public.auth_email_code_sends
       where email_hash = p_email_hash and created_at > now() - interval '1 hour'
       order by created_at desc limit (l ->> 'sends_per_hour_email')::int) s
    having count(*) >= (l ->> 'sends_per_hour_email')::int;
  end if;
  if v_oldest is null and p_ip_hash is not null then
    select min(created_at) into v_oldest from (
      select created_at from public.auth_email_code_sends
       where ip_hash = p_ip_hash and created_at > now() - interval '1 hour'
       order by created_at desc limit (l ->> 'sends_per_hour_ip')::int) s
    having count(*) >= (l ->> 'sends_per_hour_ip')::int;
  end if;
  if v_oldest is not null then
    return jsonb_build_object('ok', false, 'reason', 'hourly_limit',
      'retry_after', greatest(ceil(extract(epoch from (v_oldest + interval '1 hour' - now())))::int, 1));
  end if;

  insert into public.auth_email_codes (firebase_uid, email, code_hash, attempts, created_at, expires_at, consumed_at)
  values (p_uid, lower(trim(p_email)), p_code_hash, 0, now(),
          now() + make_interval(secs => (l ->> 'code_ttl_seconds')::int), null)
  on conflict (firebase_uid) do update
    set email = excluded.email, code_hash = excluded.code_hash, attempts = 0,
        created_at = excluded.created_at, expires_at = excluded.expires_at, consumed_at = null;
  insert into public.auth_email_code_sends (firebase_uid, email_hash, ip_hash) values (p_uid, p_email_hash, p_ip_hash);
  delete from public.auth_email_code_sends where created_at < now() - interval '1 day';
  return jsonb_build_object('ok', true, 'expires_in', (l ->> 'code_ttl_seconds')::int);
end;
$$;

-- The e-mail could not be sent: forget the code so the person can ask again right away
-- (the send still counts towards the hourly limit).
create or replace function public.auth_email_code_discard(p_uid text, p_code_hash text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.auth_email_codes where firebase_uid = p_uid and code_hash = p_code_hash and consumed_at is null;
$$;

-- One try: counts the attempt FIRST (atomically, so parallel requests cannot exceed the
-- limit) and hands back the stored hash for a constant-time compare in the function.
-- status: ok | none | expired | used | locked
create or replace function public.auth_email_code_begin_verify(p_uid text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l jsonb := public._auth_limits();
  v_row public.auth_email_codes;
begin
  update public.auth_email_codes
     set attempts = attempts + 1
   where firebase_uid = p_uid and consumed_at is null and expires_at > now()
     and attempts < (l ->> 'code_max_attempts')::int
  returning * into v_row;
  if found then
    return jsonb_build_object('status', 'ok', 'code_hash', v_row.code_hash, 'email', v_row.email,
      'attempts_left', (l ->> 'code_max_attempts')::int - v_row.attempts);
  end if;
  select * into v_row from public.auth_email_codes where firebase_uid = p_uid;
  if not found then return jsonb_build_object('status', 'none'); end if;
  if v_row.consumed_at is not null then return jsonb_build_object('status', 'used'); end if;
  if v_row.expires_at <= now() then return jsonb_build_object('status', 'expired'); end if;
  return jsonb_build_object('status', 'locked');
end;
$$;

-- Single use: only the first caller with the right hash gets true.
create or replace function public.auth_email_code_consume(p_uid text, p_code_hash text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.auth_email_codes set consumed_at = now()
   where firebase_uid = p_uid and code_hash = p_code_hash and consumed_at is null and expires_at > now();
  return found;
end;
$$;

-- 4. Captcha tokens: accepted once ---------------------------------------------------------
create or replace function public.auth_captcha_redeem(p_token_hash text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(p_token_hash, '') = '' then return false; end if;
  insert into public.auth_captcha_redemptions (token_hash) values (p_token_hash) on conflict do nothing;
  if not found then return false; end if;
  delete from public.auth_captcha_redemptions where used_at < now() - interval '1 day';
  return true;
end;
$$;

-- 5. Sign-in gate ----------------------------------------------------------------------------
-- Called before every password sign-in. Counts the attempt (a sign-in that then succeeds
-- clears it through auth_sign_in_succeeded). With 15+ attempts in 30 minutes on the e-mail,
-- the IP or the device, it answers captcha_required and records nothing until it is called
-- again with p_captcha_ok = true (the Edge Function verified a captcha token).
create or replace function public.auth_sign_in_attempt(
  p_email_hash text,
  p_ip_hash text,
  p_device_hash text,
  p_captcha_ok boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l jsonb := public._auth_limits();
  v_since timestamptz := now() - make_interval(mins => (l ->> 'sign_in_window_minutes')::int);
  v_after int := (l ->> 'sign_in_captcha_after')::int;
  v_email int := 0;
  v_ip int := 0;
  v_device int := 0;
  v_required boolean;
begin
  if coalesce(p_email_hash, '') = '' then raise exception 'auth_sign_in_attempt: missing e-mail'; end if;
  perform pg_advisory_xact_lock(hashtextextended('melai:auth:signin:' || p_email_hash, 0));

  select count(*) into v_email from public.auth_sign_in_attempts
   where key_type = 'email' and key_hash = p_email_hash and created_at > v_since;
  if p_ip_hash is not null then
    select count(*) into v_ip from public.auth_sign_in_attempts
     where key_type = 'ip' and key_hash = p_ip_hash and created_at > v_since;
  end if;
  if p_device_hash is not null then
    select count(*) into v_device from public.auth_sign_in_attempts
     where key_type = 'device' and key_hash = p_device_hash and created_at > v_since;
  end if;
  v_required := v_email >= v_after or v_ip >= v_after or v_device >= v_after;

  if v_required and not coalesce(p_captcha_ok, false) then
    return jsonb_build_object('allowed', false, 'captcha_required', true);
  end if;

  insert into public.auth_sign_in_attempts (key_type, key_hash)
  select k, h from (values ('email', p_email_hash), ('ip', p_ip_hash), ('device', p_device_hash)) v(k, h)
  where h is not null;
  delete from public.auth_sign_in_attempts where created_at < now() - interval '1 day';
  return jsonb_build_object('allowed', true, 'captcha_required', v_required);
end;
$$;

-- A real sign-in (the Edge Function verified the Firebase ID token): the e-mail's and the
-- device's counters start again. The IP's does not: many accounts share one IP, and
-- clearing it would let one working account hide a password spray from that IP.
create or replace function public.auth_sign_in_succeeded(p_email_hash text, p_device_hash text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.auth_sign_in_attempts
   where (key_type = 'email' and key_hash = p_email_hash)
      or (p_device_hash is not null and key_type = 'device' and key_hash = p_device_hash);
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.auth_email_code_issue(text, text, text, text, text)',
    'public.auth_email_code_discard(text, text)',
    'public.auth_email_code_begin_verify(text)',
    'public.auth_email_code_consume(text, text)',
    'public.auth_captcha_redeem(text)',
    'public.auth_sign_in_attempt(text, text, text, boolean)',
    'public.auth_sign_in_succeeded(text, text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

commit;

notify pgrst, 'reload schema';
