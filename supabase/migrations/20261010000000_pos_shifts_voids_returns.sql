-- =============================================================================
-- POS cash drawer shifts, POS voids, counter returns and returned-stock receipt
-- =============================================================================
-- Run after 20261009000000_admin_portal.sql. Idempotent, additive: no table is
-- dropped and no existing row is changed.
--
-- What it adds
--   * cash_drawer_sessions  one shift per cashier: opening cash, closing count,
--                           expected cash, difference. A POS sale is attached to
--                           the cashier's open shift automatically (trigger), so
--                           the existing app keeps working unchanged.
--   * cash_drawer_events    cash that leaves/enters the drawer outside a sale
--                           (cash refunds, paid-in, paid-out).
--   * pos_voids             a voided POS sale (same shift, manager permission).
--   * refund_returned_items what physically came back for a refund and in what
--                           condition. Only 'sellable' units go back into stock;
--                           before this migration nothing ever restocked a refund.
--   * permission 'void_pos_sales' (owner always; staff only by explicit grant).
--   * branches.pos_requires_shift (default false): when true, a branch refuses
--     POS sales from a cashier with no open shift.
--
-- Definitions used by every summary here (and by the analytics migration):
--   gross sales  = sum of order subtotals (before discounts, without delivery
--                  fee) whose payment is verified (payments.status success or
--                  refunded)
--   discounts    = sum of order discounts on those orders
--   refunds      = completed refund amounts, dated by when they completed
--   net sales    = gross sales - discounts - refunds
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Permission catalog: + void_pos_sales  (superset of the old list)
-- -----------------------------------------------------------------------------
create or replace function public.staff_permission_catalog()
returns text[]
language sql
immutable
as $$
  select array[
    'view_dashboard',
    'view_products',    'manage_products',
    'view_inventory',   'manage_inventory',
    'view_orders',      'manage_orders',
    'view_payments',
    'manage_refunds',
    'view_reports',
    'manage_stock_transfers',
    'view_notifications',
    'void_pos_sales'
  ]
$$;

-- -----------------------------------------------------------------------------
-- 2. Stock movement types: + return_restock. The batch-sync trigger labels an
--    increase with app.stock_increase_type when a caller sets it.
-- -----------------------------------------------------------------------------
alter table public.stock_movements drop constraint if exists stock_movements_movement_type_check;
alter table public.stock_movements add constraint stock_movements_movement_type_check
  check (movement_type in ('receive', 'assign', 'adjust', 'sale', 'sale_cancel',
                           'transfer_out', 'transfer_in', 'return_restock'));

create or replace function public._sync_batches_with_inventory()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_delta int;
  v_remaining int;
  v_take int;
  v_after int;
  b record;
  v_ref text := nullif(current_setting('app.stock_reference', true), '');
  v_inc_type text := coalesce(nullif(current_setting('app.stock_increase_type', true), ''), 'sale_cancel');
begin
  if coalesce(current_setting('app.inventory_managed', true), '') = '1' then return new; end if;
  if new.variant_id is null then return new; end if;
  v_delta := new.quantity - old.quantity;
  if v_delta = 0 then return new; end if;
  if v_inc_type not in ('sale_cancel', 'return_restock') then v_inc_type := 'sale_cancel'; end if;

  if v_delta < 0 then
    perform public._consume_batches_fefo(new.branch_id, new.product_id, new.variant_id, -v_delta,
                                         'sale', v_ref, null, false);
  else
    v_remaining := v_delta;
    for b in
      select id, quantity, initial_quantity from public.inventory_batches
      where branch_id = new.branch_id and variant_id = new.variant_id and quantity < initial_quantity
      order by expiration_date, received_date
      for update
    loop
      exit when v_remaining <= 0;
      v_take := least(b.initial_quantity - b.quantity, v_remaining);
      update public.inventory_batches set quantity = quantity + v_take
      where id = b.id returning quantity into v_after;
      insert into public.stock_movements
        (branch_id, product_id, variant_id, batch_id, movement_type, quantity_change, batch_quantity_after, reference)
      values (new.branch_id, new.product_id, new.variant_id, b.id, v_inc_type, v_take, v_after, v_ref);
      v_remaining := v_remaining - v_take;
    end loop;
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Tables
-- -----------------------------------------------------------------------------
alter table public.branches add column if not exists pos_requires_shift boolean not null default false;

create sequence if not exists public.cash_drawer_session_seq start 1001;

create table if not exists public.cash_drawer_sessions (
  id text primary key default ('SHIFT-' || nextval('public.cash_drawer_session_seq')::text),
  branch_id uuid not null references public.branches(id) on delete restrict,
  staff_uid text not null references public.staff_members(firebase_uid) on delete restrict,
  staff_name text not null default '',
  status text not null default 'open' check (status in ('open', 'closed')),
  opening_cash numeric(12, 2) not null check (opening_cash >= 0 and opening_cash <= 1000000),
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by text,
  counted_cash numeric(12, 2) check (counted_cash is null or (counted_cash >= 0 and counted_cash <= 10000000)),
  expected_cash numeric(12, 2),
  cash_difference numeric(12, 2),
  closing_notes text check (closing_notes is null or char_length(closing_notes) <= 500),
  constraint cash_drawer_closed_complete check (
    status = 'open'
    or (closed_at is not null and counted_cash is not null and expected_cash is not null and cash_difference is not null))
);
-- One open drawer per cashier.
create unique index if not exists cash_drawer_one_open_per_staff
  on public.cash_drawer_sessions (staff_uid) where status = 'open';
create index if not exists cash_drawer_branch_idx on public.cash_drawer_sessions (branch_id, opened_at desc);
alter table public.cash_drawer_sessions enable row level security;

create table if not exists public.cash_drawer_events (
  id uuid primary key default gen_random_uuid(),
  session_id text not null references public.cash_drawer_sessions(id) on delete restrict,
  event_type text not null check (event_type in ('cash_refund', 'paid_in', 'paid_out')),
  amount numeric(12, 2) not null check (amount > 0 and amount <= 1000000),
  reference text,
  reason text not null default '' check (char_length(reason) <= 200),
  created_by text not null,
  created_at timestamptz not null default now()
);
create index if not exists cash_drawer_events_session_idx on public.cash_drawer_events (session_id, created_at);
-- A refund leaves the drawer at most once.
create unique index if not exists cash_drawer_events_one_refund
  on public.cash_drawer_events (reference) where event_type = 'cash_refund';
alter table public.cash_drawer_events enable row level security;

alter table public.pos_sales add column if not exists session_id text references public.cash_drawer_sessions(id);
create index if not exists pos_sales_session_idx on public.pos_sales (session_id);

create table if not exists public.pos_voids (
  order_id text primary key references public.orders(id) on delete restrict,
  refund_id text not null unique references public.refund_requests(id) on delete restrict,
  branch_id uuid not null references public.branches(id),
  session_id text references public.cash_drawer_sessions(id),
  reason text not null check (char_length(reason) between 3 and 200),
  voided_by text not null,
  voided_by_name text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists pos_voids_branch_idx on public.pos_voids (branch_id, created_at desc);
alter table public.pos_voids enable row level security;

create table if not exists public.refund_returned_items (
  id uuid primary key default gen_random_uuid(),
  refund_id text not null references public.refund_requests(id) on delete restrict,
  branch_id uuid not null references public.branches(id),
  variant_id uuid references public.product_variants(id) on delete set null,
  product_name text not null,
  variant_label text not null,
  quantity int not null check (quantity > 0),
  condition text not null check (condition in ('sellable', 'damaged', 'expired')),
  received_by text not null,
  created_at timestamptz not null default now()
);
create index if not exists refund_returned_items_refund_idx on public.refund_returned_items (refund_id);
alter table public.refund_returned_items enable row level security;

-- Reads go through the RPCs below; staff may also read their branch rows
-- directly (owner: all). No client writes.
drop policy if exists "staff read branch shifts" on public.cash_drawer_sessions;
create policy "staff read branch shifts" on public.cash_drawer_sessions
  for select to authenticated using (public.staff_can_see_branch(branch_id));
drop policy if exists "staff read branch drawer events" on public.cash_drawer_events;
create policy "staff read branch drawer events" on public.cash_drawer_events
  for select to authenticated using (exists (
    select 1 from public.cash_drawer_sessions s
    where s.id = cash_drawer_events.session_id and public.staff_can_see_branch(s.branch_id)));
drop policy if exists "staff read branch voids" on public.pos_voids;
create policy "staff read branch voids" on public.pos_voids
  for select to authenticated using (public.staff_can_see_branch(branch_id));
drop policy if exists "staff read branch returned items" on public.refund_returned_items;
create policy "staff read branch returned items" on public.refund_returned_items
  for select to authenticated using (public.staff_can_see_branch(branch_id));

revoke insert, update, delete, truncate on public.cash_drawer_sessions, public.cash_drawer_events,
  public.pos_voids, public.refund_returned_items from anon, authenticated;
revoke all on public.cash_drawer_sessions, public.cash_drawer_events,
  public.pos_voids, public.refund_returned_items from anon;
grant select on public.cash_drawer_sessions, public.cash_drawer_events,
  public.pos_voids, public.refund_returned_items to authenticated;

-- -----------------------------------------------------------------------------
-- 4. Attach POS sales to the cashier's open shift
-- -----------------------------------------------------------------------------
create or replace function public._trg_pos_sale_attach_shift()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_required boolean;
begin
  if new.session_id is null then
    select id into new.session_id from public.cash_drawer_sessions
    where staff_uid = new.staff_uid and branch_id = new.branch_id and status = 'open';
  end if;
  if new.session_id is null then
    select pos_requires_shift into v_required from public.branches where id = new.branch_id;
    if coalesce(v_required, false) then
      raise exception 'Open your cash drawer shift before ringing up sales.';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists pos_sales_attach_shift on public.pos_sales;
create trigger pos_sales_attach_shift before insert on public.pos_sales
  for each row execute function public._trg_pos_sale_attach_shift();

-- -----------------------------------------------------------------------------
-- 5. Shift summary (internal; callers authorize first)
-- -----------------------------------------------------------------------------
create or replace function public._shift_summary(p_session_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.cash_drawer_sessions;
  v_cash_sales numeric := 0;
  v_cash_refunds numeric := 0;
  v_paid_in numeric := 0;
  v_paid_out numeric := 0;
  v_expected numeric;
  v_methods jsonb;
  v_tx int := 0;
  v_gross numeric := 0;
  v_voids int := 0;
  v_void_amount numeric := 0;
begin
  select * into s from public.cash_drawer_sessions where id = p_session_id;
  if not found then return null; end if;

  -- Every sale rung up in this shift (voided ones included: they were sold,
  -- and their refund is counted separately).
  select count(*), coalesce(sum(o.subtotal), 0),
         coalesce(sum(o.total) filter (where p.method = 'cash'), 0)
    into v_tx, v_gross, v_cash_sales
  from public.pos_sales ps
  join public.orders o on o.id = ps.order_id
  left join public.payments p on p.order_id = o.id
  where ps.session_id = s.id;

  select coalesce(jsonb_object_agg(m.method, jsonb_build_object('count', m.n, 'amount', m.amount)), '{}'::jsonb)
    into v_methods
  from (
    select p.method, count(*) as n, sum(o.total) as amount
    from public.pos_sales ps
    join public.orders o on o.id = ps.order_id
    join public.payments p on p.order_id = o.id
    where ps.session_id = s.id
    group by p.method
  ) m;

  select coalesce(sum(amount) filter (where event_type = 'cash_refund'), 0),
         coalesce(sum(amount) filter (where event_type = 'paid_in'), 0),
         coalesce(sum(amount) filter (where event_type = 'paid_out'), 0)
    into v_cash_refunds, v_paid_in, v_paid_out
  from public.cash_drawer_events where session_id = s.id;

  select count(*), coalesce(sum(o.total), 0) into v_voids, v_void_amount
  from public.pos_voids v join public.orders o on o.id = v.order_id
  where v.session_id = s.id;

  v_expected := s.opening_cash + v_cash_sales - v_cash_refunds + v_paid_in - v_paid_out;

  return jsonb_build_object(
    'session_id', s.id,
    'branch_id', s.branch_id,
    'staff_uid', s.staff_uid,
    'staff_name', s.staff_name,
    'status', s.status,
    'opened_at', s.opened_at,
    'closed_at', s.closed_at,
    'opening_cash', s.opening_cash,
    'transaction_count', v_tx,
    'gross_sales', v_gross,
    'by_method', v_methods,
    'cash_sales', v_cash_sales,
    'cash_refunds', v_cash_refunds,
    'paid_in', v_paid_in,
    'paid_out', v_paid_out,
    'void_count', v_voids,
    'void_amount', v_void_amount,
    'expected_cash', case when s.status = 'closed' then s.expected_cash else v_expected end,
    'counted_cash', s.counted_cash,
    'cash_difference', s.cash_difference,
    'closing_notes', s.closing_notes
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Shift RPCs
-- -----------------------------------------------------------------------------
create or replace function public.staff_open_shift(
  p_branch_id uuid,
  p_opening_cash numeric,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_req jsonb := jsonb_build_object('branch', p_branch_id, 'cash', p_opening_cash);
  v_prev jsonb;
  v_id text;
  v_result jsonb;
begin
  v_staff := public._require_staff(p_branch_id);
  if p_branch_id is null or not exists (select 1 from public.branches where id = p_branch_id) then
    raise exception 'That branch could not be found.';
  end if;
  v_prev := public._idem_begin(v_staff.firebase_uid, v_key, 'open_shift', v_req);
  if v_prev is not null then return v_prev; end if;

  if p_opening_cash is null or p_opening_cash < 0 or p_opening_cash > 1000000 then
    raise exception 'Enter the opening cash in the drawer (0 or more).';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('shift:' || v_staff.firebase_uid, 0));
  if exists (select 1 from public.cash_drawer_sessions where staff_uid = v_staff.firebase_uid and status = 'open') then
    raise exception 'You already have an open shift. Close it before opening a new one.';
  end if;

  insert into public.cash_drawer_sessions (branch_id, staff_uid, staff_name, opening_cash)
  values (p_branch_id, v_staff.firebase_uid, v_staff.full_name, round(p_opening_cash, 2))
  returning id into v_id;

  perform public._write_audit(v_staff.firebase_uid, p_branch_id, 'pos.shift_open', 'cash_drawer_session', v_id,
                              jsonb_build_object('opening_cash', round(p_opening_cash, 2)));
  v_result := public._shift_summary(v_id);
  perform public._idem_finish(v_staff.firebase_uid, v_key, 'open_shift', v_req, v_result);
  return v_result;
end;
$$;

-- The caller's open shift (any branch they may use), with live totals; null if none.
create or replace function public.staff_get_current_shift()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_id text;
begin
  v_staff := public._require_staff();
  select id into v_id from public.cash_drawer_sessions
  where staff_uid = v_staff.firebase_uid and status = 'open';
  if v_id is null then return null; end if;
  return public._shift_summary(v_id);
end;
$$;

create or replace function public.staff_get_shift(p_session_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.cash_drawer_sessions;
  v_staff public.staff_members;
begin
  select * into s from public.cash_drawer_sessions where id = p_session_id;
  if not found then raise exception 'That shift could not be found.'; end if;
  v_staff := public._require_staff(s.branch_id);
  return public._shift_summary(s.id);
end;
$$;

-- Paid-in / paid-out (change fund top-up, small purchases paid from the drawer).
create or replace function public.staff_record_cash_movement(
  p_session_id text,
  p_type text,
  p_amount numeric,
  p_reason text,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.cash_drawer_sessions;
  v_staff public.staff_members;
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_req jsonb := jsonb_build_object('s', p_session_id, 't', p_type, 'a', p_amount, 'r', p_reason);
  v_prev jsonb;
  v_result jsonb;
  v_reason text := trim(coalesce(p_reason, ''));
begin
  select * into s from public.cash_drawer_sessions where id = p_session_id for update;
  if not found then raise exception 'That shift could not be found.'; end if;
  v_staff := public._require_staff(s.branch_id);
  v_prev := public._idem_begin(v_staff.firebase_uid, v_key, 'cash_movement', v_req);
  if v_prev is not null then return v_prev; end if;

  if s.staff_uid <> v_staff.firebase_uid and v_staff.role <> 'owner' then
    raise exception 'Only the cashier who opened this shift can record cash movements.';
  end if;
  if s.status <> 'open' then raise exception 'This shift is already closed.'; end if;
  if p_type not in ('paid_in', 'paid_out') then raise exception 'Choose paid in or paid out.'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception 'Enter an amount greater than zero.'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 200 then
    raise exception 'Please give a reason (3 to 200 characters).';
  end if;
  if p_type = 'paid_out' and p_amount > (public._shift_summary(s.id) ->> 'expected_cash')::numeric then
    raise exception 'There is not that much cash in the drawer.';
  end if;

  insert into public.cash_drawer_events (session_id, event_type, amount, reason, created_by)
  values (s.id, p_type, round(p_amount, 2), v_reason, v_staff.firebase_uid);
  perform public._write_audit(v_staff.firebase_uid, s.branch_id, 'pos.cash_' || p_type, 'cash_drawer_session', s.id,
                              jsonb_build_object('amount', round(p_amount, 2), 'reason', v_reason));
  v_result := public._shift_summary(s.id);
  perform public._idem_finish(v_staff.firebase_uid, v_key, 'cash_movement', v_req, v_result);
  return v_result;
end;
$$;

create or replace function public.staff_close_shift(
  p_session_id text,
  p_counted_cash numeric,
  p_notes text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.cash_drawer_sessions;
  v_staff public.staff_members;
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_req jsonb := jsonb_build_object('s', p_session_id, 'c', p_counted_cash, 'n', p_notes);
  v_prev jsonb;
  v_expected numeric;
  v_diff numeric;
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_result jsonb;
begin
  select * into s from public.cash_drawer_sessions where id = p_session_id for update;
  if not found then raise exception 'That shift could not be found.'; end if;
  v_staff := public._require_staff(s.branch_id);
  v_prev := public._idem_begin(v_staff.firebase_uid, v_key, 'close_shift', v_req);
  if v_prev is not null then return v_prev; end if;

  if s.staff_uid <> v_staff.firebase_uid and v_staff.role <> 'owner'
     and not ('void_pos_sales' = any (public.staff_permission_keys())) then
    raise exception 'Only the cashier, a manager or the owner can close this shift.';
  end if;
  if s.status <> 'open' then raise exception 'This shift is already closed.'; end if;
  if p_counted_cash is null or p_counted_cash < 0 or p_counted_cash > 10000000 then
    raise exception 'Enter the cash you counted in the drawer.';
  end if;
  if v_notes is not null and char_length(v_notes) > 500 then raise exception 'Notes are too long.'; end if;

  v_expected := (public._shift_summary(s.id) ->> 'expected_cash')::numeric;
  v_diff := round(p_counted_cash, 2) - v_expected;
  if v_diff <> 0 and v_notes is null then
    raise exception 'The count is off by %. Add a note explaining the difference.', v_diff;
  end if;

  update public.cash_drawer_sessions
     set status = 'closed', closed_at = now(), closed_by = v_staff.firebase_uid,
         counted_cash = round(p_counted_cash, 2), expected_cash = v_expected,
         cash_difference = v_diff, closing_notes = v_notes
   where id = s.id;

  perform public._write_audit(v_staff.firebase_uid, s.branch_id, 'pos.shift_close', 'cash_drawer_session', s.id,
    jsonb_build_object('expected_cash', v_expected, 'counted_cash', round(p_counted_cash, 2), 'difference', v_diff));
  if v_diff <> 0 then
    perform public._notify_staff(s.branch_id, 'system', 'Cash difference on ' || s.id,
      s.staff_name || '''s drawer was off by ' || v_diff || '.', s.id, 'refunds');
  end if;
  v_result := public._shift_summary(s.id);
  perform public._idem_finish(v_staff.firebase_uid, v_key, 'close_shift', v_req, v_result);
  return v_result;
end;
$$;

create or replace function public.staff_list_shifts(
  p_branch_id uuid default null,
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_from date := coalesce(p_from, (now() at time zone 'Asia/Manila')::date - 6);
  v_to date := coalesce(p_to, (now() at time zone 'Asia/Manila')::date);
begin
  v_staff := public._require_staff(p_branch_id);
  if v_to < v_from or v_to - v_from > 400 then raise exception 'Choose a date range of up to 400 days.'; end if;
  return (
    select coalesce(jsonb_agg(public._shift_summary(s.id) order by s.opened_at desc), '[]'::jsonb)
    from public.cash_drawer_sessions s
    where (s.opened_at at time zone 'Asia/Manila')::date between v_from and v_to
      and (case when v_staff.role = 'owner' then p_branch_id is null or s.branch_id = p_branch_id
                else s.branch_id = v_staff.branch_id end)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Daily cashier summary for one branch and one day (Asia/Manila)
-- -----------------------------------------------------------------------------
create or replace function public.staff_cashier_daily_summary(
  p_branch_id uuid,
  p_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_day date := coalesce(p_date, (now() at time zone 'Asia/Manila')::date);
  v_start timestamptz;
  v_end timestamptz;
  v_cashiers jsonb;
  v_totals jsonb;
begin
  v_staff := public._require_staff(p_branch_id);
  if p_branch_id is null then raise exception 'Choose a branch.'; end if;
  v_start := v_day::timestamp at time zone 'Asia/Manila';
  v_end := (v_day + 1)::timestamp at time zone 'Asia/Manila';

  with sales as (
    select ps.staff_uid, max(ps.staff_name) as staff_name,
           count(*) as tx,
           coalesce(sum(o.subtotal), 0) as gross,
           coalesce(sum(o.discount), 0) as discounts,
           coalesce(sum(o.total) filter (where p.method = 'cash'), 0) as cash,
           coalesce(sum(o.total) filter (where p.method <> 'cash'), 0) as non_cash
    from public.pos_sales ps
    join public.orders o on o.id = ps.order_id
    join public.payments p on p.order_id = o.id and p.status in ('success', 'refunded')
    where ps.branch_id = p_branch_id and ps.created_at >= v_start and ps.created_at < v_end
    group by ps.staff_uid
  ),
  refunds as (
    -- Refunds and voids count against the cashier who rang up the sale.
    select ps.staff_uid as staff_uid,
           count(*) filter (where v.order_id is not null) as voids,
           coalesce(sum(r.amount), 0) as refunded
    from public.refund_requests r
    join public.pos_sales ps on ps.order_id = r.order_id
    left join public.pos_voids v on v.refund_id = r.id
    join lateral (
      select max(e.created_at) as done_at from public.refund_status_events e
      where e.refund_request_id = r.id and e.status = 'completed'
    ) d on true
    where r.status = 'completed' and ps.branch_id = p_branch_id
      and d.done_at >= v_start and d.done_at < v_end
    group by 1
  ),
  people as (
    select staff_uid from sales union select staff_uid from refunds
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'staff_uid', pe.staff_uid,
           'staff_name', coalesce(sa.staff_name, sm.full_name, ''),
           'transaction_count', coalesce(sa.tx, 0),
           'gross_sales', coalesce(sa.gross, 0),
           'discounts', coalesce(sa.discounts, 0),
           'refunds', coalesce(rf.refunded, 0),
           'void_count', coalesce(rf.voids, 0),
           'net_sales', coalesce(sa.gross, 0) - coalesce(sa.discounts, 0) - coalesce(rf.refunded, 0),
           'cash_sales', coalesce(sa.cash, 0),
           'non_cash_sales', coalesce(sa.non_cash, 0)
         ) order by coalesce(sa.staff_name, sm.full_name)), '[]'::jsonb),
         jsonb_build_object(
           'transaction_count', coalesce(sum(sa.tx), 0),
           'gross_sales', coalesce(sum(sa.gross), 0),
           'discounts', coalesce(sum(sa.discounts), 0),
           'refunds', coalesce(sum(rf.refunded), 0),
           'void_count', coalesce(sum(rf.voids), 0),
           'net_sales', coalesce(sum(sa.gross), 0) - coalesce(sum(sa.discounts), 0) - coalesce(sum(rf.refunded), 0),
           'cash_sales', coalesce(sum(sa.cash), 0),
           'non_cash_sales', coalesce(sum(sa.non_cash), 0))
    into v_cashiers, v_totals
  from people pe
  left join sales sa on sa.staff_uid = pe.staff_uid
  left join refunds rf on rf.staff_uid = pe.staff_uid
  left join public.staff_members sm on sm.firebase_uid = pe.staff_uid;

  return jsonb_build_object(
    'branch_id', p_branch_id,
    'date', v_day,
    'totals', v_totals,
    'cashiers', v_cashiers,
    'shifts', (
      select coalesce(jsonb_agg(public._shift_summary(s.id) order by s.opened_at), '[]'::jsonb)
      from public.cash_drawer_sessions s
      where s.branch_id = p_branch_id and s.opened_at >= v_start and s.opened_at < v_end)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Receiving returned items (any refund, online or POS)
--    Only 'sellable' units go back into branch stock (FEFO batches refilled,
--    movement 'return_restock'). 'damaged' / 'expired' are recorded only.
--    p_items: [{"variant_id": "<uuid>", "quantity": 1, "condition": "sellable"}]
-- -----------------------------------------------------------------------------
create or replace function public._receive_returned_items(
  p_refund public.refund_requests,
  p_branch_id uuid,
  p_items jsonb,
  p_staff_uid text
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line record;
  v_ordered int;
  v_refunded int;
  v_already int;
  v_restocked int := 0;
  v_prod uuid;
  v_name text;
  v_label text;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'List the items that came back.';
  end if;
  if jsonb_array_length(p_items) > 100 then raise exception 'Too many lines.'; end if;

  for v_line in
    select (e ->> 'variant_id')::uuid as variant_id,
           coalesce(nullif(e ->> 'condition', ''), 'sellable') as condition,
           sum((e ->> 'quantity')::int)::int as qty
    from jsonb_array_elements(p_items) e
    group by 1, 2 order by 1, 2
  loop
    if v_line.condition not in ('sellable', 'damaged', 'expired') then
      raise exception 'Condition must be sellable, damaged or expired.';
    end if;
    if v_line.qty is null or v_line.qty <= 0 then raise exception 'Quantities must be greater than zero.'; end if;

    select (array_agg(oi.product_id))[1], max(oi.product_name), max(oi.variant_label), sum(oi.quantity)::int
      into v_prod, v_name, v_label, v_ordered
    from public.order_items oi
    where oi.order_id = p_refund.order_id and oi.variant_id = v_line.variant_id;
    if v_ordered is null then raise exception 'An item is not part of this order.'; end if;

    select coalesce(sum(ri.quantity), 0)::int into v_refunded
    from public.refund_items ri
    where ri.refund_request_id = p_refund.id and ri.product_name = v_name and ri.variant_label = v_label;
    select coalesce(sum(quantity), 0)::int into v_already
    from public.refund_returned_items
    where refund_id = p_refund.id and variant_id = v_line.variant_id;
    if v_already + v_line.qty > v_refunded then
      raise exception 'Only % of % (%) were refunded and % already received.', v_refunded, v_name, v_label, v_already;
    end if;

    insert into public.refund_returned_items
      (refund_id, branch_id, variant_id, product_name, variant_label, quantity, condition, received_by)
    values (p_refund.id, p_branch_id, v_line.variant_id, v_name, v_label, v_line.qty, v_line.condition, p_staff_uid);

    if v_line.condition = 'sellable' then
      perform set_config('app.stock_reference', p_refund.id, true);
      perform set_config('app.stock_increase_type', 'return_restock', true);
      insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
      values (p_branch_id, v_prod, v_line.variant_id, 0)
      on conflict (branch_id, product_id, variant_id) do nothing;
      update public.branch_inventory set quantity = quantity + v_line.qty
      where branch_id = p_branch_id and variant_id = v_line.variant_id;
      perform set_config('app.stock_increase_type', '', true);
      v_restocked := v_restocked + v_line.qty;
    end if;
  end loop;
  return v_restocked;
end;
$$;

create or replace function public.staff_receive_returned_items(
  p_refund_id text,
  p_items jsonb,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.refund_requests;
  v_branch uuid;
  v_staff public.staff_members;
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_req jsonb := jsonb_build_object('r', p_refund_id, 'i', p_items);
  v_prev jsonb;
  v_restocked int;
  v_result jsonb;
begin
  select * into r from public.refund_requests where id = p_refund_id for update;
  if not found then raise exception 'That refund request could not be found.'; end if;
  select branch_id into v_branch from public.orders where id = r.order_id;
  v_staff := public._require_staff(v_branch, 'refunds');
  v_prev := public._idem_begin(v_staff.firebase_uid, v_key, 'receive_return', v_req);
  if v_prev is not null then return v_prev; end if;
  if r.status not in ('approved', 'processing', 'completed') then
    raise exception 'Items can only be received for an approved refund.';
  end if;

  v_restocked := public._receive_returned_items(r, v_branch, p_items, v_staff.firebase_uid);
  perform public._write_audit(v_staff.firebase_uid, v_branch, 'refund.items_received', 'refund_request', r.id,
                              jsonb_build_object('items', p_items, 'restocked_units', v_restocked));
  v_result := jsonb_build_object('refund_id', r.id, 'restocked_units', v_restocked,
    'received', (select coalesce(jsonb_agg(jsonb_build_object('variant_id', variant_id, 'product_name', product_name,
                   'variant_label', variant_label, 'quantity', quantity, 'condition', condition)), '[]'::jsonb)
                 from public.refund_returned_items where refund_id = r.id));
  perform public._idem_finish(v_staff.firebase_uid, v_key, 'receive_return', v_req, v_result);
  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 9. Counter return of a POS sale (customer present with the receipt)
--    p_items: [{"variant_id": "<uuid>", "quantity": 1, "condition": "sellable"}]
--    Cash sale  -> refund completed now, cash leaves the caller's open shift.
--    GCash/card -> refund stays 'approved'; refund through the terminal/wallet,
--                  then complete it with staff_review_refund(id, 'complete').
-- -----------------------------------------------------------------------------
create or replace function public._create_counter_refund(
  p_order public.orders,
  p_items jsonb,
  p_reason text,
  p_staff public.staff_members
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line record;
  v_ordered record;
  v_amount numeric := 0;
  v_refund_id text;
begin
  for v_line in
    select (e ->> 'variant_id')::uuid as variant_id, sum((e ->> 'quantity')::int)::int as qty
    from jsonb_array_elements(p_items) e group by 1 order by 1
  loop
    if v_line.qty is null or v_line.qty <= 0 then raise exception 'Quantities must be greater than zero.'; end if;
    select sum(quantity)::int as qty, max(unit_price) as unit_price, max(product_name) as product_name
      into v_ordered
    from public.order_items where order_id = p_order.id and variant_id = v_line.variant_id;
    if v_ordered.qty is null then raise exception 'An item is not part of this sale.'; end if;
    if v_line.qty > v_ordered.qty then
      raise exception 'You can return at most % of %.', v_ordered.qty, v_ordered.product_name;
    end if;
    v_amount := v_amount + v_line.qty * v_ordered.unit_price;
  end loop;
  if p_order.subtotal > 0 then
    v_amount := v_amount * greatest(0, p_order.subtotal - p_order.discount) / p_order.subtotal;
  end if;
  v_amount := least(round(v_amount, 2), p_order.total);
  if v_amount <= 0 then raise exception 'Nothing to refund on this sale.'; end if;

  insert into public.refund_requests (order_id, firebase_uid, reason, notes, amount, payment_method)
  values (p_order.id, p_order.firebase_uid, left(p_reason, 200),
          'Processed at the counter by ' || p_staff.full_name, v_amount, p_order.payment_method)
  returning id into v_refund_id;

  insert into public.refund_items (refund_request_id, product_name, variant_label, quantity, unit_price)
  select v_refund_id, oi.product_name, oi.variant_label, l.qty, oi.unit_price
  from (
    select (e ->> 'variant_id')::uuid as variant_id, sum((e ->> 'quantity')::int)::int as qty
    from jsonb_array_elements(p_items) e group by 1
  ) l
  join lateral (
    select product_name, variant_label, max(unit_price) as unit_price
    from public.order_items where order_id = p_order.id and variant_id = l.variant_id
    group by product_name, variant_label limit 1
  ) oi on true;

  return v_refund_id;
end;
$$;

create or replace function public.staff_pos_return(
  p_order_id text,
  p_items jsonb,
  p_reason text,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.orders;
  v_staff public.staff_members;
  v_pay public.payments;
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_req jsonb := jsonb_build_object('o', p_order_id, 'i', p_items, 'r', p_reason);
  v_prev jsonb;
  v_reason text := trim(coalesce(p_reason, ''));
  v_refund_id text;
  v_amount numeric;
  v_shift text;
  v_restocked int;
  v_result jsonb;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found or not exists (select 1 from public.pos_sales where order_id = p_order_id) then
    raise exception 'That in-store sale could not be found.';
  end if;
  v_staff := public._require_staff(o.branch_id, 'refunds');
  v_prev := public._idem_begin(v_staff.firebase_uid, v_key, 'pos_return', v_req);
  if v_prev is not null then return v_prev; end if;

  if char_length(v_reason) < 3 or char_length(v_reason) > 200 then
    raise exception 'Please give a reason for the return (3 to 200 characters).';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Select at least one item to return.';
  end if;
  if o.status <> 'completed' then raise exception 'Only a completed sale can be returned (this one is %).', o.status; end if;
  if exists (select 1 from public.refund_requests where order_id = o.id and status <> 'rejected') then
    raise exception 'This sale already has a refund.';
  end if;
  select * into v_pay from public.payments where order_id = o.id;

  if v_pay.method = 'cash' then
    select id into v_shift from public.cash_drawer_sessions
    where staff_uid = v_staff.firebase_uid and branch_id = o.branch_id and status = 'open';
    if v_shift is null then raise exception 'Open your cash drawer shift to pay out a cash refund.'; end if;
  end if;

  v_refund_id := public._create_counter_refund(o, p_items, v_reason, v_staff);
  select amount into v_amount from public.refund_requests where id = v_refund_id;
  update public.refund_requests set status = 'approved' where id = v_refund_id;

  if v_pay.method = 'cash' then
    if v_amount > (public._shift_summary(v_shift) ->> 'expected_cash')::numeric then
      raise exception 'There is not enough cash in your drawer for this refund.';
    end if;
    update public.refund_requests set status = 'completed' where id = v_refund_id;
    insert into public.cash_drawer_events (session_id, event_type, amount, reference, reason, created_by)
    values (v_shift, 'cash_refund', v_amount, v_refund_id, left('Return ' || o.id || ': ' || v_reason, 200), v_staff.firebase_uid);
  end if;

  v_restocked := public._receive_returned_items(
    (select r from public.refund_requests r where r.id = v_refund_id), o.branch_id, p_items, v_staff.firebase_uid);

  perform public._write_audit(v_staff.firebase_uid, o.branch_id, 'pos.return', 'order', o.id,
    jsonb_build_object('refund_id', v_refund_id, 'amount', v_amount, 'reason', v_reason, 'restocked_units', v_restocked));

  v_result := jsonb_build_object(
    'refund_id', v_refund_id, 'order_id', o.id, 'amount', v_amount,
    'refund_status', (select status from public.refund_requests where id = v_refund_id),
    'cash_paid_out', v_pay.method = 'cash', 'restocked_units', v_restocked);
  perform public._idem_finish(v_staff.firebase_uid, v_key, 'pos_return', v_req, v_result);
  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 10. Void a POS sale: same day, the sale's shift still open, whole sale,
--     permission 'void_pos_sales'. Everything goes back to stock; money goes
--     back the way it came (cash from the drawer; GCash/card refund stays
--     'approved' until the terminal/wallet reversal is confirmed).
-- -----------------------------------------------------------------------------
create or replace function public.staff_void_pos_sale(
  p_order_id text,
  p_reason text,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.orders;
  ps public.pos_sales;
  v_staff public.staff_members;
  v_pay public.payments;
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_req jsonb := jsonb_build_object('o', p_order_id, 'r', p_reason);
  v_prev jsonb;
  v_reason text := trim(coalesce(p_reason, ''));
  v_items jsonb;
  v_refund_id text;
  v_shift_status text;
  v_restocked int;
  v_result jsonb;
begin
  select * into o from public.orders where id = p_order_id for update;
  select * into ps from public.pos_sales where order_id = p_order_id;
  if o.id is null or ps.order_id is null then raise exception 'That in-store sale could not be found.'; end if;
  v_staff := public._require_staff(o.branch_id);
  v_prev := public._idem_begin(v_staff.firebase_uid, v_key, 'pos_void', v_req);
  if v_prev is not null then return v_prev; end if;

  if not ('void_pos_sales' = any (public.staff_permission_keys())) then
    raise exception 'You do not have permission to void sales. Ask a manager.';
  end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 200 then
    raise exception 'Please give a reason for the void (3 to 200 characters).';
  end if;
  if exists (select 1 from public.pos_voids where order_id = o.id) then raise exception 'This sale is already voided.'; end if;
  if o.status <> 'completed' then raise exception 'Only a completed sale can be voided (this one is %).', o.status; end if;
  if (ps.created_at at time zone 'Asia/Manila')::date <> (now() at time zone 'Asia/Manila')::date then
    raise exception 'Only today''s sales can be voided. Use a return instead.';
  end if;
  if exists (select 1 from public.refund_requests where order_id = o.id and status <> 'rejected') then
    raise exception 'This sale already has a refund.';
  end if;
  select * into v_pay from public.payments where order_id = o.id;
  if ps.session_id is not null then
    select status into v_shift_status from public.cash_drawer_sessions where id = ps.session_id for update;
    if v_shift_status <> 'open' then raise exception 'The shift for this sale is closed. Use a return instead.'; end if;
  elsif v_pay.method = 'cash' then
    raise exception 'This cash sale has no shift to take the cash from. Use a return instead.';
  end if;

  select jsonb_agg(jsonb_build_object('variant_id', variant_id, 'quantity', qty, 'condition', 'sellable'))
    into v_items
  from (select variant_id, sum(quantity)::int as qty from public.order_items
        where order_id = o.id and variant_id is not null group by variant_id) t;
  if v_items is null then raise exception 'This sale has no items that can be voided.'; end if;

  v_refund_id := public._create_counter_refund(o, v_items, 'Void: ' || v_reason, v_staff);
  update public.refund_requests set status = 'approved' where id = v_refund_id;
  if v_pay.method = 'cash' then
    update public.refund_requests set status = 'completed' where id = v_refund_id;
    insert into public.cash_drawer_events (session_id, event_type, amount, reference, reason, created_by)
    values (ps.session_id, 'cash_refund', (select amount from public.refund_requests where id = v_refund_id),
            v_refund_id, left('Void ' || o.id || ': ' || v_reason, 200), v_staff.firebase_uid);
  end if;

  insert into public.pos_voids (order_id, refund_id, branch_id, session_id, reason, voided_by, voided_by_name)
  values (o.id, v_refund_id, o.branch_id, ps.session_id, v_reason, v_staff.firebase_uid, v_staff.full_name);

  v_restocked := public._receive_returned_items(
    (select r from public.refund_requests r where r.id = v_refund_id), o.branch_id, v_items, v_staff.firebase_uid);

  perform public._write_audit(v_staff.firebase_uid, o.branch_id, 'pos.void', 'order', o.id,
    jsonb_build_object('refund_id', v_refund_id, 'reason', v_reason, 'total', o.total, 'method', v_pay.method));

  v_result := jsonb_build_object('order_id', o.id, 'refund_id', v_refund_id,
    'refund_status', (select status from public.refund_requests where id = v_refund_id),
    'amount', (select amount from public.refund_requests where id = v_refund_id),
    'restocked_units', v_restocked);
  perform public._idem_finish(v_staff.firebase_uid, v_key, 'pos_void', v_req, v_result);
  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 11. Grants
-- -----------------------------------------------------------------------------
revoke all on function public._trg_pos_sale_attach_shift() from public, anon, authenticated;
revoke all on function public._shift_summary(text) from public, anon, authenticated;
revoke all on function public._receive_returned_items(public.refund_requests, uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public._create_counter_refund(public.orders, jsonb, text, public.staff_members) from public, anon, authenticated;

revoke all on function public.staff_open_shift(uuid, numeric, text) from public, anon;
revoke all on function public.staff_get_current_shift() from public, anon;
revoke all on function public.staff_get_shift(text) from public, anon;
revoke all on function public.staff_record_cash_movement(text, text, numeric, text, text) from public, anon;
revoke all on function public.staff_close_shift(text, numeric, text, text) from public, anon;
revoke all on function public.staff_list_shifts(uuid, date, date) from public, anon;
revoke all on function public.staff_cashier_daily_summary(uuid, date) from public, anon;
revoke all on function public.staff_receive_returned_items(text, jsonb, text) from public, anon;
revoke all on function public.staff_pos_return(text, jsonb, text, text) from public, anon;
revoke all on function public.staff_void_pos_sale(text, text, text) from public, anon;

grant execute on function public.staff_open_shift(uuid, numeric, text) to authenticated;
grant execute on function public.staff_get_current_shift() to authenticated;
grant execute on function public.staff_get_shift(text) to authenticated;
grant execute on function public.staff_record_cash_movement(text, text, numeric, text, text) to authenticated;
grant execute on function public.staff_close_shift(text, numeric, text, text) to authenticated;
grant execute on function public.staff_list_shifts(uuid, date, date) to authenticated;
grant execute on function public.staff_cashier_daily_summary(uuid, date) to authenticated;
grant execute on function public.staff_receive_returned_items(text, jsonb, text) to authenticated;
grant execute on function public.staff_pos_return(text, jsonb, text, text) to authenticated;
grant execute on function public.staff_void_pos_sale(text, text, text) to authenticated;

commit;
