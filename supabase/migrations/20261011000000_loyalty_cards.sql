-- =============================================================================
-- RFID loyalty cards: card registry, register / replace / block / unblock,
-- card tap lookup at the POS
-- =============================================================================
-- Run after 20261010020000_analytics_forecasting.sql. Idempotent and additive.
--
-- Why a registry (before: one free-text customer_profiles.rfid_card_number)
--   * a lost card can be BLOCKED at once, so nobody can earn or redeem on it;
--   * a new card REPLACES the old one and the points stay (points live on the
--     customer's loyalty account, never on the card);
--   * every register / block / unblock / replace is kept in an append-only history.
--
-- How a card is identified
--   The reader (Arduino + RC522, or any USB "keyboard" reader) sends the card's
--   UID, e.g. "04:A1:B2:C3" or "04A1B2C3". It is normalised (separators removed,
--   upper case, 8–20 hex digits) and only its SHA-256 is stored. Staff and the
--   customer see a short label derived from the hash (e.g. GK-3F9A-71C2), which
--   is also written to customer_profiles.rfid_card_number so the app's existing
--   card screen keeps working.
--
--   A card UID is NOT a password. It only identifies the customer to a signed-in,
--   active staff member at the counter; every RPC here starts with _require_staff.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Tables
-- -----------------------------------------------------------------------------
create table if not exists public.loyalty_cards (
  id uuid primary key default gen_random_uuid(),
  card_uid_hash text not null,
  card_label text not null,
  firebase_uid text not null references public.customer_profiles(firebase_uid) on delete cascade,
  status text not null default 'active' check (status in ('active', 'blocked', 'replaced')),
  issued_branch_id uuid references public.branches(id) on delete set null,
  issued_by text,
  issued_at timestamptz not null default now(),
  blocked_at timestamptz,
  block_reason text,
  replaced_by uuid references public.loyalty_cards(id) on delete set null,
  updated_at timestamptz not null default now()
);
create unique index if not exists loyalty_cards_hash_key on public.loyalty_cards (card_uid_hash);
create unique index if not exists loyalty_cards_label_key on public.loyalty_cards (card_label);
-- One active card per customer.
create unique index if not exists loyalty_cards_one_active
  on public.loyalty_cards (firebase_uid) where (status = 'active');
create index if not exists loyalty_cards_customer_idx on public.loyalty_cards (firebase_uid, issued_at desc);

create table if not exists public.loyalty_card_events (
  id bigserial primary key,
  card_id uuid not null references public.loyalty_cards(id) on delete cascade,
  event text not null check (event in ('registered', 'blocked', 'unblocked', 'replaced', 'migrated')),
  staff_uid text,
  branch_id uuid references public.branches(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists loyalty_card_events_card_idx on public.loyalty_card_events (card_id, created_at);

-- Only the functions below touch these tables.
alter table public.loyalty_cards enable row level security;
alter table public.loyalty_card_events enable row level security;
revoke all on public.loyalty_cards from anon, authenticated;
revoke all on public.loyalty_card_events from anon, authenticated;

-- History is append-only, even for privileged roles.
create or replace function public._trg_loyalty_card_events_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'Loyalty card history cannot be changed or deleted.';
end;
$$;
drop trigger if exists loyalty_card_events_append_only on public.loyalty_card_events;
create trigger loyalty_card_events_append_only
  before update or delete on public.loyalty_card_events
  for each row execute function public._trg_loyalty_card_events_append_only();

-- -----------------------------------------------------------------------------
-- 2. Helpers
-- -----------------------------------------------------------------------------
-- "04:a1 b2-c3" -> "04A1B2C3"; null when it is not a plausible card UID.
create or replace function public._normalize_card_uid(p_raw text)
returns text
language sql
immutable
as $$
  select case
    when v ~ '^[0-9A-F]{8,20}$' then v
    else null
  end
  from (select upper(regexp_replace(coalesce(p_raw, ''), '[\s:\-\.]', '', 'g')) as v) t
$$;

create or replace function public._card_uid_hash(p_normalized text)
returns text
language sql
immutable
as $$
  select encode(sha256(convert_to('melai-card:' || p_normalized, 'UTF8')), 'hex')
$$;

create or replace function public._card_label(p_hash text)
returns text
language sql
immutable
as $$
  select 'GK-' || upper(substr(p_hash, 1, 4)) || '-' || upper(substr(p_hash, 5, 4))
$$;

create or replace function public._card_json(c public.loyalty_cards)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', c.id,
    'label', c.card_label,
    'status', c.status,
    'firebase_uid', c.firebase_uid,
    'customer_name', (select full_name from public.customer_profiles where firebase_uid = c.firebase_uid),
    'issued_at', c.issued_at,
    'issued_branch', (select name from public.branches where id = c.issued_branch_id),
    'blocked_at', c.blocked_at,
    'block_reason', c.block_reason,
    'replaced_by', c.replaced_by)
$$;

-- Keeps the label the app shows in step with the active card.
create or replace function public._sync_profile_card_label(p_uid text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.customer_profiles
     set rfid_card_number = (select card_label from public.loyalty_cards
                             where firebase_uid = p_uid and status = 'active')
   where firebase_uid = p_uid;
$$;

-- -----------------------------------------------------------------------------
-- 3. Move existing customer_profiles.rfid_card_number values into the registry
--    (only values that look like a card UID; anything else is left as it was).
-- -----------------------------------------------------------------------------
create or replace function public._migrate_legacy_rfid_cards()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_norm text;
  v_hash text;
  v_id uuid;
  v_n int := 0;
begin
  for r in
    select cp.firebase_uid, cp.rfid_card_number
    from public.customer_profiles cp
    where cp.rfid_card_number is not null
      and cp.firebase_uid <> 'walk-in'
      and not exists (select 1 from public.loyalty_cards c where c.firebase_uid = cp.firebase_uid)
  loop
    v_norm := public._normalize_card_uid(r.rfid_card_number);
    continue when v_norm is null;
    v_hash := public._card_uid_hash(v_norm);
    continue when exists (select 1 from public.loyalty_cards where card_uid_hash = v_hash);
    insert into public.loyalty_cards (card_uid_hash, card_label, firebase_uid, issued_by)
    values (v_hash, public._card_label(v_hash), r.firebase_uid, 'migration')
    returning id into v_id;
    insert into public.loyalty_card_events (card_id, event, note)
    values (v_id, 'migrated', 'Moved from customer_profiles.rfid_card_number');
    perform public._sync_profile_card_label(r.firebase_uid);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
select public._migrate_legacy_rfid_cards();

-- -----------------------------------------------------------------------------
-- 4. Tap at the counter: who owns this card?
--    {"status": "active", "card": {...}, "customer": {firebase_uid, full_name, points_balance}}
--    {"status": "blocked" | "replaced", "card": {"label": ...}}   (no customer data)
--    {"status": "unregistered"}                                 (offer "link to customer")
-- -----------------------------------------------------------------------------
create or replace function public.staff_lookup_card(p_card_uid text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_norm text := public._normalize_card_uid(p_card_uid);
  c public.loyalty_cards;
begin
  perform public._require_staff();
  if v_norm is null then
    raise exception 'That is not a card number the reader would send (8 to 20 letters A–F / digits).';
  end if;
  select * into c from public.loyalty_cards where card_uid_hash = public._card_uid_hash(v_norm);
  if c.id is null then
    return jsonb_build_object('status', 'unregistered');
  end if;
  if c.status <> 'active' then
    return jsonb_build_object('status', c.status,
      'card', jsonb_build_object('id', c.id, 'label', c.card_label, 'blocked_at', c.blocked_at));
  end if;
  return jsonb_build_object(
    'status', 'active',
    'card', public._card_json(c),
    'customer', (
      select jsonb_build_object(
        'firebase_uid', cp.firebase_uid,
        'full_name', cp.full_name,
        'points_balance', coalesce(la.points_balance, 0))
      from public.customer_profiles cp
      left join public.loyalty_accounts la on la.firebase_uid = cp.firebase_uid
      where cp.firebase_uid = c.firebase_uid));
end;
$$;

-- The POS "find loyalty customer" box: a tapped card (registry), the printed
-- label, phone or e-mail — exact matches only, as before. A blocked or replaced
-- card is refused with a clear message instead of "not found".
create or replace function public.staff_lookup_customer(p_query text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := trim(coalesce(p_query, ''));
  v_norm text := public._normalize_card_uid(v_q);
  c public.loyalty_cards;
begin
  perform public._require_staff();
  if length(v_q) < 4 then raise exception 'Enter at least 4 characters to look up a customer.'; end if;

  if v_norm is not null then
    select * into c from public.loyalty_cards where card_uid_hash = public._card_uid_hash(v_norm);
    if c.id is not null and c.status = 'blocked' then
      raise exception 'Loyalty card % is blocked and cannot be used. Look the customer up by e-mail instead.', c.card_label;
    elsif c.id is not null and c.status = 'replaced' then
      raise exception 'Loyalty card % was replaced by a newer card and can no longer be used.', c.card_label;
    end if;
  end if;

  return (
    select coalesce(jsonb_agg(t.j), '[]'::jsonb)
    from (
      select jsonb_build_object(
        'firebase_uid', cp.firebase_uid,
        'full_name', cp.full_name,
        'points_balance', coalesce(la.points_balance, 0)) as j
      from public.customer_profiles cp
      left join public.loyalty_accounts la on la.firebase_uid = cp.firebase_uid
      where cp.firebase_uid <> 'walk-in'
        and (cp.rfid_card_number = v_q
             or upper(cp.rfid_card_number) = upper(v_q)
             or cp.phone = v_q
             or lower(cp.email) = lower(v_q)
             or (c.id is not null and c.status = 'active' and cp.firebase_uid = c.firebase_uid))
      limit 5
    ) t
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Register a new card to a customer (staff at the counter)
-- -----------------------------------------------------------------------------
create or replace function public.staff_register_loyalty_card(
  p_card_uid text,
  p_customer_uid text,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_norm text := public._normalize_card_uid(p_card_uid);
  v_hash text;
  v_uid text := trim(coalesce(p_customer_uid, ''));
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_req jsonb;
  v_prev jsonb;
  c public.loyalty_cards;
  v_result jsonb;
begin
  v_staff := public._require_staff();
  if v_norm is null then
    raise exception 'Tap the card on the reader (the card number was not readable).';
  end if;
  v_hash := public._card_uid_hash(v_norm);
  v_req := jsonb_build_object('h', v_hash, 'u', v_uid);
  v_prev := public._idem_begin(v_staff.firebase_uid, v_key, 'card_register', v_req);
  if v_prev is not null then return v_prev; end if;

  if v_uid = '' or v_uid = 'walk-in'
     or not exists (select 1 from public.customer_profiles where firebase_uid = v_uid) then
    raise exception 'Find the customer first, then tap the new card.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('card:' || v_hash, 0));
  perform pg_advisory_xact_lock(hashtextextended('card-owner:' || v_uid, 0));

  select * into c from public.loyalty_cards where card_uid_hash = v_hash;
  if c.id is not null then
    if c.firebase_uid = v_uid and c.status = 'active' then
      -- Same card, same customer: already done (double tap / retry).
      v_result := public._card_json(c);
      perform public._idem_finish(v_staff.firebase_uid, v_key, 'card_register', v_req, v_result);
      return v_result;
    elsif c.status = 'active' then
      raise exception 'This card already belongs to another customer.';
    elsif c.status = 'blocked' then
      raise exception 'This card is blocked. Use a new card.';
    else
      raise exception 'This card was replaced earlier and cannot be used again. Use a new card.';
    end if;
  end if;

  if exists (select 1 from public.loyalty_cards where firebase_uid = v_uid and status = 'active') then
    raise exception 'This customer already has an active card. Use "Replace card" instead.';
  end if;

  insert into public.loyalty_cards (card_uid_hash, card_label, firebase_uid, issued_branch_id, issued_by)
  values (v_hash, public._card_label(v_hash), v_uid, v_staff.branch_id, v_staff.firebase_uid)
  returning * into c;
  insert into public.loyalty_card_events (card_id, event, staff_uid, branch_id)
  values (c.id, 'registered', v_staff.firebase_uid, v_staff.branch_id);
  perform public._sync_profile_card_label(v_uid);
  perform public.notify_customer(v_uid, 'loyalty', 'Loyalty card linked',
    'Your Golden Kernel Club card ' || c.card_label || ' is now linked to your account.');
  perform public._write_audit(v_staff.firebase_uid, v_staff.branch_id, 'loyalty.card_register', 'loyalty_card',
    c.id::text, jsonb_build_object('label', c.card_label, 'customer', v_uid));

  v_result := public._card_json(c);
  perform public._idem_finish(v_staff.firebase_uid, v_key, 'card_register', v_req, v_result);
  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Replace (lost / damaged): the old card stops working, the points stay.
-- -----------------------------------------------------------------------------
create or replace function public.staff_replace_loyalty_card(
  p_customer_uid text,
  p_new_card_uid text,
  p_reason text,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_norm text := public._normalize_card_uid(p_new_card_uid);
  v_hash text;
  v_uid text := trim(coalesce(p_customer_uid, ''));
  v_reason text := trim(coalesce(p_reason, ''));
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_req jsonb;
  v_prev jsonb;
  v_old public.loyalty_cards;
  c public.loyalty_cards;
  v_result jsonb;
begin
  v_staff := public._require_staff();
  if v_norm is null then
    raise exception 'Tap the new card on the reader (the card number was not readable).';
  end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 200 then
    raise exception 'Give a reason for the replacement (3 to 200 characters), e.g. "lost".';
  end if;
  v_hash := public._card_uid_hash(v_norm);
  v_req := jsonb_build_object('h', v_hash, 'u', v_uid, 'r', v_reason);
  v_prev := public._idem_begin(v_staff.firebase_uid, v_key, 'card_replace', v_req);
  if v_prev is not null then return v_prev; end if;

  perform pg_advisory_xact_lock(hashtextextended('card:' || v_hash, 0));
  perform pg_advisory_xact_lock(hashtextextended('card-owner:' || v_uid, 0));

  -- The card being replaced: the active one, else the most recently blocked one.
  select * into v_old from public.loyalty_cards
  where firebase_uid = v_uid and status in ('active', 'blocked')
  order by (status = 'active') desc, issued_at desc
  limit 1
  for update;
  if v_old.id is null then
    raise exception 'This customer has no card to replace. Use "Register card" instead.';
  end if;

  select * into c from public.loyalty_cards where card_uid_hash = v_hash;
  if c.id is not null then
    if c.id = v_old.id then raise exception 'That is the same card. Tap the NEW card.'; end if;
    raise exception 'This card is already registered. Use a new, unused card.';
  end if;

  update public.loyalty_cards
     set status = 'replaced', updated_at = now(),
         blocked_at = coalesce(blocked_at, now()),
         block_reason = coalesce(block_reason, v_reason)
   where id = v_old.id;

  insert into public.loyalty_cards (card_uid_hash, card_label, firebase_uid, issued_branch_id, issued_by)
  values (v_hash, public._card_label(v_hash), v_uid, v_staff.branch_id, v_staff.firebase_uid)
  returning * into c;
  update public.loyalty_cards set replaced_by = c.id where id = v_old.id;

  insert into public.loyalty_card_events (card_id, event, staff_uid, branch_id, note) values
    (v_old.id, 'replaced', v_staff.firebase_uid, v_staff.branch_id, v_reason || ' → ' || c.card_label),
    (c.id, 'registered', v_staff.firebase_uid, v_staff.branch_id, 'Replaces ' || v_old.card_label);
  perform public._sync_profile_card_label(v_uid);
  perform public.notify_customer(v_uid, 'loyalty', 'Loyalty card replaced',
    'Your old card ' || v_old.card_label || ' no longer works. Your new card is ' || c.card_label
    || '. Your points were kept.');
  perform public._write_audit(v_staff.firebase_uid, v_staff.branch_id, 'loyalty.card_replace', 'loyalty_card',
    c.id::text, jsonb_build_object('old', v_old.card_label, 'new', c.card_label, 'customer', v_uid, 'reason', v_reason));

  v_result := public._card_json(c);
  perform public._idem_finish(v_staff.firebase_uid, v_key, 'card_replace', v_req, v_result);
  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Block (any active staff: a customer reports a lost card) /
--    unblock (owner only: the card was found again).
-- -----------------------------------------------------------------------------
create or replace function public.staff_block_loyalty_card(p_card_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_reason text := trim(coalesce(p_reason, ''));
  c public.loyalty_cards;
begin
  v_staff := public._require_staff();
  if char_length(v_reason) < 3 or char_length(v_reason) > 200 then
    raise exception 'Give a reason for blocking (3 to 200 characters), e.g. "reported lost".';
  end if;
  select * into c from public.loyalty_cards where id = p_card_id for update;
  if c.id is null then raise exception 'That card could not be found.'; end if;
  if c.status = 'blocked' then return public._card_json(c); end if;      -- already done
  if c.status = 'replaced' then raise exception 'This card was already replaced; it no longer works.'; end if;

  update public.loyalty_cards
     set status = 'blocked', blocked_at = now(), block_reason = v_reason, updated_at = now()
   where id = c.id
  returning * into c;
  insert into public.loyalty_card_events (card_id, event, staff_uid, branch_id, note)
  values (c.id, 'blocked', v_staff.firebase_uid, v_staff.branch_id, v_reason);
  perform public._sync_profile_card_label(c.firebase_uid);
  perform public.notify_customer(c.firebase_uid, 'loyalty', 'Loyalty card blocked',
    'Your card ' || c.card_label || ' was blocked (' || v_reason || '). Your points are safe. '
    || 'Visit any branch for a replacement card.');
  perform public._write_audit(v_staff.firebase_uid, v_staff.branch_id, 'loyalty.card_block', 'loyalty_card',
    c.id::text, jsonb_build_object('label', c.card_label, 'customer', c.firebase_uid, 'reason', v_reason));
  return public._card_json(c);
end;
$$;

create or replace function public.owner_unblock_loyalty_card(p_card_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
  c public.loyalty_cards;
begin
  v_owner := public._require_owner();
  select * into c from public.loyalty_cards where id = p_card_id for update;
  if c.id is null then raise exception 'That card could not be found.'; end if;
  if c.status = 'active' then return public._card_json(c); end if;
  if c.status = 'replaced' then raise exception 'A replaced card cannot be turned back on.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('card-owner:' || c.firebase_uid, 0));
  if exists (select 1 from public.loyalty_cards where firebase_uid = c.firebase_uid and status = 'active') then
    raise exception 'This customer already has another active card.';
  end if;

  update public.loyalty_cards
     set status = 'active', blocked_at = null, block_reason = null, updated_at = now()
   where id = c.id
  returning * into c;
  insert into public.loyalty_card_events (card_id, event, staff_uid, branch_id)
  values (c.id, 'unblocked', v_owner.firebase_uid, v_owner.branch_id);
  perform public._sync_profile_card_label(c.firebase_uid);
  perform public.notify_customer(c.firebase_uid, 'loyalty', 'Loyalty card active again',
    'Your card ' || c.card_label || ' works again.');
  perform public._write_audit(v_owner.firebase_uid, null, 'loyalty.card_unblock', 'loyalty_card',
    c.id::text, jsonb_build_object('label', c.card_label, 'customer', c.firebase_uid));
  return public._card_json(c);
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Reads
-- -----------------------------------------------------------------------------
-- A customer's cards with history (staff who already found that customer).
create or replace function public.staff_customer_cards(p_customer_uid text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_staff();
  return coalesce((
    select jsonb_agg(public._card_json(c) || jsonb_build_object('events', (
             select coalesce(jsonb_agg(jsonb_build_object(
                      'event', e.event, 'note', e.note, 'at', e.created_at,
                      'by', coalesce(sm.full_name, e.staff_uid),
                      'branch', b.name) order by e.created_at, e.id), '[]'::jsonb)
             from public.loyalty_card_events e
             left join public.staff_members sm on sm.firebase_uid = e.staff_uid
             left join public.branches b on b.id = e.branch_id
             where e.card_id = c.id))
           order by (c.status = 'active') desc, c.issued_at desc)
    from public.loyalty_cards c
    where c.firebase_uid = p_customer_uid), '[]'::jsonb);
end;
$$;

-- Every card (owner only: it is a customer list).
create or replace function public.owner_list_loyalty_cards(
  p_query text default null,
  p_status text default null,
  p_limit int default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := lower(trim(coalesce(p_query, '')));
begin
  perform public._require_owner();
  return jsonb_build_object(
    'counts', (select jsonb_build_object(
                 'active', count(*) filter (where status = 'active'),
                 'blocked', count(*) filter (where status = 'blocked'),
                 'replaced', count(*) filter (where status = 'replaced'))
               from public.loyalty_cards),
    'cards', coalesce((
      select jsonb_agg(public._card_json(c) || jsonb_build_object(
               'points_balance', coalesce(la.points_balance, 0),
               'phone', cp.phone, 'email', cp.email) order by c.issued_at desc)
      from (select * from public.loyalty_cards c0
            where (p_status is null or p_status = '' or c0.status = p_status)
            order by c0.issued_at desc) c
      join public.customer_profiles cp on cp.firebase_uid = c.firebase_uid
      left join public.loyalty_accounts la on la.firebase_uid = c.firebase_uid
      where v_q = ''
         or lower(c.card_label) like '%' || v_q || '%'
         or lower(coalesce(cp.full_name, '')) like '%' || v_q || '%'
         or lower(coalesce(cp.email, '')) like '%' || v_q || '%'
         or coalesce(cp.phone, '') like '%' || v_q || '%'
      limit greatest(1, least(coalesce(p_limit, 200), 500))), '[]'::jsonb));
end;
$$;

-- The customer's own card (label + status) for the app.
create or replace function public.get_my_loyalty_card()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select (
    select jsonb_build_object('label', c.card_label, 'status', c.status, 'issued_at', c.issued_at,
                              'blocked_at', c.blocked_at)
    from public.loyalty_cards c
    where c.firebase_uid = public.current_firebase_uid()
    order by (c.status = 'active') desc, c.issued_at desc
    limit 1)
$$;

-- -----------------------------------------------------------------------------
-- 9. Grants
-- -----------------------------------------------------------------------------
revoke all on function public._trg_loyalty_card_events_append_only() from public, anon, authenticated;
revoke all on function public._card_json(public.loyalty_cards) from public, anon, authenticated;
revoke all on function public._sync_profile_card_label(text) from public, anon, authenticated;
revoke all on function public._migrate_legacy_rfid_cards() from public, anon, authenticated;

revoke all on function public.staff_lookup_card(text) from public, anon;
revoke all on function public.staff_lookup_customer(text) from public, anon;
revoke all on function public.staff_register_loyalty_card(text, text, text) from public, anon;
revoke all on function public.staff_replace_loyalty_card(text, text, text, text) from public, anon;
revoke all on function public.staff_block_loyalty_card(uuid, text) from public, anon;
revoke all on function public.owner_unblock_loyalty_card(uuid) from public, anon;
revoke all on function public.staff_customer_cards(text) from public, anon;
revoke all on function public.owner_list_loyalty_cards(text, text, int) from public, anon;
revoke all on function public.get_my_loyalty_card() from public, anon;

grant execute on function public.staff_lookup_card(text) to authenticated;
grant execute on function public.staff_lookup_customer(text) to authenticated;
grant execute on function public.staff_register_loyalty_card(text, text, text) to authenticated;
grant execute on function public.staff_replace_loyalty_card(text, text, text, text) to authenticated;
grant execute on function public.staff_block_loyalty_card(uuid, text) to authenticated;
grant execute on function public.owner_unblock_loyalty_card(uuid) to authenticated;
grant execute on function public.staff_customer_cards(text) to authenticated;
grant execute on function public.owner_list_loyalty_cards(text, text, int) to authenticated;
grant execute on function public.get_my_loyalty_card() to authenticated;

commit;
