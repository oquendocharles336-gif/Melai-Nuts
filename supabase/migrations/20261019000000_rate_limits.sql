-- =============================================================================
-- Melai Nuts — Migration 20261019000000: rate limits for voucher codes and orders
-- =============================================================================
-- Run after 20261018000000_business_settings.sql. Idempotent, one transaction.
--
-- WHY
--   A modified client (or a script using the public anon key + a Firebase token)
--   could try voucher codes in a loop, or create orders in a burst. Firebase
--   App Check (see docs/APP_CHECK.md) makes such clients harder to build; these
--   limits are enforced by the database whatever the client is.
--
-- WHAT
--   * Voucher codes: a code must be "registered" by public.register_voucher_attempt()
--     before a cart may use it (a carts trigger checks that). Registering is limited
--     to 10 codes per account per 15 minutes. The registration is committed on its
--     own, so failed guesses count too (a failed cart sync rolls back, a registration
--     does not). A registration stays valid for 24 hours.
--   * Orders: at most 5 new customer orders per account per 10 minutes. Replaying an
--     idempotency key returns the existing order and is not counted; POS sales are
--     not affected.
--   The numbers are technical security limits (not business data), kept in one
--   function, public._rate_limits().
--
-- SCOPE
--   The limits apply to requests coming through the Data API (session user
--   `authenticator`, i.e. the app and anything using its keys). SQL run by the
--   database owner (repairs, the admin portal's own role) is not limited. Tests can
--   force them on with:  select set_config('melai.force_rate_limits', 'on', true);
--   (turning them ON is the only thing that setting can do).
-- =============================================================================
begin;

create table if not exists public.rate_limit_events (
  id bigserial primary key,
  firebase_uid text not null,
  action text not null check (action in ('voucher')),
  subject text,
  created_at timestamptz not null default now()
);
create index if not exists rate_limit_events_lookup_idx
  on public.rate_limit_events (firebase_uid, action, created_at desc);
alter table public.rate_limit_events enable row level security;
revoke all on public.rate_limit_events from anon, authenticated;
revoke all on sequence public.rate_limit_events_id_seq from anon, authenticated;

create or replace function public._rate_limits()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'voucher_max', 10, 'voucher_window_minutes', 15, 'voucher_valid_hours', 24,
    'order_max', 5, 'order_window_minutes', 10)
$$;

create or replace function public._rate_limit_applies()
returns boolean
language sql
stable
as $$
  select session_user = 'authenticator'
      or coalesce(current_setting('melai.force_rate_limits', true), '') = 'on'
$$;

-- -----------------------------------------------------------------------------
-- Voucher codes
-- -----------------------------------------------------------------------------
create or replace function public.register_voucher_attempt(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_code text := nullif(upper(trim(coalesce(p_code, ''))), '');
  v_lim jsonb := public._rate_limits();
  v_max int := (v_lim ->> 'voucher_max')::int;
  v_window int := (v_lim ->> 'voucher_window_minutes')::int;
  v_used int;
begin
  if v_uid is null then raise exception 'Please sign in to use a voucher.'; end if;
  if v_code is null or length(v_code) > 64 then raise exception 'Enter a voucher code.'; end if;

  -- One account's attempts are counted one at a time (no race past the limit).
  perform pg_advisory_xact_lock(hashtext('melai:rl:voucher:' || v_uid));
  select count(*) into v_used from public.rate_limit_events
   where firebase_uid = v_uid and action = 'voucher'
     and created_at > now() - make_interval(mins => v_window);
  if public._rate_limit_applies() and v_used >= v_max then
    raise exception 'Too many voucher attempts. Please wait % minutes and try again.', v_window;
  end if;

  insert into public.rate_limit_events (firebase_uid, action, subject) values (v_uid, 'voucher', v_code);
  delete from public.rate_limit_events where firebase_uid = v_uid and created_at < now() - interval '2 days';
  return jsonb_build_object('ok', true, 'remaining', greatest(v_max - v_used - 1, 0));
end;
$$;
revoke all on function public.register_voucher_attempt(text) from public, anon;
grant execute on function public.register_voucher_attempt(text) to authenticated;

create or replace function public._trg_carts_voucher_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_code text := nullif(upper(trim(coalesce(new.voucher_code, ''))), '');
  v_valid int := (public._rate_limits() ->> 'voucher_valid_hours')::int;
begin
  if v_code is null or v_uid is null or not public._rate_limit_applies() then return new; end if;
  if tg_op = 'UPDATE' and v_code is not distinct from nullif(upper(trim(coalesce(old.voucher_code, ''))), '') then
    return new;   -- the same code as before (every cart sync re-sends it)
  end if;
  if not exists (
    select 1 from public.rate_limit_events
     where firebase_uid = v_uid and action = 'voucher' and subject = v_code
       and created_at > now() - make_interval(hours => v_valid)) then
    raise exception 'Please enter the voucher code again.';
  end if;
  return new;
end;
$$;
revoke all on function public._trg_carts_voucher_rate_limit() from public, anon, authenticated;

drop trigger if exists carts_voucher_rate_limit on public.carts;
create trigger carts_voucher_rate_limit
  before insert or update of voucher_code on public.carts
  for each row execute function public._trg_carts_voucher_rate_limit();

-- -----------------------------------------------------------------------------
-- Orders
-- -----------------------------------------------------------------------------
create or replace function public._trg_orders_rate_limit()
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
  if not public._rate_limit_applies() then return new; end if;
  if coalesce(current_setting('app.pos_sale', true), '') = '1' then return new; end if;   -- POS sale
  if v_uid is null or new.firebase_uid is distinct from v_uid then return new; end if;

  perform pg_advisory_xact_lock(hashtext('melai:rl:order:' || v_uid));
  select count(*) into v_recent from public.orders
   where firebase_uid = v_uid
     and created_at > now() - make_interval(mins => (v_lim ->> 'order_window_minutes')::int);
  if v_recent >= (v_lim ->> 'order_max')::int then
    raise exception 'Too many orders in a short time. Please wait a few minutes and try again.';
  end if;
  return new;
end;
$$;
revoke all on function public._trg_orders_rate_limit() from public, anon, authenticated;

drop trigger if exists orders_rate_limit on public.orders;
create trigger orders_rate_limit
  before insert on public.orders
  for each row execute function public._trg_orders_rate_limit();

commit;
