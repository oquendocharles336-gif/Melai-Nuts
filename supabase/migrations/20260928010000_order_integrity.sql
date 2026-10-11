-- =============================================================================
-- Melai Nuts — Migration 20260928010000
-- Database integrity: atomic checkout guarantees, state machines, constraints
-- =============================================================================
-- RUN ORDER: schema.sql -> 20260928000000_customer_security_hardening.sql
--            -> this file -> supabase/tests/*.sql
-- Idempotent and atomic (single transaction). If you ever re-run migration
-- 20260928000000, re-run this one afterwards.
--
-- CHECKOUT (place_order) is ONE database transaction: customer -> branch ->
-- products -> variants -> stock (row-locked) -> prices -> voucher -> loyalty ->
-- totals -> order -> items -> stock deduction -> payment -> loyalty ledger ->
-- voucher usage -> cart conversion. Any failure rolls ALL of it back (verified
-- by the failure-injection tests). This migration closes the remaining gaps:
--
--  1. Concurrent retries of the SAME checkout (double tap / flaky-network
--     retry) are serialised and all get the one real order, instead of the
--     losers getting a misleading "cart no longer available" error.
--  2. Defence in depth for ANY code path that creates orders (future staff POS,
--     admin tools): a deferred constraint guarantees at COMMIT that an order has
--     items, that the items add up to the subtotal, and that a payment exists
--     for exactly the order total. Column CHECKs pin the money arithmetic.
--  3. State machines: orders, payments and refunds can only move along valid
--     transitions (no cancelled -> completed, no un-paying, no completing an
--     unpaid order, no "out for delivery" on a pickup order).
--  4. Immutability: financial columns of orders/payments/refunds/order lines and
--     the loyalty ledger cannot be edited after the fact by ANY role.
--  5. A failing notification can no longer roll back a checkout (notifications
--     are non-critical side effects).
--  6. Variant <-> product pairing is enforced by composite foreign keys.
--  7. New functions are no longer executable by anon/authenticated by default
--     (the implicit PUBLIC grant is removed).
--  8. loyalty_ledger_drift view: reconciles every balance against its ledger.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Idempotent checkout wrapper (replaces the schema.sql definition)
-- -----------------------------------------------------------------------------
-- pg_advisory_xact_lock serialises concurrent calls carrying the same
-- (customer, key). The second caller waits for the first to commit, then finds
-- the finished order and returns it. The unique index on
-- orders(firebase_uid, idempotency_key) remains the hard backstop.
create or replace function public.place_order(
  p_cart_id uuid,
  p_is_delivery boolean,
  p_delivery_address_id uuid,
  p_payment_method text,
  p_customer_notes text,
  p_idempotency_key text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_existing_order_id text;
  v_order_id text;
begin
  if v_uid is null then raise exception 'You must be signed in to place this order.'; end if;

  -- Step 1: validate the customer.
  if not exists (select 1 from public.customer_profiles where firebase_uid = v_uid) then
    raise exception 'Your customer profile is not set up yet. Please sign in again.';
  end if;

  if v_key is not null then
    if length(v_key) > 200 then raise exception 'Invalid checkout reference.'; end if;
    perform pg_advisory_xact_lock(hashtextextended(v_uid || ':' || v_key, 0));
    select id into v_existing_order_id
    from public.orders
    where firebase_uid = v_uid and idempotency_key = v_key;
    if found then
      -- This checkout attempt already went through: hand back the same order
      -- without touching stock, loyalty, vouchers or the cart again.
      return v_existing_order_id;
    end if;
  end if;

  -- Steps 2-16 (branch, products, variants, stock, prices, voucher, loyalty,
  -- totals, order, items, stock deduction, payment, ledger, cart) run inside
  -- the 5-argument core, in this same transaction.
  v_order_id := public.place_order(p_cart_id, p_is_delivery, p_delivery_address_id, p_payment_method, p_customer_notes);

  if v_key is not null then
    update public.orders set idempotency_key = v_key where id = v_order_id;
  end if;

  return v_order_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Constraints
-- -----------------------------------------------------------------------------
-- Added NOT VALID so legacy rows never block the migration; VALIDATE is then
-- attempted, and a warning (not a failure) is raised if old data violates it.
-- New and updated rows are checked either way.

create or replace function pg_temp.add_check(p_table regclass, p_name text, p_expr text)
returns void language plpgsql as $$
begin
  if not exists (select 1 from pg_constraint where conname = p_name and conrelid = p_table) then
    execute format('alter table %s add constraint %I check (%s) not valid', p_table, p_name, p_expr);
  end if;
  begin
    execute format('alter table %s validate constraint %I', p_table, p_name);
  exception when others then
    raise warning 'Constraint % on % is enforced for new rows but existing rows violate it: %', p_name, p_table, sqlerrm;
  end;
end $$;

-- The money arithmetic of an order is a database invariant, not a client promise.
select pg_temp.add_check('public.orders', 'orders_amounts_nonnegative',
  'subtotal >= 0 and discount >= 0 and delivery_fee >= 0 and total >= 0');
select pg_temp.add_check('public.orders', 'orders_discount_within_subtotal',
  'discount <= subtotal');
select pg_temp.add_check('public.orders', 'orders_total_consistent',
  'total = greatest(0, subtotal - discount + delivery_fee)');
select pg_temp.add_check('public.order_items', 'order_items_price_nonnegative', 'unit_price >= 0');
select pg_temp.add_check('public.payments', 'payments_amount_nonnegative', 'amount >= 0');
select pg_temp.add_check('public.refund_requests', 'refund_requests_amount_positive', 'amount > 0');
select pg_temp.add_check('public.refund_items', 'refund_items_price_nonnegative', 'unit_price >= 0');
select pg_temp.add_check('public.vouchers', 'vouchers_used_within_limit',
  'usage_limit is null or used_count <= usage_limit');

-- A variant belongs to exactly one product; every table that names both must
-- name a matching pair (a typo in staff tooling can't sell product A as B's variant).
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'product_variants_id_product_key') then
    alter table public.product_variants
      add constraint product_variants_id_product_key unique (id, product_id);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'branch_inventory_variant_product_fk') then
    alter table public.branch_inventory
      add constraint branch_inventory_variant_product_fk
      foreign key (variant_id, product_id) references public.product_variants (id, product_id)
      on delete cascade not valid;
  end if;
  begin
    alter table public.branch_inventory validate constraint branch_inventory_variant_product_fk;
  exception when others then
    raise warning 'branch_inventory has rows whose variant belongs to a different product: %', sqlerrm;
  end;

  -- ON DELETE SET NULL (column list) needs PostgreSQL 15+, which Supabase uses.
  if not exists (select 1 from pg_constraint where conname = 'cart_items_variant_product_fk') then
    begin
      execute 'alter table public.cart_items
               add constraint cart_items_variant_product_fk
               foreign key (variant_id, product_id) references public.product_variants (id, product_id)
               on delete set null (variant_id) not valid';
    exception when others then
      raise warning 'cart_items_variant_product_fk not created: %', sqlerrm;
    end;
  end if;
  begin
    alter table public.cart_items validate constraint cart_items_variant_product_fk;
  exception when others then
    null; -- constraint absent, or legacy rows violate it; new rows are still checked when present
  end;
end $$;

-- -----------------------------------------------------------------------------
-- 3. An order can never exist half-created (deferred to COMMIT)
-- -----------------------------------------------------------------------------
-- Deferred so the order row, its lines and its payment can be inserted in any
-- order within the transaction; checked once, when the transaction commits.
create or replace function public.check_order_integrity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
  v_items numeric;
begin
  select count(*), coalesce(sum(quantity * unit_price), 0)
  into v_count, v_items
  from public.order_items where order_id = new.id;

  if v_count = 0 then
    raise exception 'Order % must have at least one item.', new.id;
  end if;
  if v_items <> new.subtotal then
    raise exception 'Order % subtotal (%) does not match its items (%).', new.id, new.subtotal, v_items;
  end if;
  if not exists (select 1 from public.payments p where p.order_id = new.id and p.amount = new.total) then
    raise exception 'Order % must have a payment record for exactly its total (%).', new.id, new.total;
  end if;
  return null;
end;
$$;

drop trigger if exists orders_integrity_check on public.orders;
create constraint trigger orders_integrity_check
  after insert on public.orders
  deferrable initially deferred
  for each row execute function public.check_order_integrity();

-- -----------------------------------------------------------------------------
-- 4. State machines (apply to EVERY writer, including staff and service role)
-- -----------------------------------------------------------------------------

-- Orders: pending -> confirmed -> preparing -> (readyForPickup | outForDelivery)
-- -> completed, cancellable while active; completed <-> refundRequested ->
-- refunded. cancelled and refunded are final. Completion needs a confirmed
-- payment (or a zero total), which is what makes loyalty points trustworthy.
create or replace function public.enforce_order_transition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old int;
  v_new int;
begin
  if new.status = old.status then return new; end if;

  if old.status in ('cancelled', 'refunded') then
    raise exception 'Order % is % and can no longer change status.', old.id, old.status;
  end if;

  if old.status = 'completed' then
    if new.status <> 'refundRequested' then
      raise exception 'A completed order can only move to refundRequested (not %).', new.status;
    end if;
    return new;
  end if;

  if old.status = 'refundRequested' then
    if new.status not in ('refunded', 'completed') then
      raise exception 'A refund-requested order can only become refunded or return to completed (not %).', new.status;
    end if;
    return new;
  end if;

  -- From here `old` is an active (unfulfilled) status.
  if new.status in ('refundRequested', 'refunded') then
    raise exception 'Only a completed order can be refunded.';
  end if;
  if new.status = 'cancelled' then return new; end if;
  if new.status = 'readyForPickup' and new.is_delivery then
    raise exception 'A delivery order cannot be ready for pickup.';
  end if;
  if new.status = 'outForDelivery' and not new.is_delivery then
    raise exception 'A pickup order cannot be out for delivery.';
  end if;

  v_old := case old.status when 'pending' then 1 when 'confirmed' then 2 when 'preparing' then 3
                           when 'readyForPickup' then 4 when 'outForDelivery' then 4 end;
  v_new := case new.status when 'pending' then 1 when 'confirmed' then 2 when 'preparing' then 3
                           when 'readyForPickup' then 4 when 'outForDelivery' then 4 when 'completed' then 5 end;
  if v_new is null or v_new <= v_old then
    raise exception 'Order status cannot move from % to %.', old.status, new.status;
  end if;

  if new.status = 'completed' and new.total > 0 and not exists (
       select 1 from public.payments p where p.order_id = new.id and p.status = 'success') then
    raise exception 'Order % cannot be completed until its payment is confirmed.', new.id;
  end if;

  return new;
end;
$$;

drop trigger if exists orders_enforce_transition on public.orders;
create trigger orders_enforce_transition
  before update of status on public.orders
  for each row execute function public.enforce_order_transition();

-- Payments: pending -> processing -> success | failed; failed may retry;
-- success -> refunded; refunded is final.
create or replace function public.enforce_payment_transition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = old.status then return new; end if;
  if not (
       (old.status = 'pending'    and new.status in ('processing', 'success', 'failed'))
    or (old.status = 'processing' and new.status in ('success', 'failed'))
    or (old.status = 'failed'     and new.status in ('pending', 'processing'))
    or (old.status = 'success'    and new.status = 'refunded')
  ) then
    raise exception 'Payment % cannot move from % to %.', old.id, old.status, new.status;
  end if;
  return new;
end;
$$;

drop trigger if exists payments_enforce_transition on public.payments;
create trigger payments_enforce_transition
  before update of status on public.payments
  for each row execute function public.enforce_payment_transition();

-- Refunds: pending -> approved | rejected; approved -> processing | completed
-- | rejected; processing -> completed | rejected. completed/rejected are final.
create or replace function public.enforce_refund_transition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = old.status then return new; end if;
  if not (
       (old.status = 'pending'    and new.status in ('approved', 'rejected'))
    or (old.status = 'approved'   and new.status in ('processing', 'completed', 'rejected'))
    or (old.status = 'processing' and new.status in ('completed', 'rejected'))
  ) then
    raise exception 'Refund % cannot move from % to %.', old.id, old.status, new.status;
  end if;
  return new;
end;
$$;

drop trigger if exists refund_requests_enforce_transition on public.refund_requests;
create trigger refund_requests_enforce_transition
  before update of status on public.refund_requests
  for each row execute function public.enforce_refund_transition();

-- -----------------------------------------------------------------------------
-- 5. Immutability of financial facts
-- -----------------------------------------------------------------------------
create or replace function public.forbid_financial_edits()
returns trigger
language plpgsql
as $$
begin
  if tg_table_name = 'orders' then
    if (new.firebase_uid, new.branch_id, new.is_delivery, new.subtotal, new.discount,
        new.delivery_fee, new.total, new.payment_method, new.points_earned)
       is distinct from
       (old.firebase_uid, old.branch_id, old.is_delivery, old.subtotal, old.discount,
        old.delivery_fee, old.total, old.payment_method, old.points_earned) then
      raise exception 'The financial details of order % cannot be changed after it is placed.', old.id;
    end if;
  elsif tg_table_name = 'payments' then
    if (new.order_id, new.firebase_uid, new.amount, new.method)
       is distinct from (old.order_id, old.firebase_uid, old.amount, old.method) then
      raise exception 'The amount, method and owner of payment % cannot be changed.', old.id;
    end if;
  elsif tg_table_name = 'refund_requests' then
    if (new.order_id, new.firebase_uid, new.amount, new.payment_method)
       is distinct from (old.order_id, old.firebase_uid, old.amount, old.payment_method) then
      raise exception 'The order, owner and amount of refund % cannot be changed.', old.id;
    end if;
  elsif tg_table_name = 'order_items' then
    -- product_id / variant_id may still be nulled by ON DELETE SET NULL.
    if (new.order_id, new.product_name, new.variant_label, new.quantity, new.unit_price)
       is distinct from (old.order_id, old.product_name, old.variant_label, old.quantity, old.unit_price) then
      raise exception 'Order lines cannot be edited after the order is placed.';
    end if;
  elsif tg_table_name = 'refund_items' then
    raise exception 'Refund lines cannot be edited.';
  end if;
  return new;
end;
$$;

drop trigger if exists orders_forbid_financial_edits on public.orders;
create trigger orders_forbid_financial_edits before update on public.orders
  for each row execute function public.forbid_financial_edits();
drop trigger if exists payments_forbid_financial_edits on public.payments;
create trigger payments_forbid_financial_edits before update on public.payments
  for each row execute function public.forbid_financial_edits();
drop trigger if exists refund_requests_forbid_financial_edits on public.refund_requests;
create trigger refund_requests_forbid_financial_edits before update on public.refund_requests
  for each row execute function public.forbid_financial_edits();
drop trigger if exists order_items_forbid_financial_edits on public.order_items;
create trigger order_items_forbid_financial_edits before update on public.order_items
  for each row execute function public.forbid_financial_edits();
drop trigger if exists refund_items_forbid_financial_edits on public.refund_items;
create trigger refund_items_forbid_financial_edits before update on public.refund_items
  for each row execute function public.forbid_financial_edits();

-- The loyalty ledger is append-only: corrections are new rows, never edits.
create or replace function public.forbid_ledger_rewrite()
returns trigger
language plpgsql
as $$
begin
  raise exception 'The loyalty ledger is append-only; post a correcting entry instead.';
end;
$$;

drop trigger if exists loyalty_transactions_append_only on public.loyalty_transactions;
create trigger loyalty_transactions_append_only
  before update or delete on public.loyalty_transactions
  for each row execute function public.forbid_ledger_rewrite();

-- -----------------------------------------------------------------------------
-- 6. Non-critical side effects must never abort a critical transaction
-- -----------------------------------------------------------------------------
create or replace function public.notify_on_order_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if tg_op = 'INSERT' then
      perform public.notify_customer(new.firebase_uid, 'order', 'Order placed',
        'Your order ' || new.id || ' has been received.');
    elsif new.status is distinct from old.status then
      perform public.notify_customer(new.firebase_uid, 'order', 'Order ' || new.id || ' updated',
        'Status changed to ' || new.status || '.');
    end if;
  exception when others then
    raise warning 'order notification for % failed: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create or replace function public.notify_on_refund_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if tg_op = 'INSERT' then
      perform public.notify_customer(new.firebase_uid, 'refund', 'Refund request submitted',
        'Request ' || new.id || ' for order ' || new.order_id || ' is pending review.');
    elsif new.status is distinct from old.status then
      perform public.notify_customer(new.firebase_uid, 'refund', 'Refund ' || new.id || ' updated',
        'Status changed to ' || new.status || '.');
    end if;
  exception when others then
    raise warning 'refund notification for % failed: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Fail-closed function privileges for FUTURE functions
-- -----------------------------------------------------------------------------
-- PostgreSQL grants EXECUTE to PUBLIC on every new function, and anon /
-- authenticated inherit PUBLIC. Removing that default means a function added
-- later is private until it is explicitly granted.
alter default privileges revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

-- Everything this migration created is internal (trigger functions): make sure
-- none is callable by client roles.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('check_order_integrity', 'enforce_order_transition', 'enforce_payment_transition',
                        'enforce_refund_transition', 'forbid_financial_edits', 'forbid_ledger_rewrite',
                        'notify_on_order_status', 'notify_on_refund_status')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 8. Reconciliation: every loyalty balance must equal the sum of its ledger.
--    Any row returned means points were changed outside the ledger.
--    No client role is granted access (default privileges are revoked).
-- -----------------------------------------------------------------------------
create or replace view public.loyalty_ledger_drift as
select a.firebase_uid,
       a.points_balance,
       coalesce(sum(t.points), 0)::int as ledger_total,
       a.points_balance - coalesce(sum(t.points), 0)::int as drift
from public.loyalty_accounts a
left join public.loyalty_transactions t on t.firebase_uid = a.firebase_uid
group by a.firebase_uid, a.points_balance
having a.points_balance <> coalesce(sum(t.points), 0);

revoke all on public.loyalty_ledger_drift from anon, authenticated;

commit;
