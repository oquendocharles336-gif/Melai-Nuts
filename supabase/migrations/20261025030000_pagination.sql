-- =============================================================================
-- Melai Nuts — Migration 20261025030000: real pagination and bounded list sizes
-- =============================================================================
-- Run after 20261025020000_grants_hardening.sql. Idempotent, one transaction.
--
-- WHAT
--   1. Indexes for the app's paginated lists (newest first, keyset by created_at, id):
--      a customer's orders, notifications, loyalty transactions and refunds; a branch's
--      orders; staff notifications.
--   2. owner_all_users(search, limit, offset): the customers list is paged in the
--      database (limit max 200 per page, offset) with the total that matched; a phone
--      search finds numbers typed as 0917… even though they are stored as +63917….
--   3. admin_portal_orders_page(...): one page of orders with search, status / payment
--      filters and sorting done in SQL, plus the total, so the website can paginate
--      without loading a 90-day window (max 100 rows per call).
--   4. Every list function has a hard maximum (a client cannot ask for 1,000,000 rows):
--      get_popular_products is capped at 50.
-- =============================================================================
begin;

-- 1. Indexes ----------------------------------------------------------------------------
create index if not exists orders_customer_page_idx on public.orders (firebase_uid, created_at desc, id desc);
create index if not exists orders_branch_page_idx on public.orders (branch_id, created_at desc, id desc);
create index if not exists notifications_customer_page_idx on public.notifications (firebase_uid, created_at desc, id desc);
create index if not exists loyalty_transactions_page_idx on public.loyalty_transactions (firebase_uid, created_at desc, id desc);
create index if not exists refund_requests_customer_page_idx on public.refund_requests (firebase_uid, created_at desc, id desc);
create index if not exists refund_requests_order_idx on public.refund_requests (order_id);
create index if not exists payments_order_idx on public.payments (order_id);
create index if not exists order_items_order_idx on public.order_items (order_id);
create index if not exists products_name_lower_idx on public.products (lower(name));
create index if not exists customer_profiles_created_idx on public.customer_profiles (created_at desc, firebase_uid);

-- 2. owner_all_users with offset --------------------------------------------------------
drop function if exists public.owner_all_users(text, int);

create or replace function public.owner_all_users(
  p_search text default null,
  p_limit int default 50,
  p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := nullif(lower(trim(coalesce(p_search, ''))), '');
  -- 0917… typed by a person, +63917… stored: search both forms.
  v_q_phone text := case when nullif(lower(trim(coalesce(p_search, ''))), '') ~ '^0?9[0-9]*$'
                         then '+63' || regexp_replace(lower(trim(p_search)), '^0', '') end;
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 2000);
  v_offset int := least(greatest(coalesce(p_offset, 0), 0), 1000000);
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
        where cp.firebase_uid <> 'walk-in'
          and (v_q is null
               or lower(cp.full_name) like '%' || v_q || '%'
               or lower(cp.email) like '%' || v_q || '%'
               or lower(cp.phone) like '%' || v_q || '%'
               or (v_q_phone is not null and cp.phone like v_q_phone || '%')
               or lower(coalesce(cp.rfid_card_number, '')) like '%' || v_q || '%')
        order by cp.created_at desc, cp.firebase_uid
        limit v_limit offset v_offset
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
             or (v_q_phone is not null and cp.phone like v_q_phone || '%')
             or lower(coalesce(cp.rfid_card_number, '')) like '%' || v_q || '%')
    ),
    'limit', v_limit,
    'offset', v_offset
  );
end;
$$;
revoke all on function public.owner_all_users(text, int, int) from public, anon;
grant execute on function public.owner_all_users(text, int, int) to authenticated;

-- 3. One page of orders for the website ------------------------------------------------
create or replace function public.admin_portal_orders_page(
  p_from timestamptz,
  p_to timestamptz,
  p_branch_id uuid default null,
  p_search text default null,
  p_status text default null,
  p_payment_method text default null,
  p_sort text default 'created_at',
  p_dir text default 'desc',
  p_limit int default 25,
  p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_branches uuid[];
  v_refunds boolean;
  v_q text := nullif(lower(trim(coalesce(p_search, ''))), '');
  v_limit int := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset int := least(greatest(coalesce(p_offset, 0), 0), 1000000);
  v_sort text := case when p_sort in ('created_at', 'total', 'id', 'status') then p_sort else 'created_at' end;
  v_desc boolean := lower(coalesce(p_dir, 'desc')) <> 'asc';
  v_total bigint;
  v_rows jsonb;
begin
  perform public._require_staff();
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

  select count(*) into v_total
    from public.orders o
    left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
   where o.branch_id = any (v_branches)
     and o.created_at >= p_from and o.created_at <= p_to
     and (p_status is null or o.status = p_status)
     and (p_payment_method is null or o.payment_method = p_payment_method)
     and (v_q is null
          or lower(o.id) like '%' || v_q || '%'
          or lower(coalesce(cp.full_name, '')) like '%' || v_q || '%'
          or lower(coalesce(o.branch_name, '')) like '%' || v_q || '%');

  select coalesce(jsonb_agg(x.j order by x.rn), '[]'::jsonb) into v_rows
  from (
    select pg.rn,
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
        'refund_summary', public._order_refund_json(o.id),
        'refund', case when v_refunds then (
                    select jsonb_build_object('id', r.id, 'status', r.status, 'amount', r.amount,
                                              'reason', r.reason, 'notes', r.notes,
                                              'payment_method', r.payment_method,
                                              'created_at', r.created_at, 'updated_at', r.updated_at)
                    from public.refund_requests r where r.order_id = o.id
                    order by r.created_at desc limit 1) end
      ) as j
    from (
      select o2.id, row_number() over (
               order by
                 case when v_sort = 'created_at' and v_desc then o2.created_at end desc nulls last,
                 case when v_sort = 'created_at' and not v_desc then o2.created_at end asc nulls last,
                 case when v_sort = 'total' and v_desc then o2.total end desc nulls last,
                 case when v_sort = 'total' and not v_desc then o2.total end asc nulls last,
                 case when v_sort = 'status' and v_desc then o2.status end desc nulls last,
                 case when v_sort = 'status' and not v_desc then o2.status end asc nulls last,
                 case when v_desc then o2.id end desc,
                 case when not v_desc then o2.id end asc) as rn
        from public.orders o2
        left join public.customer_profiles cp2 on cp2.firebase_uid = o2.firebase_uid
       where o2.branch_id = any (v_branches)
         and o2.created_at >= p_from and o2.created_at <= p_to
         and (p_status is null or o2.status = p_status)
         and (p_payment_method is null or o2.payment_method = p_payment_method)
         and (v_q is null
              or lower(o2.id) like '%' || v_q || '%'
              or lower(coalesce(cp2.full_name, '')) like '%' || v_q || '%'
              or lower(coalesce(o2.branch_name, '')) like '%' || v_q || '%')
       order by rn
       limit v_limit offset v_offset
    ) pg
    join public.orders o on o.id = pg.id
    left join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid
  ) x;

  return jsonb_build_object('rows', v_rows, 'total', v_total, 'limit', v_limit, 'offset', v_offset,
                            'sort', v_sort, 'dir', case when v_desc then 'desc' else 'asc' end);
end;
$$;
revoke all on function public.admin_portal_orders_page(timestamptz, timestamptz, uuid, text, text, text, text, text, int, int) from public, anon;
grant execute on function public.admin_portal_orders_page(timestamptz, timestamptz, uuid, text, text, text, text, text, int, int) to authenticated;

-- 4. Hard caps -------------------------------------------------------------------------
create or replace function public.get_popular_products(p_limit integer default 8)
returns table(product_id uuid, total_quantity bigint)
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
  limit least(greatest(coalesce(p_limit, 8), 0), 50)
$$;

commit;
