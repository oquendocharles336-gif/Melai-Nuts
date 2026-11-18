-- =============================================================================
-- Melai Nuts — Migration 20261118050000: account e-mails without Firebase
-- =============================================================================
-- Run after 20261118040000_verified_phone_first_order.sql. Idempotent, one transaction.
--
-- Backing store for the Edge Function supabase/functions/account-email, which now sends
-- the password-reset, e-mail-change and security-notice e-mails itself (through
-- _shared/mailer.ts) instead of Firebase. Identity stays in Firebase (the function changes
-- the password / e-mail with the Firebase Admin credentials, server-side only).
--
-- 1. auth_action_tokens: the single-use links in those e-mails. Only an HMAC of each token
--    is stored (the function's AUTH_CODE_PEPPER), never the token. Each has a kind, an
--    expiry and used_at. A password reset makes every other open reset link of the account
--    unusable; confirming or cancelling an e-mail change closes both of its links.
-- 2. auth_action_sends: every request (also for an e-mail with no account, so the answer
--    and the timing never tell whether an address exists), as HMACs of the e-mail and IP,
--    for the per-e-mail cooldown and the hourly limits per e-mail and per IP.
--
-- SECURITY. RLS on, no policies, no privileges for anon / authenticated: only the service
-- role (the Edge Function) can use these tables and functions.
-- =============================================================================
begin;

create table if not exists public.auth_action_tokens (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null,
  kind text not null check (kind in ('password_reset', 'email_change', 'email_change_cancel')),
  firebase_uid text not null,
  email text not null,
  new_email text,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);
create index if not exists auth_action_tokens_uid_idx on public.auth_action_tokens (firebase_uid, kind) where used_at is null;
create index if not exists auth_action_tokens_request_idx on public.auth_action_tokens (request_id);

create table if not exists public.auth_action_sends (
  id bigserial primary key,
  kind text not null,
  email_hash text not null,
  ip_hash text,
  created_at timestamptz not null default now()
);
create index if not exists auth_action_sends_email_idx on public.auth_action_sends (email_hash, kind, created_at desc);
create index if not exists auth_action_sends_ip_idx on public.auth_action_sends (ip_hash, created_at desc) where ip_hash is not null;

do $$
declare t text;
begin
  foreach t in array array['auth_action_tokens', 'auth_action_sends'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end $$;
revoke all on sequence public.auth_action_sends_id_seq from public, anon, authenticated;
grant usage on sequence public.auth_action_sends_id_seq to service_role;

-- Limits, in one place.
create or replace function public._auth_action_limits()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'password_reset_ttl_seconds', 1800,   -- 30 minutes
    'email_change_ttl_seconds', 3600,     -- 1 hour
    'cooldown_seconds', 60,               -- per e-mail and kind
    'per_hour_email', 5,
    'per_hour_ip', 20)
$$;
revoke all on function public._auth_action_limits() from public, anon, authenticated;
grant execute on function public._auth_action_limits() to service_role;

-- Counts one request against the limits and, when allowed and p_uid is set, stores its
-- tokens (p_tokens: [{"kind": "...", "hash": "..."}], all with one request id).
-- p_uid null = an address with no account (or a notice): only counted, nothing stored.
-- Answer: {ok: true, request_id} or {ok: false, reason: cooldown|hourly_limit, retry_after}.
create or replace function public.auth_action_issue(
  p_kind text,
  p_uid text,
  p_email text,
  p_new_email text,
  p_email_hash text,
  p_ip_hash text,
  p_tokens jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l jsonb := public._auth_action_limits();
  v_ttl int;
  v_last timestamptz;
  v_count int;
  v_oldest timestamptz;
  v_request uuid := gen_random_uuid();
  t jsonb;
begin
  if coalesce(p_kind, '') = '' or coalesce(p_email_hash, '') = '' then
    raise exception 'auth_action_issue: missing argument';
  end if;
  -- Serialise requests for the same address (cooldown race).
  perform pg_advisory_xact_lock(hashtext('auth_action:' || p_email_hash));

  select max(created_at) into v_last from public.auth_action_sends
   where email_hash = p_email_hash and kind = p_kind;
  if v_last is not null and v_last > now() - make_interval(secs => (l->>'cooldown_seconds')::int) then
    return jsonb_build_object('ok', false, 'reason', 'cooldown',
      'retry_after', greatest(1, ceil(extract(epoch from (v_last + make_interval(secs => (l->>'cooldown_seconds')::int) - now())))::int));
  end if;

  select count(*), min(created_at) into v_count, v_oldest from public.auth_action_sends
   where email_hash = p_email_hash and created_at > now() - interval '1 hour';
  if v_count >= (l->>'per_hour_email')::int then
    return jsonb_build_object('ok', false, 'reason', 'hourly_limit',
      'retry_after', greatest(1, ceil(extract(epoch from (v_oldest + interval '1 hour' - now())))::int));
  end if;
  if p_ip_hash is not null then
    select count(*), min(created_at) into v_count, v_oldest from public.auth_action_sends
     where ip_hash = p_ip_hash and created_at > now() - interval '1 hour';
    if v_count >= (l->>'per_hour_ip')::int then
      return jsonb_build_object('ok', false, 'reason', 'hourly_limit',
        'retry_after', greatest(1, ceil(extract(epoch from (v_oldest + interval '1 hour' - now())))::int));
    end if;
  end if;

  insert into public.auth_action_sends (kind, email_hash, ip_hash) values (p_kind, p_email_hash, p_ip_hash);

  if p_uid is not null and jsonb_typeof(p_tokens) = 'array' then
    v_ttl := case when p_kind = 'password_reset' then (l->>'password_reset_ttl_seconds')::int
                  else (l->>'email_change_ttl_seconds')::int end;
    -- One open request per account and kind: a new e-mail makes the older links unusable.
    if p_kind = 'email_change' then
      update public.auth_action_tokens set used_at = now()
       where firebase_uid = p_uid and kind in ('email_change', 'email_change_cancel') and used_at is null;
    else
      update public.auth_action_tokens set used_at = now()
       where firebase_uid = p_uid and kind = p_kind and used_at is null;
    end if;
    for t in select * from jsonb_array_elements(p_tokens) loop
      insert into public.auth_action_tokens (request_id, kind, firebase_uid, email, new_email, token_hash, expires_at)
      values (v_request, t->>'kind', p_uid, p_email, p_new_email, t->>'hash', now() + make_interval(secs => v_ttl));
    end loop;
  end if;

  -- Housekeeping.
  delete from public.auth_action_sends where created_at < now() - interval '1 day';
  delete from public.auth_action_tokens where created_at < now() - interval '7 days';

  return jsonb_build_object('ok', true, 'request_id', v_request);
end;
$$;

-- Looks a token up WITHOUT using it (the page that asks for the new password).
-- {status: ok|used|expired|invalid, email, new_email} — uid only for status ok.
create or replace function public.auth_action_peek(p_kind text, p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r public.auth_action_tokens;
begin
  select * into r from public.auth_action_tokens where token_hash = p_token_hash and kind = p_kind;
  if not found then return jsonb_build_object('status', 'invalid'); end if;
  if r.used_at is not null then return jsonb_build_object('status', 'used'); end if;
  if r.expires_at <= now() then return jsonb_build_object('status', 'expired'); end if;
  return jsonb_build_object('status', 'ok', 'uid', r.firebase_uid, 'email', r.email, 'new_email', r.new_email);
end;
$$;

-- Uses a token, once (concurrent calls: exactly one gets status ok). Also closes the
-- account's other open links of the same request / kind (see the header).
create or replace function public.auth_action_consume(p_kind text, p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r public.auth_action_tokens;
begin
  update public.auth_action_tokens set used_at = now()
   where token_hash = p_token_hash and kind = p_kind and used_at is null and expires_at > now()
  returning * into r;
  if not found then
    return public.auth_action_peek(p_kind, p_token_hash);   -- used / expired / invalid
  end if;
  if r.kind = 'password_reset' then
    update public.auth_action_tokens set used_at = now()
     where firebase_uid = r.firebase_uid and kind = 'password_reset' and used_at is null;
  else
    update public.auth_action_tokens set used_at = now()
     where request_id = r.request_id and used_at is null;
  end if;
  return jsonb_build_object('status', 'ok', 'uid', r.firebase_uid, 'email', r.email, 'new_email', r.new_email);
end;
$$;

-- After an e-mail change: the app's own copies of the address follow Firebase.
create or replace function public.auth_action_apply_email(p_uid text, p_new_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.customer_profiles set email = p_new_email where firebase_uid = p_uid;
  update public.staff_members set email = p_new_email where firebase_uid = p_uid;
end;
$$;

-- The "second sign-in step was added" notice may be asked for with the person's own Firebase
-- token only right after staff_2fa_confirm (20261118033157) turned two-step sign-in on.
-- Returns the staff e-mail, or null when nothing was confirmed in the last 10 minutes.
create or replace function public.auth_action_mfa_recent(p_uid text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select sm.email
    from public.staff_two_factor t
    join public.staff_members sm on sm.firebase_uid = t.firebase_uid
   where t.firebase_uid = p_uid
     and t.confirmed_at > now() - interval '10 minutes'
$$;
revoke all on function public.auth_action_mfa_recent(text) from public, anon, authenticated;
grant execute on function public.auth_action_mfa_recent(text) to service_role;

revoke all on function public.auth_action_issue(text, text, text, text, text, text, jsonb),
  public.auth_action_peek(text, text), public.auth_action_consume(text, text),
  public.auth_action_apply_email(text, text) from public, anon, authenticated;
grant execute on function public.auth_action_issue(text, text, text, text, text, text, jsonb),
  public.auth_action_peek(text, text), public.auth_action_consume(text, text),
  public.auth_action_apply_email(text, text) to service_role;

commit;
