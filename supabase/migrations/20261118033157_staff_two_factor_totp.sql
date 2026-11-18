-- Authenticator-app (TOTP, RFC 6238) two-step sign-in for the staff website.
-- Secrets never leave the database: the table has RLS on and no policies, and only these
-- SECURITY DEFINER functions (acting on the caller's own Firebase uid) can use it.

create table if not exists public.staff_two_factor (
  firebase_uid text primary key references public.staff_members(firebase_uid) on delete cascade,
  secret bytea not null,
  confirmed_at timestamptz,
  recovery_codes text[] not null default '{}',   -- sha256 hex of unused codes
  last_used_counter bigint not null default 0,
  failed_attempts int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.staff_two_factor enable row level security;
revoke all on public.staff_two_factor from anon, authenticated;

create or replace function public._b32_encode(p bytea) returns text
language plpgsql immutable set search_path = public as $$
declare
  alphabet constant text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  bits int := 0; val int := 0; out text := ''; i int;
begin
  for i in 0 .. length(p) - 1 loop
    val := (val << 8) | get_byte(p, i);
    bits := bits + 8;
    while bits >= 5 loop
      out := out || substr(alphabet, ((val >> (bits - 5)) & 31) + 1, 1);
      bits := bits - 5;
    end loop;
    val := val & ((1 << bits) - 1);
  end loop;
  if bits > 0 then out := out || substr(alphabet, ((val << (5 - bits)) & 31) + 1, 1); end if;
  return out;
end $$;

create or replace function public._totp_code(p_secret bytea, p_counter bigint) returns text
language plpgsql immutable set search_path = public, extensions as $$
declare
  msg bytea := decode(lpad(to_hex(p_counter), 16, '0'), 'hex');
  h bytea := extensions.hmac(msg, p_secret, 'sha1');
  o int := get_byte(h, 19) & 15;
  bin bigint := ((get_byte(h, o) & 127)::bigint << 24) | (get_byte(h, o + 1)::bigint << 16)
              | (get_byte(h, o + 2)::bigint << 8) | get_byte(h, o + 3)::bigint;
begin
  return lpad((bin % 1000000)::text, 6, '0');
end $$;

-- Checks a 6-digit code (±1 step, no reuse) or an unused recovery code (used up).
-- Locks for 5 minutes after 5 wrong codes. Returns true/false; never raises for a wrong code.
create or replace function public._staff_2fa_accept(p_uid text, p_code text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare
  r public.staff_two_factor;
  c text := upper(regexp_replace(coalesce(p_code, ''), '[\s-]', '', 'g'));
  now_counter bigint := floor(extract(epoch from clock_timestamp()) / 30)::bigint;
  k bigint; h text;
begin
  select * into r from public.staff_two_factor where firebase_uid = p_uid for update;
  if not found then return false; end if;
  if r.locked_until is not null and r.locked_until > now() then
    raise exception 'Too many wrong codes. Wait a few minutes and try again.';
  end if;
  if c ~ '^[0-9]{6}$' then
    for k in now_counter - 1 .. now_counter + 1 loop
      if k > r.last_used_counter and public._totp_code(r.secret, k) = c then
        update public.staff_two_factor set last_used_counter = k, failed_attempts = 0, locked_until = null, updated_at = now()
         where firebase_uid = p_uid;
        return true;
      end if;
    end loop;
  elsif r.confirmed_at is not null and length(c) between 8 and 16 then
    h := encode(extensions.digest(c, 'sha256'), 'hex');
    if h = any(r.recovery_codes) then
      update public.staff_two_factor set recovery_codes = array_remove(recovery_codes, h), failed_attempts = 0, locked_until = null, updated_at = now()
       where firebase_uid = p_uid;
      perform public._write_audit(p_uid, null, 'auth.two_factor_recovery_used', 'staff', p_uid,
        jsonb_build_object('remaining', coalesce(array_length(r.recovery_codes, 1), 1) - 1, 'via', 'web'));
      return true;
    end if;
  end if;
  update public.staff_two_factor
     set failed_attempts = failed_attempts + 1,
         locked_until = case when failed_attempts + 1 >= 5 then now() + interval '5 minutes' else locked_until end,
         updated_at = now()
   where firebase_uid = p_uid;
  return false;
end $$;

create or replace function public.staff_2fa_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_staff public.staff_members; r public.staff_two_factor;
begin
  v_staff := public._require_staff();
  select * into r from public.staff_two_factor where firebase_uid = v_staff.firebase_uid;
  return jsonb_build_object(
    'enabled', found and r.confirmed_at is not null,
    'pending', found and r.confirmed_at is null,
    'recovery_remaining', case when found then coalesce(array_length(r.recovery_codes, 1), 0) else 0 end);
end $$;

create or replace function public.staff_2fa_begin() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_staff public.staff_members; v_secret bytea := extensions.gen_random_bytes(20); b32 text;
begin
  v_staff := public._require_staff();
  if exists (select 1 from public.staff_two_factor where firebase_uid = v_staff.firebase_uid and confirmed_at is not null) then
    raise exception 'Two-step sign-in is already on. Turn it off first to set up a new authenticator.';
  end if;
  insert into public.staff_two_factor (firebase_uid, secret) values (v_staff.firebase_uid, v_secret)
  on conflict (firebase_uid) do update set secret = excluded.secret, confirmed_at = null, recovery_codes = '{}',
    last_used_counter = 0, failed_attempts = 0, locked_until = null, updated_at = now();
  b32 := public._b32_encode(v_secret);
  return jsonb_build_object('secret', b32,
    'otpauth_uri', 'otpauth://totp/' || replace('Melai Nuts Admin:' || coalesce(v_staff.email, v_staff.firebase_uid), ' ', '%20')
      || '?secret=' || b32 || '&issuer=Melai%20Nuts%20Admin&algorithm=SHA1&digits=6&period=30');
end $$;

create or replace function public.staff_2fa_confirm(p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_staff public.staff_members; plain text[] := '{}'; hashed text[] := '{}'; c text; i int;
begin
  v_staff := public._require_staff();
  if not exists (select 1 from public.staff_two_factor where firebase_uid = v_staff.firebase_uid and confirmed_at is null) then
    raise exception 'Start the setup first.';
  end if;
  if not public._staff_2fa_accept(v_staff.firebase_uid, p_code) then
    raise exception 'That code is not right. Check the time on your phone and try the newest code.';
  end if;
  for i in 1 .. 8 loop
    c := upper(substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 10));
    plain := plain || c;
    hashed := hashed || encode(extensions.digest(c, 'sha256'), 'hex');
  end loop;
  update public.staff_two_factor set confirmed_at = now(), recovery_codes = hashed, updated_at = now()
   where firebase_uid = v_staff.firebase_uid;
  perform public._write_audit(v_staff.firebase_uid, v_staff.branch_id, 'auth.two_factor_enabled', 'staff', v_staff.firebase_uid, '{"via":"web"}');
  return jsonb_build_object('recovery_codes', to_jsonb(plain));
end $$;

create or replace function public.staff_2fa_verify(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff public.staff_members;
begin
  v_staff := public._require_staff();
  if not exists (select 1 from public.staff_two_factor where firebase_uid = v_staff.firebase_uid and confirmed_at is not null) then
    return jsonb_build_object('ok', true, 'enabled', false);
  end if;
  if not public._staff_2fa_accept(v_staff.firebase_uid, p_code) then
    raise exception 'That code is not right. Try the newest code, or a recovery code.';
  end if;
  return jsonb_build_object('ok', true, 'enabled', true);
end $$;

create or replace function public.staff_2fa_disable(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare v_staff public.staff_members;
begin
  v_staff := public._require_staff();
  if not exists (select 1 from public.staff_two_factor where firebase_uid = v_staff.firebase_uid) then return; end if;
  if exists (select 1 from public.staff_two_factor where firebase_uid = v_staff.firebase_uid and confirmed_at is not null)
     and not public._staff_2fa_accept(v_staff.firebase_uid, p_code) then
    raise exception 'Enter a current code from your authenticator (or a recovery code).';
  end if;
  delete from public.staff_two_factor where firebase_uid = v_staff.firebase_uid;
  perform public._write_audit(v_staff.firebase_uid, v_staff.branch_id, 'auth.two_factor_disabled', 'staff', v_staff.firebase_uid, '{"via":"web"}');
end $$;

revoke all on function public._b32_encode(bytea), public._totp_code(bytea, bigint), public._staff_2fa_accept(text, text) from public, anon, authenticated;
revoke all on function public.staff_2fa_status(), public.staff_2fa_begin(), public.staff_2fa_confirm(text), public.staff_2fa_verify(text), public.staff_2fa_disable(text) from public, anon;
grant execute on function public.staff_2fa_status(), public.staff_2fa_begin(), public.staff_2fa_confirm(text), public.staff_2fa_verify(text), public.staff_2fa_disable(text) to authenticated;
