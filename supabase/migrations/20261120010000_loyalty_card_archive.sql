-- =============================================================================
-- Melai Nuts — loyalty card ARCHIVE (blocked or replaced cards)
-- =============================================================================
-- Builds on 20261011000000_loyalty_cards.sql and 20261119050000_rfid_reader_self_link_and_pos_points.sql.
--
-- A card that is blocked or replaced ("retired") is in the archive. On the owner website
-- (Loyalty Cards > Archive) the owner can:
--   * Re-activate it   owner_reactivate_archived_card(card)   (only while the customer has
--                      no other active card: still one active card per customer)
--   * Delete it        owner_delete_archived_card(card, label) (the label typed again is the
--                      confirm step; the card and its history are removed for good)
-- An archived card that is not re-activated within 30 days is deleted automatically by
-- purge_expired_archived_loyalty_cards() (schedule it once with pg_cron, see the end).
-- Points belong to the customer's loyalty account, never to a card: nothing here touches
-- loyalty_accounts or loyalty_transactions.
--
-- Additive and backward-compatible:
--   * one new column, loyalty_cards.archived_at (null for active cards);
--   * a trigger keeps it in step with status, so the existing block / replace / unblock
--     functions, the card readers and the POS work exactly as before;
--   * the history table stays append-only; only the owner delete / the 30-day purge may
--     remove a deleted card's own history rows (transaction-local switch);
--   * new functions only; no existing function changes signature or behaviour.
-- Existing blocked / replaced cards get archived_at = the time this migration first runs,
-- so each gets the full 30 days from the deploy (none is deleted the moment it lands).
-- =============================================================================

begin;

alter table public.loyalty_cards add column if not exists archived_at timestamptz;

update public.loyalty_cards
   set archived_at = now()
 where status in ('blocked', 'replaced') and archived_at is null;

create index if not exists loyalty_cards_archived_idx
  on public.loyalty_cards (archived_at) where (archived_at is not null);

-- In the archive while blocked or replaced; out of it when active again.
create or replace function public._trg_loyalty_card_archive_stamp()
returns trigger
language plpgsql
as $$
begin
  if new.status in ('blocked', 'replaced') then
    if tg_op = 'INSERT' or old.status = 'active' or new.archived_at is null then
      new.archived_at := coalesce(case when tg_op = 'UPDATE' and old.status <> 'active' then old.archived_at end, now());
    end if;
  else
    new.archived_at := null;
  end if;
  return new;
end;
$$;
drop trigger if exists loyalty_cards_archive_stamp on public.loyalty_cards;
create trigger loyalty_cards_archive_stamp
  before insert or update of status on public.loyalty_cards
  for each row execute function public._trg_loyalty_card_archive_stamp();

-- History stays append-only. The one exception: the rows of a card being deleted by
-- owner_delete_archived_card / purge_expired_archived_loyalty_cards (they set the switch
-- for their own transaction only).
create or replace function public._trg_loyalty_card_events_append_only()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('melai.loyalty_card_purge', true), '') = 'on' then
    return old;
  end if;
  raise exception 'Loyalty card history cannot be changed or deleted.';
end;
$$;

-- Removes one archived card for good (caller has checked the rights). Returns the label.
create or replace function public._delete_archived_card(p_card public.loyalty_cards, p_actor text, p_why text)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('melai.loyalty_card_purge', 'on', true);
  delete from public.loyalty_cards where id = p_card.id and status in ('blocked', 'replaced');
  perform set_config('melai.loyalty_card_purge', '', true);
  perform public._sync_profile_card_label(p_card.firebase_uid);
  perform public._write_audit(p_actor, null, 'loyalty.card_deleted', 'loyalty_card', p_card.id::text,
    jsonb_build_object('label', p_card.card_label, 'customer', p_card.firebase_uid, 'status', p_card.status,
                       'archived_at', p_card.archived_at, 'why', p_why));
  return p_card.card_label;
end;
$$;

-- -----------------------------------------------------------------------------
-- Owner: the archive list
-- -----------------------------------------------------------------------------
create or replace function public.owner_archived_loyalty_cards(p_limit int default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_owner();
  return coalesce((
    select jsonb_agg(public._card_json(c) || jsonb_build_object(
             'archived_at', c.archived_at,
             'deletes_at', c.archived_at + interval '30 days',
             'days_left', greatest(0, ceil(extract(epoch from (c.archived_at + interval '30 days' - now())) / 86400)::int),
             'points_balance', coalesce(la.points_balance, 0),
             'email', cp.email,
             'has_active_card', exists (select 1 from public.loyalty_cards a
                                        where a.firebase_uid = c.firebase_uid and a.status = 'active'))
           order by c.archived_at, c.id)
    from (select * from public.loyalty_cards
          where status in ('blocked', 'replaced') and archived_at is not null
          order by archived_at
          limit greatest(1, least(coalesce(p_limit, 200), 500))) c
    join public.customer_profiles cp on cp.firebase_uid = c.firebase_uid
    left join public.loyalty_accounts la on la.firebase_uid = c.firebase_uid), '[]'::jsonb);
end;
$$;

-- -----------------------------------------------------------------------------
-- Owner: re-activate (blocked or replaced -> active)
-- -----------------------------------------------------------------------------
create or replace function public.owner_reactivate_archived_card(p_card_id uuid)
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
  if c.id is null then raise exception 'That card could not be found. It may have been deleted already.'; end if;
  if c.status = 'active' then return public._card_json(c); end if;
  perform pg_advisory_xact_lock(hashtextextended('card-owner:' || c.firebase_uid, 0));
  if exists (select 1 from public.loyalty_cards where firebase_uid = c.firebase_uid and status = 'active') then
    raise exception 'This customer already has another active card. Block that card first, then re-activate this one.';
  end if;

  update public.loyalty_cards
     set status = 'active', blocked_at = null, block_reason = null, updated_at = now()
   where id = c.id
  returning * into c;
  insert into public.loyalty_card_events (card_id, event, staff_uid, branch_id, note)
  values (c.id, 'unblocked', v_owner.firebase_uid, v_owner.branch_id, 'Re-activated from the archive');
  perform public._sync_profile_card_label(c.firebase_uid);
  perform public.notify_customer(c.firebase_uid, 'loyalty', 'Loyalty card active again',
    'Your card ' || c.card_label || ' works again.');
  perform public._write_audit(v_owner.firebase_uid, null, 'loyalty.card_reactivate', 'loyalty_card',
    c.id::text, jsonb_build_object('label', c.card_label, 'customer', c.firebase_uid));
  return public._card_json(c);
end;
$$;

-- -----------------------------------------------------------------------------
-- Owner: delete for good. p_confirm_label must be the card's label (the confirm step).
-- -----------------------------------------------------------------------------
create or replace function public.owner_delete_archived_card(p_card_id uuid, p_confirm_label text)
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
  if c.id is null then raise exception 'That card could not be found. It may have been deleted already.'; end if;
  if c.status = 'active' then
    raise exception 'An active card cannot be deleted. Block it first; it then moves to the archive.';
  end if;
  if upper(trim(coalesce(p_confirm_label, ''))) <> upper(c.card_label) then
    raise exception 'Type the card label (%) to confirm the deletion.', c.card_label;
  end if;
  perform public._delete_archived_card(c, v_owner.firebase_uid, 'owner');
  return jsonb_build_object('deleted', true, 'label', c.card_label, 'firebase_uid', c.firebase_uid);
end;
$$;

-- -----------------------------------------------------------------------------
-- The 30-day clean-up (pg_cron). Returns how many cards were deleted.
-- -----------------------------------------------------------------------------
create or replace function public.purge_expired_archived_loyalty_cards()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.loyalty_cards;
  n int := 0;
begin
  for c in
    select * from public.loyalty_cards
     where status in ('blocked', 'replaced') and archived_at is not null
       and archived_at < now() - interval '30 days'
     order by archived_at
     limit 500
     for update skip locked
  loop
    perform public._delete_archived_card(c, 'system', 'archived for 30 days');
    n := n + 1;
  end loop;
  return n;
end;
$$;

revoke all on function public._trg_loyalty_card_archive_stamp() from public, anon, authenticated;
revoke all on function public._delete_archived_card(public.loyalty_cards, text, text) from public, anon, authenticated;
revoke all on function public.purge_expired_archived_loyalty_cards() from public, anon, authenticated;
revoke all on function public.owner_archived_loyalty_cards(int) from public, anon;
revoke all on function public.owner_reactivate_archived_card(uuid) from public, anon;
revoke all on function public.owner_delete_archived_card(uuid, text) from public, anon;
grant execute on function public.owner_archived_loyalty_cards(int) to authenticated;
grant execute on function public.owner_reactivate_archived_card(uuid) to authenticated;
grant execute on function public.owner_delete_archived_card(uuid, text) to authenticated;

commit;

-- After deploying, schedule the clean-up once (Supabase SQL editor, pg_cron enabled):
--   select cron.schedule('melai-loyalty-card-archive-purge', '17 3 * * *',
--                        $$ select public.purge_expired_archived_loyalty_cards() $$);
