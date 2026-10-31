-- =============================================================================
-- Melai Nuts — Migration 20261031052943: points are only earned on completion
-- =============================================================================
-- Run after 20261031045119_hitpay_payment_method_codes.sql. Idempotent.
--
-- Migration 20260928000000 moved earning to completion and dropped the
-- award-at-placement trigger, but orders_award_points is live again (schema.sql
-- still created it). So every order earned when placed, kept those points when
-- cancelled, and earned a second time when completed.
--
--  1. Drop the award-at-placement trigger.
--  2. Completion does not award an order that still holds points from that trigger.
--  3. Cancelling removes any points the order still holds. Only orders placed while
--     the old trigger was live can hold any.
--
-- This changes no existing balance. Past wrong balances are corrected separately
-- by supabase/repair/20261031_correct_double_loyalty_points.sql.
-- =============================================================================
begin;

-- 1. ---------------------------------------------------------------------------
drop trigger if exists orders_award_points on public.orders;
drop function if exists public.award_order_points();

-- 2. ---------------------------------------------------------------------------
-- The points an order currently holds: what it earned (source is null on rows from
-- the old trigger), less corrections and reversals posted against that order.
create or replace function public._order_points_held(p_order_id text)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(points), 0)::int
  from public.loyalty_transactions
  where order_id = p_order_id
    and ((type = 'earn' and coalesce(source, 'order_earn') = 'order_earn')
         or source in ('admin_adjust', 'order_clawback'));
$$;
revoke all on function public._order_points_held(text) from public, anon, authenticated;

create or replace function public.award_points_on_completion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.points_earned > 0 and not exists (
       select 1 from public.loyalty_transactions t
       where t.order_id = new.id and t.source = 'order_earn')
     and public._order_points_held(new.id) <= 0 then
    insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points)
    values (new.firebase_uid, new.points_earned, new.points_earned)
    on conflict (firebase_uid) do update
      set points_balance  = public.loyalty_accounts.points_balance  + excluded.points_balance,
          lifetime_points = public.loyalty_accounts.lifetime_points + excluded.lifetime_points;

    insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
    values (new.firebase_uid, 'earn', new.points_earned, 'Order ' || new.id, new.id, 'order_earn');
  end if;
  return new;
end;
$$;

-- 3. ---------------------------------------------------------------------------
create or replace function public.reverse_order_on_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line record;
  v_points int;
  v_voucher_id uuid;
  v_held int;
  v_take int;
begin
  -- Only undo orders that never reached the customer.
  if old.status in ('completed', 'refundRequested', 'refunded') then
    return new;
  end if;

  if new.branch_id is not null then
    for v_line in
      select product_id, variant_id, quantity from public.order_items
      where order_id = new.id and product_id is not null and variant_id is not null
    loop
      update public.branch_inventory
      set quantity = quantity + v_line.quantity
      where branch_id = new.branch_id
        and product_id = v_line.product_id
        and variant_id = v_line.variant_id;
    end loop;
  end if;

  select coalesce(-sum(points), 0) into v_points
  from public.loyalty_transactions
  where order_id = new.id and source = 'order_redeem';

  if v_points > 0 and not exists (
       select 1 from public.loyalty_transactions t
       where t.order_id = new.id and t.source = 'order_return') then
    insert into public.loyalty_accounts (firebase_uid, points_balance)
    values (new.firebase_uid, v_points)
    on conflict (firebase_uid) do update
      set points_balance = public.loyalty_accounts.points_balance + excluded.points_balance;

    insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
    values (new.firebase_uid, 'earn', v_points,
            'Points returned - order ' || new.id || ' cancelled', new.id, 'order_return');
  end if;

  -- Runs after the points spent on this order are returned above, and takes the
  -- balance no lower than zero, like a refund's reversal.
  v_held := public._order_points_held(new.id);
  if v_held > 0 then
    select least(points_balance, v_held) into v_take
    from public.loyalty_accounts where firebase_uid = new.firebase_uid for update;

    if coalesce(v_take, 0) > 0 then
      update public.loyalty_accounts
      set points_balance = points_balance - v_take,
          lifetime_points = greatest(lifetime_points - v_held, 0)
      where firebase_uid = new.firebase_uid;

      insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
      values (new.firebase_uid, 'redeem', -v_take,
              'Points removed - order ' || new.id || ' cancelled', new.id, 'order_clawback');
    end if;
  end if;

  delete from public.voucher_usage where order_id = new.id returning voucher_id into v_voucher_id;
  if v_voucher_id is not null then
    update public.vouchers set used_count = greatest(used_count - 1, 0) where id = v_voucher_id;
  end if;

  return new;
end;
$$;

commit;
