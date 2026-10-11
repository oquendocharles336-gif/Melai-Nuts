-- =============================================================================
-- Melai Nuts — Migration 20261025010000: more rate limits (refunds, addresses, cards)
-- =============================================================================
-- Run after 20261025001000_phone_lookup_normalized.sql. Idempotent, one transaction.
--
-- 20261019000000_rate_limits.sql limits voucher guessing and order bursts. This adds the
-- other customer actions that write to the database and could be abused by a modified
-- client using the public key and a real Firebase sign-in:
--   * refund requests      at most 3 per account per 30 minutes
--   * saved addresses      at most 20 new addresses per account per hour
-- Same scope as before: only requests through the Data API (the app) are limited;
-- SQL run by the owner / admin portal is not. Tests force the limits on with
--   select set_config('melai.force_rate_limits', 'on', true);
--
-- WHAT IS LIMITED ELSEWHERE (not in Postgres)
--   sign-in attempts, password-reset e-mails, SMS codes, registration: Firebase Auth's
--   own server-side throttling (too-many-requests) + App Check, plus the app's
--   on-device brakes (AuthService._FailureBrake, 60 s resend cooldowns). The 6-digit
--   e-mail code API must rate-limit send/verify itself (SECURITY.md, "Your API MUST").
--   The admin website limits every POST/PUT/DELETE (App\Http\Middleware\ThrottleWrites)
--   and locks a login after 5 failures (LoginRequest).
-- =============================================================================
begin;

create or replace function public._rate_limits()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'voucher_max', 10, 'voucher_window_minutes', 15, 'voucher_valid_hours', 24,
    'order_max', 5, 'order_window_minutes', 10,
    'refund_max', 3, 'refund_window_minutes', 30,
    'address_max', 20, 'address_window_minutes', 60)
$$;

-- Generic per-account counter on a table's own rows: raises when the caller already
-- created p_max rows in the last p_minutes.
create or replace function public._rate_limit_rows(
  p_kind text, p_count int, p_max int, p_minutes int, p_message text)
returns void
language plpgsql
as $$
begin
  if p_count >= p_max then
    raise exception '%', p_message using errcode = 'P0001', hint = 'rate_limited:' || p_kind;
  end if;
end;
$$;

create or replace function public._trg_refund_requests_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_lim jsonb := public._rate_limits();
  v_recent int;
begin
  if not public._rate_limit_applies() or v_uid is null or new.firebase_uid is distinct from v_uid then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtext('melai:rl:refund:' || v_uid));
  select count(*) into v_recent from public.refund_requests
   where firebase_uid = v_uid
     and created_at > now() - make_interval(mins => (v_lim ->> 'refund_window_minutes')::int);
  perform public._rate_limit_rows('refund', v_recent, (v_lim ->> 'refund_max')::int,
    (v_lim ->> 'refund_window_minutes')::int,
    'Too many refund requests in a short time. Please wait 30 minutes and try again.');
  return new;
end;
$$;
revoke all on function public._trg_refund_requests_rate_limit() from public, anon, authenticated;
drop trigger if exists refund_requests_rate_limit on public.refund_requests;
create trigger refund_requests_rate_limit before insert on public.refund_requests
  for each row execute function public._trg_refund_requests_rate_limit();

create or replace function public._trg_customer_addresses_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_lim jsonb := public._rate_limits();
  v_recent int;
begin
  if not public._rate_limit_applies() or v_uid is null or new.firebase_uid is distinct from v_uid then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtext('melai:rl:address:' || v_uid));
  select count(*) into v_recent from public.customer_addresses
   where firebase_uid = v_uid
     and created_at > now() - make_interval(mins => (v_lim ->> 'address_window_minutes')::int);
  perform public._rate_limit_rows('address', v_recent, (v_lim ->> 'address_max')::int,
    (v_lim ->> 'address_window_minutes')::int,
    'Too many new addresses in a short time. Please try again later.');
  return new;
end;
$$;
revoke all on function public._trg_customer_addresses_rate_limit() from public, anon, authenticated;
drop trigger if exists customer_addresses_rate_limit on public.customer_addresses;
create trigger customer_addresses_rate_limit before insert on public.customer_addresses
  for each row execute function public._trg_customer_addresses_rate_limit();

commit;
