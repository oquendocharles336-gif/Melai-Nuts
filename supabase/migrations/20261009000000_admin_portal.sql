-- =============================================================================
-- Melai Nuts — Migration 20261009000000
-- Admin web portal (Laravel, folder `admin/`) on the SAME Supabase database.
-- =============================================================================
-- RUN ORDER: after every earlier file in supabase/migrations/. Safe to re-run.
--
-- WHY
--   The admin dashboard used to read mock data and keep its own copies of
--   refund decisions, COD confirmations and loyalty points in a local SQLite
--   database. That would have been a second source of truth next to Supabase.
--   Now the admin portal reads and writes the shared Supabase data through the
--   same rules the mobile app uses:
--     * every call runs as the `authenticated` role with the Firebase UID of a
--       registered `staff_members` row (owner or staff), exactly like the app;
--     * every write goes through a SECURITY DEFINER function that checks that
--       staff row, locks the rows it changes and keeps the existing state
--       machines / triggers (payments, refunds, loyalty ledger) in charge.
--
-- WHAT THIS FILE ADDS
--   1. loyalty_cart_settings.earn_pesos_per_point (default 50 = current rule),
--      compute_points_earned() now reads it, and get_loyalty_earn_rate() lets
--      the customer app show it.
--   2. loyalty_transactions.source accepts 'admin_adjust'.
--   3. Read functions for the portal: admin_portal_orders, admin_portal_stock,
--      admin_portal_products, admin_portal_stock_movements,
--      admin_portal_loyalty_summary, admin_portal_loyalty_members,
--      admin_portal_loyalty_member, admin_portal_loyalty_settings,
--      admin_portal_audit_logs, admin_portal_staff_directory.
--   4. Writes: owner_update_loyalty_settings, owner_adjust_loyalty_points
--      (owner only, idempotent per request key) and admin_portal_review_refund
--      (staff with the refunds permission; wraps staff_review_refund).
--   5. The `melai_admin_portal` login role the Laravel server connects with.
--      It owns nothing and is granted nothing except the right to become
--      `authenticated` (SET ROLE), i.e. it can do only what the app can do.
--      Set its password once in the SQL editor (never commit it):
--        alter role melai_admin_portal with login password '<long random>';
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Earn rate becomes a setting (default keeps today's 1 point per PHP 50)
-- -----------------------------------------------------------------------------
alter table public.loyalty_cart_settings
  add column if not exists earn_pesos_per_point numeric(10, 2) not null default 50;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'loyalty_cart_settings_earn_rate_positive') then
    alter table public.loyalty_cart_settings
      add constraint loyalty_cart_settings_earn_rate_positive check (earn_pesos_per_point >= 1);
  end if;
end $$;

-- Same trigger, same timing (before insert on orders); only the divisor moved
-- from a literal into the settings row. Falls back to 50 if the row is missing.
create or replace function public.compute_points_earned()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rate numeric;
begin
  select earn_pesos_per_point into v_rate from public.loyalty_cart_settings where id = 'default';
  new.points_earned := greatest(0, floor(new.total / greatest(coalesce(v_rate, 50), 1))::int);
  return new;
end;
$$;

-- The customer app shows "Earn 1 pt per PHP X"; X is public, so anyone may read it.
create or replace function public.get_loyalty_earn_rate()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select earn_pesos_per_point from public.loyalty_cart_settings where id = 'default'), 50)
$$;
revoke all on function public.get_loyalty_earn_rate() from public;
grant execute on function public.get_loyalty_earn_rate() to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. Ledger source for manual owner adjustments (superset of the old list)
-- -----------------------------------------------------------------------------
alter table public.loyalty_transactions drop constraint if exists loyalty_transactions_source_check;
alter table public.loyalty_transactions add constraint loyalty_transactions_source_check
  check (source is null or source in ('order_earn', 'order_redeem', 'order_return', 'order_clawback', 'admin_adjust'));

-- -----------------------------------------------------------------------------
-- 3. Read functions
-- -----------------------------------------------------------------------------

-- Orders with their payment and latest refund request, for the caller's
-- authorized branches (owner: all; staff: own branch). Refund details are only
-- included for callers allowed to review refunds.
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
          'refund', case when v_refunds then (
                      select jsonb_build_object('id', r.id, 'status', r.status, 'amount', r.amount,
                                                'reason', r.reason, 'notes', r.notes,
                                                'payment_method', r.payment_method,
                                                'created_at', r.created_at, 'updated_at', r.updated_at)
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

-- Stock per authorized branch and variant, with the branch's restock threshold.
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

-- Full catalog for staff (inactive products included) with stock summed over
-- the caller's authorized branches.
create or replace function public.admin_portal_products()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_branches uuid[];
begin
  perform public._require_staff();
  v_branches := public.staff_authorized_branch_ids();
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', p.id, 'name', p.name, 'sku', p.sku, 'unit', p.unit, 'price', p.price,
             'is_active', p.is_active, 'is_featured', p.is_featured,
             'category', nullif(c.label, ''),
             'updated_at', p.updated_at,
             'variants', (select coalesce(jsonb_agg(jsonb_build_object(
                             'id', pv.id, 'label', pv.label, 'sku', pv.sku, 'price', pv.price,
                             'stock', coalesce((select sum(bi.quantity) from public.branch_inventory bi
                                                where bi.variant_id = pv.id and bi.branch_id = any (v_branches)), 0))
                           order by pv.sort_order, pv.label), '[]'::jsonb)
                          from public.product_variants pv where pv.product_id = p.id)
           ) order by p.is_active desc, p.name), '[]'::jsonb)
    from public.products p
    left join public.product_categories c on c.id = p.category_id
  );
end;
$$;

create or replace function public.admin_portal_stock_movements(
  p_branch_id uuid default null,
  p_limit int default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_branches uuid[];
begin
  perform public._require_staff();
  v_branches := public.staff_authorized_branch_ids();
  if p_branch_id is not null then
    if not (p_branch_id = any (v_branches)) then
      raise exception 'You can only work in your assigned branch.';
    end if;
    v_branches := array[p_branch_id];
  end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
    from (
      select m.id, m.created_at, m.branch_id, b.name as branch_name, m.movement_type,
             m.quantity_change, m.reason, m.reference,
             p.name as product_name, pv.label as variant_label,
             nullif(s.full_name, '') as staff_name
      from public.stock_movements m
      join public.branches b on b.id = m.branch_id
      left join public.products p on p.id = m.product_id
      left join public.product_variants pv on pv.id = m.variant_id
      left join public.staff_members s on s.firebase_uid = m.created_by
      where m.branch_id = any (v_branches)
      order by m.created_at desc
      limit least(greatest(coalesce(p_limit, 100), 1), 500)
    ) x
  );
end;
$$;

-- Loyalty: staff may read (they already look customers up at the counter);
-- only owners may change settings or balances.
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
    'redeemed_month', (select coalesce(-sum(points), 0) from public.loyalty_transactions
                       where points < 0 and created_at >= v_month_start)
  );
end;
$$;

create or replace function public.admin_portal_loyalty_members(
  p_search text default null,
  p_limit int default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := nullif(lower(trim(coalesce(p_search, ''))), '');
begin
  perform public._require_staff();
  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.name, x.id), '[]'::jsonb)
    from (
      select a.firebase_uid as id,
             coalesce(nullif(cp.full_name, ''), 'Customer') as name,
             cp.email, cp.rfid_card_number as card_number,
             a.points_balance as balance, a.lifetime_points as lifetime,
             coalesce((select sum(t.points) from public.loyalty_transactions t
                       where t.firebase_uid = a.firebase_uid and t.source = 'order_earn'), 0) as earned,
             coalesce((select -sum(t.points) from public.loyalty_transactions t
                       where t.firebase_uid = a.firebase_uid and t.type = 'redeem'
                         and coalesce(t.source, '') not in ('order_clawback', 'admin_adjust')), 0) as redeemed,
             coalesce((select -sum(t.points) from public.loyalty_transactions t
                       where t.firebase_uid = a.firebase_uid and t.source = 'order_clawback'), 0) as refunded,
             coalesce((select sum(t.points) from public.loyalty_transactions t
                       where t.firebase_uid = a.firebase_uid and t.source = 'admin_adjust'), 0) as adjusted
      from public.loyalty_accounts a
      join public.customer_profiles cp on cp.firebase_uid = a.firebase_uid
      where a.firebase_uid <> 'walk-in'
        and (v_q is null
             or lower(cp.full_name) like '%' || v_q || '%'
             or lower(cp.email) like '%' || v_q || '%'
             or lower(coalesce(cp.rfid_card_number, '')) like '%' || v_q || '%')
      order by coalesce(nullif(cp.full_name, ''), 'Customer'), a.firebase_uid
      limit least(greatest(coalesce(p_limit, 200), 1), 1000)
    ) x
  );
end;
$$;

create or replace function public.admin_portal_loyalty_member(p_firebase_uid text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_member jsonb;
begin
  perform public._require_staff();
  select to_jsonb(x) into v_member
  from (
    select cp.firebase_uid as id, coalesce(nullif(cp.full_name, ''), 'Customer') as name,
           cp.email, cp.rfid_card_number as card_number,
           coalesce(a.points_balance, 0) as balance, coalesce(a.lifetime_points, 0) as lifetime
    from public.customer_profiles cp
    left join public.loyalty_accounts a on a.firebase_uid = cp.firebase_uid
    where cp.firebase_uid = p_firebase_uid and cp.firebase_uid <> 'walk-in'
  ) x;
  if v_member is null then
    return null;
  end if;
  return v_member || jsonb_build_object('history', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc, t.id desc), '[]'::jsonb)
    from (
      select id, type, points, description, order_id, source, created_at
      from public.loyalty_transactions
      where firebase_uid = p_firebase_uid
      order by created_at desc
      limit 500
    ) t
  ));
end;
$$;

create or replace function public.admin_portal_loyalty_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_staff();
  return (
    select jsonb_build_object('earn_pesos_per_point', s.earn_pesos_per_point,
                              'points_per_peso', s.points_per_peso,
                              'max_discount_percent', s.max_discount_percent,
                              'updated_at', s.updated_at)
    from public.loyalty_cart_settings s where s.id = 'default'
  );
end;
$$;

-- Staff audit trail with readable names. Owners see everything; staff see
-- their own entries (same rule as the table's RLS policy).
create or replace function public.admin_portal_audit_logs(
  p_limit int default 100,
  p_before timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
begin
  v_staff := public._require_staff();
  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
    from (
      select l.id, l.created_at, l.action, l.entity_type, l.entity_id, l.metadata,
             nullif(s.full_name, '') as staff_name, s.email as staff_email, b.name as branch_name
      from public.staff_audit_logs l
      left join public.staff_members s on s.firebase_uid = l.staff_firebase_uid
      left join public.branches b on b.id = l.branch_id
      where (v_staff.role = 'owner' or l.staff_firebase_uid = v_staff.firebase_uid)
        and (p_before is null or l.created_at < p_before)
      order by l.created_at desc
      limit least(greatest(coalesce(p_limit, 100), 1), 500)
    ) x
  );
end;
$$;

-- Owners pick from this list when linking an admin-portal login to a
-- registered staff/owner account.
create or replace function public.admin_portal_staff_directory()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_owner();
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'firebase_uid', s.firebase_uid, 'full_name', s.full_name, 'email', s.email,
             'role', s.role, 'branch_id', s.branch_id, 'branch_name', b.name,
             'is_active', s.is_active, 'account_status', s.account_status)
           order by s.role desc, s.full_name), '[]'::jsonb)
    from public.staff_members s
    left join public.branches b on b.id = s.branch_id
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Owner-only writes
-- -----------------------------------------------------------------------------
create or replace function public.owner_update_loyalty_settings(
  p_earn_pesos_per_point numeric,
  p_points_per_peso numeric,
  p_max_discount_percent numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
  v_old public.loyalty_cart_settings;
begin
  v_owner := public._require_owner();
  if p_earn_pesos_per_point is null or p_earn_pesos_per_point < 1 or p_earn_pesos_per_point > 100000 then
    raise exception 'Earn rate must be between PHP 1 and PHP 100,000 per point.';
  end if;
  if p_points_per_peso is null or p_points_per_peso <= 0 or p_points_per_peso > 10000 then
    raise exception 'Redeem rate must be more than 0 and at most 10,000 points per peso.';
  end if;
  if p_max_discount_percent is null or p_max_discount_percent <= 0 or p_max_discount_percent > 100 then
    raise exception 'Maximum discount must be more than 0%% and at most 100%%.';
  end if;

  select * into v_old from public.loyalty_cart_settings where id = 'default' for update;
  insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point, updated_at)
  values ('default', p_points_per_peso, p_max_discount_percent, p_earn_pesos_per_point, now())
  on conflict (id) do update
    set points_per_peso = excluded.points_per_peso,
        max_discount_percent = excluded.max_discount_percent,
        earn_pesos_per_point = excluded.earn_pesos_per_point,
        updated_at = now();

  perform public._write_audit(v_owner.firebase_uid, null, 'loyalty.settings_updated', 'loyalty_settings', 'default',
    jsonb_build_object(
      'before', jsonb_build_object('earn_pesos_per_point', v_old.earn_pesos_per_point,
                                   'points_per_peso', v_old.points_per_peso,
                                   'max_discount_percent', v_old.max_discount_percent),
      'after', jsonb_build_object('earn_pesos_per_point', p_earn_pesos_per_point,
                                  'points_per_peso', p_points_per_peso,
                                  'max_discount_percent', p_max_discount_percent)));
  return public.admin_portal_loyalty_settings();
end;
$$;

-- Manual add (+) / deduct (-) with a required reason. Appends to the ledger
-- (never edits it), keeps the balance >= 0, notifies the customer and audits.
-- p_request_key makes a double-submitted form apply once: the second call
-- returns {"duplicate": true} and changes nothing.
create or replace function public.owner_adjust_loyalty_points(
  p_firebase_uid text,
  p_points int,
  p_reason text,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
  v_reason text := trim(coalesce(p_reason, ''));
  v_key text := trim(coalesce(p_request_key, ''));
  v_balance int;
  v_tx_id text;
begin
  v_owner := public._require_owner();
  if p_points is null or p_points = 0 then raise exception 'Enter a non-zero whole number of points.'; end if;
  if abs(p_points) > 100000 then raise exception 'That adjustment is too large (maximum 100,000 points).'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 255 then
    raise exception 'A reason of 3 to 255 characters is required for a manual adjustment.';
  end if;
  if v_key !~ '^[A-Za-z0-9_-]{8,64}$' then raise exception 'Missing or invalid request key.'; end if;
  if p_firebase_uid is null or p_firebase_uid = 'walk-in'
     or not exists (select 1 from public.customer_profiles where firebase_uid = p_firebase_uid) then
    raise exception 'That loyalty member could not be found.';
  end if;

  -- Serialise retries of the same request, then check whether it already ran.
  perform pg_advisory_xact_lock(hashtextextended('loyalty_adjust:' || v_owner.firebase_uid || ':' || v_key, 0));
  if exists (select 1 from public.staff_audit_logs
             where staff_firebase_uid = v_owner.firebase_uid and client_operation_id = 'loyalty_adjust:' || v_key) then
    return jsonb_build_object('duplicate', true);
  end if;

  insert into public.loyalty_accounts (firebase_uid) values (p_firebase_uid) on conflict (firebase_uid) do nothing;
  select points_balance into v_balance from public.loyalty_accounts where firebase_uid = p_firebase_uid for update;
  if p_points < 0 and abs(p_points) > v_balance then
    raise exception 'You cannot deduct more points than the member''s current balance (%).', v_balance;
  end if;

  update public.loyalty_accounts
  set points_balance = points_balance + p_points,
      lifetime_points = lifetime_points + greatest(p_points, 0)
  where firebase_uid = p_firebase_uid;

  insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
  values (p_firebase_uid, case when p_points > 0 then 'earn' else 'redeem' end, p_points,
          'Adjustment by Melai Nuts: ' || v_reason, null, 'admin_adjust')
  returning id into v_tx_id;

  perform public.notify_customer(p_firebase_uid, 'loyalty',
    case when p_points > 0 then 'Points added' else 'Points deducted' end,
    abs(p_points)::text || ' points were ' || case when p_points > 0 then 'added to' else 'deducted from' end
      || ' your account. Reason: ' || v_reason);

  perform public._write_audit(v_owner.firebase_uid, null, 'loyalty.adjusted', 'loyalty_account', p_firebase_uid,
    jsonb_build_object('points', p_points, 'reason', v_reason, 'transaction_id', v_tx_id,
                       'balance_after', v_balance + p_points),
    'loyalty_adjust:' || v_key);

  return jsonb_build_object('duplicate', false, 'transaction_id', v_tx_id, 'balance', v_balance + p_points);
end;
$$;

-- Refund review from the portal. Wraps staff_review_refund (which checks the
-- branch + refunds permission and lets the state-machine trigger validate the
-- move) and adds what the portal needs on top:
--   'approve'       pending -> approved (online payments: money goes back
--                   through the gateway / e-wallet, then 'complete')
--   'approve_cash'  pending -> approved -> completed in one transaction, only
--                   for cash payments (cash handed back at the counter)
--   'complete'      approved/processing -> completed; p_note = the gateway or
--                   e-wallet refund reference (required, 4+ characters)
--   'reject'        p_note = reason (required); the customer is told why
-- Every action is written to staff_audit_logs.
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
    raise exception 'Unsupported refund action.';
  end if;

  perform public._write_audit(v_staff.firebase_uid, v_branch, 'refund.' || p_action, 'refund_request', r.id,
    jsonb_build_object('order_id', r.order_id, 'amount', r.amount, 'payment_method', v_pay_method,
                       'note', v_note, 'via', 'admin_portal'));

  return (select jsonb_build_object('id', id, 'status', status, 'order_id', order_id)
          from public.refund_requests where id = r.id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Grants: only signed-in callers (the functions check staff/owner inside)
-- -----------------------------------------------------------------------------
revoke all on function public.admin_portal_orders(timestamptz, timestamptz, uuid) from public, anon;
revoke all on function public.admin_portal_stock() from public, anon;
revoke all on function public.admin_portal_products() from public, anon;
revoke all on function public.admin_portal_stock_movements(uuid, int) from public, anon;
revoke all on function public.admin_portal_loyalty_summary() from public, anon;
revoke all on function public.admin_portal_loyalty_members(text, int) from public, anon;
revoke all on function public.admin_portal_loyalty_member(text) from public, anon;
revoke all on function public.admin_portal_loyalty_settings() from public, anon;
revoke all on function public.admin_portal_audit_logs(int, timestamptz) from public, anon;
revoke all on function public.admin_portal_staff_directory() from public, anon;
revoke all on function public.owner_update_loyalty_settings(numeric, numeric, numeric) from public, anon;
revoke all on function public.owner_adjust_loyalty_points(text, int, text, text) from public, anon;
revoke all on function public.admin_portal_review_refund(text, text, text) from public, anon;

grant execute on function public.admin_portal_orders(timestamptz, timestamptz, uuid) to authenticated;
grant execute on function public.admin_portal_stock() to authenticated;
grant execute on function public.admin_portal_products() to authenticated;
grant execute on function public.admin_portal_stock_movements(uuid, int) to authenticated;
grant execute on function public.admin_portal_loyalty_summary() to authenticated;
grant execute on function public.admin_portal_loyalty_members(text, int) to authenticated;
grant execute on function public.admin_portal_loyalty_member(text) to authenticated;
grant execute on function public.admin_portal_loyalty_settings() to authenticated;
grant execute on function public.admin_portal_audit_logs(int, timestamptz) to authenticated;
grant execute on function public.admin_portal_staff_directory() to authenticated;
grant execute on function public.owner_update_loyalty_settings(numeric, numeric, numeric) to authenticated;
grant execute on function public.owner_adjust_loyalty_points(text, int, text, text) to authenticated;
grant execute on function public.admin_portal_review_refund(text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 6. Login role for the Laravel server (no password here; set it manually)
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'melai_admin_portal') then
    create role melai_admin_portal noinherit nologin;
  end if;
end $$;
-- NOINHERIT: the role has no privileges of its own. Each request must
-- `SET LOCAL ROLE authenticated` inside a transaction with a staff UID in
-- request.jwt.claims, which puts it under exactly the app's RLS and checks.
grant authenticated to melai_admin_portal;
alter role melai_admin_portal set statement_timeout = '15s';

commit;
