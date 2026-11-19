-- =============================================================================
-- Melai Nuts — the loyalty PIN is checked wherever points are SPENT
-- =============================================================================
-- Builds on 20261119050000_rfid_reader_self_link_and_pos_points.sql (loyalty_pins,
-- _check_loyalty_pin: 5 wrong tries = 15-minute lock).
--
-- Before: the PIN was checked only at the counter (staff_create_pos_sale p_loyalty_pin).
-- A customer's own spends did not ask for it: points on an app / website order
-- (_place_order_core, 'order_redeem') and rewards in the app (redeem_reward).
--
-- Now, for a customer WHO SET A PIN, every spend of their points needs it:
--   * counter (POS): unchanged, staff_create_pos_sale checks p_loyalty_pin itself;
--   * their own app / website order with points, and redeem_reward: the client first calls
--     verify_my_loyalty_pin(pin) (same counter and lock as the counter), which gives a
--     single-use pass for 5 minutes; the spend uses it up. Without a pass the spend is
--     refused by a trigger on loyalty_transactions, so a direct RPC / REST call cannot skip it.
-- Customers WITHOUT a PIN: nothing changes (no pass is needed or looked at).
-- Earning, refunds, reversals and owner adjustments never need a PIN.
--
-- Additive and backward-compatible: one new table, one new function, one new trigger.
-- No existing function changes; place_order, sync_customer_cart, redeem_reward and
-- staff_create_pos_sale keep their parameters. A client that does not know about the PIN
-- yet gets a clear message ("Enter your loyalty PIN ...") only when a PIN holder spends points.
-- Open carts of PIN holders that already had "use points" on are switched off once, so no
-- cart prepared before this migration can skip the PIN (the customer turns it on again).
-- =============================================================================

begin;

create table if not exists public.loyalty_pin_passes (
  firebase_uid text primary key references public.customer_profiles(firebase_uid) on delete cascade,
  valid_until timestamptz not null
);
alter table public.loyalty_pin_passes enable row level security;
revoke all on public.loyalty_pin_passes from anon, authenticated;

-- The signed-in customer proves their PIN before spending points online.
-- '{ok: true}' | '{ok: true, reason: no_pin}' | '{ok: false, reason: wrong | locked, attempts_left, locked_until, message}'.
-- A wrong PIN is answered WITHOUT an error, so the failure counter is kept.
create or replace function public.verify_my_loyalty_pin(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v jsonb;
begin
  if v_uid is null then raise exception 'Please sign in again.'; end if;
  v := public._check_loyalty_pin(v_uid, p_pin);
  if (v ->> 'ok')::boolean then
    if coalesce(v ->> 'reason', '') <> 'no_pin' then
      insert into public.loyalty_pin_passes (firebase_uid, valid_until)
      values (v_uid, now() + interval '5 minutes')
      on conflict (firebase_uid) do update set valid_until = excluded.valid_until;
    end if;
    return v;
  end if;
  return v || jsonb_build_object('message', case v ->> 'reason'
    when 'locked' then 'Too many wrong PINs. Points can be used again in 15 minutes.'
    else 'Wrong loyalty PIN. ' || (v ->> 'attempts_left') || ' tries left.' end);
end;
$$;

-- Refuses a customer's own points spend without a fresh PIN pass (PIN holders only).
create or replace function public._trg_loyalty_spend_needs_pin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller text := public.current_firebase_uid();
  v_ok boolean;
begin
  if new.points >= 0 or new.type <> 'redeem' then return new; end if;
  -- Only the customer spending their OWN points. Staff (POS: staff_create_pos_sale checks the
  -- PIN itself), the owner (adjustments) and server jobs are someone else.
  if v_caller is null or v_caller <> new.firebase_uid then return new; end if;
  if exists (select 1 from public.staff_members where firebase_uid = v_caller and account_status = 'active') then
    return new;
  end if;
  if not exists (select 1 from public.loyalty_pins where firebase_uid = new.firebase_uid) then
    return new;
  end if;
  delete from public.loyalty_pin_passes
   where firebase_uid = new.firebase_uid and valid_until > now()
  returning true into v_ok;
  if coalesce(v_ok, false) then return new; end if;
  raise exception 'Enter your loyalty PIN to use your points.' using errcode = '42501', hint = 'loyalty_pin_required';
end;
$$;
drop trigger if exists loyalty_transactions_spend_needs_pin on public.loyalty_transactions;
create trigger loyalty_transactions_spend_needs_pin
  before insert on public.loyalty_transactions
  for each row execute function public._trg_loyalty_spend_needs_pin();

-- Carts prepared before this rule: "use points" off once for PIN holders (they turn it on
-- again and are asked for the PIN at checkout). Re-running changes nothing new.
update public.carts c
   set redeem_points = false, updated_at = now()
 where c.redeem_points
   and c.status = 'open'
   and exists (select 1 from public.loyalty_pins p where p.firebase_uid = c.firebase_uid)
   and not exists (select 1 from public.loyalty_pin_passes s where s.firebase_uid = c.firebase_uid);

revoke all on function public._trg_loyalty_spend_needs_pin() from public, anon, authenticated;
revoke all on function public.verify_my_loyalty_pin(text) from public, anon;
grant execute on function public.verify_my_loyalty_pin(text) to authenticated;

commit;
