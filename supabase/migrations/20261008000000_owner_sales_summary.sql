-- =============================================================================
-- Owner sales summary
--
-- One owner-only, read-only RPC that powers the owner analytics screens. All
-- figures are computed here, from the real orders / order_items tables; the
-- app never calculates revenue itself.
--
-- A "sale" uses the same definition as staff_get_dashboard: an order that is
-- `completed`, or `completed` with a refund request pending. Cancelled and
-- refunded orders are excluded. Days are Asia/Manila calendar days.
--
--   branches[]  per branch: revenue + number of sales for today, the last 7
--               days (today included) and the requested window.
--   products[]  top 50 products over the window by item sales (quantity x
--               unit_price, before vouchers and delivery fees). order_items
--               records no product id, so products are grouped by the product
--               name stored on the order.
--   daily[]     one row per day of the window (zero-filled), order totals.
-- =============================================================================
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
  v_day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Manila') at time zone 'Asia/Manila';
  v_week_start timestamptz := (date_trunc('day', now() at time zone 'Asia/Manila') - interval '6 days') at time zone 'Asia/Manila';
  v_window_start timestamptz := (date_trunc('day', now() at time zone 'Asia/Manila') - make_interval(days => v_days - 1)) at time zone 'Asia/Manila';
  v_branches jsonb;
  v_products jsonb;
  v_daily jsonb;
begin
  v_owner := public._require_owner();

  select coalesce(jsonb_agg(jsonb_build_object(
           'branch_id', b.id,
           'name', b.name,
           'today_revenue', coalesce(s.today_revenue, 0),
           'week_revenue', coalesce(s.week_revenue, 0),
           'window_revenue', coalesce(s.window_revenue, 0),
           'orders_today', coalesce(s.orders_today, 0),
           'orders_week', coalesce(s.orders_week, 0),
           'orders_window', coalesce(s.orders_window, 0)
         ) order by b.name), '[]'::jsonb)
    into v_branches
  from public.branches b
  left join lateral (
    select
      sum(o.total) filter (where o.created_at >= v_day_start) as today_revenue,
      sum(o.total) filter (where o.created_at >= v_week_start) as week_revenue,
      sum(o.total) filter (where o.created_at >= v_window_start) as window_revenue,
      count(*) filter (where o.created_at >= v_day_start) as orders_today,
      count(*) filter (where o.created_at >= v_week_start) as orders_week,
      count(*) filter (where o.created_at >= v_window_start) as orders_window
    from public.orders o
    where o.branch_id = b.id
      and o.status in ('completed', 'refundRequested')
      and o.created_at >= least(v_week_start, v_window_start)
  ) s on true;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_name', t.product_name,
           'units', t.units,
           'revenue', t.revenue
         ) order by t.revenue desc, t.product_name), '[]'::jsonb)
    into v_products
  from (
    select oi.product_name,
           sum(oi.quantity)::int as units,
           sum(oi.quantity * oi.unit_price) as revenue
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where o.status in ('completed', 'refundRequested')
      and o.created_at >= v_window_start
    group by oi.product_name
    order by revenue desc, oi.product_name
    limit 50
  ) t;

  select coalesce(jsonb_agg(jsonb_build_object(
           'date', d.day,
           'revenue', coalesce(s.revenue, 0)
         ) order by d.day), '[]'::jsonb)
    into v_daily
  from (
    select (v_today - (v_days - 1) + g) as day
    from generate_series(0, v_days - 1) as g
  ) d
  left join lateral (
    select sum(o.total) as revenue
    from public.orders o
    where o.status in ('completed', 'refundRequested')
      and o.created_at >= v_window_start
      and (o.created_at at time zone 'Asia/Manila')::date = d.day
  ) s on true;

  return jsonb_build_object(
    'generated_at', now(),
    'days', v_days,
    'branches', v_branches,
    'products', v_products,
    'daily', v_daily
  );
end;
$$;

revoke all on function public.owner_sales_summary(int) from public, anon;
grant execute on function public.owner_sales_summary(int) to authenticated;
