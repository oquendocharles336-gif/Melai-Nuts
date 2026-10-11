-- =============================================================================
-- Melai Nuts — Migration 20261015000000: refunds count everywhere
-- =============================================================================
-- Run after 20261014000000_admin_portal_all_users.sql. Idempotent (create or
-- replace / if not exists), one transaction. No table is created or dropped and
-- no existing row is changed.
--
-- ONE DEFINITION (the one already written in 20261010000000 / 20261010020000):
--   verified sale  an order whose payment is 'success' or 'refunded'
--   gross sales    subtotal of verified sales (before discounts, without
--                  delivery fee), dated by the ORDER date (Asia/Manila).
--                  The database has no "paid at" column: payments.updated_at
--                  moves when a payment is later marked refunded, so it cannot
--                  date a sale without moving the sale to the refund day.
--   discounts      discounts on those orders
--   refunds        refund_requests.status = 'completed', refund_requests.amount
--                  (partial refunds included, never the order total), dated by
--                  the 'completed' event in refund_status_events
--   net sales      gross sales - discounts - refunds        (the headline)
--   refund rate    refunds / (gross sales - discounts); null when that is 0
--   pending        refunds that are pending / approved / processing right now:
--                  shown apart (count + amount), never deducted
--   branch         the order's branch; POS refunds count against the cashier
--                  who rang up the sale (pos_sales.staff_uid)
--
-- Every figure below is built from three internal functions, so there is
-- exactly one place that decides what a sale and what a refund is:
--   _sales_facts(start, end, branches)      one row per sale and per refund
--   _sales_line_facts(start, end, branches) the same, per product line, with
--                                           discounts and refunds allocated to
--                                           lines so product totals add up to
--                                           the order totals
--   _pending_refund_facts(branches)         open refunds right now
--   _sales_money_json(...)                  the one formula for net / rate / AOV
--
-- What changes
--   * NEW sales_overview(from, to, branch)  summary, by day / branch / payment
--     method / channel / cashier / product, pending refunds. Owner: all branches
--     or one; staff: own branch only (the per-cashier breakdown needs view_reports).
--     The admin website's dashboard, sales page, reports and CSV exports use it.
--   * owner_sales_summary      net sales instead of order totals of
--     completed/refundRequested orders; refunded orders no longer vanish,
--     partial refunds count, refund-requested orders are not pre-deducted.
--     Old keys kept (today_revenue... = net sales), new gross/refund/net keys.
--   * staff_get_dashboard      sales_today = net; refunds today; pending amount.
--   * get_product_sales_30d, get_popular_products: verified sales minus
--     refunded units (completed refunds), same 30-day Manila window as the
--     owner summary.
--   * analytics_report         same numbers, plus refund counts / rates per
--     day and branch, pending refunds, net units per product, by cashier, and
--     loyalty points reversed shown apart from points redeemed.
--   * owner_staff_overview     POS figures from the shared facts (+ gross,
--     discounts, refund count).
--   * admin_portal_orders, staff_list_orders, staff_list_refunds: per-order
--     refund summary (refunded / pending amount, units, points reversed);
--     owner_all_users: each customer's completed refunds beside paid total.
--   * NEW get_my_order_refunds  customers: the same summary for their orders.
--   * finalize_order_refund    points reversed in proportion to the amount
--     refunded (a partial refund no longer takes back every point); still once.
--   * refund amount check      a refund can never exceed what was paid minus
--     refunds already completed on that order (insert and completion).
--   * staff_review_refund      writes the decision to staff_audit_logs (it did
--     not before); admin_portal_review_refund keeps its own entry, no duplicate.
--
-- Not changed on purpose: the refund state machine, request_refund, the POS
-- return / void flow, HitPay functions, the cash drawer (_shift_summary,
-- staff_cashier_daily_summary — already on this definition), and the forecast
-- series (_sales_series / staff_reorder_suggestions take refunded units out of
-- DEMAND on the sale date, which is what a demand forecast needs).
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. The one definition
-- -----------------------------------------------------------------------------

-- One row per verified sale ('sale') and per completed refund ('refund') in
-- [p_start, p_end). Null bounds = unbounded; null p_branch_ids = all branches.
-- (Internal and new in this file: dropped first so a re-run may change its columns.)
drop function if exists public._sales_line_facts(timestamptz, timestamptz, uuid[]);
drop function if exists public._sales_facts(timestamptz, timestamptz, uuid[]);
create or replace function public._sales_facts(
  p_start timestamptz,
  p_end timestamptz,
  p_branch_ids uuid[] default null
)
returns table (
  kind text,
  order_id text,
  refund_id text,
  branch_id uuid,
  staff_uid text,
  event_at timestamptz,
  event_date date,
  is_pos boolean,
  is_void boolean,
  is_delivery boolean,
  payment_method text,
  gross numeric,
  discount numeric,
  delivery_fee numeric,
  refund numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select 'sale'::text, o.id, null::text, o.branch_id, ps.staff_uid, o.created_at,
         (o.created_at at time zone 'Asia/Manila')::date,
         ps.order_id is not null, false, o.is_delivery, pay.method,
         o.subtotal, o.discount, o.delivery_fee, 0::numeric
  from public.orders o
  join lateral (
    select p.method from public.payments p
    where p.order_id = o.id and p.status in ('success', 'refunded')
    order by p.created_at desc limit 1
  ) pay on true
  left join public.pos_sales ps on ps.order_id = o.id
  where (p_start is null or o.created_at >= p_start)
    and (p_end is null or o.created_at < p_end)
    and (p_branch_ids is null or o.branch_id = any (p_branch_ids))
  union all
  select 'refund'::text, r.order_id, r.id, o.branch_id, ps.staff_uid, d.done_at,
         (d.done_at at time zone 'Asia/Manila')::date,
         ps.order_id is not null,
         exists (select 1 from public.pos_voids v where v.refund_id = r.id),
         o.is_delivery,
         coalesce((select p.method from public.payments p where p.order_id = o.id
                   order by p.created_at desc limit 1), r.payment_method),
         0::numeric, 0::numeric, 0::numeric, r.amount
  from public.refund_requests r
  join public.orders o on o.id = r.order_id
  left join public.pos_sales ps on ps.order_id = r.order_id
  cross join lateral (
    -- refund_status_events is written by a trigger on every status change; a
    -- completed refund is final, so updated_at is the fallback for rows that
    -- pre-date that trigger.
    select coalesce(max(e.created_at), r.updated_at) as done_at
    from public.refund_status_events e
    where e.refund_request_id = r.id and e.status = 'completed'
  ) d
  where r.status = 'completed'
    and (p_start is null or d.done_at >= p_start)
    and (p_end is null or d.done_at < p_end)
    and (p_branch_ids is null or o.branch_id = any (p_branch_ids))
$$;

-- Refunds that are open right now (requested, approved or being processed).
create or replace function public._pending_refund_facts(p_branch_ids uuid[] default null)
returns table (
  refund_id text,
  order_id text,
  branch_id uuid,
  staff_uid text,
  status text,
  amount numeric,
  requested_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select r.id, r.order_id, o.branch_id, ps.staff_uid, r.status, r.amount, r.created_at
  from public.refund_requests r
  join public.orders o on o.id = r.order_id
  left join public.pos_sales ps on ps.order_id = r.order_id
  where r.status in ('pending', 'approved', 'processing')
    and (p_branch_ids is null or o.branch_id = any (p_branch_ids))
$$;

-- The same facts per product line. A sale's gross and discount are spread over
-- its lines by line value (quantity x unit price); a refund's amount is spread
-- over its refund_items the same way. So per-product gross / discounts /
-- refunds add up to the order-level totals (up to rounding of the sums).
-- An order without lines, or a refund without items, keeps one line with no
-- product (product_name null) so nothing is lost.
create or replace function public._sales_line_facts(
  p_start timestamptz,
  p_end timestamptz,
  p_branch_ids uuid[] default null
)
returns table (
  kind text,
  order_id text,
  refund_id text,
  branch_id uuid,
  staff_uid text,
  event_date date,
  product_id uuid,
  variant_id uuid,
  product_name text,
  variant_label text,
  units int,
  refunded_units int,
  gross numeric,
  discount numeric,
  refund numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with f as materialized (
    select * from public._sales_facts(p_start, p_end, p_branch_ids)
  ),
  sale_lines as (
    select f.order_id, f.branch_id, f.staff_uid, f.event_date, f.gross, f.discount,
           oi.product_id, oi.variant_id, oi.product_name, oi.variant_label, oi.quantity,
           oi.quantity * oi.unit_price as line_value,
           sum(oi.quantity * oi.unit_price) over (partition by f.order_id) as order_value,
           count(oi.id) over (partition by f.order_id) as line_count
    from f
    left join public.order_items oi on oi.order_id = f.order_id
    where f.kind = 'sale'
  ),
  refund_lines as (
    select f.order_id, f.refund_id, f.branch_id, f.staff_uid, f.event_date, f.refund,
           ri.product_name, ri.variant_label, ri.quantity,
           ri.quantity * ri.unit_price as line_value,
           sum(ri.quantity * ri.unit_price) over (partition by f.refund_id) as refund_value,
           count(ri.id) over (partition by f.refund_id) as line_count
    from f
    left join public.refund_items ri on ri.refund_request_id = f.refund_id
    where f.kind = 'refund'
  )
  select 'sale'::text, s.order_id, null::text, s.branch_id, s.staff_uid, s.event_date,
         s.product_id, s.variant_id, s.product_name, s.variant_label,
         coalesce(s.quantity, 0), 0,
         case when s.line_count = 0 then s.gross
              when coalesce(s.order_value, 0) > 0 then s.gross * s.line_value / s.order_value
              else s.gross / s.line_count end,
         case when s.line_count = 0 then s.discount
              when coalesce(s.order_value, 0) > 0 then s.discount * s.line_value / s.order_value
              else s.discount / s.line_count end,
         0::numeric
  from sale_lines s
  union all
  select 'refund'::text, rl.order_id, rl.refund_id, rl.branch_id, rl.staff_uid, rl.event_date,
         m.product_id, m.variant_id, rl.product_name, rl.variant_label,
         0, coalesce(rl.quantity, 0),
         0::numeric, 0::numeric,
         case when rl.line_count = 0 then rl.refund
              when coalesce(rl.refund_value, 0) > 0 then rl.refund * rl.line_value / rl.refund_value
              else rl.refund / rl.line_count end
  from refund_lines rl
  left join lateral (
    select (array_agg(oi.product_id))[1] as product_id, (array_agg(oi.variant_id))[1] as variant_id
    from public.order_items oi
    where oi.order_id = rl.order_id and oi.product_name = rl.product_name
      and oi.variant_label = rl.variant_label
  ) m on true
$$;

-- The one formula. Parts are rounded first so the shown numbers add up exactly.
create or replace function public._sales_money_json(
  p_orders bigint,
  p_gross numeric,
  p_discounts numeric,
  p_refunds numeric,
  p_refund_count bigint,
  p_delivery_fees numeric default 0
)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'orders', coalesce(p_orders, 0),
    'gross_sales', g,
    'discounts', d,
    'refunds', r,
    'refund_count', coalesce(p_refund_count, 0),
    'net_sales', g - d - r,
    'delivery_fees', f,
    'revenue', g - d - r + f,
    'refund_rate', case when g - d > 0 then round(r / (g - d), 4) end,
    'average_order_value', case when coalesce(p_orders, 0) > 0 then round((g - d) / p_orders, 2) end)
  from (select round(coalesce(p_gross, 0), 2) as g, round(coalesce(p_discounts, 0), 2) as d,
               round(coalesce(p_refunds, 0), 2) as r, round(coalesce(p_delivery_fees, 0), 2) as f) x
$$;

-- Refund state of one order, from the same tables (for order lists and the
-- customer's own orders). 'full' = everything that can be refunded on the
-- order (paid goods value, without delivery fee) has been refunded.
create or replace function public._order_refund_json(p_order_id text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'state', case
               when coalesce(c.amount, 0) > 0
                    and c.amount >= greatest(o.subtotal - o.discount, 0) - 0.005 then 'full'
               when coalesce(c.amount, 0) > 0 then 'partial'
               when coalesce(pd.amount, 0) > 0 then 'pending'
               else 'none' end,
    'refunded_amount', coalesce(c.amount, 0),
    'refund_count', coalesce(c.n, 0),
    'refunded_units', coalesce(c.units, 0),
    'refunded_at', c.done_at,
    'pending_amount', coalesce(pd.amount, 0),
    'pending_status', pd.status,
    'points_reversed', coalesce(lp.reversed, 0),
    'refundable_amount', greatest(coalesce(pay.paid, o.total) - coalesce(c.amount, 0), 0))
  from public.orders o
  left join lateral (
    select sum(r.amount) as amount, count(*) as n,
           (select coalesce(sum(ri.quantity), 0) from public.refund_items ri
              join public.refund_requests r2 on r2.id = ri.refund_request_id
             where r2.order_id = o.id and r2.status = 'completed') as units,
           max((select coalesce(max(e.created_at), r.updated_at) from public.refund_status_events e
                where e.refund_request_id = r.id and e.status = 'completed')) as done_at
    from public.refund_requests r where r.order_id = o.id and r.status = 'completed'
  ) c on true
  left join lateral (
    select sum(r.amount) as amount, max(r.status) as status
    from public.refund_requests r
    where r.order_id = o.id and r.status in ('pending', 'approved', 'processing')
  ) pd on true
  left join lateral (
    select sum(p.amount) as paid from public.payments p
    where p.order_id = o.id and p.status in ('success', 'refunded')
  ) pay on true
  left join lateral (
    select -sum(lt.points)::int as reversed from public.loyalty_transactions lt
    where lt.order_id = o.id and lt.source = 'order_clawback'
  ) lp on true
  where o.id = p_order_id
$$;

-- -----------------------------------------------------------------------------
-- 2. sales_overview: the figures every screen shows (app + website)
-- -----------------------------------------------------------------------------
create or replace function public.sales_overview(
  p_from date default null,
  p_to date default null,
  p_branch_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_from date := coalesce(p_from, (now() at time zone 'Asia/Manila')::date);
  v_to date := coalesce(p_to, (now() at time zone 'Asia/Manila')::date);
  v_start timestamptz;
  v_end timestamptz;
  v_branches uuid[];
  v_detail boolean;
begin
  v_staff := public._require_staff(p_branch_id);
  if v_to < v_from then raise exception 'The end date is before the start date.'; end if;
  if v_to - v_from > 400 then raise exception 'Date range is too long (maximum 400 days).'; end if;
  if p_branch_id is not null and not exists (select 1 from public.branches where id = p_branch_id) then
    raise exception 'That branch could not be found.';
  end if;
  if v_staff.role = 'owner' then
    v_branches := case when p_branch_id is null then null else array[p_branch_id] end;
  else
    if v_staff.branch_id is null then raise exception 'Please choose a branch first.'; end if;
    v_branches := array[v_staff.branch_id];
  end if;
  v_detail := v_staff.role = 'owner' or 'view_reports' = any (public.staff_permission_keys());
  v_start := v_from::timestamp at time zone 'Asia/Manila';
  v_end := (v_to + 1)::timestamp at time zone 'Asia/Manila';

  return (
    with f as materialized (select * from public._sales_facts(v_start, v_end, v_branches)),
    l as materialized (select * from public._sales_line_facts(v_start, v_end, v_branches)),
    pr as materialized (select * from public._pending_refund_facts(v_branches)),
    scope_branches as (
      select b.id, b.name from public.branches b
      where v_branches is null or b.id = any (v_branches)
    ),
    agg_branch as (
      select f.branch_id,
             count(*) filter (where kind = 'sale') as n, sum(gross) as g, sum(discount) as d,
             sum(refund) as r, count(*) filter (where kind = 'refund') as rn, sum(delivery_fee) as fee,
             count(*) filter (where is_void) as voids
      from f group by f.branch_id
    ),
    pend_branch as (
      select pr.branch_id, count(*) as n, sum(amount) as amount from pr group by pr.branch_id
    )
    select jsonb_build_object(
      'from', v_from, 'to', v_to, 'branch_id', case when v_branches is null then null else v_branches[1] end,
      'generated_at', now(),
      'definitions', jsonb_build_object(
        'gross_sales', 'Subtotal of orders with a successful payment (before discounts, without delivery fee), by order date',
        'refunds', 'Completed refunds (the refunded amount, partial refunds included), by the day they completed',
        'net_sales', 'Gross sales - discounts - refunds',
        'refund_rate', 'Refunds / (gross sales - discounts)',
        'pending_refunds', 'Refunds requested, approved or processing right now; not deducted until completed'),
      'summary', (
        select public._sales_money_json(count(*) filter (where kind = 'sale'), sum(gross), sum(discount),
                                        sum(refund), count(*) filter (where kind = 'refund'), sum(delivery_fee))
               || jsonb_build_object('voids', count(*) filter (where is_void),
                                     'pos_orders', count(*) filter (where kind = 'sale' and is_pos),
                                     'online_orders', count(*) filter (where kind = 'sale' and not is_pos))
               || (select jsonb_build_object('units', coalesce(sum(units), 0), 'refunded_units', coalesce(sum(refunded_units), 0),
                                             'net_units', coalesce(sum(units), 0) - coalesce(sum(refunded_units), 0)) from l)
        from f),
      'pending_refunds', (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0)) from pr),
      'by_day', (
        select coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'units', coalesce(u.units, 0),
                                                     'refunded_units', coalesce(u.refunded_units, 0),
                                                     'net_units', coalesce(u.units, 0) - coalesce(u.refunded_units, 0))
                 || public._sales_money_json(s.n, s.g, s.d, s.r, s.rn, s.fee) order by d.day), '[]'::jsonb)
        from (select (v_from + g)::date as day from generate_series(0, v_to - v_from) g) d
        left join (
          select event_date, count(*) filter (where kind = 'sale') as n, sum(gross) as g, sum(discount) as d,
                 sum(refund) as r, count(*) filter (where kind = 'refund') as rn, sum(delivery_fee) as fee
          from f group by event_date) s on s.event_date = d.day
        left join (select event_date, sum(units)::int as units, sum(refunded_units)::int as refunded_units
                   from l group by event_date) u on u.event_date = d.day),
      'by_channel', (
        select coalesce(jsonb_agg(jsonb_build_object('channel', c.channel)
                 || public._sales_money_json(c.n, c.g, c.d, c.r, c.rn, c.fee) order by c.channel), '[]'::jsonb)
        from (
          select case when is_pos then 'pos' when is_delivery then 'delivery' else 'pickup' end as channel,
                 count(*) filter (where kind = 'sale') as n, sum(gross) as g, sum(discount) as d,
                 sum(refund) as r, count(*) filter (where kind = 'refund') as rn, sum(delivery_fee) as fee
          from f group by 1) c),
      'by_branch', (
        select coalesce(jsonb_agg(jsonb_build_object('branch_id', coalesce(sb.id, a.branch_id), 'branch', sb.name)
                 || public._sales_money_json(a.n, a.g, a.d, a.r, a.rn, a.fee)
                 || jsonb_build_object('voids', coalesce(a.voids, 0),
                                       'pending_refund_count', coalesce(pb.n, 0),
                                       'pending_refund_amount', coalesce(pb.amount, 0))
                 order by sb.name nulls last), '[]'::jsonb)
        from scope_branches sb
        full join agg_branch a on a.branch_id = sb.id
        left join pend_branch pb on pb.branch_id = coalesce(sb.id, a.branch_id)),
      'by_method', (
        select coalesce(jsonb_agg(jsonb_build_object('method', m.payment_method, 'amount_paid', m.paid)
                 || public._sales_money_json(m.n, m.g, m.d, m.r, m.rn, m.fee) order by m.g desc nulls last), '[]'::jsonb)
        from (
          select f.payment_method, count(*) filter (where kind = 'sale') as n, sum(gross) as g,
                 sum(discount) as d, sum(refund) as r, count(*) filter (where kind = 'refund') as rn,
                 sum(delivery_fee) as fee, sum(gross - discount + delivery_fee) filter (where kind = 'sale') as paid
          from f group by f.payment_method) m),
      'by_staff', case when v_detail then (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'staff_uid', s.staff_uid,
                 'staff_name', case when s.staff_uid is null then null else coalesce(nullif(sm.full_name, ''), s.staff_uid) end,
                 'channel', case when s.staff_uid is null then 'online' else 'pos' end)
                 || public._sales_money_json(s.n, s.g, s.d, s.r, s.rn, s.fee)
                 || jsonb_build_object('voids', s.voids)
                 order by (s.staff_uid is null), sm.full_name), '[]'::jsonb)
        from (
          select f.staff_uid, count(*) filter (where kind = 'sale') as n, sum(gross) as g, sum(discount) as d,
                 sum(refund) as r, count(*) filter (where kind = 'refund') as rn, sum(delivery_fee) as fee,
                 count(*) filter (where is_void) as voids
          from f group by f.staff_uid) s
        left join public.staff_members sm on sm.firebase_uid = s.staff_uid) end,
      -- Products: every staff member of the branch (the website's Overview shows top sellers).
      'by_product', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'product', p.product_name, 'variant', p.variant_label, 'variant_id', p.variant_id,
                 'units', p.units, 'refunded_units', p.refunded_units, 'net_units', p.units - p.refunded_units)
                 || public._sales_money_json(p.n, p.g, p.d, p.r, p.rn, 0)
                 order by round(p.g, 2) - round(p.d, 2) - round(p.r, 2) desc, p.product_name nulls last), '[]'::jsonb)
        from (
          select l.product_name, l.variant_label, (array_agg(l.variant_id) filter (where l.variant_id is not null))[1] as variant_id,
                 sum(l.units)::int as units, sum(l.refunded_units)::int as refunded_units,
                 count(distinct l.order_id) filter (where l.kind = 'sale') as n,
                 sum(l.gross) as g, sum(l.discount) as d, sum(l.refund) as r,
                 count(distinct l.refund_id) as rn
          from l
          group by l.product_name, l.variant_label) p)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. owner_sales_summary (owner app screens) on the same definition
-- -----------------------------------------------------------------------------
create or replace function public.owner_sales_summary(p_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
  v_days int := least(greatest(coalesce(p_days, 30), 1), 365);
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_week_from date;
  v_window_from date;
  v_start timestamptz;
  v_end timestamptz;
begin
  v_owner := public._require_owner();
  v_week_from := v_today - 6;
  v_window_from := v_today - (v_days - 1);
  v_start := least(v_week_from, v_window_from)::timestamp at time zone 'Asia/Manila';
  v_end := (v_today + 1)::timestamp at time zone 'Asia/Manila';

  return (
    with f as materialized (select * from public._sales_facts(v_start, v_end, null)),
    pr as materialized (select * from public._pending_refund_facts(null)),
    per_branch as (
      select f.branch_id,
        count(*) filter (where kind = 'sale' and event_date = v_today) as n_t,
        sum(gross) filter (where event_date = v_today) as g_t,
        sum(discount) filter (where event_date = v_today) as d_t,
        sum(refund) filter (where event_date = v_today) as r_t,
        count(*) filter (where kind = 'refund' and event_date = v_today) as rn_t,
        sum(delivery_fee) filter (where event_date = v_today) as f_t,
        count(*) filter (where kind = 'sale' and event_date >= v_week_from) as n_w,
        sum(gross) filter (where event_date >= v_week_from) as g_w,
        sum(discount) filter (where event_date >= v_week_from) as d_w,
        sum(refund) filter (where event_date >= v_week_from) as r_w,
        count(*) filter (where kind = 'refund' and event_date >= v_week_from) as rn_w,
        sum(delivery_fee) filter (where event_date >= v_week_from) as f_w,
        count(*) filter (where kind = 'sale' and event_date >= v_window_from) as n_x,
        sum(gross) filter (where event_date >= v_window_from) as g_x,
        sum(discount) filter (where event_date >= v_window_from) as d_x,
        sum(refund) filter (where event_date >= v_window_from) as r_x,
        count(*) filter (where kind = 'refund' and event_date >= v_window_from) as rn_x,
        sum(delivery_fee) filter (where event_date >= v_window_from) as f_x
      from f group by f.branch_id
    ),
    br_rows as (
      select coalesce(b.id, pb.branch_id) as branch_id, b.name,
             public._sales_money_json(pb.n_t, pb.g_t, pb.d_t, pb.r_t, pb.rn_t, pb.f_t) as t,
             public._sales_money_json(pb.n_w, pb.g_w, pb.d_w, pb.r_w, pb.rn_w, pb.f_w) as w,
             public._sales_money_json(pb.n_x, pb.g_x, pb.d_x, pb.r_x, pb.rn_x, pb.f_x) as x,
             (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0))
              from pr where pr.branch_id = coalesce(b.id, pb.branch_id)) as p
      from public.branches b
      full join per_branch pb on pb.branch_id = b.id
    )
    select jsonb_build_object(
      'generated_at', now(),
      'days', v_days,
      'definitions', jsonb_build_object(
        'revenue', 'Net sales: gross sales - discounts - completed refunds',
        'gross_sales', 'Subtotal of orders with a successful payment, by order date (Asia/Manila)',
        'refunds', 'Completed refunds (partial refunds included), by the day they completed',
        'pending_refunds', 'Requested / approved / processing refunds right now, not deducted yet'),
      'branches', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'branch_id', r.branch_id,
                 'name', r.name,
                 -- existing keys (now net sales and verified orders)
                 'today_revenue', r.t -> 'net_sales',
                 'week_revenue', r.w -> 'net_sales',
                 'window_revenue', r.x -> 'net_sales',
                 'orders_today', r.t -> 'orders',
                 'orders_week', r.w -> 'orders',
                 'orders_window', r.x -> 'orders',
                 -- full figures per period
                 'today', r.t, 'week', r.w, 'window', r.x,
                 'gross', r.x -> 'gross_sales',
                 'discounts', r.x -> 'discounts',
                 'refunds', r.x -> 'refunds',
                 'net', r.x -> 'net_sales',
                 'refund_count', r.x -> 'refund_count',
                 'refund_rate', r.x -> 'refund_rate',
                 'pending_refund_count', r.p -> 'count',
                 'pending_refund_amount', r.p -> 'amount'
               ) order by r.name nulls last), '[]'::jsonb)
        from br_rows r),
      'totals', (
        select jsonb_build_object(
          'today', public._sales_money_json(count(*) filter (where kind = 'sale' and event_date = v_today),
                     sum(gross) filter (where event_date = v_today), sum(discount) filter (where event_date = v_today),
                     sum(refund) filter (where event_date = v_today),
                     count(*) filter (where kind = 'refund' and event_date = v_today),
                     sum(delivery_fee) filter (where event_date = v_today)),
          'week', public._sales_money_json(count(*) filter (where kind = 'sale' and event_date >= v_week_from),
                     sum(gross) filter (where event_date >= v_week_from), sum(discount) filter (where event_date >= v_week_from),
                     sum(refund) filter (where event_date >= v_week_from),
                     count(*) filter (where kind = 'refund' and event_date >= v_week_from),
                     sum(delivery_fee) filter (where event_date >= v_week_from)),
          'window', public._sales_money_json(count(*) filter (where kind = 'sale' and event_date >= v_window_from),
                     sum(gross) filter (where event_date >= v_window_from), sum(discount) filter (where event_date >= v_window_from),
                     sum(refund) filter (where event_date >= v_window_from),
                     count(*) filter (where kind = 'refund' and event_date >= v_window_from),
                     sum(delivery_fee) filter (where event_date >= v_window_from)),
          'pending_refunds', (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0)) from pr))
        from f),
      'products', (
        -- (money keys first; 'revenue' here is net sales, as in the old key)
        select coalesce(jsonb_agg(t.m || jsonb_build_object(
                 'product_name', t.product_name,
                 'units', t.units - t.refunded_units,       -- net units (sold - refunded)
                 'revenue', t.m -> 'net_sales',             -- net item sales
                 'gross_units', t.units,
                 'refunded_units', t.refunded_units)
                 order by (t.m ->> 'net_sales')::numeric desc, t.product_name), '[]'::jsonb)
        from (
          select l.product_name, sum(l.units)::int as units, sum(l.refunded_units)::int as refunded_units,
                 public._sales_money_json(count(distinct l.order_id) filter (where l.kind = 'sale'), sum(l.gross),
                                          sum(l.discount), sum(l.refund), count(distinct l.refund_id), 0) as m
          from public._sales_line_facts(v_window_from::timestamp at time zone 'Asia/Manila', v_end, null) l
          where l.product_name is not null
          group by l.product_name
          order by round(sum(l.gross), 2) - round(sum(l.discount), 2) - round(sum(l.refund), 2) desc, l.product_name
          limit 50) t),
      'daily', (
        select coalesce(jsonb_agg(m || jsonb_build_object('date', d.day, 'revenue', m -> 'net_sales') order by d.day), '[]'::jsonb)
        from (select (v_window_from + g)::date as day from generate_series(0, v_days - 1) g) d
        cross join lateral (
          select public._sales_money_json(count(*) filter (where kind = 'sale'), sum(gross), sum(discount),
                                          sum(refund), count(*) filter (where kind = 'refund'), sum(delivery_fee)) as m
          from f where f.event_date = d.day) x)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. staff_get_dashboard: sales today = net sales (same scope rules as before)
-- -----------------------------------------------------------------------------
create or replace function public.staff_get_dashboard(p_branch_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branch uuid;
  v_day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Manila') at time zone 'Asia/Manila';
  v_today date := (now() at time zone 'Asia/Manila')::date;
  b record;
  o record;
  v_money jsonb;
  v_low int;
  v_out int;
  v_expiring int;
  v_await_approval int;
  v_await_receipt int;
  v_refunds int;
  v_refund_amount numeric;
  v_unread int;
begin
  v_staff := public._require_staff();
  v_branch := case when v_staff.role = 'owner' then p_branch_id else v_staff.branch_id end;
  if v_branch is null then raise exception 'Please choose a branch first.'; end if;
  select * into b from public.branches where id = v_branch;
  if not found then raise exception 'That branch could not be found.'; end if;

  select
    count(*) filter (where created_at >= v_day_start) as orders_today,
    count(*) filter (where status in ('pending', 'confirmed')) as pending_orders,
    count(*) filter (where status = 'preparing') as preparing_orders,
    count(*) filter (where status in ('readyForPickup', 'outForDelivery')) as ready_orders,
    count(*) filter (where created_at >= v_day_start and status = 'completed') as completed_today,
    count(*) filter (where created_at >= v_day_start and status = 'cancelled') as cancelled_today
  into o
  from public.orders where branch_id = v_branch;

  select public._sales_money_json(count(*) filter (where kind = 'sale'), sum(gross), sum(discount),
                                  sum(refund), count(*) filter (where kind = 'refund'), sum(delivery_fee))
    into v_money
  from public._sales_facts(v_day_start, null, array[v_branch]);

  with items as (
    select bi.quantity,
           coalesce(th.restock_threshold, public._default_restock_threshold()) as thr
    from public.branch_inventory bi
    join public.products p on p.id = bi.product_id and p.is_active
    left join public.stock_thresholds th on th.branch_id = bi.branch_id and th.variant_id = bi.variant_id
    where bi.branch_id = v_branch and bi.variant_id is not null
  )
  select count(*) filter (where quantity = 0), count(*) filter (where quantity > 0 and quantity <= thr)
  into v_out, v_low from items;

  select count(*) into v_expiring from public.inventory_batches
  where branch_id = v_branch and quantity > 0 and expiration_date <= v_today + 15;

  select count(*) into v_await_approval from public.stock_transfers
  where from_branch_id = v_branch and status = 'requested';
  select count(*) into v_await_receipt from public.stock_transfers
  where to_branch_id = v_branch and status = 'in_transit';

  if v_staff.role = 'owner' or v_staff.can_review_refunds then
    select count(*), coalesce(sum(amount), 0) into v_refunds, v_refund_amount
    from public._pending_refund_facts(array[v_branch]);
  end if;

  select count(*) into v_unread from public.staff_notifications
  where recipient_uid = v_staff.firebase_uid and not read;

  return jsonb_build_object(
    'branch', jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address, 'contact_phone', b.contact_phone,
      'operating_hours', b.operating_hours, 'is_active', b.is_active,
      'supports_delivery', b.supports_delivery, 'supports_pickup', b.supports_pickup),
    'sales_today', v_money -> 'net_sales',          -- net sales today (gross - discounts - refunds)
    'net_sales_today', v_money -> 'net_sales',
    'gross_sales_today', v_money -> 'gross_sales',
    'discounts_today', v_money -> 'discounts',
    'refunds_today', v_money -> 'refunds',
    'refund_count_today', v_money -> 'refund_count',
    'refund_rate_today', v_money -> 'refund_rate',
    'paid_orders_today', v_money -> 'orders',
    'orders_today', o.orders_today,
    'pending_orders', o.pending_orders,
    'preparing_orders', o.preparing_orders,
    'ready_orders', o.ready_orders,
    'completed_today', o.completed_today,
    'cancelled_today', o.cancelled_today,
    'low_stock_count', v_low,
    'out_of_stock_count', v_out,
    'expiring_soon_count', v_expiring,
    'transfers_awaiting_approval', v_await_approval,
    'transfers_awaiting_receipt', v_await_receipt,
    'pending_refunds', v_refunds,                -- null when the caller may not review refunds
    'pending_refund_amount', v_refund_amount,    -- null when the caller may not review refunds
    'unread_notifications', v_unread,
    'generated_at', now()
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Product units: verified sales minus refunded units
-- -----------------------------------------------------------------------------
-- Every active product's net units in the last 30 Manila days (today included,
-- the same window as owner_sales_summary(30)). 0 when nothing sold; can be
-- below 0 only if more units were refunded in the window than sold in it.
create or replace function public.get_product_sales_30d()
returns table (product_id uuid, units_sold bigint)
language sql
stable
security definer
set search_path = public
as $$
  select p.id as product_id,
         coalesce(sum(l.units - l.refunded_units), 0)::bigint as units_sold
  from public.products p
  left join public._sales_line_facts(
         (((now() at time zone 'Asia/Manila')::date - 29)::timestamp at time zone 'Asia/Manila'), null, null) l
    on l.product_id = p.id or (l.product_id is null and l.product_name = p.name)
  where p.is_active
  group by p.id
$$;

create or replace function public.get_popular_products(p_limit int default 8)
returns table (product_id uuid, total_quantity bigint)
language sql
stable
security definer
set search_path = public
as $$
  select p.id as product_id, sum(l.units - l.refunded_units)::bigint as total_quantity
  from public._sales_line_facts(null, null, null) l
  join public.products p on p.id = l.product_id or (l.product_id is null and p.name = l.product_name)
  where p.is_active
  group by p.id
  having sum(l.units - l.refunded_units) > 0
  order by total_quantity desc
  limit greatest(p_limit, 0)
$$;

-- -----------------------------------------------------------------------------
-- 6. analytics_report on the shared facts (same keys, more refund detail)
-- -----------------------------------------------------------------------------
create or replace function public.analytics_report(
  p_from date,
  p_to date,
  p_branch_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_from date := coalesce(p_from, (now() at time zone 'Asia/Manila')::date - 29);
  v_to date := coalesce(p_to, (now() at time zone 'Asia/Manila')::date);
  v_start timestamptz;
  v_end timestamptz;
  v_branches uuid[];
  v_summary jsonb;
begin
  v_staff := public._require_reports(p_branch_id);
  if v_to < v_from then raise exception 'The end date is before the start date.'; end if;
  if v_to - v_from > 400 then raise exception 'Date range is too long (maximum 400 days).'; end if;
  v_start := v_from::timestamp at time zone 'Asia/Manila';
  v_end := (v_to + 1)::timestamp at time zone 'Asia/Manila';
  v_branches := case when p_branch_id is null then null else array[p_branch_id] end;

  create temp table if not exists _ar_facts on commit drop as
    select * from public._sales_facts(null, null, null) limit 0;
  truncate _ar_facts;
  insert into _ar_facts select * from public._sales_facts(v_start, v_end, v_branches);

  create temp table if not exists _ar_lines on commit drop as
    select * from public._sales_line_facts(null, null, null) limit 0;
  truncate _ar_lines;
  insert into _ar_lines select * from public._sales_line_facts(v_start, v_end, v_branches);

  select public._sales_money_json(count(*) filter (where kind = 'sale'), sum(gross), sum(discount),
                                  sum(refund), count(*) filter (where kind = 'refund'), sum(delivery_fee))
         || jsonb_build_object(
              'verified_orders', count(*) filter (where kind = 'sale'),
              'pos_orders', count(*) filter (where kind = 'sale' and is_pos),
              'online_orders', count(*) filter (where kind = 'sale' and not is_pos),
              'voids', count(*) filter (where is_void))
    into v_summary
  from _ar_facts;

  v_summary := v_summary || jsonb_build_object(
    'pending_refunds', (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0))
                        from public._pending_refund_facts(v_branches)),
    'pending_payments', (
      select jsonb_build_object('count', count(*), 'amount', coalesce(sum(o.total), 0))
      from public.orders o join public.payments p on p.order_id = o.id
      where p.status in ('pending', 'processing') and o.status <> 'cancelled'
        and o.created_at >= v_start and o.created_at < v_end
        and (p_branch_id is null or o.branch_id = p_branch_id)),
    'cancelled_orders', (
      select count(*) from public.orders o
      where o.status = 'cancelled' and o.created_at >= v_start and o.created_at < v_end
        and (p_branch_id is null or o.branch_id = p_branch_id)),
    'completed_deliveries', (
      select count(*) from public.delivery_stops ds join public.deliveries d on d.id = ds.delivery_id
      join public.orders o on o.id = ds.order_id
      where ds.status = 'delivered' and o.status = 'completed'
        and coalesce(ds.delivered_at, ds.updated_at) >= v_start and coalesce(ds.delivered_at, ds.updated_at) < v_end
        and (p_branch_id is null or d.branch_id = p_branch_id)),
    'failed_deliveries', (
      select count(*) from public.delivery_stops ds join public.deliveries d on d.id = ds.delivery_id
      where ds.status = 'failed' and ds.failed_at >= v_start and ds.failed_at < v_end
        and (p_branch_id is null or d.branch_id = p_branch_id)));

  return jsonb_build_object(
    'from', v_from, 'to', v_to, 'branch_id', p_branch_id,
    'definitions', jsonb_build_object(
      'gross_sales', 'Subtotal of orders with a verified payment (before discounts, without delivery fee), by order date',
      'refunds', 'Completed refunds (partial refunds included), by completion date',
      'net_sales', 'Gross sales - discounts - refunds',
      'refund_rate', 'Refunds / (gross sales - discounts)',
      'revenue', 'Net sales + delivery fees',
      'pending_refunds', 'Refunds requested / approved / processing right now (not deducted)',
      'pending_payments', 'Orders not cancelled whose payment is not verified yet (not counted as sales)',
      'units', 'Units sold on verified orders minus units refunded (completed refunds, by completion date)'),
    'summary', v_summary,

    'by_day', (
      select coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'units', coalesce(u.units, 0),
                                                   'refunded_units', coalesce(u.refunded_units, 0),
                                                   'net_units', coalesce(u.units, 0) - coalesce(u.refunded_units, 0))
               || public._sales_money_json(s.n, s.g, s.d, s.r, s.rn, s.fee) order by d.day), '[]'::jsonb)
      from (select (v_from + g)::date as day from generate_series(0, v_to - v_from) g) d
      left join (select event_date, count(*) filter (where kind = 'sale') n, sum(gross) g, sum(discount) d,
                        sum(refund) r, count(*) filter (where kind = 'refund') rn, sum(delivery_fee) fee
                 from _ar_facts group by event_date) s on s.event_date = d.day
      left join (select event_date, sum(units)::int as units, sum(refunded_units)::int as refunded_units
                 from _ar_lines group by event_date) u on u.event_date = d.day),

    'by_branch', (
      select coalesce(jsonb_agg(jsonb_build_object('branch_id', coalesce(b.id, s.branch_id), 'branch', b.name)
               || public._sales_money_json(s.n, s.g, s.d, s.r, s.rn, s.fee)
               || jsonb_build_object('pending_refund_count', coalesce(pd.n, 0), 'pending_refund_amount', coalesce(pd.amount, 0))
               order by b.name nulls last), '[]'::jsonb)
      from (select * from public.branches where p_branch_id is null or id = p_branch_id) b
      full join (select branch_id, count(*) filter (where kind = 'sale') n, sum(gross) g, sum(discount) d,
                        sum(refund) r, count(*) filter (where kind = 'refund') rn, sum(delivery_fee) fee
                 from _ar_facts group by branch_id) s on s.branch_id = b.id
      left join (select branch_id, count(*) n, sum(amount) amount from public._pending_refund_facts(v_branches)
                 group by branch_id) pd on pd.branch_id = coalesce(b.id, s.branch_id)),

    'by_payment_method', (
      select coalesce(jsonb_agg(jsonb_build_object('method', payment_method, 'orders', n, 'amount', coalesce(paid, 0))
               || public._sales_money_json(n, g, d, r, rn, fee) order by g desc nulls last), '[]'::jsonb)
      from (select payment_method, count(*) filter (where kind = 'sale') n, sum(gross) g, sum(discount) d,
                   sum(refund) r, count(*) filter (where kind = 'refund') rn, sum(delivery_fee) fee,
                   sum(gross - discount + delivery_fee) filter (where kind = 'sale') paid
            from _ar_facts group by payment_method) t),

    'by_category', (
      select coalesce(jsonb_agg(jsonb_build_object('category', category, 'units', units - refunded_units,
                                                   'gross_units', units, 'refunded_units', refunded_units)
               || public._sales_money_json(n, g, d, r, rn, 0) order by g desc), '[]'::jsonb)
      from (
        select coalesce(pc.label, 'Uncategorised') as category, sum(l.units)::int as units,
               sum(l.refunded_units)::int as refunded_units, count(distinct l.order_id) filter (where l.kind = 'sale') n,
               sum(l.gross) g, sum(l.discount) d, sum(l.refund) r, count(distinct l.refund_id) rn
        from _ar_lines l
        left join public.products p on p.id = l.product_id
        left join public.product_categories pc on pc.id = p.category_id
        group by 1) t),

    'by_product', (
      select coalesce(jsonb_agg(jsonb_build_object('product', product_name, 'variant', variant_label, 'variant_id', variant_id,
                                                   'units', units - refunded_units, 'gross_units', units,
                                                   'refunded_units', refunded_units)
               || public._sales_money_json(n, g, d, r, rn, 0)
               order by round(g, 2) - round(d, 2) - round(r, 2) desc, product_name nulls last), '[]'::jsonb)
      from (
        select l.product_name, l.variant_label, (array_agg(l.variant_id) filter (where l.variant_id is not null))[1] as variant_id,
               sum(l.units)::int as units, sum(l.refunded_units)::int as refunded_units,
               count(distinct l.order_id) filter (where l.kind = 'sale') n,
               sum(l.gross) g, sum(l.discount) d, sum(l.refund) r, count(distinct l.refund_id) rn
        from _ar_lines l group by l.product_name, l.variant_label) t),

    'top_products', (
      select coalesce(jsonb_agg(jsonb_build_object('product', product_name, 'variant', variant_label, 'variant_id', variant_id,
                                                   'units', units - refunded_units, 'gross_units', units,
                                                   'refunded_units', refunded_units,
                                                   'gross_sales', round(g, 2), 'refunds', round(r, 2),
                                                   'net_sales', round(g, 2) - round(d, 2) - round(r, 2))
               order by round(g, 2) - round(d, 2) - round(r, 2) desc), '[]'::jsonb)
      from (
        select l.product_name, l.variant_label, (array_agg(l.variant_id) filter (where l.variant_id is not null))[1] as variant_id,
               sum(l.units)::int as units, sum(l.refunded_units)::int as refunded_units,
               sum(l.gross) g, sum(l.discount) d, sum(l.refund) r
        from _ar_lines l where l.product_name is not null
        group by l.product_name, l.variant_label
        order by round(sum(l.gross), 2) - round(sum(l.discount), 2) - round(sum(l.refund), 2) desc
        limit 15) t),

    'by_staff', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'staff_uid', s.staff_uid,
               'staff_name', case when s.staff_uid is null then null else coalesce(nullif(sm.full_name, ''), s.staff_uid) end,
               'channel', case when s.staff_uid is null then 'online' else 'pos' end)
               || public._sales_money_json(s.n, s.g, s.d, s.r, s.rn, s.fee) || jsonb_build_object('voids', s.voids)
               order by (s.staff_uid is null), sm.full_name), '[]'::jsonb)
      from (select staff_uid, count(*) filter (where kind = 'sale') n, sum(gross) g, sum(discount) d,
                   sum(refund) r, count(*) filter (where kind = 'refund') rn, sum(delivery_fee) fee,
                   count(*) filter (where is_void) voids
            from _ar_facts group by staff_uid) s
      left join public.staff_members sm on sm.firebase_uid = s.staff_uid),

    -- Active products that are in stock but sold least (net of refunds, including zero).
    'slow_movers', (
      select coalesce(jsonb_agg(jsonb_build_object('product', product, 'variant', variant, 'variant_id', variant_id,
                                                   'in_stock', stock, 'units_sold', units) order by units, stock desc), '[]'::jsonb)
      from (
        select p.name as product, pv.label as variant, pv.id as variant_id, sum(bi.quantity)::int as stock,
               coalesce((select sum(l.units - l.refunded_units) from _ar_lines l where l.variant_id = pv.id), 0)::int as units
        from public.product_variants pv
        join public.products p on p.id = pv.product_id and p.is_active
        join public.branch_inventory bi on bi.variant_id = pv.id and (p_branch_id is null or bi.branch_id = p_branch_id)
        group by p.name, pv.label, pv.id
        having sum(bi.quantity) > 0
        order by units, stock desc limit 15) t),

    'customers', (
      select jsonb_build_object(
        'new_customers', (select count(*) from public.customer_profiles c
                          where c.firebase_uid <> 'walk-in' and c.created_at >= v_start and c.created_at < v_end),
        'active_customers', count(distinct firebase_uid),
        'repeat_customers', count(*) filter (where n >= 2),
        'repeat_rate', case when count(*) > 0 then round(count(*) filter (where n >= 2)::numeric / count(*), 4) end)
      from (select o.firebase_uid, count(*) n from _ar_facts f join public.orders o on o.id = f.order_id
            where f.kind = 'sale' and o.firebase_uid <> 'walk-in' group by o.firebase_uid) t),

    -- Points reversed by refunds are shown apart from points customers redeemed.
    'loyalty', (
      select jsonb_build_object(
        'points_earned', coalesce(sum(points) filter (where points > 0 and coalesce(source, 'order_earn') <> 'admin_adjust'), 0),
        'points_redeemed', coalesce(-sum(points) filter (where points < 0 and coalesce(source, 'order_redeem') = 'order_redeem'), 0),
        'points_reversed', coalesce(-sum(points) filter (where source = 'order_clawback'), 0),
        'points_adjusted', coalesce(sum(points) filter (where source = 'admin_adjust'), 0),
        'members_active', count(distinct firebase_uid))
      from public.loyalty_transactions lt
      where lt.created_at >= v_start and lt.created_at < v_end
        and (p_branch_id is null or exists (select 1 from public.orders o where o.id = lt.order_id and o.branch_id = p_branch_id))),

    'drivers', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'driver_uid', t.driver_uid, 'driver', t.full_name, 'runs', t.runs, 'delivered', t.delivered,
               'failed', t.failed,
               'success_rate', case when t.delivered + t.failed > 0 then round(t.delivered::numeric / (t.delivered + t.failed), 4) end,
               'avg_minutes_pickup_to_delivered', t.avg_minutes) order by t.delivered desc), '[]'::jsonb)
      from (
        select dr.firebase_uid as driver_uid, dr.full_name,
               count(distinct d.id) as runs,
               count(*) filter (where ds.status = 'delivered') as delivered,
               count(*) filter (where ds.status = 'failed') as failed,
               round(avg(extract(epoch from ds.delivered_at - d.picked_up_at) / 60)
                       filter (where ds.status = 'delivered' and d.picked_up_at is not null)::numeric, 1) as avg_minutes
        from public.drivers dr
        join public.deliveries d on d.driver_uid = dr.firebase_uid
        join public.delivery_stops ds on ds.delivery_id = d.id
        where d.created_at >= v_start and d.created_at < v_end
          and (p_branch_id is null or d.branch_id = p_branch_id)
        group by dr.firebase_uid, dr.full_name) t),

    'inventory', (
      select jsonb_build_object(
        'units_on_hand', coalesce(sum(bi.quantity), 0),
        'stock_value_at_cost', sum(bi.quantity * c.cost_price),
        'variants_without_cost', count(*) filter (where c.cost_price is null and bi.quantity > 0),
        'out_of_stock', count(*) filter (where bi.quantity = 0),
        'low_stock', count(*) filter (where bi.quantity > 0 and bi.quantity <= coalesce(st.restock_threshold, public._default_restock_threshold())))
      from public.branch_inventory bi
      join public.products p on p.id = bi.product_id and p.is_active
      left join public.product_variant_costs c on c.variant_id = bi.variant_id
      left join public.stock_thresholds st on st.branch_id = bi.branch_id and st.variant_id = bi.variant_id
      where p_branch_id is null or bi.branch_id = p_branch_id)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. owner_staff_overview: POS figures from the shared facts
-- -----------------------------------------------------------------------------
create or replace function public.owner_staff_overview(
  p_from timestamptz,
  p_to timestamptz,
  p_branch_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_owner();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Choose a valid date range.';
  end if;
  if p_to - p_from > interval '400 days' then
    raise exception 'Date range is too long (maximum 400 days).';
  end if;
  if p_branch_id is not null and not exists (select 1 from public.branches where id = p_branch_id) then
    raise exception 'That branch does not exist.';
  end if;

  return (
    with pos as (
      select f.staff_uid,
             count(*) filter (where kind = 'sale') as tx,
             coalesce(sum(gross), 0) as gross, coalesce(sum(discount), 0) as disc,
             coalesce(sum(refund), 0) as refunds, count(*) filter (where kind = 'refund') as refund_count
      from public._sales_facts(p_from, p_to,
                               case when p_branch_id is null then null else array[p_branch_id] end) f
      where f.is_pos and f.staff_uid is not null
      group by f.staff_uid
    ),
    shifts as (
      select s.staff_uid,
             count(*) filter (where s.opened_at >= p_from and s.opened_at < p_to) as opened,
             bool_or(s.status = 'open') as is_open
      from public.cash_drawer_sessions s
      where p_branch_id is null or s.branch_id = p_branch_id
      group by s.staff_uid
    ),
    activity as (
      select uid, max(at) as last_at from (
        select ps.staff_uid as uid, max(ps.created_at) as at from public.pos_sales ps group by 1
        union all
        select s.staff_uid, max(greatest(s.opened_at, coalesce(s.closed_at, s.opened_at))) from public.cash_drawer_sessions s group by 1
        union all
        select m.created_by, max(m.created_at) from public.stock_movements m where m.created_by is not null group by 1
      ) a
      group by uid
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'firebase_uid', sm.firebase_uid,
             'full_name', sm.full_name,
             'email', sm.email,
             'role', sm.role,
             'branch_id', sm.branch_id,
             'branch_name', b.name,
             'account_status', sm.account_status,
             'is_active', sm.is_active,
             'pos_transactions', coalesce(p.tx, 0),
             'pos_gross_sales', round(coalesce(p.gross, 0), 2),
             'pos_discounts', round(coalesce(p.disc, 0), 2),
             'pos_sales', round(coalesce(p.gross, 0), 2) - round(coalesce(p.disc, 0), 2),   -- after discounts
             'pos_refunds', round(coalesce(p.refunds, 0), 2),
             'pos_refund_count', coalesce(p.refund_count, 0),
             'pos_net_sales', round(coalesce(p.gross, 0), 2) - round(coalesce(p.disc, 0), 2) - round(coalesce(p.refunds, 0), 2),
             'pos_refund_rate', case when coalesce(p.gross, 0) - coalesce(p.disc, 0) > 0
                                     then round(p.refunds / (p.gross - p.disc), 4) end,
             'shifts_opened', coalesce(sh.opened, 0),
             'open_shift', coalesce(sh.is_open, false),
             'last_activity_at', ac.last_at
           ) order by coalesce(p.gross - p.disc, 0) desc, sm.role desc, sm.full_name), '[]'::jsonb)
    from public.staff_members sm
    left join public.branches b on b.id = sm.branch_id
    left join pos p on p.staff_uid = sm.firebase_uid
    left join shifts sh on sh.staff_uid = sm.firebase_uid
    left join activity ac on ac.uid = sm.firebase_uid
    where p_branch_id is null
       or sm.branch_id = p_branch_id
       or p.staff_uid is not null or coalesce(sh.opened, 0) > 0
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Order lists carry the order's refund summary
-- -----------------------------------------------------------------------------
create or replace function public.admin_portal_orders(
  p_from timestamptz,
  p_to timestamptz,
  p_branch_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branches uuid[];
  v_refunds boolean;
begin
  v_staff := public._require_staff();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Choose a valid date range.';
  end if;
  if p_to - p_from > interval '400 days' then
    raise exception 'Date range is too long (maximum 400 days).';
  end if;
  v_branches := public.staff_authorized_branch_ids();
  if p_branch_id is not null then
    if not (p_branch_id = any (v_branches)) then
      raise exception 'You can only work in your assigned branch.';
    end if;
    v_branches := array[p_branch_id];
  end if;
  v_refunds := public.staff_has_permission('refunds');

  return (
    select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb)
    from (
      select o.created_at,
        jsonb_build_object(
          'id', o.id, 'created_at', o.created_at, 'updated_at', o.updated_at, 'status', o.status,
          'branch_id', o.branch_id, 'branch_name', o.branch_name, 'is_delivery', o.is_delivery,
          'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', o.total,
          'payment_label', o.payment_method, 'points_earned', o.points_earned,
          'customer_uid', case when o.firebase_uid = 'walk-in' then null else o.firebase_uid end,
          'customer_name', case when o.firebase_uid = 'walk-in' then 'Walk-in' else nullif(cp.full_name, '') end,
          'is_pos', exists (select 1 from public.pos_sales ps where ps.order_id = o.id),
          'items', (select coalesce(jsonb_agg(jsonb_build_object(
                      'product_name', i.product_name, 'variant_label', i.variant_label,
                      'quantity', i.quantity, 'unit_price', i.unit_price)), '[]'::jsonb)
                    from public.order_items i where i.order_id = o.id),
          'payment', (select jsonb_build_object('id', pay.id, 'method', pay.method, 'status', pay.status,
                                                'reference_number', pay.reference_number, 'amount', pay.amount,
                                                'updated_at', pay.updated_at)
                      from public.payments pay where pay.order_id = o.id
                      order by pay.created_at desc limit 1),
          -- Amounts only (they are part of the order's money); details stay behind 'refunds'.
          'refund_summary', public._order_refund_json(o.id),
          'refund', case when v_refunds then (
                      select jsonb_build_object('id', r.id, 'status', r.status, 'amount', r.amount,
                                                'reason', r.reason, 'notes', r.notes,
                                                'payment_method', r.payment_method,
                                                'created_at', r.created_at, 'updated_at', r.updated_at,
                                                'completed_at', (select max(e.created_at) from public.refund_status_events e
                                                                 where e.refund_request_id = r.id and e.status = 'completed'))
                      from public.refund_requests r where r.order_id = o.id
                      order by r.created_at desc limit 1) end
        ) as j
      from public.orders o
      left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
      where o.branch_id = any (v_branches)
        and o.created_at >= p_from and o.created_at <= p_to
      order by o.created_at desc
      limit 5000
    ) x
  );
end;
$$;

create or replace function public.staff_list_orders(
  p_branch_id uuid default null,
  p_statuses text[] default null,
  p_since timestamptz default null,
  p_limit int default 100,
  p_order_id text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branch uuid;
begin
  v_staff := public._require_staff();
  v_branch := case when v_staff.role = 'owner' then p_branch_id else v_staff.branch_id end;
  if v_branch is null then raise exception 'Please choose a branch first.'; end if;

  return (
    select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb)
    from (
      select o.created_at,
        jsonb_build_object(
          'id', o.id, 'created_at', o.created_at, 'status', o.status,
          'branch_id', o.branch_id, 'branch_name', o.branch_name, 'is_delivery', o.is_delivery,
          'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', o.total,
          'payment_method', o.payment_method, 'points_earned', o.points_earned,
          'customer_notes', o.customer_notes, 'contact_phone', o.contact_phone,
          'delivery_address_text', o.delivery_address_text,
          'rider_name', o.rider_name, 'eta_label', o.eta_label,
          'customer_name', case when o.firebase_uid = 'walk-in' then null else nullif(cp.full_name, '') end,
          'is_pos', (ps.order_id is not null),
          'cashier_name', nullif(ps.staff_name, ''),
          'cash_received', ps.cash_received, 'change_given', ps.change_given,
          'items', (select coalesce(jsonb_agg(jsonb_build_object(
                      'product_name', i.product_name, 'variant_label', i.variant_label,
                      'quantity', i.quantity, 'unit_price', i.unit_price)), '[]'::jsonb)
                    from public.order_items i where i.order_id = o.id),
          'payment', (select jsonb_build_object('id', pay.id, 'method', pay.method, 'status', pay.status,
                                                'reference_number', pay.reference_number, 'amount', pay.amount)
                      from public.payments pay where pay.order_id = o.id limit 1),
          'refund_summary', public._order_refund_json(o.id)
        ) as j
      from public.orders o
      left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
      left join public.pos_sales ps on ps.order_id = o.id
      where o.branch_id = v_branch
        and (p_statuses is null or o.status = any(p_statuses))
        and (p_since is null or o.created_at >= p_since)
        and (p_order_id is null or o.id = p_order_id)
      order by o.created_at desc
      limit least(greatest(coalesce(p_limit, 100), 1), 300)
    ) x
  );
end;
$$;

create or replace function public.staff_list_refunds(
  p_branch_id uuid default null,
  p_statuses text[] default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_branch uuid;
begin
  v_staff := public._require_staff(null, 'refunds');
  v_branch := case when v_staff.role = 'owner' then p_branch_id else v_staff.branch_id end;
  if v_branch is null then raise exception 'Please choose a branch first.'; end if;
  return (
    select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb)
    from (
      select r.created_at,
        jsonb_build_object(
          'id', r.id, 'order_id', r.order_id, 'status', r.status, 'reason', r.reason, 'notes', r.notes,
          'amount', r.amount, 'payment_method', r.payment_method, 'created_at', r.created_at,
          'completed_at', (select max(e.created_at) from public.refund_status_events e
                           where e.refund_request_id = r.id and e.status = 'completed'),
          'customer_name', nullif(cp.full_name, ''),
          'order_total', o.total,
          'is_pos', exists (select 1 from public.pos_sales ps where ps.order_id = o.id),
          'is_partial', r.amount < greatest(o.subtotal - o.discount, 0) - 0.005,
          'order_refund', public._order_refund_json(o.id),
          'items', (select coalesce(jsonb_agg(jsonb_build_object(
                      'product_name', ri.product_name, 'variant_label', ri.variant_label,
                      'quantity', ri.quantity, 'unit_price', ri.unit_price)), '[]'::jsonb)
                    from public.refund_items ri where ri.refund_request_id = r.id),
          'returned', (select coalesce(jsonb_agg(jsonb_build_object(
                         'product_name', rr.product_name, 'variant_label', rr.variant_label,
                         'quantity', rr.quantity, 'condition', rr.condition, 'received_at', rr.created_at)
                         order by rr.created_at), '[]'::jsonb)
                       from public.refund_returned_items rr where rr.refund_id = r.id)
        ) as j
      from public.refund_requests r
      join public.orders o on o.id = r.order_id
      left join public.customer_profiles cp on cp.firebase_uid = r.firebase_uid
      where o.branch_id = v_branch and (p_statuses is null or r.status = any(p_statuses))
      order by r.created_at desc
      limit 200
    ) x
  );
end;
$$;

-- Customers: refund summary of their own orders (all, or the ones listed).
create or replace function public.get_my_order_refunds(p_order_ids text[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
begin
  if v_uid is null then raise exception 'Please sign in.'; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object('order_id', o.id) || public._order_refund_json(o.id)
                              order by o.created_at desc), '[]'::jsonb)
    from public.orders o
    where o.firebase_uid = v_uid
      and (p_order_ids is null or o.id = any (p_order_ids))
      and exists (select 1 from public.refund_requests r where r.order_id = o.id)
  );
end;
$$;

-- Users page: each customer's completed refunds next to what they paid
-- (owner_all_users from 20261014000000, + refunded_total; nothing else changed).
create or replace function public.owner_all_users(
  p_search text default null,
  p_limit int default 500
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := nullif(lower(trim(coalesce(p_search, ''))), '');
  v_limit int := least(greatest(coalesce(p_limit, 500), 1), 2000);
begin
  perform public._require_owner();

  return jsonb_build_object(
    'staff', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'firebase_uid', s.firebase_uid, 'full_name', s.full_name, 'email', s.email,
               'role', s.role, 'branch_id', s.branch_id, 'branch_name', b.name,
               'is_active', s.is_active, 'account_status', s.account_status,
               'can_manage_inventory', s.can_manage_inventory, 'can_review_refunds', s.can_review_refunds,
               'created_at', s.created_at)
             order by s.role desc, s.full_name, s.firebase_uid), '[]'::jsonb)
      from public.staff_members s
      left join public.branches b on b.id = s.branch_id
    ),
    'drivers', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'firebase_uid', d.firebase_uid, 'full_name', d.full_name, 'email', d.email, 'phone', d.phone,
               'branch_id', d.branch_id, 'branch_name', b.name, 'vehicle', d.vehicle,
               'account_status', d.account_status, 'is_available', d.is_available, 'created_at', d.created_at,
               'active_runs', (select count(*) from public.deliveries x
                               where x.driver_uid = d.firebase_uid and x.status not in ('completed', 'cancelled')))
             order by d.full_name, d.firebase_uid), '[]'::jsonb)
      from public.drivers d
      left join public.branches b on b.id = d.branch_id
    ),
    'customers', (
      select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc, c.firebase_uid), '[]'::jsonb)
      from (
        select cp.firebase_uid,
               coalesce(nullif(cp.full_name, ''), 'Customer') as full_name,
               cp.email, nullif(cp.phone, '') as phone, cp.rfid_card_number as card_number,
               cp.default_branch_id as branch_id, b.name as branch_name, cp.created_at,
               coalesce(o.orders, 0) as orders, coalesce(o.paid_total, 0) as paid_total, o.last_order_at,
               coalesce(rf.refunded_total, 0) as refunded_total,
               la.points_balance as points_balance
        from public.customer_profiles cp
        left join public.branches b on b.id = cp.default_branch_id
        left join public.loyalty_accounts la on la.firebase_uid = cp.firebase_uid
        left join lateral (
          select count(*) filter (where ord.status <> 'cancelled') as orders,
                 sum(ord.total) filter (where exists (select 1 from public.payments p
                                                      where p.order_id = ord.id and p.status in ('success', 'refunded'))) as paid_total,
                 max(ord.created_at) as last_order_at
          from public.orders ord
          where ord.firebase_uid = cp.firebase_uid
        ) o on true
        -- completed refunds (partial ones included) on the customer's orders
        left join lateral (
          select sum(r.amount) as refunded_total
          from public.refund_requests r
          join public.orders ord on ord.id = r.order_id
          where ord.firebase_uid = cp.firebase_uid and r.status = 'completed'
        ) rf on true
        where cp.firebase_uid <> 'walk-in'
          and (v_q is null
               or lower(cp.full_name) like '%' || v_q || '%'
               or lower(cp.email) like '%' || v_q || '%'
               or lower(cp.phone) like '%' || v_q || '%'
               or lower(coalesce(cp.rfid_card_number, '')) like '%' || v_q || '%')
        order by cp.created_at desc, cp.firebase_uid
        limit v_limit
      ) c
    ),
    'customers_total', (
      select count(*)
      from public.customer_profiles cp
      where cp.firebase_uid <> 'walk-in'
        and (v_q is null
             or lower(cp.full_name) like '%' || v_q || '%'
             or lower(cp.email) like '%' || v_q || '%'
             or lower(cp.phone) like '%' || v_q || '%'
             or lower(coalesce(cp.rfid_card_number, '')) like '%' || v_q || '%')
    )
  );
end;
$$;


-- -----------------------------------------------------------------------------
-- 9. Loyalty: points reversed in proportion to the amount refunded (once)
-- -----------------------------------------------------------------------------
-- Fires (unchanged trigger) when an order becomes 'refunded'. Before, every
-- point earned on the order was taken back even when only part of it was
-- refunded. Now: points to reverse = round(earned x refunded / refundable),
-- refundable = subtotal - discount (what request_refund / POS returns can
-- refund; delivery fees are never refunded). A full refund still reverses all
-- of them. Reversals already written for the order are subtracted, so it
-- never takes points twice; never below a zero balance (as before).
create or replace function public.finalize_order_refund()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_earned int;
  v_refunded numeric;
  v_base numeric;
  v_target int;
  v_done int;
  v_take int;
begin
  select coalesce(sum(points), 0) into v_earned
  from public.loyalty_transactions
  where order_id = new.id and source = 'order_earn';

  select coalesce(sum(amount), 0) into v_refunded
  from public.refund_requests where order_id = new.id and status = 'completed';
  v_base := greatest(new.subtotal - new.discount, 0);

  if v_earned > 0 and v_refunded > 0 then
    v_target := case when v_base <= 0 or v_refunded >= v_base then v_earned
                     else least(v_earned, round(v_earned * v_refunded / v_base)::int) end;
    select coalesce(-sum(points), 0) into v_done
    from public.loyalty_transactions where order_id = new.id and source = 'order_clawback';

    if v_target - v_done > 0 then
      select least(points_balance, v_target - v_done) into v_take
      from public.loyalty_accounts where firebase_uid = new.firebase_uid for update;

      if coalesce(v_take, 0) > 0 then
        update public.loyalty_accounts
        set points_balance = points_balance - v_take
        where firebase_uid = new.firebase_uid;

        insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
        values (new.firebase_uid, 'redeem', -v_take,
                'Points reversed - order ' || new.id || ' refunded'
                  || case when v_refunded < v_base then ' (partial)' else '' end,
                new.id, 'order_clawback');
      end if;
    end if;
  end if;

  update public.payments set status = 'refunded'
  where order_id = new.id and status = 'success';

  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 10. No over-refunding: amount <= paid - refunds already completed
-- -----------------------------------------------------------------------------
-- Checked when a refund is created, when its amount changes and when it is
-- completed (in case another refund on the order completed in between).
create or replace function public._validate_refund_against_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paid numeric;
  v_has_payment boolean;
  v_total numeric;
  v_done numeric;
begin
  if tg_op = 'UPDATE' and new.amount = old.amount
     and not (new.status = 'completed' and old.status is distinct from 'completed') then
    return new;
  end if;
  select o.total into v_total from public.orders o where o.id = new.order_id;
  select coalesce(sum(p.amount) filter (where p.status in ('success', 'refunded')), 0), count(*) > 0
    into v_paid, v_has_payment
  from public.payments p where p.order_id = new.order_id;
  -- Orders from before payments were recorded fall back to the order total.
  if not v_has_payment then v_paid := coalesce(v_total, 0); end if;
  select coalesce(sum(r.amount), 0) into v_done
  from public.refund_requests r
  where r.order_id = new.order_id and r.status = 'completed' and r.id <> new.id;
  if new.amount > v_paid - v_done + 0.004 then
    raise exception 'Refund amount (₱%) is more than what is left to refund on this order (₱%).',
      new.amount, greatest(v_paid - v_done, 0);
  end if;
  return new;
end;
$$;
drop trigger if exists refund_requests_validate_against_paid on public.refund_requests;
create trigger refund_requests_validate_against_paid
  before insert or update of amount, status on public.refund_requests
  for each row execute function public._validate_refund_against_paid();

-- -----------------------------------------------------------------------------
-- 11. Refund decisions in the audit log
-- -----------------------------------------------------------------------------
-- staff_review_refund (the app's Refunds screen, HitPay completion) wrote no
-- audit entry. It does now, unless the caller already writes its own
-- (admin_portal_review_refund sets app.refund_audit = 'caller').
create or replace function public.staff_review_refund(p_refund_id text, p_action text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.refund_requests;
  v_branch uuid;
  v_status text;
  v_staff public.staff_members;
begin
  select * into r from public.refund_requests where id = p_refund_id for update;
  if not found then raise exception 'That refund request could not be found.'; end if;
  select branch_id into v_branch from public.orders where id = r.order_id;
  v_staff := public._require_staff(v_branch, 'refunds');
  v_status := case p_action when 'approve' then 'approved' when 'reject' then 'rejected'
                            when 'process' then 'processing' when 'complete' then 'completed' end;
  if v_status is null then raise exception 'Unsupported refund action.'; end if;
  -- enforce_refund_transition validates the move; sync triggers update the order.
  update public.refund_requests set status = v_status where id = r.id;
  if coalesce(current_setting('app.refund_audit', true), '') <> 'caller' then
    perform public._write_audit(v_staff.firebase_uid, v_branch, 'refund.' || p_action, 'refund_request', r.id,
      jsonb_build_object('order_id', r.order_id, 'amount', r.amount, 'from_status', r.status,
                         'to_status', v_status, 'via', 'app'));
  end if;
end;
$$;

create or replace function public.admin_portal_review_refund(
  p_refund_id text,
  p_action text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.refund_requests;
  v_staff public.staff_members;
  v_branch uuid;
  v_pay_method text;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into r from public.refund_requests where id = p_refund_id for update;
  if not found then raise exception 'That refund request could not be found.'; end if;
  select o.branch_id, (select pay.method from public.payments pay where pay.order_id = o.id order by pay.created_at desc limit 1)
    into v_branch, v_pay_method
  from public.orders o where o.id = r.order_id;
  v_staff := public._require_staff(v_branch, 'refunds');
  perform set_config('app.refund_audit', 'caller', true);

  if p_action = 'approve' then
    perform public.staff_review_refund(r.id, 'approve');
  elsif p_action = 'approve_cash' then
    if v_pay_method is distinct from 'cash' then
      raise exception 'Only cash payments can be refunded in one step. Approve it, refund through the payment provider, then mark it completed.';
    end if;
    perform public.staff_review_refund(r.id, 'approve');
    perform public.staff_review_refund(r.id, 'complete');
  elsif p_action = 'complete' then
    if v_note is null or char_length(v_note) < 4 or char_length(v_note) > 120 then
      raise exception 'Enter the refund reference from the payment provider (4 to 120 characters).';
    end if;
    perform public.staff_review_refund(r.id, 'complete');
  elsif p_action = 'reject' then
    if v_note is null or char_length(v_note) < 5 or char_length(v_note) > 500 then
      raise exception 'A written reason (5 to 500 characters) is required to reject a refund.';
    end if;
    perform public.staff_review_refund(r.id, 'reject');
    perform public.notify_customer(r.firebase_uid, 'refund', 'Refund request not approved',
      'Request ' || r.id || ' for order ' || r.order_id || ': ' || v_note);
  else
    perform set_config('app.refund_audit', '', true);
    raise exception 'Unsupported refund action.';
  end if;
  perform set_config('app.refund_audit', '', true);

  perform public._write_audit(v_staff.firebase_uid, v_branch, 'refund.' || p_action, 'refund_request', r.id,
    jsonb_build_object('order_id', r.order_id, 'amount', r.amount, 'payment_method', v_pay_method,
                       'note', v_note, 'via', 'admin_portal'));

  return (select jsonb_build_object('id', id, 'status', status, 'order_id', order_id)
          from public.refund_requests where id = r.id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 12. Loyalty summary: reversals apart from redemptions
-- -----------------------------------------------------------------------------
create or replace function public.admin_portal_loyalty_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_month_start timestamptz := date_trunc('month', now() at time zone 'Asia/Manila') at time zone 'Asia/Manila';
begin
  perform public._require_staff();
  return jsonb_build_object(
    'members', (select count(*) from public.loyalty_accounts where firebase_uid <> 'walk-in'),
    'issued_month', (select coalesce(sum(points), 0) from public.loyalty_transactions
                     where points > 0 and created_at >= v_month_start),
    -- points customers spent (before: also counted points taken back by refunds)
    'redeemed_month', (select coalesce(-sum(points), 0) from public.loyalty_transactions
                       where points < 0 and coalesce(source, '') <> 'order_clawback' and created_at >= v_month_start),
    'reversed_month', (select coalesce(-sum(points), 0) from public.loyalty_transactions
                       where source = 'order_clawback' and created_at >= v_month_start)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 13. Grants
-- -----------------------------------------------------------------------------
revoke all on function public._sales_facts(timestamptz, timestamptz, uuid[]) from public, anon, authenticated;
revoke all on function public._pending_refund_facts(uuid[]) from public, anon, authenticated;
revoke all on function public._sales_line_facts(timestamptz, timestamptz, uuid[]) from public, anon, authenticated;
revoke all on function public._sales_money_json(bigint, numeric, numeric, numeric, bigint, numeric) from public, anon, authenticated;
revoke all on function public._order_refund_json(text) from public, anon, authenticated;
revoke all on function public._validate_refund_against_paid() from public, anon, authenticated;

revoke all on function public.sales_overview(date, date, uuid) from public, anon;
grant execute on function public.sales_overview(date, date, uuid) to authenticated;
revoke all on function public.get_my_order_refunds(text[]) from public, anon;
grant execute on function public.get_my_order_refunds(text[]) to authenticated;

-- Re-stated (create or replace keeps grants; listed so the file is self-contained).
revoke all on function public.owner_sales_summary(int) from public, anon;
grant execute on function public.owner_sales_summary(int) to authenticated;
grant execute on function public.staff_get_dashboard(uuid) to authenticated;
grant execute on function public.get_product_sales_30d() to anon, authenticated;
grant execute on function public.get_popular_products(int) to anon, authenticated;
revoke all on function public.analytics_report(date, date, uuid) from public, anon;
grant execute on function public.analytics_report(date, date, uuid) to authenticated;
revoke all on function public.owner_staff_overview(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.owner_staff_overview(timestamptz, timestamptz, uuid) to authenticated;
revoke all on function public.admin_portal_orders(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.admin_portal_orders(timestamptz, timestamptz, uuid) to authenticated;
grant execute on function public.staff_list_orders(uuid, text[], timestamptz, int, text) to authenticated;
grant execute on function public.staff_list_refunds(uuid, text[]) to authenticated;
grant execute on function public.staff_review_refund(text, text) to authenticated;
revoke all on function public.admin_portal_review_refund(text, text, text) from public, anon;
grant execute on function public.admin_portal_review_refund(text, text, text) to authenticated;
revoke all on function public.admin_portal_loyalty_summary() from public, anon;
grant execute on function public.admin_portal_loyalty_summary() to authenticated;
revoke all on function public.owner_all_users(text, int) from public, anon;
grant execute on function public.owner_all_users(text, int) to authenticated;

commit;
