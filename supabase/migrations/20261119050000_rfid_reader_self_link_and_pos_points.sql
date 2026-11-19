-- =============================================================================
-- Melai Nuts — Migration 20261119050000: Wi-Fi card readers (ESP32 + RC522),
-- customer self-link, card self-service, optional loyalty PIN, and points
-- redemption at the POS.
-- =============================================================================
-- Run after 20261119040000_admin_product_reviews.sql. Idempotent, one transaction.
-- Builds on 20261011000000_loyalty_cards.sql (card registry, hash, label,
-- events) — no table from it is changed, no status is added.
--
-- 1. READERS (rfid_devices). Each ESP32 reader has a device code and a secret key.
--    Only SHA-256('melai-device:' || key) is stored. The reader talks to the
--    rfid-device-tap Edge Function, never to the database: the Edge Function
--    holds the service-role key, the reader holds only its own key.
--    Readers are created / rotated / switched off from the SQL editor
--    (rfid_register_device, rfid_rotate_device_key, rfid_set_device_active).
--
-- 2. SELF-LINK (rfid_pairing_sessions). The customer picks a reader in the app
--    and presses "Link my card": a 60-second session for that reader, one at a
--    time per reader. The next card tapped on that reader is linked to the
--    customer (same rules as staff linking: one active card per customer, a card
--    belongs to one account, blocked / retired cards are refused). The app sees
--    the outcome over realtime. Tapping a linked card again only syncs.
--
-- 3. TAP LOG (rfid_device_taps). Every request a reader makes — accepted, refused,
--    rate-limited, wrong key — is logged (append-only). A customer can read only
--    the result rows of their own card (used to refresh points live).
--    Limits: 30 taps per reader per minute; 20 wrong-key requests per device
--    code per 10 minutes blocks that code for the rest of the window.
--
-- 4. CARD SELF-SERVICE. customer_block_my_card (lost / stolen: stops at once,
--    owner can unblock) and customer_remove_my_card (retired for good). Points
--    stay on the account either way.
--
-- 5. LOYALTY PIN (optional, 4–6 digits). When a customer sets one, points can
--    only be REDEEMED at the counter with that PIN (5 wrong tries = 15 min lock).
--    Earning never needs it.
--
-- 6. POS POINTS. staff_create_pos_sale gains p_redeem_points, p_loyalty_pin and
--    p_customer_confirmed. Redeeming uses the SAME rule as an app order
--    (_loyalty_redeem_quote: points_per_peso, max_discount_percent, the
--    balance — the formula of _place_order_api), in the same transaction that
--    creates the order, with the loyalty account row locked; the balance can
--    never go below zero (check constraint). Earning is unchanged
--    (compute_points_earned + award_points_on_completion on the final total).
--    staff_pos_quote shows the server's totals before payment.
--    The ledger rows of a POS sale record the staff member and branch
--    (loyalty_transactions.staff_uid / branch_id, set by a trigger from the sale).
--    One redemption per order (unique index), on top of the idempotency key.
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1. Readers
-- -----------------------------------------------------------------------------
create table if not exists public.rfid_devices (
  id uuid primary key default gen_random_uuid(),
  device_code text not null unique check (device_code ~ '^MN-RDR-[0-9A-F]{8}$'),
  name text not null check (char_length(name) between 2 and 60),
  branch_id uuid references public.branches(id) on delete set null,
  key_hash text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  key_rotated_at timestamptz not null default now(),
  last_seen_at timestamptz,
  last_ip text
);
alter table public.rfid_devices enable row level security;
revoke all on public.rfid_devices from anon, authenticated;

create or replace function public._device_key_hash(p_key text)
returns text
language sql
immutable
as $$
  select encode(sha256(convert_to('melai-device:' || coalesce(p_key, ''), 'UTF8')), 'hex')
$$;

-- 64 hex characters from two random UUIDs (gen_random_uuid is built in).
create or replace function public._new_device_key()
returns text
language sql
volatile
as $$
  select upper(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
$$;

-- SQL editor only (database owner). Returns the key ONCE; store it in the sketch.
create or replace function public.rfid_register_device(p_name text, p_branch_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := public._new_device_key();
  v_code text;
  d public.rfid_devices;
begin
  if p_branch_id is not null and not exists (select 1 from public.branches where id = p_branch_id) then
    raise exception 'That branch could not be found.';
  end if;
  loop
    v_code := 'MN-RDR-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.rfid_devices where device_code = v_code);
  end loop;
  insert into public.rfid_devices (device_code, name, branch_id, key_hash)
  values (v_code, trim(p_name), p_branch_id, public._device_key_hash(v_key))
  returning * into d;
  return jsonb_build_object('device_code', d.device_code, 'device_key', v_key, 'name', d.name,
                            'note', 'Copy the key now. It is not stored and cannot be shown again.');
end;
$$;

create or replace function public.rfid_rotate_device_key(p_device_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := public._new_device_key();
begin
  update public.rfid_devices set key_hash = public._device_key_hash(v_key), key_rotated_at = now()
   where device_code = upper(trim(p_device_code));
  if not found then raise exception 'No reader with that device code.'; end if;
  return jsonb_build_object('device_code', upper(trim(p_device_code)), 'device_key', v_key,
                            'note', 'The old key stops working now. Update the sketch.');
end;
$$;

create or replace function public.rfid_set_device_active(p_device_code text, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.rfid_devices set is_active = coalesce(p_active, false)
   where device_code = upper(trim(p_device_code));
  if not found then raise exception 'No reader with that device code.'; end if;
  return jsonb_build_object('device_code', upper(trim(p_device_code)), 'is_active', coalesce(p_active, false));
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Pairing sessions (the customer's "Link my card")
-- -----------------------------------------------------------------------------
create table if not exists public.rfid_pairing_sessions (
  id uuid primary key default gen_random_uuid(),
  firebase_uid text not null references public.customer_profiles(firebase_uid) on delete cascade,
  device_id uuid not null references public.rfid_devices(id) on delete cascade,
  status text not null default 'waiting'
    check (status in ('waiting', 'linked', 'already_linked', 'failed', 'expired', 'cancelled')),
  result_code text,
  message text,
  card_label text,
  points_balance int,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists rfid_pairing_sessions_customer_idx
  on public.rfid_pairing_sessions (firebase_uid, created_at desc);
-- One open session per reader (stale ones are closed before a new one starts).
create unique index if not exists rfid_pairing_sessions_one_waiting_per_device
  on public.rfid_pairing_sessions (device_id) where (status = 'waiting');

alter table public.rfid_pairing_sessions enable row level security;
revoke all on public.rfid_pairing_sessions from anon, authenticated;
grant select on public.rfid_pairing_sessions to authenticated;
drop policy if exists "customer: read own pairing sessions" on public.rfid_pairing_sessions;
create policy "customer: read own pairing sessions" on public.rfid_pairing_sessions
  for select to authenticated using (firebase_uid = public.current_firebase_uid());

-- -----------------------------------------------------------------------------
-- 3. Tap log (audit of every reader request)
-- -----------------------------------------------------------------------------
create table if not exists public.rfid_device_taps (
  id bigserial primary key,
  -- No foreign keys: the log is append-only and must not block deleting a reader
  -- or an account.
  device_id uuid,
  device_code text,
  card_uid_hash text,
  firebase_uid text,
  result text not null check (result in (
    'linked', 'already_linked', 'synced', 'unregistered', 'card_taken', 'card_blocked',
    'customer_has_card', 'invalid_card', 'device_rejected', 'rate_limited')),
  points_balance int,
  ip text,
  created_at timestamptz not null default now()
);
create index if not exists rfid_device_taps_device_idx on public.rfid_device_taps (device_id, created_at desc);
create index if not exists rfid_device_taps_code_idx on public.rfid_device_taps (device_code, result, created_at desc);
create index if not exists rfid_device_taps_customer_idx on public.rfid_device_taps (firebase_uid, created_at desc)
  where (firebase_uid is not null);

alter table public.rfid_device_taps enable row level security;
revoke all on public.rfid_device_taps from anon, authenticated;
revoke all on sequence public.rfid_device_taps_id_seq from anon, authenticated;
-- The customer sees the outcome of their own card's taps, not the reader or card hash.
grant select (id, firebase_uid, result, points_balance, created_at) on public.rfid_device_taps to authenticated;
drop policy if exists "customer: read own card taps" on public.rfid_device_taps;
create policy "customer: read own card taps" on public.rfid_device_taps
  for select to authenticated using (firebase_uid = public.current_firebase_uid());

create or replace function public._trg_rfid_device_taps_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'The card reader log cannot be changed or deleted.';
end;
$$;
drop trigger if exists rfid_device_taps_append_only on public.rfid_device_taps;
create trigger rfid_device_taps_append_only
  before update or delete on public.rfid_device_taps
  for each row execute function public._trg_rfid_device_taps_append_only();

-- Realtime: the app watches its own pairing session and card taps (RLS applies).
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['rfid_pairing_sessions', 'rfid_device_taps'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 4. Linking a card to a customer from a reader (shared by the tap function)
-- -----------------------------------------------------------------------------
-- Returns the new card. The caller holds the card-hash and card-owner locks.
create or replace function public._self_link_card(p_hash text, p_uid text, p_device public.rfid_devices)
returns public.loyalty_cards
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.loyalty_cards;
  v_old public.loyalty_cards;
begin
  insert into public.loyalty_cards (card_uid_hash, card_label, firebase_uid, issued_branch_id, issued_by)
  values (p_hash, public._card_label(p_hash), p_uid, p_device.branch_id, 'reader:' || p_device.device_code)
  returning * into c;
  insert into public.loyalty_card_events (card_id, event, branch_id, note)
  values (c.id, 'registered', p_device.branch_id, 'Linked by the customer at reader ' || p_device.name);

  -- A blocked card the customer still had is retired and points to the new one.
  select * into v_old from public.loyalty_cards
   where firebase_uid = p_uid and status = 'blocked' and id <> c.id
   order by blocked_at desc nulls last, issued_at desc limit 1 for update;
  if v_old.id is not null then
    update public.loyalty_cards set status = 'replaced', replaced_by = c.id, updated_at = now() where id = v_old.id;
    insert into public.loyalty_card_events (card_id, event, branch_id, note)
    values (v_old.id, 'replaced', p_device.branch_id, 'Replaced by ' || c.card_label || ' (linked by the customer)');
  end if;

  perform public._sync_profile_card_label(p_uid);
  perform public.notify_customer(p_uid, 'loyalty', 'Loyalty card linked',
    'Your Golden Kernel Club card ' || c.card_label || ' is now linked to your account.');
  return c;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. The reader's request (called ONLY by the rfid-device-tap Edge Function,
--    with the service-role key). p_key_hash = SHA-256('melai-device:' || key),
--    computed by the Edge Function so the plain key never reaches the database.
--    Answers {result, message, points_balance, card_label}; never a name.
-- -----------------------------------------------------------------------------
create or replace function public.rfid_device_tap(
  p_device_code text,
  p_key_hash text,
  p_card_uid text,
  p_ip text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(trim(coalesce(p_device_code, '')));
  v_ip text := left(nullif(trim(coalesce(p_ip, '')), ''), 64);
  d public.rfid_devices;
  v_norm text := public._normalize_card_uid(p_card_uid);
  v_hash text;
  c public.loyalty_cards;
  s public.rfid_pairing_sessions;
  v_result text;
  v_message text;
  v_uid text;
  v_points int;
  v_label text;
  v_recent int;
begin
  if v_code !~ '^MN-RDR-[0-9A-F]{8}$' then
    return jsonb_build_object('result', 'device_rejected', 'message', 'Unknown reader.');
  end if;

  -- Requests of one device code are handled one at a time (limits cannot be raced).
  perform pg_advisory_xact_lock(hashtextextended('rfid-device:' || v_code, 0));

  select count(*) into v_recent from public.rfid_device_taps
   where device_code = v_code and result = 'device_rejected' and created_at > now() - interval '10 minutes';
  if v_recent >= 20 then
    return jsonb_build_object('result', 'rate_limited', 'message', 'Too many wrong keys. Wait 10 minutes.');
  end if;

  select * into d from public.rfid_devices where device_code = v_code;
  if d.id is null or not d.is_active or d.key_hash <> lower(coalesce(p_key_hash, '')) then
    insert into public.rfid_device_taps (device_id, device_code, result, ip)
    values (d.id, v_code, 'device_rejected', v_ip);
    return jsonb_build_object('result', 'device_rejected',
      'message', case when d.id is not null and not d.is_active then 'This reader is switched off.'
                      else 'Wrong device code or key.' end);
  end if;

  update public.rfid_devices set last_seen_at = now(), last_ip = coalesce(v_ip, last_ip) where id = d.id;

  select count(*) into v_recent from public.rfid_device_taps
   where device_id = d.id and created_at > now() - interval '1 minute';
  if v_recent >= 30 then
    insert into public.rfid_device_taps (device_id, device_code, result, ip) values (d.id, v_code, 'rate_limited', v_ip);
    return jsonb_build_object('result', 'rate_limited', 'message', 'Too many taps. Wait a minute.');
  end if;

  if v_norm is null then
    insert into public.rfid_device_taps (device_id, device_code, result, ip) values (d.id, v_code, 'invalid_card', v_ip);
    return jsonb_build_object('result', 'invalid_card', 'message', 'Card UID not readable. Tap again.');
  end if;
  v_hash := public._card_uid_hash(v_norm);
  perform pg_advisory_xact_lock(hashtextextended('card:' || v_hash, 0));

  -- Close this reader's expired session, then take the open one (if any).
  update public.rfid_pairing_sessions
     set status = 'expired', result_code = 'expired', message = 'No card was tapped in time.', completed_at = now()
   where device_id = d.id and status = 'waiting' and expires_at <= now();
  select * into s from public.rfid_pairing_sessions
   where device_id = d.id and status = 'waiting' and expires_at > now()
   for update;

  select * into c from public.loyalty_cards where card_uid_hash = v_hash;

  if s.id is not null then
    perform pg_advisory_xact_lock(hashtextextended('card-owner:' || s.firebase_uid, 0));
    -- Re-read after the owner lock (a staff link may have just finished).
    select * into c from public.loyalty_cards where card_uid_hash = v_hash;
    if c.id is not null and c.status = 'active' and c.firebase_uid = s.firebase_uid then
      v_result := 'already_linked'; v_message := 'This card is already linked to this account.';
      v_uid := s.firebase_uid; v_label := c.card_label;
    elsif c.id is not null and c.status = 'active' then
      v_result := 'card_taken'; v_message := 'This card belongs to another account.';
    elsif c.id is not null then
      v_result := 'card_blocked'; v_message := 'This card is blocked or retired. Use a new card.';
    elsif exists (select 1 from public.loyalty_cards where firebase_uid = s.firebase_uid and status = 'active') then
      v_result := 'customer_has_card';
      v_message := 'This account already has an active card. Block or remove it in the app first.';
    else
      c := public._self_link_card(v_hash, s.firebase_uid, d);
      v_result := 'linked'; v_message := 'Card linked.';
      v_uid := s.firebase_uid; v_label := c.card_label;
    end if;

    select coalesce((select points_balance from public.loyalty_accounts where firebase_uid = s.firebase_uid), 0)
      into v_points;
    update public.rfid_pairing_sessions
       set status = case when v_result in ('linked', 'already_linked') then v_result else 'failed' end,
           result_code = v_result, message = v_message, card_label = v_label,
           points_balance = case when v_result in ('linked', 'already_linked') then v_points end,
           completed_at = now()
     where id = s.id;
    if v_result not in ('linked', 'already_linked') then v_points := null; end if;
  else
    if c.id is not null and c.status = 'active' then
      v_result := 'synced'; v_message := 'Points synced.'; v_uid := c.firebase_uid; v_label := c.card_label;
      select coalesce((select points_balance from public.loyalty_accounts where firebase_uid = c.firebase_uid), 0)
        into v_points;
    elsif c.id is not null then
      v_result := 'card_blocked'; v_message := 'This card is blocked or retired.';
    else
      v_result := 'unregistered'; v_message := 'Card not linked. Open the app: RFID card > Link my card.';
    end if;
  end if;

  insert into public.rfid_device_taps (device_id, device_code, card_uid_hash, firebase_uid, result, points_balance, ip)
  values (d.id, v_code, v_hash, v_uid, v_result, v_points, v_ip);

  return jsonb_build_object('result', v_result, 'message', v_message,
                            'points_balance', v_points, 'card_label', v_label);
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Customer: readers, pairing, card self-service
-- -----------------------------------------------------------------------------
create or replace function public._require_customer()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
begin
  if v_uid is null or v_uid = 'walk-in'
     or not exists (select 1 from public.customer_profiles where firebase_uid = v_uid) then
    raise exception 'Please sign in to your customer account.';
  end if;
  return v_uid;
end;
$$;

create or replace function public.customer_list_card_readers()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_customer();
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'branch_name', b.name)
                     order by b.name nulls last, d.name)
    from public.rfid_devices d
    left join public.branches b on b.id = d.branch_id
    where d.is_active), '[]'::jsonb);
end;
$$;

create or replace function public._pairing_json(s public.rfid_pairing_sessions)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', s.id, 'status', s.status, 'result_code', s.result_code, 'message', s.message,
    'card_label', s.card_label, 'points_balance', s.points_balance,
    'expires_at', s.expires_at, 'created_at', s.created_at, 'completed_at', s.completed_at,
    'seconds_left', greatest(0, ceil(extract(epoch from (s.expires_at - now()))))::int,
    'device_name', (select name from public.rfid_devices where id = s.device_id))
$$;

create or replace function public.customer_start_card_pairing(p_device_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public._require_customer();
  d public.rfid_devices;
  v_recent int;
  s public.rfid_pairing_sessions;
begin
  select * into d from public.rfid_devices where id = p_device_id and is_active;
  if d.id is null then raise exception 'That card reader is not available. Pick another one.'; end if;

  perform pg_advisory_xact_lock(hashtextextended('rfid-device:' || d.device_code, 0));
  perform pg_advisory_xact_lock(hashtextextended('card-owner:' || v_uid, 0));

  if exists (select 1 from public.loyalty_cards where firebase_uid = v_uid and status = 'active') then
    raise exception 'You already have an active card. Block or remove it first to link a new one.';
  end if;

  select count(*) into v_recent from public.rfid_pairing_sessions
   where firebase_uid = v_uid and created_at > now() - interval '10 minutes';
  if public._rate_limit_applies() and v_recent >= 10 then
    raise exception 'Too many link attempts. Please wait 10 minutes and try again.';
  end if;

  -- This customer's other open sessions end; this reader's expired one closes.
  update public.rfid_pairing_sessions
     set status = 'cancelled', result_code = 'cancelled', message = 'A new link was started.', completed_at = now()
   where firebase_uid = v_uid and status = 'waiting';
  update public.rfid_pairing_sessions
     set status = 'expired', result_code = 'expired', message = 'No card was tapped in time.', completed_at = now()
   where device_id = d.id and status = 'waiting' and expires_at <= now();
  if exists (select 1 from public.rfid_pairing_sessions where device_id = d.id and status = 'waiting') then
    raise exception 'This reader is linking another card right now. Try again in a minute.';
  end if;

  insert into public.rfid_pairing_sessions (firebase_uid, device_id, expires_at)
  values (v_uid, d.id, now() + interval '60 seconds')
  returning * into s;
  return public._pairing_json(s);
end;
$$;

create or replace function public.customer_cancel_card_pairing(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public._require_customer();
  s public.rfid_pairing_sessions;
begin
  update public.rfid_pairing_sessions
     set status = 'cancelled', result_code = 'cancelled', message = 'Cancelled.', completed_at = now()
   where id = p_session_id and firebase_uid = v_uid and status = 'waiting'
  returning * into s;
  if s.id is null then
    select * into s from public.rfid_pairing_sessions where id = p_session_id and firebase_uid = v_uid;
  end if;
  if s.id is null then raise exception 'That link request could not be found.'; end if;
  return public._pairing_json(s);
end;
$$;

create or replace function public.customer_get_card_pairing(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public._require_customer();
  s public.rfid_pairing_sessions;
begin
  -- An expired session is closed when it is read.
  update public.rfid_pairing_sessions
     set status = 'expired', result_code = 'expired', message = 'No card was tapped in time.', completed_at = now()
   where id = p_session_id and firebase_uid = v_uid and status = 'waiting' and expires_at <= now();
  select * into s from public.rfid_pairing_sessions where id = p_session_id and firebase_uid = v_uid;
  if s.id is null then raise exception 'That link request could not be found.'; end if;
  return public._pairing_json(s);
end;
$$;

-- Lost or stolen: stops working everywhere at once. Owner can unblock (existing).
create or replace function public.customer_block_my_card(p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public._require_customer();
  v_reason text := coalesce(nullif(left(trim(coalesce(p_reason, '')), 200), ''), 'Reported lost by the customer');
  c public.loyalty_cards;
begin
  perform pg_advisory_xact_lock(hashtextextended('card-owner:' || v_uid, 0));
  select * into c from public.loyalty_cards where firebase_uid = v_uid and status = 'active' for update;
  if c.id is null then raise exception 'You have no active card to block.'; end if;
  update public.loyalty_cards
     set status = 'blocked', blocked_at = now(), block_reason = v_reason, updated_at = now()
   where id = c.id returning * into c;
  insert into public.loyalty_card_events (card_id, event, note) values (c.id, 'blocked', 'By the customer: ' || v_reason);
  perform public._sync_profile_card_label(v_uid);
  perform public.notify_customer(v_uid, 'loyalty', 'Loyalty card blocked',
    'Your card ' || c.card_label || ' was blocked. Your points are safe. Link a new card any time.');
  return public.get_my_loyalty_card();
end;
$$;

-- Unlink for good (the card can never be used again). Works on an active or blocked card.
create or replace function public.customer_remove_my_card()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public._require_customer();
  c public.loyalty_cards;
begin
  perform pg_advisory_xact_lock(hashtextextended('card-owner:' || v_uid, 0));
  select * into c from public.loyalty_cards
   where firebase_uid = v_uid and status in ('active', 'blocked')
   order by (status = 'active') desc, issued_at desc limit 1 for update;
  if c.id is null then raise exception 'You have no card to remove.'; end if;
  update public.loyalty_cards
     set status = 'replaced', blocked_at = coalesce(blocked_at, now()),
         block_reason = coalesce(block_reason, 'Removed by the customer'), updated_at = now()
   where id = c.id;
  insert into public.loyalty_card_events (card_id, event, note) values (c.id, 'replaced', 'Removed by the customer');
  perform public._sync_profile_card_label(v_uid);
  perform public.notify_customer(v_uid, 'loyalty', 'Loyalty card removed',
    'Card ' || c.card_label || ' was removed from your account and no longer works. Your points are safe.');
  return coalesce(public.get_my_loyalty_card(), jsonb_build_object('status', 'none'));
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Optional loyalty PIN (needed only to redeem points at the counter)
-- -----------------------------------------------------------------------------
create table if not exists public.loyalty_pins (
  firebase_uid text primary key references public.customer_profiles(firebase_uid) on delete cascade,
  pin_salt text not null,
  pin_hash text not null,
  failed_attempts int not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.loyalty_pins enable row level security;
revoke all on public.loyalty_pins from anon, authenticated;

create or replace function public._pin_hash(p_salt text, p_uid text, p_pin text)
returns text
language plpgsql
immutable
as $$
declare
  h bytea := convert_to(p_salt || ':' || p_uid || ':' || p_pin, 'UTF8');
begin
  -- Stretched a little; the lock after 5 wrong tries is the real protection.
  for i in 1..2000 loop h := sha256(h || convert_to(p_pin, 'UTF8')); end loop;
  return encode(h, 'hex');
end;
$$;

-- '{ok: true}' or '{ok: false, reason: no_pin | wrong | locked, attempts_left, locked_until}'.
-- Writes the failure counter, so callers must NOT raise afterwards in the same call.
create or replace function public._check_loyalty_pin(p_uid text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.loyalty_pins;
  v_pin text := trim(coalesce(p_pin, ''));
begin
  select * into r from public.loyalty_pins where firebase_uid = p_uid for update;
  if r.firebase_uid is null then return jsonb_build_object('ok', true, 'reason', 'no_pin'); end if;
  if r.locked_until is not null and r.locked_until > now() then
    return jsonb_build_object('ok', false, 'reason', 'locked', 'locked_until', r.locked_until);
  end if;
  if v_pin ~ '^[0-9]{4,6}$' and public._pin_hash(r.pin_salt, p_uid, v_pin) = r.pin_hash then
    update public.loyalty_pins set failed_attempts = 0, locked_until = null where firebase_uid = p_uid;
    return jsonb_build_object('ok', true);
  end if;
  update public.loyalty_pins
     set failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
         locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else null end
   where firebase_uid = p_uid
  returning * into r;
  if r.locked_until is not null then
    return jsonb_build_object('ok', false, 'reason', 'locked', 'locked_until', r.locked_until);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'wrong', 'attempts_left', 5 - r.failed_attempts);
end;
$$;

create or replace function public.get_my_loyalty_pin_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid text := public._require_customer();
  r public.loyalty_pins;
begin
  select * into r from public.loyalty_pins where firebase_uid = v_uid;
  return jsonb_build_object('has_pin', r.firebase_uid is not null,
                            'locked_until', case when r.locked_until > now() then r.locked_until end);
end;
$$;

-- New PIN, or change it (p_current_pin needed when one is set).
create or replace function public.customer_set_loyalty_pin(p_new_pin text, p_current_pin text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public._require_customer();
  v_new text := trim(coalesce(p_new_pin, ''));
  v_check jsonb;
  v_salt text := replace(gen_random_uuid()::text, '-', '');
begin
  if v_new !~ '^[0-9]{4,6}$' then raise exception 'The PIN must be 4 to 6 digits.'; end if;
  if exists (select 1 from public.loyalty_pins where firebase_uid = v_uid) then
    v_check := public._check_loyalty_pin(v_uid, p_current_pin);
    if not (v_check ->> 'ok')::boolean then
      return v_check || jsonb_build_object('has_pin', true);   -- the failed try stays counted
    end if;
  end if;
  insert into public.loyalty_pins (firebase_uid, pin_salt, pin_hash)
  values (v_uid, v_salt, public._pin_hash(v_salt, v_uid, v_new))
  on conflict (firebase_uid) do update
    set pin_salt = excluded.pin_salt, pin_hash = excluded.pin_hash,
        failed_attempts = 0, locked_until = null, updated_at = now();
  return jsonb_build_object('ok', true, 'has_pin', true);
end;
$$;

create or replace function public.customer_clear_loyalty_pin(p_current_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public._require_customer();
  v_check jsonb := public._check_loyalty_pin(v_uid, p_current_pin);
begin
  if not (v_check ->> 'ok')::boolean then return v_check || jsonb_build_object('has_pin', true); end if;
  delete from public.loyalty_pins where firebase_uid = v_uid;
  return jsonb_build_object('ok', true, 'has_pin', false);
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. The loyalty rules, shared by the app order and the POS
-- -----------------------------------------------------------------------------
-- Points and peso discount for redeeming against p_subtotal after p_other_discount.
-- The SAME formula as _place_order_api (20261118015010): capped by the balance,
-- by what is left to pay and by max_discount_percent of the subtotal.
create or replace function public._loyalty_redeem_quote(
  p_balance int,
  p_subtotal numeric,
  p_other_discount numeric default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_per_peso numeric;
  v_max_pct numeric;
  v_points int := 0;
begin
  select points_per_peso, max_discount_percent into v_per_peso, v_max_pct
  from public.loyalty_cart_settings where id = 'default';
  if v_per_peso is null then
    return jsonb_build_object('configured', false, 'points_used', 0, 'discount', 0);
  end if;
  v_points := least(
    greatest(coalesce(p_balance, 0), 0),
    floor(greatest(0, least(p_subtotal - coalesce(p_other_discount, 0),
                            p_subtotal * v_max_pct / 100)) * v_per_peso)::int);
  return jsonb_build_object('configured', true, 'points_used', v_points,
                            'discount', round(v_points / v_per_peso, 2),
                            'points_per_peso', v_per_peso, 'max_discount_percent', v_max_pct);
end;
$$;

-- Points an order total earns: the rule of compute_points_earned (20261018000000).
create or replace function public._loyalty_points_for_total(p_total numeric)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select case when s.rate is null or s.rate < 1 then 0
              else greatest(0, floor(coalesce(p_total, 0) / s.rate)::int) end
  from (select (select earn_pesos_per_point from public.loyalty_cart_settings where id = 'default') as rate) s
$$;

-- Staff and branch on the ledger rows a POS sale writes (set by the sale, see below).
alter table public.loyalty_transactions add column if not exists staff_uid text;
alter table public.loyalty_transactions add column if not exists branch_id uuid references public.branches(id) on delete set null;

create or replace function public._trg_loyalty_tx_pos_context()
returns trigger
language plpgsql
as $$
begin
  if new.staff_uid is null then
    new.staff_uid := nullif(current_setting('app.loyalty_staff_uid', true), '');
  end if;
  if new.branch_id is null and coalesce(current_setting('app.loyalty_branch_id', true), '') <> '' then
    new.branch_id := current_setting('app.loyalty_branch_id', true)::uuid;
  end if;
  return new;
end;
$$;
drop trigger if exists loyalty_transactions_pos_context on public.loyalty_transactions;
create trigger loyalty_transactions_pos_context
  before insert on public.loyalty_transactions
  for each row execute function public._trg_loyalty_tx_pos_context();

-- Customers keep reading their history, but not which staff account served them.
revoke select on public.loyalty_transactions from authenticated;
grant select (id, firebase_uid, type, points, description, order_id, created_at, source, branch_id)
  on public.loyalty_transactions to authenticated;

-- One redemption per order, whatever the caller.
do $$
begin
  create unique index if not exists loyalty_transactions_one_redeem_per_order
    on public.loyalty_transactions (order_id) where (source = 'order_redeem' and order_id is not null);
exception when unique_violation then
  raise warning 'loyalty_transactions_one_redeem_per_order NOT created: an order has several redemptions. Resolve manually and re-run.';
end $$;

-- -----------------------------------------------------------------------------
-- 9. POS: quote and sale with points
-- -----------------------------------------------------------------------------
-- What the sale WILL be, computed here (the app shows these numbers, never its own).
create or replace function public.staff_pos_quote(
  p_branch_id uuid,
  p_items jsonb,
  p_customer_uid text default null,
  p_redeem_points boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid text := nullif(trim(coalesce(p_customer_uid, '')), '');
  v_line record;
  v_price numeric;
  v_subtotal numeric := 0;
  v_balance int := 0;
  v_quote jsonb := jsonb_build_object('configured', false, 'points_used', 0, 'discount', 0);
  v_max jsonb;
  v_total numeric;
begin
  perform public._require_staff(p_branch_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'The sale has no items.';
  end if;
  if jsonb_array_length(p_items) > 100 then raise exception 'Too many lines in one sale.'; end if;
  for v_line in
    select (e ->> 'variant_id')::uuid as variant_id, sum((e ->> 'quantity')::int)::int as qty
    from jsonb_array_elements(p_items) e group by 1
  loop
    if v_line.qty <= 0 or v_line.qty > 1000 then raise exception 'Invalid quantity in this sale.'; end if;
    select pv.price into v_price from public.product_variants pv join public.products p on p.id = pv.product_id
     where pv.id = v_line.variant_id and p.is_active;
    if v_price is null then raise exception 'A product in this sale is no longer available.'; end if;
    v_subtotal := v_subtotal + v_price * v_line.qty;
  end loop;

  if v_uid is not null and v_uid <> 'walk-in' then
    if not exists (select 1 from public.customer_profiles where firebase_uid = v_uid) then
      raise exception 'That loyalty customer could not be found.';
    end if;
    select coalesce((select points_balance from public.loyalty_accounts where firebase_uid = v_uid), 0) into v_balance;
    v_max := public._loyalty_redeem_quote(v_balance, v_subtotal, 0);
    if coalesce(p_redeem_points, false) then v_quote := v_max; end if;
  else
    v_uid := null;
  end if;

  v_total := greatest(0, v_subtotal - (v_quote ->> 'discount')::numeric);
  return jsonb_build_object(
    'subtotal', v_subtotal,
    'points_used', (v_quote ->> 'points_used')::int,
    'loyalty_discount', (v_quote ->> 'discount')::numeric,
    'total', v_total,
    'points_to_earn', case when v_uid is null then 0 else public._loyalty_points_for_total(v_total) end,
    'points_balance', v_balance,
    'redeem_configured', coalesce((v_max ->> 'configured')::boolean, false),
    'max_points_redeemable', coalesce((v_max ->> 'points_used')::int, 0),
    'max_discount', coalesce((v_max ->> 'discount')::numeric, 0),
    'pin_required', v_uid is not null and exists (select 1 from public.loyalty_pins where firebase_uid = v_uid));
end;
$$;

-- The 7-argument version is replaced by this one (same arguments first, so every
-- existing positional / named call keeps working).
drop function if exists public.staff_create_pos_sale(uuid, jsonb, text, text, numeric, text, text);
create or replace function public.staff_create_pos_sale(
  p_branch_id uuid,
  p_items jsonb,
  p_payment_method text,
  p_payment_reference text default null,
  p_cash_received numeric default null,
  p_customer_uid text default null,
  p_idempotency_key text default null,
  p_redeem_points boolean default false,
  p_loyalty_pin text default null,
  p_customer_confirmed boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_uid text := coalesce(nullif(trim(coalesce(p_customer_uid, '')), ''), 'walk-in');
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_redeem boolean := coalesce(p_redeem_points, false);
  v_fingerprint text;
  v_branch_name text;
  v_existing text;
  v_existing_fp text;
  v_line record;
  v_var record;
  v_avail int;
  v_subtotal numeric := 0;
  v_balance int;
  v_quote jsonb;
  v_points_used int := 0;
  v_discount numeric := 0;
  v_total numeric;
  v_pin jsonb;
  v_order_id text;
  v_payment_id text;
  v_code text;
  v_label text;
  v_ref text := nullif(trim(coalesce(p_payment_reference, '')), '');
  v_change numeric := 0;
  v_count int;
begin
  v_staff := public._require_staff(p_branch_id);
  select name into v_branch_name from public.branches where id = p_branch_id;
  if v_branch_name is null then raise exception 'That branch could not be found.'; end if;

  if v_key is not null then
    if length(v_key) > 200 then raise exception 'Invalid checkout reference.'; end if;
    v_fingerprint := public._pos_sale_fingerprint(p_branch_id, p_items, p_payment_method, v_uid, v_ref);
    -- A sale that redeems points is a different request (older sales keep their fingerprint).
    if v_redeem then v_fingerprint := md5(v_fingerprint || '|redeem'); end if;
    perform pg_advisory_xact_lock(hashtextextended('pos:' || v_staff.firebase_uid || ':' || v_key, 0));
    select ps.order_id, ps.request_fingerprint into v_existing, v_existing_fp
    from public.pos_sales ps
    where ps.staff_uid = v_staff.firebase_uid and ps.idempotency_key = v_key;
    if not found then
      select o.id, null into v_existing, v_existing_fp
      from public.orders o
      join public.pos_sales ps on ps.order_id = o.id
      where ps.staff_uid = v_staff.firebase_uid and ps.idempotency_key is null
        and o.idempotency_key = v_key
      limit 1;
    end if;
    if v_existing is not null then
      if v_existing_fp is not null and v_existing_fp <> v_fingerprint then
        raise exception 'This sale was already recorded with different details. Start a new sale.';
      end if;
      return (
        select jsonb_build_object('order_id', o.id, 'subtotal', o.subtotal, 'total', o.total,
                                  'loyalty_discount', o.discount,
                                  'points_redeemed', coalesce((select -sum(t.points) from public.loyalty_transactions t
                                                               where t.order_id = o.id and t.source = 'order_redeem'), 0),
                                  'points_earned', o.points_earned,
                                  'payment_id', p.id, 'change', coalesce(ps.change_given, 0),
                                  'line_count', (select count(*) from public.order_items i where i.order_id = o.id),
                                  'already_recorded', true)
        from public.orders o
        left join public.payments p on p.order_id = o.id
        left join public.pos_sales ps on ps.order_id = o.id
        where o.id = v_existing
      );
    end if;
  end if;

  if v_uid <> 'walk-in' and not exists (select 1 from public.customer_profiles where firebase_uid = v_uid) then
    raise exception 'That loyalty customer could not be found.';
  end if;
  if v_redeem and v_uid = 'walk-in' then
    raise exception 'Find the loyalty customer first to redeem points.';
  end if;
  if v_redeem and not coalesce(p_customer_confirmed, false) then
    raise exception 'Confirm the customer''s name with them before redeeming points.';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'The sale has no items.';
  end if;
  if jsonb_array_length(p_items) > 100 then raise exception 'Too many lines in one sale.'; end if;

  select case p_payment_method when 'cash' then 'cash' when 'gcash' then 'gcash' when 'card' then 'card' end,
         case p_payment_method when 'cash' then 'Cash (In-store)' when 'gcash' then 'GCash (In-store)'
                               when 'card' then 'Card (In-store)' end
  into v_code, v_label;
  if v_code is null then raise exception 'Unsupported payment method.'; end if;
  if v_code <> 'cash' and (v_ref is null or length(v_ref) < 4) then
    raise exception 'Enter the payment reference number from the terminal or wallet.';
  end if;

  -- The PIN first: a wrong PIN is counted and answered WITHOUT an error (an error
  -- would roll the counter back). Nothing else has been written yet.
  if v_redeem then
    v_pin := public._check_loyalty_pin(v_uid, p_loyalty_pin);
    if not (v_pin ->> 'ok')::boolean then
      return jsonb_build_object('error', 'pin_' || (v_pin ->> 'reason'),
        'message', case v_pin ->> 'reason'
                     when 'locked' then 'Too many wrong PINs. Points can be redeemed again in 15 minutes.'
                     else 'Wrong loyalty PIN. ' || (v_pin ->> 'attempts_left') || ' tries left.' end,
        'attempts_left', (v_pin ->> 'attempts_left')::int,
        'locked_until', v_pin ->> 'locked_until');
    end if;
  end if;

  for v_line in
    select (e ->> 'variant_id')::uuid as variant_id, sum((e ->> 'quantity')::int)::int as qty
    from jsonb_array_elements(p_items) e
    group by 1 order by 1
  loop
    if v_line.qty <= 0 or v_line.qty > 1000 then raise exception 'Invalid quantity in this sale.'; end if;
    select pv.id, pv.product_id, pv.label, pv.price, p.name into v_var
    from public.product_variants pv join public.products p on p.id = pv.product_id
    where pv.id = v_line.variant_id and p.is_active;
    if not found then raise exception 'A product in this sale is no longer available.'; end if;
    select quantity into v_avail from public.branch_inventory
    where branch_id = p_branch_id and variant_id = v_line.variant_id for update;
    if coalesce(v_avail, 0) < v_line.qty then
      raise exception 'Only % left of % (%) at this branch.', coalesce(v_avail, 0), v_var.name, v_var.label;
    end if;
    v_subtotal := v_subtotal + v_var.price * v_line.qty;
  end loop;

  -- Redeem: the account row is locked, so the same points cannot be spent twice.
  if v_redeem then
    insert into public.loyalty_accounts (firebase_uid) values (v_uid) on conflict (firebase_uid) do nothing;
    select points_balance into v_balance from public.loyalty_accounts where firebase_uid = v_uid for update;
    v_quote := public._loyalty_redeem_quote(v_balance, v_subtotal, 0);
    if not (v_quote ->> 'configured')::boolean then
      raise exception 'Loyalty point redemption is not configured yet.';
    end if;
    if v_balance <= 0 then raise exception 'This customer has no points to redeem.'; end if;
    v_points_used := (v_quote ->> 'points_used')::int;
    v_discount := (v_quote ->> 'discount')::numeric;
    if v_points_used <= 0 then raise exception 'No points can be used on this sale.'; end if;
  end if;
  v_total := greatest(0, v_subtotal - v_discount);

  if v_code = 'cash' then
    if p_cash_received is null or p_cash_received < v_total then
      raise exception 'The cash received is less than the total.';
    end if;
    v_change := p_cash_received - v_total;
  end if;

  perform set_config('app.pos_sale', '1', true);
  -- Staff and branch for the ledger rows written below and by the completion trigger.
  perform set_config('app.loyalty_staff_uid', v_staff.firebase_uid, true);
  perform set_config('app.loyalty_branch_id', p_branch_id::text, true);

  insert into public.orders
    (firebase_uid, branch_id, branch_name, is_delivery, subtotal, discount, delivery_fee, total,
     payment_method, idempotency_key)
  values (v_uid, p_branch_id, v_branch_name, false, v_subtotal, v_discount, 0, v_total, v_label, v_key)
  returning id into v_order_id;

  perform set_config('app.stock_reference', v_order_id, true);

  for v_line in
    select (e ->> 'variant_id')::uuid as variant_id, sum((e ->> 'quantity')::int)::int as qty
    from jsonb_array_elements(p_items) e
    group by 1 order by 1
  loop
    select pv.product_id, pv.label, pv.price, p.name into v_var
    from public.product_variants pv join public.products p on p.id = pv.product_id
    where pv.id = v_line.variant_id;
    insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
    values (v_order_id, v_var.product_id, v_line.variant_id, v_var.name, v_var.label, v_line.qty, v_var.price);
    update public.branch_inventory set quantity = quantity - v_line.qty
    where branch_id = p_branch_id and variant_id = v_line.variant_id;
  end loop;

  if v_points_used > 0 then
    update public.loyalty_accounts set points_balance = points_balance - v_points_used where firebase_uid = v_uid;
    insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
    values (v_uid, 'redeem', -v_points_used, 'Applied to in-store sale ' || v_order_id, v_order_id, 'order_redeem');
  end if;

  insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number)
  values (v_order_id, v_uid, v_code, 'pending', v_total, coalesce(v_ref, v_order_id))
  returning id into v_payment_id;

  insert into public.pos_sales (order_id, branch_id, staff_uid, staff_name, payment_reference, cash_received, change_given,
                                idempotency_key, request_fingerprint)
  values (v_order_id, p_branch_id, v_staff.firebase_uid, v_staff.full_name, v_ref,
          case when v_code = 'cash' then p_cash_received end,
          case when v_code = 'cash' then v_change end,
          v_key, v_fingerprint);

  update public.payments set status = 'success' where id = v_payment_id;
  update public.orders set status = 'completed' where id = v_order_id;

  if v_points_used > 0 then
    perform public._write_audit(v_staff.firebase_uid, p_branch_id, 'loyalty.pos_redeem', 'order', v_order_id,
      jsonb_build_object('customer', v_uid, 'points', v_points_used, 'discount', v_discount));
  end if;

  perform set_config('app.loyalty_staff_uid', '', true);
  perform set_config('app.loyalty_branch_id', '', true);

  select count(*) into v_count from public.order_items where order_id = v_order_id;
  return (
    select jsonb_build_object('order_id', o.id, 'subtotal', o.subtotal, 'total', o.total,
                              'loyalty_discount', o.discount, 'points_redeemed', v_points_used,
                              'points_earned', o.points_earned,
                              'payment_id', v_payment_id, 'change', v_change, 'line_count', v_count,
                              'already_recorded', false)
    from public.orders o where o.id = v_order_id
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 10. Owner: readers and their activity
-- -----------------------------------------------------------------------------
create or replace function public.owner_list_rfid_devices()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_owner();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'device_code', d.device_code, 'name', d.name, 'branch', b.name, 'is_active', d.is_active,
             'last_seen_at', d.last_seen_at, 'key_rotated_at', d.key_rotated_at,
             'taps_24h', (select count(*) from public.rfid_device_taps t
                          where t.device_id = d.id and t.created_at > now() - interval '24 hours'),
             'rejected_24h', (select count(*) from public.rfid_device_taps t
                              where t.device_code = d.device_code and t.result = 'device_rejected'
                                and t.created_at > now() - interval '24 hours'))
           order by d.name)
    from public.rfid_devices d left join public.branches b on b.id = d.branch_id), '[]'::jsonb);
end;
$$;

-- -----------------------------------------------------------------------------
-- 11. Grants
-- -----------------------------------------------------------------------------
revoke all on function public._device_key_hash(text) from public, anon, authenticated;
revoke all on function public._new_device_key() from public, anon, authenticated;
revoke all on function public.rfid_register_device(text, uuid) from public, anon, authenticated, service_role;
revoke all on function public.rfid_rotate_device_key(text) from public, anon, authenticated, service_role;
revoke all on function public.rfid_set_device_active(text, boolean) from public, anon, authenticated, service_role;
revoke all on function public._trg_rfid_device_taps_append_only() from public, anon, authenticated;
revoke all on function public._self_link_card(text, text, public.rfid_devices) from public, anon, authenticated;
revoke all on function public.rfid_device_tap(text, text, text, text) from public, anon, authenticated;
grant execute on function public.rfid_device_tap(text, text, text, text) to service_role;
revoke all on function public._require_customer() from public, anon, authenticated;
revoke all on function public._pairing_json(public.rfid_pairing_sessions) from public, anon, authenticated;
revoke all on function public._pin_hash(text, text, text) from public, anon, authenticated;
revoke all on function public._check_loyalty_pin(text, text) from public, anon, authenticated;
revoke all on function public._loyalty_redeem_quote(int, numeric, numeric) from public, anon, authenticated;
revoke all on function public._loyalty_points_for_total(numeric) from public, anon, authenticated;
revoke all on function public._trg_loyalty_tx_pos_context() from public, anon, authenticated;

revoke all on function public.customer_list_card_readers() from public, anon;
revoke all on function public.customer_start_card_pairing(uuid) from public, anon;
revoke all on function public.customer_cancel_card_pairing(uuid) from public, anon;
revoke all on function public.customer_get_card_pairing(uuid) from public, anon;
revoke all on function public.customer_block_my_card(text) from public, anon;
revoke all on function public.customer_remove_my_card() from public, anon;
revoke all on function public.get_my_loyalty_pin_status() from public, anon;
revoke all on function public.customer_set_loyalty_pin(text, text) from public, anon;
revoke all on function public.customer_clear_loyalty_pin(text) from public, anon;
revoke all on function public.staff_pos_quote(uuid, jsonb, text, boolean) from public, anon;
revoke all on function public.staff_create_pos_sale(uuid, jsonb, text, text, numeric, text, text, boolean, text, boolean) from public, anon;
revoke all on function public.owner_list_rfid_devices() from public, anon;

grant execute on function public.customer_list_card_readers() to authenticated;
grant execute on function public.customer_start_card_pairing(uuid) to authenticated;
grant execute on function public.customer_cancel_card_pairing(uuid) to authenticated;
grant execute on function public.customer_get_card_pairing(uuid) to authenticated;
grant execute on function public.customer_block_my_card(text) to authenticated;
grant execute on function public.customer_remove_my_card() to authenticated;
grant execute on function public.get_my_loyalty_pin_status() to authenticated;
grant execute on function public.customer_set_loyalty_pin(text, text) to authenticated;
grant execute on function public.customer_clear_loyalty_pin(text) to authenticated;
grant execute on function public.staff_pos_quote(uuid, jsonb, text, boolean) to authenticated;
grant execute on function public.staff_create_pos_sale(uuid, jsonb, text, text, numeric, text, text, boolean, text, boolean) to authenticated;
grant execute on function public.owner_list_rfid_devices() to authenticated;

commit;
