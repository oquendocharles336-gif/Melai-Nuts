-- =============================================================================
-- Melai Nuts — Migration 20261014000000
-- Admin portal: one owner-only read of EVERY account in the app (all-users view)
-- =============================================================================
-- RUN ORDER: after 20261013000000_admin_portal_owner_overview.sql. Safe to re-run.
--
-- WHY
--   The website's "Team & roles" page only listed the website's own logins. People
--   also exist in the app's database as staff / owners (staff_members), delivery
--   drivers (drivers) and customers (customer_profiles), and the owner needs to see
--   all of them in one place. The existing functions cannot do that in one call:
--   admin_portal_staff_directory() has staff only, staff_list_drivers() drivers only,
--   and admin_portal_loyalty_members() only customers that have a loyalty account,
--   without any order history.
--
--   owner_all_users(search, limit) returns the three lists in ONE call:
--     staff      every staff / owner row with branch and permissions
--     drivers    every driver with branch, availability and open runs
--     customers  customers (never the 'walk-in' POS placeholder), newest first, with
--                order count, paid total, last order and loyalty balance; filtered by
--                p_search (name, email, phone, card number) and capped at p_limit,
--                with the total number that matched so the page can say "showing N of M".
--
--   OWNER ONLY (_require_owner), read-only, security definer like the other
--   admin_portal_* functions. No RLS change, no new table.
-- =============================================================================

begin;

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

revoke all on function public.owner_all_users(text, int) from public, anon;
grant execute on function public.owner_all_users(text, int) to authenticated;

commit;
