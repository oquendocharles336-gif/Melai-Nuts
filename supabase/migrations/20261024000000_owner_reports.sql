-- =============================================================================
-- Melai Nuts — Migration 20261024000000: owner reports and the daily digest
-- =============================================================================
-- Run after 20261023000000_customer_features.sql. Idempotent, one transaction.
--
--   owner_profit_report(from, to, branch)   per product option: net units, net sales
--       (the same sales/refund definition as sales_overview, 20261015000000), cost per
--       unit from product_variant_costs, cost of goods, profit, margin. COST BASIS: the
--       variant's CURRENT cost (the database keeps no cost-at-time-of-sale), so the
--       report says so. Options with no cost entered are listed with cost "Not set"
--       and left out of profit totals (never counted as zero cost).
--   owner_inventory_valuation(branch)       stock on hand x current cost, per branch
--       and option; options without a cost are counted, not valued.
--   enqueue_owner_daily_digest(day)         one notification per active owner (pushed
--       by the outbox from 20261021000000): yesterday's net sales and orders, items
--       at / below their restock level, out of stock, and batches expiring within the
--       owner's expiry_alert_days. Once per day (reference 'digest:<day>').
--       Service role only; run daily by the same schedule as push-dispatch
--       (docs/PUSH_NOTIFICATIONS.md).
-- Owner only (checked here, not in the apps). Nothing is changed by the reports.
-- =============================================================================
begin;

create or replace function public.owner_profit_report(p_from date, p_to date, p_branch_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_start timestamptz;
  v_end timestamptz;
  v_rows jsonb;
begin
  perform public._require_owner();
  if p_from is null or p_to is null or p_from > p_to then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose at most one year.'; end if;
  v_start := (p_from::timestamp at time zone 'Asia/Manila');
  v_end := ((p_to + 1)::timestamp at time zone 'Asia/Manila');

  with lines as (
    select l.variant_id, max(l.product_name) as product_name, max(l.variant_label) as variant_label,
           sum(l.units - l.refunded_units)::int as net_units,
           round(sum(l.gross - l.discount - l.refund), 2) as net_sales
      from public._sales_line_facts(v_start, v_end, case when p_branch_id is null then null else array[p_branch_id] end) l
     group by l.variant_id, case when l.variant_id is null then l.product_name || '|' || l.variant_label end
  ), costed as (
    select ln.*, c.cost_price,
           case when c.cost_price is not null then round(ln.net_units * c.cost_price, 2) end as cogs
      from lines ln
      left join public.product_variant_costs c on c.variant_id = ln.variant_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'variant_id', variant_id, 'product', product_name, 'variant', variant_label,
           'net_units', net_units, 'net_sales', net_sales, 'unit_cost', cost_price, 'cogs', cogs,
           'profit', case when cogs is not null then net_sales - cogs end,
           'margin_percent', case when cogs is not null and net_sales > 0 then round((net_sales - cogs) / net_sales * 100, 1) end)
         order by net_sales desc, product_name), '[]'::jsonb)
    into v_rows
    from costed;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'branch_id', p_branch_id,
    'cost_basis', 'current cost of each product option (cost at the time of sale is not recorded)',
    'rows', v_rows,
    'totals', (
      select jsonb_build_object(
        'net_sales', coalesce(sum((r ->> 'net_sales')::numeric), 0),
        'costed_net_sales', coalesce(sum((r ->> 'net_sales')::numeric) filter (where r ->> 'cogs' is not null), 0),
        'cogs', coalesce(sum((r ->> 'cogs')::numeric), 0),
        'profit', coalesce(sum((r ->> 'profit')::numeric), 0),
        'margin_percent', case when sum((r ->> 'net_sales')::numeric) filter (where r ->> 'cogs' is not null) > 0
          then round(sum((r ->> 'profit')::numeric) / sum((r ->> 'net_sales')::numeric) filter (where r ->> 'cogs' is not null) * 100, 1) end,
        'options_without_cost', count(*) filter (where r ->> 'cogs' is null and (r ->> 'net_units')::int <> 0),
        'net_sales_without_cost', coalesce(sum((r ->> 'net_sales')::numeric) filter (where r ->> 'cogs' is null), 0))
      from jsonb_array_elements(v_rows) r));
end;
$$;
revoke all on function public.owner_profit_report(date, date, uuid) from public, anon;
grant execute on function public.owner_profit_report(date, date, uuid) to authenticated;

create or replace function public.owner_inventory_valuation(p_branch_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rows jsonb;
begin
  perform public._require_owner();
  select coalesce(jsonb_agg(jsonb_build_object(
           'branch_id', b.id, 'branch', b.name, 'is_warehouse', coalesce((to_jsonb(b) ->> 'is_warehouse')::boolean, false),
           'variant_id', bi.variant_id, 'product', p.name, 'variant', pv.label,
           'quantity', bi.quantity, 'unit_cost', c.cost_price,
           'value', case when c.cost_price is not null then round(bi.quantity * c.cost_price, 2) end)
         order by b.name, p.name, pv.label), '[]'::jsonb)
    into v_rows
    from public.branch_inventory bi
    join public.branches b on b.id = bi.branch_id
    join public.products p on p.id = bi.product_id and p.is_active
    left join public.product_variants pv on pv.id = bi.variant_id
    left join public.product_variant_costs c on c.variant_id = bi.variant_id
   where bi.quantity > 0 and (p_branch_id is null or bi.branch_id = p_branch_id);

  return jsonb_build_object(
    'as_of', now(), 'branch_id', p_branch_id,
    'cost_basis', 'current cost of each product option',
    'rows', v_rows,
    'totals', (
      select jsonb_build_object(
        'units', coalesce(sum((r ->> 'quantity')::int), 0),
        'value', coalesce(sum((r ->> 'value')::numeric), 0),
        'units_without_cost', coalesce(sum((r ->> 'quantity')::int) filter (where r ->> 'value' is null), 0),
        'options_without_cost', count(*) filter (where r ->> 'value' is null))
      from jsonb_array_elements(v_rows) r),
    'by_branch', coalesce((
      select jsonb_agg(jsonb_build_object('branch', branch, 'units', units, 'value', value) order by branch)
      from (select r ->> 'branch' as branch, sum((r ->> 'quantity')::int) as units,
                   coalesce(sum((r ->> 'value')::numeric), 0) as value
              from jsonb_array_elements(v_rows) r group by 1) x), '[]'::jsonb));
end;
$$;
revoke all on function public.owner_inventory_valuation(uuid) from public, anon;
grant execute on function public.owner_inventory_valuation(uuid) to authenticated;

-- Daily digest for owners --------------------------------------------------------
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
    left join public.stock_thresholds st on st.branch_id = bi.branch_id and st.variant_id = bi.variant_id;

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
