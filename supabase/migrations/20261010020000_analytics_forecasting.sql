-- =============================================================================
-- Business analytics, linear-regression sales forecast, reorder suggestions,
-- expiring-batch list.
-- =============================================================================
-- Run after 20261010010000_driver_module.sql. Idempotent, additive.
--
-- Who may read: the owner (all branches or one), or staff holding the
-- 'view_reports' permission (their own branch only). Reorder suggestions and
-- expiring batches: any active staff for their branch.
--
-- Definitions (the same everywhere; also used by staff_cashier_daily_summary):
--   verified order  an order whose payment is 'success' or 'refunded'
--                   (pending / processing / failed payments are NOT sales)
--   gross sales     sum of verified orders' subtotals (before discount, without
--                   delivery fee), dated by order date (Asia/Manila)
--   discounts       sum of verified orders' discounts
--   refunds         completed refund amounts, dated by completion date
--   net sales       gross sales - discounts - refunds
--   delivery fees   verified orders' delivery fees (reported apart)
--   revenue         net sales + delivery fees
--   pending         non-cancelled orders whose payment is not yet verified
--
-- Forecast model (analytics_sales_forecast)
--   Ordinary least squares on one variable: y = a + b*t, t = period index.
--   For daily data an optional day-of-week adjustment is added: the mean
--   training residual for each weekday (an additive seasonal term).
--   Series: units (or revenue) from verified orders, minus units refunded on
--   those orders, per period. Days on which the branch recorded NO verified
--   order at all are treated as closed/missing and left out of training.
--   Evaluation is chronological: the last p_holdout periods of the training
--   window are hidden, the model is fitted on the earlier periods and scored
--   on the hidden ones (MAE, RMSE, and the MAE of a naive "training mean"
--   baseline for comparison). The final model is then refitted on the whole
--   window to produce the future forecast. Nothing after p_train_to is used.
--   Intervals are approximate: prediction +/- 1.96 * residual standard error.
--   Known limits: no stock-out detection (a day sold out reads as low
--   demand), no holidays/promotions, linear trend only.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 0. Access helper
-- -----------------------------------------------------------------------------
create or replace function public._require_reports(p_branch_id uuid)
returns public.staff_members
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.staff_members;
begin
  v := public._require_staff(p_branch_id);
  if v.role <> 'owner' then
    if p_branch_id is null then raise exception 'Choose your branch.'; end if;
    if not ('view_reports' = any (public.staff_permission_keys())) then
      raise exception 'You do not have permission to view reports.';
    end if;
  end if;
  return v;
end;
$$;

-- Verified order lines with their Manila date (one place for the definition).
create or replace view public.analytics_verified_orders
with (security_invoker = true) as
select o.id as order_id, o.branch_id, o.firebase_uid, o.created_at,
       (o.created_at at time zone 'Asia/Manila')::date as sale_date,
       o.subtotal, o.discount, o.delivery_fee, o.total, o.is_delivery,
       p.method as payment_method,
       exists (select 1 from public.pos_sales ps where ps.order_id = o.id) as is_pos
from public.orders o
join public.payments p on p.order_id = o.id
where p.status in ('success', 'refunded');
revoke all on public.analytics_verified_orders from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 1. The report
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
  v_summary jsonb;
  v_gross numeric; v_disc numeric; v_refunds numeric; v_fees numeric; v_orders int;
  v_refund_count int;
begin
  v_staff := public._require_reports(p_branch_id);
  if v_to < v_from then raise exception 'The end date is before the start date.'; end if;
  if v_to - v_from > 400 then raise exception 'Date range is too long (maximum 400 days).'; end if;
  v_start := v_from::timestamp at time zone 'Asia/Manila';
  v_end := (v_to + 1)::timestamp at time zone 'Asia/Manila';

  create temp table if not exists _ar_orders (like public.analytics_verified_orders) on commit drop;
  truncate _ar_orders;
  insert into _ar_orders
  select * from public.analytics_verified_orders v
  where v.created_at >= v_start and v.created_at < v_end
    and (p_branch_id is null or v.branch_id = p_branch_id);

  create temp table if not exists _ar_refunds (refund_id text, order_id text, branch_id uuid, amount numeric,
                                               done_date date, is_void boolean) on commit drop;
  truncate _ar_refunds;
  insert into _ar_refunds
  select r.id, r.order_id, o.branch_id, r.amount, (d.done_at at time zone 'Asia/Manila')::date,
         exists (select 1 from public.pos_voids pv where pv.refund_id = r.id)
  from public.refund_requests r
  join public.orders o on o.id = r.order_id
  join lateral (select max(e.created_at) as done_at from public.refund_status_events e
                where e.refund_request_id = r.id and e.status = 'completed') d on true
  where r.status = 'completed' and d.done_at >= v_start and d.done_at < v_end
    and (p_branch_id is null or o.branch_id = p_branch_id);

  select coalesce(sum(subtotal), 0), coalesce(sum(discount), 0), coalesce(sum(delivery_fee), 0), count(*)
    into v_gross, v_disc, v_fees, v_orders from _ar_orders;
  select coalesce(sum(amount), 0), count(*) into v_refunds, v_refund_count from _ar_refunds;

  v_summary := jsonb_build_object(
    'verified_orders', v_orders,
    'gross_sales', v_gross,
    'discounts', v_disc,
    'refunds', v_refunds,
    'refund_count', v_refund_count,
    'net_sales', v_gross - v_disc - v_refunds,
    'delivery_fees', v_fees,
    'revenue', v_gross - v_disc - v_refunds + v_fees,
    'refund_rate', case when v_gross - v_disc > 0 then round(v_refunds / (v_gross - v_disc), 4) end,
    'average_order_value', case when v_orders > 0 then round((v_gross - v_disc) / v_orders, 2) end,
    'pos_orders', (select count(*) from _ar_orders where is_pos),
    'online_orders', (select count(*) from _ar_orders where not is_pos),
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
    'voids', (select count(*) from _ar_refunds where is_void),
    'completed_deliveries', (
      select count(*) from public.delivery_stops ds join public.deliveries d on d.id = ds.delivery_id
      join public.orders o on o.id = ds.order_id
      where ds.status = 'delivered' and o.status = 'completed'
        and coalesce(ds.delivered_at, ds.updated_at) >= v_start and coalesce(ds.delivered_at, ds.updated_at) < v_end
        and (p_branch_id is null or d.branch_id = p_branch_id)),
    'failed_deliveries', (
      select count(*) from public.delivery_stops ds join public.deliveries d on d.id = ds.delivery_id
      where ds.status = 'failed' and ds.failed_at >= v_start and ds.failed_at < v_end
        and (p_branch_id is null or d.branch_id = p_branch_id))
  );

  return jsonb_build_object(
    'from', v_from, 'to', v_to, 'branch_id', p_branch_id,
    'definitions', jsonb_build_object(
      'gross_sales', 'Subtotal of orders with a verified payment (before discounts, without delivery fee), by order date',
      'refunds', 'Completed refunds, by completion date',
      'net_sales', 'Gross sales - discounts - refunds',
      'revenue', 'Net sales + delivery fees',
      'pending_payments', 'Orders not cancelled whose payment is not verified yet (not counted as sales)'),
    'summary', v_summary,

    'by_day', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'date', d.day, 'orders', coalesce(s.n, 0), 'gross_sales', coalesce(s.gross, 0),
               'discounts', coalesce(s.disc, 0), 'refunds', coalesce(r.amount, 0),
               'net_sales', coalesce(s.gross, 0) - coalesce(s.disc, 0) - coalesce(r.amount, 0)) order by d.day), '[]'::jsonb)
      from generate_series(v_from, v_to, interval '1 day') as d0(ts)
      cross join lateral (select d0.ts::date as day) d
      left join (select sale_date, count(*) n, sum(subtotal) gross, sum(discount) disc from _ar_orders group by sale_date) s
        on s.sale_date = d.day
      left join (select done_date, sum(amount) amount from _ar_refunds group by done_date) r on r.done_date = d.day),

    'by_branch', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'branch_id', b.id, 'branch', b.name, 'orders', coalesce(s.n, 0),
               'gross_sales', coalesce(s.gross, 0), 'discounts', coalesce(s.disc, 0), 'refunds', coalesce(r.amount, 0),
               'net_sales', coalesce(s.gross, 0) - coalesce(s.disc, 0) - coalesce(r.amount, 0)) order by b.name), '[]'::jsonb)
      from public.branches b
      left join (select branch_id, count(*) n, sum(subtotal) gross, sum(discount) disc from _ar_orders group by branch_id) s on s.branch_id = b.id
      left join (select branch_id, sum(amount) amount from _ar_refunds group by branch_id) r on r.branch_id = b.id
      where p_branch_id is null or b.id = p_branch_id),

    'by_payment_method', (
      select coalesce(jsonb_agg(jsonb_build_object('method', payment_method, 'orders', n, 'amount', amount) order by amount desc), '[]'::jsonb)
      from (select payment_method, count(*) n, sum(total) amount from _ar_orders group by payment_method) t),

    'by_category', (
      select coalesce(jsonb_agg(jsonb_build_object('category', category, 'units', units, 'gross_sales', gross) order by gross desc), '[]'::jsonb)
      from (
        select coalesce(pc.label, 'Uncategorised') as category, sum(oi.quantity)::int as units, sum(oi.quantity * oi.unit_price) as gross
        from _ar_orders o join public.order_items oi on oi.order_id = o.order_id
        left join public.products p on p.id = oi.product_id
        left join public.product_categories pc on pc.id = p.category_id
        group by 1) t),

    'top_products', (
      select coalesce(jsonb_agg(jsonb_build_object('product', product_name, 'variant', variant_label, 'variant_id', variant_id,
                                                   'units', units, 'gross_sales', gross) order by gross desc), '[]'::jsonb)
      from (
        select oi.product_name, oi.variant_label, oi.variant_id, sum(oi.quantity)::int as units, sum(oi.quantity * oi.unit_price) as gross
        from _ar_orders o join public.order_items oi on oi.order_id = o.order_id
        group by 1, 2, 3 order by gross desc limit 15) t),

    -- Active products that are in stock but sold least (including zero).
    'slow_movers', (
      select coalesce(jsonb_agg(jsonb_build_object('product', product, 'variant', variant, 'variant_id', variant_id,
                                                   'in_stock', stock, 'units_sold', units) order by units, stock desc), '[]'::jsonb)
      from (
        select p.name as product, pv.label as variant, pv.id as variant_id, sum(bi.quantity)::int as stock,
               coalesce((select sum(oi.quantity) from public.order_items oi join _ar_orders o on o.order_id = oi.order_id
                         where oi.variant_id = pv.id), 0)::int as units
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
      from (select firebase_uid, count(*) n from _ar_orders where firebase_uid <> 'walk-in' group by firebase_uid) t),

    'loyalty', (
      select jsonb_build_object(
        'points_earned', coalesce(sum(points) filter (where points > 0), 0),
        'points_redeemed', coalesce(-sum(points) filter (where points < 0), 0),
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
-- 2. Linear regression
-- -----------------------------------------------------------------------------
-- OLS of y on t (1..n) with optional additive weekday effect.
-- p_t: period index, p_y: value, p_dow: 0..6 (ignored unless p_seasonal).
create or replace function public._ols_fit(p_t float8[], p_y float8[], p_dow int[], p_seasonal boolean)
returns jsonb
language plpgsql
immutable
as $$
-- Least squares of y = a + b*t (+ weekday effect s[dow] when p_seasonal).
-- With weekday effects the joint least-squares solution is found by
-- backfitting: fit the trend on y - s[dow], set s[dow] to the mean residual of
-- each weekday, centre s so it sums to zero over the observations, repeat.
-- Each step can only lower the squared error, so it converges to the same
-- answer as a regression with weekday dummy variables.
declare
  v_a float8; v_b float8; v_n int; v_r2 float8; v_sd float8; v_eff float8; v_mean float8;
  v_dow float8[] := array[0, 0, 0, 0, 0, 0, 0];
  v_iter int;
  i int;
begin
  for v_iter in 1 .. case when p_seasonal then 25 else 1 end loop
    select regr_intercept(y - v_dow[d + 1], t), regr_slope(y - v_dow[d + 1], t), regr_count(y, t)
      into v_a, v_b, v_n
    from unnest(p_t, p_y, p_dow) as u(t, y, d);
    if v_n is null or v_n < 2 then return null; end if;
    v_a := coalesce(v_a, 0); v_b := coalesce(v_b, 0);
    exit when not p_seasonal;
    for i in 0..6 loop
      select coalesce(avg(y - (v_a + v_b * t)), 0) into v_eff
      from unnest(p_t, p_y, p_dow) as u(t, y, d) where d = i;
      v_dow[i + 1] := v_eff;
    end loop;
    select avg(v_dow[d + 1]) into v_mean from unnest(p_dow) as u(d);
    for i in 1..7 loop v_dow[i] := v_dow[i] - v_mean; end loop;
  end loop;
  if p_seasonal then
    -- refit the trend once more against the final weekday effects
    select regr_intercept(y - v_dow[d + 1], t), regr_slope(y - v_dow[d + 1], t)
      into v_a, v_b
    from unnest(p_t, p_y, p_dow) as u(t, y, d);
    v_a := coalesce(v_a, 0); v_b := coalesce(v_b, 0);
  end if;

  select sqrt(sum(power(y - (v_a + v_b * t + v_dow[d + 1]), 2))
              / greatest(count(*) - 2 - case when p_seasonal then 6 else 0 end, 1)),
         case when sum(power(y - avg_y, 2)) > 0
              then 1 - sum(power(y - (v_a + v_b * t + v_dow[d + 1]), 2)) / sum(power(y - avg_y, 2)) end
    into v_sd, v_r2
  from (select t, y, d, avg(y) over () as avg_y from unnest(p_t, p_y, p_dow) as u(t, y, d)) x;

  return jsonb_build_object('intercept', v_a, 'slope', v_b, 'n', v_n, 'r2', v_r2,
                            'residual_sd', coalesce(v_sd, 0), 'seasonal', p_seasonal,
                            'weekday_effects', to_jsonb(v_dow));
end;
$$;

create or replace function public._ols_predict(p_model jsonb, p_t float8, p_dow int)
returns float8
language sql
immutable
as $$
  select (p_model ->> 'intercept')::float8 + (p_model ->> 'slope')::float8 * p_t
         + case when (p_model ->> 'seasonal')::boolean then (p_model -> 'weekday_effects' ->> p_dow)::float8 else 0 end
$$;

-- -----------------------------------------------------------------------------
-- 3. Forecast tables (saved runs, to compare against actuals later)
-- -----------------------------------------------------------------------------
create table if not exists public.forecast_runs (
  id uuid primary key default gen_random_uuid(),
  created_by text not null,
  branch_id uuid not null references public.branches(id),
  variant_id uuid references public.product_variants(id) on delete set null,
  metric text not null check (metric in ('units', 'revenue')),
  granularity text not null check (granularity in ('day', 'week')),
  train_from date not null,
  train_to date not null,
  model jsonb not null,
  metrics jsonb not null,
  created_at timestamptz not null default now()
);
create table if not exists public.forecast_points (
  run_id uuid not null references public.forecast_runs(id) on delete cascade,
  period_start date not null,
  predicted numeric(14, 2) not null,
  lower_bound numeric(14, 2) not null,
  upper_bound numeric(14, 2) not null,
  primary key (run_id, period_start)
);
alter table public.forecast_runs enable row level security;
alter table public.forecast_points enable row level security;
revoke all on public.forecast_runs, public.forecast_points from anon, authenticated;

-- Actual values per period (internal).
create or replace function public._sales_series(
  p_branch_id uuid, p_variant_id uuid, p_metric text, p_granularity text, p_from date, p_to date
)
returns table (period_start date, actual float8, open_days int)
language sql
stable
security definer
set search_path = public
as $$
  with days as (
    select d::date as day from generate_series(p_from, p_to, interval '1 day') d
  ),
  verified as (
    select v.order_id, v.sale_date from public.analytics_verified_orders v
    where v.branch_id = p_branch_id and v.sale_date between p_from and p_to
  ),
  open_day as (select distinct sale_date as day from verified),
  sold as (
    select v.sale_date as day,
           sum(case when p_metric = 'revenue' then oi.quantity * oi.unit_price else oi.quantity end) as amt
    from verified v join public.order_items oi on oi.order_id = v.order_id
    where p_variant_id is null or oi.variant_id = p_variant_id
    group by 1
  ),
  returned as (  -- refunded units take demand back out, on the original sale date
    select v.sale_date as day,
           sum(case when p_metric = 'revenue' then ri.quantity * ri.unit_price else ri.quantity end) as amt
    from verified v
    join public.refund_requests r on r.order_id = v.order_id and r.status = 'completed'
    join public.refund_items ri on ri.refund_request_id = r.id
    where p_variant_id is null or exists (
      select 1 from public.order_items oi where oi.order_id = v.order_id and oi.variant_id = p_variant_id
        and oi.product_name = ri.product_name and oi.variant_label = ri.variant_label)
    group by 1
  ),
  daily as (
    select d.day, (od.day is not null) as is_open,
           greatest(coalesce(s.amt, 0) - coalesce(r.amt, 0), 0)::float8 as amt
    from days d
    left join open_day od on od.day = d.day
    left join sold s on s.day = d.day
    left join returned r on r.day = d.day
  )
  select case when p_granularity = 'week' then date_trunc('week', day)::date else day end as period_start,
         sum(amt) filter (where is_open) as actual,
         count(*) filter (where is_open)::int as open_days
  from daily
  group by 1
  order by 1
$$;

-- -----------------------------------------------------------------------------
-- 4. Forecast RPC
-- -----------------------------------------------------------------------------
create or replace function public.analytics_sales_forecast(
  p_branch_id uuid,
  p_variant_id uuid default null,
  p_metric text default 'units',
  p_granularity text default 'day',
  p_train_from date default null,
  p_train_to date default null,
  p_horizon int default 14,
  p_holdout int default null,
  p_save boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_to date;
  v_from date;
  v_step interval;
  v_seasonal boolean;
  v_hold int;
  v_min_train int;
  v_t float8[]; v_y float8[]; v_dow int[]; v_period date[];
  v_n int;
  v_model_eval jsonb;
  v_model jsonb;
  v_mae float8; v_rmse float8; v_base_mae float8; v_train_mean float8;
  v_holdout jsonb := '[]'::jsonb;
  v_forecast jsonb := '[]'::jsonb;
  v_history jsonb;
  v_last_t float8;
  v_last_period date;
  v_p float8; v_pd date; v_z float8 := 1.96;
  v_run uuid;
  i int;
begin
  v_staff := public._require_reports(p_branch_id);
  if p_branch_id is null then raise exception 'Choose a branch.'; end if;
  if p_metric not in ('units', 'revenue') then raise exception 'Metric must be units or revenue.'; end if;
  if p_granularity not in ('day', 'week') then raise exception 'Granularity must be day or week.'; end if;
  if p_horizon is null or p_horizon < 1 or p_horizon > (case when p_granularity = 'day' then 90 else 26 end) then
    raise exception 'Forecast horizon must be 1-90 days or 1-26 weeks.';
  end if;
  if p_variant_id is not null and not exists (select 1 from public.product_variants where id = p_variant_id) then
    raise exception 'That product variant could not be found.';
  end if;

  v_step := case when p_granularity = 'day' then interval '1 day' else interval '7 days' end;
  v_seasonal := p_granularity = 'day';
  -- Train up to yesterday (today is incomplete) or the last complete week.
  v_to := least(coalesce(p_train_to, v_today - 1), v_today - 1);
  if p_granularity = 'week' then v_to := (date_trunc('week', v_to + 1)::date - 1); end if;
  v_from := coalesce(p_train_from, v_to - case when p_granularity = 'day' then 89 else 7 * 26 - 1 end);
  if p_granularity = 'week' then v_from := date_trunc('week', v_from)::date; end if;
  if v_from >= v_to then raise exception 'The training period is empty.'; end if;
  if v_to - v_from > 730 then raise exception 'Training period is too long (maximum 2 years).'; end if;
  v_hold := coalesce(p_holdout, case when p_granularity = 'day' then 14 else 4 end);
  v_min_train := case when p_granularity = 'day' then 21 else 8 end;

  -- Observed periods only (closed days / empty weeks are missing, not zero).
  select array_agg(row_number::float8 order by period_start), array_agg(actual order by period_start),
         array_agg(extract(dow from period_start)::int order by period_start), array_agg(period_start order by period_start)
    into v_t, v_y, v_dow, v_period
  from (
    select s.period_start, s.actual,
           -- t counts calendar periods from the start, so gaps keep their spacing
           ((s.period_start - v_from) / case when p_granularity = 'day' then 1 else 7 end + 1) as row_number
    from public._sales_series(p_branch_id, p_variant_id, p_metric, p_granularity, v_from, v_to) s
    where s.open_days > 0 and (p_granularity = 'day' or s.open_days >= 4)
  ) x;
  v_n := coalesce(array_length(v_y, 1), 0);

  select coalesce(jsonb_agg(jsonb_build_object('period', s.period_start,
           'actual', case when s.open_days > 0 then round(s.actual::numeric, 2) end, 'open_days', s.open_days)
           order by s.period_start), '[]'::jsonb)
    into v_history
  from public._sales_series(p_branch_id, p_variant_id, p_metric, p_granularity, v_from, v_to) s;

  if v_n < v_min_train + v_hold then
    return jsonb_build_object('status', 'insufficient_data',
      'message', format('Need at least %s %s with verified sales in the training period (found %s).',
                        v_min_train + v_hold, case when p_granularity = 'day' then 'open days' else 'weeks' end, v_n),
      'history', v_history, 'train_from', v_from, 'train_to', v_to);
  end if;

  -- Chronological evaluation: fit on the first n - hold points, score on the rest.
  v_model_eval := public._ols_fit(v_t[1:v_n - v_hold], v_y[1:v_n - v_hold], v_dow[1:v_n - v_hold], v_seasonal);
  select avg(y) into v_train_mean from unnest(v_y[1:v_n - v_hold]) y;
  v_mae := 0; v_rmse := 0; v_base_mae := 0;
  for i in (v_n - v_hold + 1)..v_n loop
    v_p := greatest(public._ols_predict(v_model_eval, v_t[i], v_dow[i]), 0);
    v_mae := v_mae + abs(v_y[i] - v_p);
    v_rmse := v_rmse + power(v_y[i] - v_p, 2);
    v_base_mae := v_base_mae + abs(v_y[i] - v_train_mean);
    v_holdout := v_holdout || jsonb_build_object('period', v_period[i], 'actual', round(v_y[i]::numeric, 2),
                                                 'predicted', round(v_p::numeric, 2));
  end loop;
  v_mae := v_mae / v_hold; v_rmse := sqrt(v_rmse / v_hold); v_base_mae := v_base_mae / v_hold;

  -- Final model on the whole window, then project forward.
  v_model := public._ols_fit(v_t, v_y, v_dow, v_seasonal);
  v_last_t := (v_to - v_from) / case when p_granularity = 'day' then 1 else 7 end + 1;
  v_last_period := case when p_granularity = 'day' then v_to else date_trunc('week', v_to)::date end;
  for i in 1..p_horizon loop
    v_pd := (v_last_period + v_step * i)::date;
    v_p := public._ols_predict(v_model, v_last_t + i, extract(dow from v_pd)::int);
    v_forecast := v_forecast || jsonb_build_object(
      'period', v_pd,
      'predicted', round(greatest(v_p, 0)::numeric, 2),
      'lower', round(greatest(v_p - v_z * (v_model ->> 'residual_sd')::float8, 0)::numeric, 2),
      'upper', round(greatest(v_p + v_z * (v_model ->> 'residual_sd')::float8, 0)::numeric, 2));
  end loop;

  if coalesce(p_save, false) then
    insert into public.forecast_runs (created_by, branch_id, variant_id, metric, granularity, train_from, train_to, model, metrics)
    values (v_staff.firebase_uid, p_branch_id, p_variant_id, p_metric, p_granularity, v_from, v_to, v_model,
            jsonb_build_object('mae', round(v_mae::numeric, 3), 'rmse', round(v_rmse::numeric, 3),
                               'baseline_mae', round(v_base_mae::numeric, 3), 'holdout_periods', v_hold))
    returning id into v_run;
    insert into public.forecast_points (run_id, period_start, predicted, lower_bound, upper_bound)
    select v_run, (e ->> 'period')::date, (e ->> 'predicted')::numeric, (e ->> 'lower')::numeric, (e ->> 'upper')::numeric
    from jsonb_array_elements(v_forecast) e;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'run_id', v_run,
    'branch_id', p_branch_id, 'variant_id', p_variant_id, 'metric', p_metric, 'granularity', p_granularity,
    'train_from', v_from, 'train_to', v_to, 'observed_periods', v_n,
    'model', jsonb_build_object(
      'type', case when v_seasonal then 'linear trend + weekday adjustment (OLS)' else 'linear trend (OLS)' end,
      'intercept', round((v_model ->> 'intercept')::numeric, 4),
      'slope_per_period', round((v_model ->> 'slope')::numeric, 4),
      'r2', round(coalesce((v_model ->> 'r2')::numeric, 0), 4),
      'residual_sd', round((v_model ->> 'residual_sd')::numeric, 4),
      'weekday_effects', case when v_seasonal then v_model -> 'weekday_effects' end),
    'evaluation', jsonb_build_object(
      'method', 'chronological hold-out (last periods of the training window)',
      'holdout_periods', v_hold,
      'mae', round(v_mae::numeric, 3), 'rmse', round(v_rmse::numeric, 3),
      'baseline_mae', round(v_base_mae::numeric, 3),
      'beats_baseline', v_mae < v_base_mae,
      'points', v_holdout),
    'history', v_history,
    'forecast', v_forecast,
    'notes', jsonb_build_array(
      'Forecasts are estimates, not guaranteed sales.',
      'Days with no verified sales at the branch are treated as closed and left out.',
      'Sold-out days are not detected and can pull the forecast down.',
      'The range is approximate (about 95% if errors are normal and the trend holds).')
  );
end;
$$;

-- Compare a saved forecast with what actually happened.
create or replace function public.analytics_forecast_accuracy(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.forecast_runs;
  v_last date;
begin
  select * into r from public.forecast_runs where id = p_run_id;
  if not found then raise exception 'That forecast could not be found.'; end if;
  perform public._require_reports(r.branch_id);
  select max(period_start) into v_last from public.forecast_points where run_id = r.id;
  return (
    with actuals as (
      select * from public._sales_series(r.branch_id, r.variant_id, r.metric, r.granularity,
        (select min(period_start) from public.forecast_points where run_id = r.id),
        least(v_last + case when r.granularity = 'week' then 6 else 0 end, (now() at time zone 'Asia/Manila')::date - 1))
    ),
    joined as (
      select fp.period_start, fp.predicted, fp.lower_bound, fp.upper_bound,
             case when a.open_days > 0 then round(a.actual::numeric, 2) end as actual
      from public.forecast_points fp left join actuals a on a.period_start = fp.period_start
      where fp.run_id = r.id
    )
    select jsonb_build_object(
      'run_id', r.id, 'created_at', r.created_at, 'metric', r.metric, 'granularity', r.granularity,
      'model', r.model, 'evaluation_at_creation', r.metrics,
      'periods_with_actuals', count(actual),
      'mae', round(avg(abs(actual - predicted)), 3),
      'rmse', round(sqrt(avg(power(actual - predicted, 2))), 3),
      'within_range', count(*) filter (where actual between lower_bound and upper_bound),
      'points', jsonb_agg(jsonb_build_object('period', period_start, 'predicted', predicted, 'lower', lower_bound,
                                             'upper', upper_bound, 'actual', actual) order by period_start))
    from joined
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Reorder suggestions and expiring batches (inventory)
-- -----------------------------------------------------------------------------
-- Average daily demand over the look-back (verified sales minus refunds, open
-- days only). Usable stock excludes units in batches expiring within the lead
-- time. Suggest an order when usable stock <= demand * (lead time + safety
-- days); the quantity tops stock up to cover lead time + safety + cover days.
create or replace function public.staff_reorder_suggestions(
  p_branch_id uuid,
  p_lookback_days int default 28,
  p_lead_time_days int default 7,
  p_safety_days int default 3,
  p_cover_days int default 14
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
  v_open int;
begin
  v_staff := public._require_staff(p_branch_id);
  if p_branch_id is null then raise exception 'Choose a branch.'; end if;
  if p_lookback_days not between 7 and 365 or p_lead_time_days not between 0 and 90
     or p_safety_days not between 0 and 60 or p_cover_days not between 1 and 120 then
    raise exception 'Look-back 7-365, lead time 0-90, safety 0-60, cover 1-120 days.';
  end if;

  select count(distinct sale_date) into v_open from public.analytics_verified_orders
  where branch_id = p_branch_id and sale_date between v_today - p_lookback_days and v_today - 1;

  return jsonb_build_object(
    'branch_id', p_branch_id, 'lookback_days', p_lookback_days, 'open_days', v_open,
    'lead_time_days', p_lead_time_days, 'safety_days', p_safety_days, 'cover_days', p_cover_days,
    'items', (
      select coalesce(jsonb_agg(to_jsonb(t) order by t.needs_reorder desc, t.days_of_cover nulls last), '[]'::jsonb)
      from (
        select p.name as product, pv.label as variant, pv.id as variant_id,
               bi.quantity as on_hand,
               bi.quantity - coalesce(exp.qty, 0) as usable,
               coalesce(exp.qty, 0) as expiring_within_lead_time,
               round(coalesce(dm.units, 0)::numeric / greatest(v_open, 1), 2) as avg_daily_demand,
               case when coalesce(dm.units, 0) > 0
                    then round((bi.quantity - coalesce(exp.qty, 0)) / (dm.units::numeric / greatest(v_open, 1)), 1) end as days_of_cover,
               ceil(coalesce(dm.units, 0)::numeric / greatest(v_open, 1) * (p_lead_time_days + p_safety_days)) as reorder_point,
               (bi.quantity - coalesce(exp.qty, 0))
                 <= ceil(coalesce(dm.units, 0)::numeric / greatest(v_open, 1) * (p_lead_time_days + p_safety_days))
                 and coalesce(dm.units, 0) > 0 as needs_reorder,
               greatest(ceil(coalesce(dm.units, 0)::numeric / greatest(v_open, 1)
                             * (p_lead_time_days + p_safety_days + p_cover_days))
                        - (bi.quantity - coalesce(exp.qty, 0)), 0)::int as suggested_quantity
        from public.branch_inventory bi
        join public.product_variants pv on pv.id = bi.variant_id
        join public.products p on p.id = pv.product_id and p.is_active
        left join lateral (
          select sum(oi.quantity) - coalesce((
                   select sum(ri.quantity) from public.refund_requests r
                   join public.refund_items ri on ri.refund_request_id = r.id
                   join public.analytics_verified_orders v2 on v2.order_id = r.order_id
                   where r.status = 'completed' and v2.branch_id = p_branch_id
                     and v2.sale_date between v_today - p_lookback_days and v_today - 1
                     and ri.product_name = p.name and ri.variant_label = pv.label), 0) as units
          from public.analytics_verified_orders v
          join public.order_items oi on oi.order_id = v.order_id and oi.variant_id = pv.id
          where v.branch_id = p_branch_id and v.sale_date between v_today - p_lookback_days and v_today - 1
        ) dm on true
        left join lateral (
          select sum(b.quantity) as qty from public.inventory_batches b
          where b.branch_id = p_branch_id and b.variant_id = pv.id and b.quantity > 0
            and b.expiration_date <= v_today + p_lead_time_days
        ) exp on true
        where bi.branch_id = p_branch_id
      ) t)
  );
end;
$$;

create or replace function public.staff_expiring_batches(p_branch_id uuid, p_within_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  perform public._require_staff(p_branch_id);
  if p_branch_id is null then raise exception 'Choose a branch.'; end if;
  if p_within_days not between 0 and 365 then raise exception 'Choose 0-365 days.'; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'batch_id', b.id, 'batch_code', b.batch_code, 'product', p.name, 'variant', pv.label,
             'variant_id', b.variant_id, 'quantity', b.quantity, 'expiration_date', b.expiration_date,
             'days_left', b.expiration_date - v_today, 'expired', b.expiration_date < v_today)
           order by b.expiration_date), '[]'::jsonb)
    from public.inventory_batches b
    join public.product_variants pv on pv.id = b.variant_id
    join public.products p on p.id = b.product_id
    where b.branch_id = p_branch_id and b.quantity > 0 and b.expiration_date <= v_today + p_within_days
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Grants
-- -----------------------------------------------------------------------------
revoke all on function public._require_reports(uuid) from public, anon, authenticated;
revoke all on function public._sales_series(uuid, uuid, text, text, date, date) from public, anon, authenticated;
revoke all on function public._ols_fit(float8[], float8[], int[], boolean) from public, anon;
revoke all on function public._ols_predict(jsonb, float8, int) from public, anon;

do $g$
declare f text;
begin
  foreach f in array array[
    'public.analytics_report(date, date, uuid)',
    'public.analytics_sales_forecast(uuid, uuid, text, text, date, date, int, int, boolean)',
    'public.analytics_forecast_accuracy(uuid)',
    'public.staff_reorder_suggestions(uuid, int, int, int, int)',
    'public.staff_expiring_batches(uuid, int)'
  ] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end
$g$;

commit;
