-- =============================================================================
-- Melai Nuts — Migration 20261027010000: stock counts follow branch_inventory.is_carried
-- =============================================================================
-- Run after 20261027000000_review_fixes.sql (which adds the column). Idempotent,
-- one transaction.
--
-- 20261027000000 made "this branch sells this item" an explicit flag
-- (branch_inventory.is_carried) and used it in admin_portal_stock and the app.
-- The other places that count "out of stock" / "running low" still counted
-- every row, so items a branch never sells were reported as out of stock:
--   * staff_get_dashboard        (staff app dashboard: out / low counts)
--   * analytics_report           ('inventory' block: out_of_stock / low_stock)
--   * enqueue_owner_daily_digest (owners' daily "Stock: N low, N out" message)
-- Each function below is its latest definition (20261015000000 / 20261024000000)
-- with ONLY the extra "bi.is_carried" condition added. Units on hand and stock
-- value are unchanged: a row that isn't carried always holds 0 units (receiving
-- stock makes it carried).
-- =============================================================================
begin;

-- staff_get_dashboard (from 20261015000000_refunds_in_analytics.sql) -----------
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
    where bi.branch_id = v_branch and bi.variant_id is not null and bi.is_carried
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
revoke all on function public.staff_get_dashboard(uuid) from public, anon;
grant execute on function public.staff_get_dashboard(uuid) to authenticated;

-- analytics_report (from 20261015000000_refunds_in_analytics.sql) --------------
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
      where bi.is_carried and (p_branch_id is null or bi.branch_id = p_branch_id))
  );
end;
$$;
revoke all on function public.analytics_report(date, date, uuid) from public, anon;
grant execute on function public.analytics_report(date, date, uuid) to authenticated;

-- enqueue_owner_daily_digest (from 20261024000000_owner_reports.sql) -----------
create or replace function public.enqueue_owner_daily_digest(p_day date default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day date := coalesce(p_day, (now() at time zone 'Asia/Manila')::date - 1);
  v_start timestamptz := (v_day::timestamp at time zone 'Asia/Manila');
  v_end timestamptz := ((v_day + 1)::timestamp at time zone 'Asia/Manila');
  v_days int := (select expiry_alert_days from public.business_settings where id = 'default');
  v_orders bigint;
  v_net numeric;
  v_low int;
  v_out int;
  v_exp int;
  v_body text;
  n int := 0;
begin
  select count(*) filter (where kind = 'sale'),
         round(coalesce(sum(gross - discount - refund), 0), 2)
    into v_orders, v_net
    from public._sales_facts(v_start, v_end, null);

  select count(*) filter (where bi.quantity = 0),
         count(*) filter (where bi.quantity > 0
                          and bi.quantity <= coalesce(st.restock_threshold, public._default_restock_threshold()))
    into v_out, v_low
    from public.branch_inventory bi
    join public.products p on p.id = bi.product_id and p.is_active
    join public.branches b on b.id = bi.branch_id and b.is_active
    left join public.stock_thresholds st on st.branch_id = bi.branch_id and st.variant_id = bi.variant_id
   where bi.is_carried;

  if v_days is not null then
    select count(*) into v_exp
      from public.inventory_batches ib
     where ib.quantity > 0 and ib.expiration_date <= current_date + v_days;
  end if;

  v_body := v_orders || ' sale(s), net ₱' || to_char(v_net, 'FM999,999,999,990.00')
    || '. Stock: ' || v_low || ' low, ' || v_out || ' out'
    || case when v_days is null then '.' else '. Expiring within ' || v_days || ' day(s): ' || coalesce(v_exp, 0) || ' batch(es).' end;

  insert into public.staff_notifications (recipient_uid, branch_id, category, title, body, reference)
  select s.firebase_uid, null, 'system', 'Daily summary for ' || to_char(v_day, 'Mon DD'), v_body, 'digest:' || v_day
    from public.staff_members s
   where s.is_active and s.role = 'owner'
     and not exists (select 1 from public.staff_notifications sn
                      where sn.recipient_uid = s.firebase_uid and sn.reference = 'digest:' || v_day);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.enqueue_owner_daily_digest(date) from public, anon, authenticated;
grant execute on function public.enqueue_owner_daily_digest(date) to service_role;

commit;
