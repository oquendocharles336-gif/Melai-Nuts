-- =============================================================================
-- Melai Nuts — Migration 20261020000000: order items carry their variant id
-- =============================================================================
-- Run after 20261019000000_rate_limits.sql. Idempotent, one transaction.
-- staff_list_orders() now returns variant_id and product_id for every order
-- item, so the staff app can offer COUNTER RETURNS (staff_pos_return /
-- staff_receive_returned_items need the variant of each returned line).
-- Same function otherwise (same scoping, same columns).
-- =============================================================================
begin;

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
                      'variant_id', i.variant_id, 'product_id', i.product_id,
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

grant execute on function public.staff_list_orders(uuid, text[], timestamptz, int, text) to authenticated;

commit;
