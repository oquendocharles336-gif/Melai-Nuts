-- =============================================================================
-- Melai Nuts — Migration 20261027000000: code-review fixes
-- =============================================================================
-- Idempotent (create or replace / if not exists), one transaction. Safe to run
-- more than once and on a database that already holds real data.
--
--   1. POS sales: an idempotency key is tied to the staff member and to the
--      exact request. A retry with the same key and the same request returns
--      the recorded sale (already_recorded = true); the same key with a
--      different request (customer, items, branch, method, reference) is
--      refused instead of creating a second sale or returning the wrong one.
--   2. HitPay refunds: staff_get_gateway_refund_attempt finds a pending attempt
--      by its id (same staff check as the other refund functions), so the
--      Edge Function can re-check an attempt without a HitPay refund id.
--   3. HitPay checkout links: claim_gateway_checkout locks the payment row so
--      two "Pay now" taps cannot create two payment requests, and remembers
--      when the link was made so expired links are not reused.
--   4. branch_inventory.is_carried: "this branch sells this item" no longer
--      depends on whether a stock row exists (20261026 created a row for every
--      product at every branch).
--   5. branches.daily_sales_target is not readable by signed-out users or
--      customers.
--   6. owner_delete_driver: undo a delivery account whose creation failed.
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1. POS idempotency: key per staff member + request fingerprint
-- -----------------------------------------------------------------------------
alter table public.pos_sales add column if not exists idempotency_key text;
alter table public.pos_sales add column if not exists request_fingerprint text;
create unique index if not exists pos_sales_staff_idempotency_key
  on public.pos_sales (staff_uid, idempotency_key)
  where idempotency_key is not null;

-- What makes two POS requests "the same sale". Items are summed per variant and
-- sorted, so the order of the lines does not matter. Cash received is left out
-- on purpose: correcting the cash amount on a retry is still the same sale.
create or replace function public._pos_sale_fingerprint(
  p_branch_id uuid,
  p_items jsonb,
  p_payment_method text,
  p_customer_uid text,
  p_payment_reference text
)
returns text
language sql
immutable
set search_path = public
as $$
  select md5(concat_ws('|',
    coalesce(p_branch_id::text, ''),
    coalesce(lower(trim(p_payment_method)), ''),
    coalesce(p_customer_uid, ''),
    coalesce(p_payment_reference, ''),
    coalesce((
      select string_agg(s.variant_id || 'x' || s.qty::text, ',' order by s.variant_id)
      from (
        select lower(trim(e ->> 'variant_id')) as variant_id,
               sum(case when (e ->> 'quantity') ~ '^-?[0-9]+$' then (e ->> 'quantity')::bigint else 0 end) as qty
        from jsonb_array_elements(case when jsonb_typeof(p_items) = 'array' then p_items else '[]'::jsonb end) e
        group by 1
      ) s
    ), '')
  ));
$$;
revoke all on function public._pos_sale_fingerprint(uuid, jsonb, text, text, text) from public, anon, authenticated;

-- Rings up a sale. Prices and stock are decided HERE from the catalog and
-- branch_inventory — the client only says which variants and how many.
-- p_items: [{"variant_id": "<uuid>", "quantity": 2}, ...]
-- p_payment_method: 'cash' | 'gcash' | 'card'. Cash needs p_cash_received;
-- GCash/card need the terminal / wallet reference number.
-- p_idempotency_key: one key per sale attempt. Replays are found by staff
-- member + key (NOT by customer), and must carry the same request.
create or replace function public.staff_create_pos_sale(
  p_branch_id uuid,
  p_items jsonb,
  p_payment_method text,
  p_payment_reference text default null,
  p_cash_received numeric default null,
  p_customer_uid text default null,
  p_idempotency_key text default null
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
  v_fingerprint text;
  v_branch_name text;
  v_existing text;
  v_existing_fp text;
  v_line record;
  v_var record;
  v_avail int;
  v_subtotal numeric := 0;
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
    -- Keyed by the STAFF member, not the customer: attaching a loyalty
    -- customer on a retry must not turn the retry into a second sale.
    perform pg_advisory_xact_lock(hashtextextended('pos:' || v_staff.firebase_uid || ':' || v_key, 0));
    select ps.order_id, ps.request_fingerprint into v_existing, v_existing_fp
    from public.pos_sales ps
    where ps.staff_uid = v_staff.firebase_uid and ps.idempotency_key = v_key;
    if not found then
      -- Sales recorded before this migration kept the key on the order only.
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
        select jsonb_build_object('order_id', o.id, 'total', o.total, 'points_earned', o.points_earned,
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

  -- Validate every line and lock its stock row (variant order = lock order).
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

  if v_code = 'cash' then
    if p_cash_received is null or p_cash_received < v_subtotal then
      raise exception 'The cash received is less than the total.';
    end if;
    v_change := p_cash_received - v_subtotal;
  end if;

  perform set_config('app.pos_sale', '1', true);

  insert into public.orders
    (firebase_uid, branch_id, branch_name, is_delivery, subtotal, discount, delivery_fee, total,
     payment_method, idempotency_key)
  values (v_uid, p_branch_id, v_branch_name, false, v_subtotal, 0, 0, v_subtotal, v_label, v_key)
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
    -- The sync trigger takes these units out of the soonest-expiring batches.
    update public.branch_inventory set quantity = quantity - v_line.qty
    where branch_id = p_branch_id and variant_id = v_line.variant_id;
  end loop;

  insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number)
  values (v_order_id, v_uid, v_code, 'pending', v_subtotal, coalesce(v_ref, v_order_id))
  returning id into v_payment_id;

  insert into public.pos_sales (order_id, branch_id, staff_uid, staff_name, payment_reference, cash_received, change_given,
                                idempotency_key, request_fingerprint)
  values (v_order_id, p_branch_id, v_staff.firebase_uid, v_staff.full_name, v_ref,
          case when v_code = 'cash' then p_cash_received end,
          case when v_code = 'cash' then v_change end,
          v_key, v_fingerprint);

  -- Money is taken at the counter, so the sale is paid and handed over now.
  update public.payments set status = 'success' where id = v_payment_id;
  update public.orders set status = 'completed' where id = v_order_id;

  select count(*) into v_count from public.order_items where order_id = v_order_id;
  return (
    select jsonb_build_object('order_id', o.id, 'total', o.total, 'points_earned', o.points_earned,
                              'payment_id', v_payment_id, 'change', v_change, 'line_count', v_count,
                              'already_recorded', false)
    from public.orders o where o.id = v_order_id
  );
end;
$$;
revoke all on function public.staff_create_pos_sale(uuid, jsonb, text, text, numeric, text, text) from public, anon;
grant execute on function public.staff_create_pos_sale(uuid, jsonb, text, text, numeric, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. HitPay refund check: find an attempt by its id (same staff check)
-- -----------------------------------------------------------------------------
-- The hitpay-refund Edge Function re-checks a pending attempt with only its id.
-- Returns null when the attempt does not exist; raises when the caller may not
-- review refunds for that order's branch (like staff_refund_gateway_attempts).
create or replace function public.staff_gateway_refund_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a public.refund_gateway_attempts;
  v_branch uuid;
begin
  select * into a from public.refund_gateway_attempts where id = p_attempt_id;
  if a.id is null then
    -- Same check as for a real attempt, so "not found" tells nothing to non-staff.
    perform public._require_staff(null, 'refunds');
    return null;
  end if;
  select o.branch_id into v_branch from public.orders o where o.id = a.order_id;
  perform public._require_staff(v_branch, 'refunds');
  return public._gateway_attempt_json(a);
end;
$$;
revoke all on function public.staff_gateway_refund_attempt(uuid) from public, anon;
grant execute on function public.staff_gateway_refund_attempt(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. HitPay checkout links: one request at a time, no stale links
-- -----------------------------------------------------------------------------
alter table public.payments add column if not exists checkout_started_at timestamptz;
alter table public.payments add column if not exists gateway_checkout_created_at timestamptz;

-- Called by hitpay-create-payment (service role) BEFORE it asks HitPay for a
-- payment request. Locks the payment row, so two "Pay now" taps at the same
-- moment are served one after the other. Answers:
--   {"action": "reuse", "checkout_url", "payment_request_id"}  a fresh link exists
--   {"action": "busy"}     another call is creating the link right now (wait, ask again)
--   {"action": "create"}   this caller may create a link (claim held for 60 s)
--   {"action": "closed", "status"}  nothing to pay
-- A link older than p_max_age_minutes is never reused (HitPay expires links).
create or replace function public.hitpay_claim_checkout(p_order_id text, p_max_age_minutes int default 60)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay public.payments;
  v_max_age interval := make_interval(mins => greatest(coalesce(p_max_age_minutes, 60), 1));
begin
  select * into v_pay from public.payments where order_id = p_order_id for update;
  if not found then raise exception 'Order % has no payment record.', p_order_id; end if;
  if v_pay.status not in ('pending', 'processing', 'failed') then
    return jsonb_build_object('action', 'closed', 'status', v_pay.status);
  end if;
  if v_pay.status <> 'failed'
     and v_pay.gateway_checkout_url is not null and v_pay.gateway_payment_id is not null
     and v_pay.gateway_checkout_created_at is not null
     and v_pay.gateway_checkout_created_at > now() - v_max_age then
    return jsonb_build_object('action', 'reuse', 'checkout_url', v_pay.gateway_checkout_url,
                              'payment_request_id', v_pay.gateway_payment_id);
  end if;
  if v_pay.checkout_started_at is not null and v_pay.checkout_started_at > now() - interval '60 seconds' then
    return jsonb_build_object('action', 'busy');
  end if;
  update public.payments set checkout_started_at = now() where id = v_pay.id;
  return jsonb_build_object('action', 'create');
end;
$$;

-- Gives the claim back when creating the link failed, so the next tap can try
-- at once instead of waiting for the claim to run out.
create or replace function public.hitpay_release_checkout(p_order_id text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.payments set checkout_started_at = null where order_id = p_order_id;
$$;

-- Stores the HitPay payment-request id and checkout URL (and when it was made).
-- A pending (or failed, i.e. being retried) payment becomes 'processing'.
create or replace function public.hitpay_set_checkout(
  p_order_id text,
  p_payment_id text,
  p_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay public.payments;
begin
  select * into v_pay from public.payments where order_id = p_order_id for update;
  if not found then raise exception 'Order % has no payment record.', p_order_id; end if;

  update public.payments
  set gateway = 'hitpay',
      gateway_payment_id = nullif(trim(coalesce(p_payment_id, '')), ''),
      gateway_checkout_url = nullif(trim(coalesce(p_url, '')), ''),
      gateway_checkout_created_at = now(),
      checkout_started_at = null
  where id = v_pay.id;

  if v_pay.status in ('pending', 'failed') then
    update public.payments set status = 'processing' where id = v_pay.id;
  end if;
end;
$$;

-- HitPay "expired" event: the CURRENT link ran out unpaid. The payment leaves
-- 'processing' (-> 'failed', which the customer can retry with a new link) and
-- the dead link is forgotten. An old link expiring never touches a newer one,
-- and a paid payment is never changed. Returns the resulting status.
create or replace function public.hitpay_expire_checkout(p_order_id text, p_payment_request_id text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay public.payments;
begin
  select * into v_pay from public.payments where order_id = p_order_id for update;
  if not found then return null; end if;
  if v_pay.status <> 'processing'
     or v_pay.gateway_payment_id is distinct from nullif(trim(coalesce(p_payment_request_id, '')), '') then
    return v_pay.status;
  end if;
  update public.payments
     set status = 'failed', gateway_checkout_url = null, gateway_checkout_created_at = null, checkout_started_at = null
   where id = v_pay.id;
  return 'failed';
end;
$$;

revoke all on function public.hitpay_claim_checkout(text, int) from public, anon, authenticated;
revoke all on function public.hitpay_release_checkout(text) from public, anon, authenticated;
revoke all on function public.hitpay_set_checkout(text, text, text) from public, anon, authenticated;
revoke all on function public.hitpay_expire_checkout(text, text) from public, anon, authenticated;
grant execute on function public.hitpay_claim_checkout(text, int) to service_role;
grant execute on function public.hitpay_release_checkout(text) to service_role;
grant execute on function public.hitpay_set_checkout(text, text, text) to service_role;
grant execute on function public.hitpay_expire_checkout(text, text) to service_role;

-- -----------------------------------------------------------------------------
-- 4. branch_inventory.is_carried
-- -----------------------------------------------------------------------------
-- 20261026000000 created a stock row for every product at every branch, and
-- admin_portal_stock (20261012000000) decided "carried" by whether a row
-- exists, so every branch "carried" everything: products a branch never sells
-- were counted as out of stock / running low, and the app said "out of stock"
-- instead of "not sold here". From now on "carried" is this explicit flag.
--
-- The column is added (and filled) ONCE. Rows that were never stocked at all —
-- quantity 0, no batch ever received, no stock movement ever — are the ones the
-- seed created for items the branch doesn't sell: they become not carried. Every
-- row created from now on is carried by default, and receiving stock for a row
-- that isn't carried makes it carried (trigger below). Re-running this file
-- never changes a flag again.
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'branch_inventory' and column_name = 'is_carried') then
    alter table public.branch_inventory add column is_carried boolean not null default true;
    update public.branch_inventory bi
       set is_carried = false
     where bi.quantity = 0
       and not exists (select 1 from public.inventory_batches ib
                       where ib.branch_id = bi.branch_id and ib.variant_id = bi.variant_id)
       and not exists (select 1 from public.stock_movements sm
                       where sm.branch_id = bi.branch_id and sm.variant_id = bi.variant_id);
  end if;
end $$;

create or replace function public._trg_branch_inventory_carried()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- Stock arrived: the branch sells it now.
  if new.quantity > 0 and not new.is_carried then
    new.is_carried := true;
  end if;
  return new;
end;
$$;
revoke all on function public._trg_branch_inventory_carried() from public, anon, authenticated;
drop trigger if exists branch_inventory_carried on public.branch_inventory;
create trigger branch_inventory_carried before insert or update of quantity, is_carried on public.branch_inventory
  for each row execute function public._trg_branch_inventory_carried();

-- Same as 20261012000000, but 'carried' is the flag (and a row must exist).
create or replace function public.admin_portal_stock()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_staff();
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'branch_id', b.id, 'branch_name', b.name,
             'items', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'product_id', p.id, 'product_name', p.name,
                        'variant_id', pv.id, 'variant_label', pv.label, 'sku', pv.sku,
                        'quantity', coalesce(bi.quantity, 0),
                        'carried', (bi.branch_id is not null and bi.is_carried),
                        'restock_threshold', coalesce(th.restock_threshold, public._default_restock_threshold()))
                      order by p.name, pv.sort_order, pv.label), '[]'::jsonb)
               from public.products p
               join public.product_variants pv on pv.product_id = p.id
               left join public.branch_inventory bi on bi.branch_id = b.id and bi.variant_id = pv.id
               left join public.stock_thresholds th on th.branch_id = b.id and th.variant_id = pv.id
               where p.is_active)
           ) order by b.name), '[]'::jsonb)
    from public.branches b
    where b.id = any (public.staff_authorized_branch_ids())
  );
end;
$$;
revoke all on function public.admin_portal_stock() from public, anon;
grant execute on function public.admin_portal_stock() to authenticated;

-- -----------------------------------------------------------------------------
-- 5. branches.daily_sales_target is internal
-- -----------------------------------------------------------------------------
-- A column-level REVOKE does nothing while the table-level SELECT grant stands,
-- so the table grant is replaced by a grant on every OTHER column. Staff and the
-- owner keep reading the target through get_business_settings (SECURITY
-- DEFINER). The app reads branches with an explicit column list.
do $$
declare
  v_cols text;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'branches' and column_name <> 'daily_sales_target';
  execute 'revoke select on public.branches from anon, authenticated';
  execute format('grant select (%s) on public.branches to anon, authenticated', v_cols);
end $$;

-- -----------------------------------------------------------------------------
-- 6. Owner: remove a just-created driver row (rollback of a failed creation)
-- -----------------------------------------------------------------------------
-- AuthService.createManagedAccount undoes a half-created delivery account in
-- reverse order: driver row, then the Firebase Auth user. Like
-- owner_delete_staff_member, this only succeeds for a driver nothing refers to
-- yet (deliveries.driver_uid is ON DELETE RESTRICT).
create or replace function public.owner_delete_driver(p_firebase_uid text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
begin
  v_owner := public._require_owner();
  if exists (select 1 from public.deliveries where driver_uid = p_firebase_uid) then
    raise exception 'This driver already has deliveries. Deactivate the account instead.';
  end if;
  delete from public.drivers where firebase_uid = p_firebase_uid;
  if found then
    perform public._write_audit(v_owner.firebase_uid, null, 'driver.delete', 'driver', p_firebase_uid, '{}'::jsonb);
  end if;
end;
$$;
revoke all on function public.owner_delete_driver(text) from public, anon;
grant execute on function public.owner_delete_driver(text) to authenticated;

commit;
