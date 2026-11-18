-- =============================================================================
-- Melai Nuts — Migration 20261118060000: expiry alerts on by default
-- =============================================================================
-- Run after 20261118050000_account_email_actions.sql. Idempotent, one transaction.
--
-- Branch staff are now always told when a batch is about to expire:
--   * business_settings.expiry_alert_days defaults to 30 (the owner can still
--     change it on Business settings); "Not set" now also means 30 days.
--   * public.staff_check_expiring_batches(p_branch_id): the staff app calls it
--     when the Staff Portal opens, so the alerts appear even if the daily
--     `melai-expiry-alerts` cron job (docs/PUSH_NOTIFICATIONS.md) is not
--     scheduled. Each batch is announced once (reference `expiry:<batch id>`),
--     exactly like enqueue_expiring_batch_alerts(), and every alert is also
--     pushed to the staff member's phone through push_outbox.
-- =============================================================================
begin;

alter table public.business_settings add column if not exists expiry_alert_days int;
update public.business_settings set expiry_alert_days = 30
 where id = 'default' and expiry_alert_days is null;

-- Shared worker: one branch, or every branch when p_branch_id is null.
create or replace function public._enqueue_expiring_batch_alerts(p_branch_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days int := coalesce((select expiry_alert_days from public.business_settings where id = 'default'), 30);
  b record;
  n int := 0;
begin
  -- Two staff opening the app at once must not announce the same batch twice.
  perform pg_advisory_xact_lock(hashtext('melai-expiry-alerts'));
  for b in
    select ib.id, ib.branch_id, ib.expiration_date, ib.quantity,
           p.name || ' (' || pv.label || ')' as item
      from public.inventory_batches ib
      join public.product_variants pv on pv.id = ib.variant_id
      join public.products p on p.id = pv.product_id
     where ib.quantity > 0
       and (p_branch_id is null or ib.branch_id = p_branch_id)
       and ib.expiration_date <= current_date + v_days
       and not exists (select 1 from public.staff_notifications sn where sn.reference = 'expiry:' || ib.id::text)
  loop
    perform public._notify_staff(b.branch_id, 'inventory',
      case when b.expiration_date < current_date then 'Expired: ' else 'Expiring soon: ' end || b.item,
      b.quantity || ' unit(s), batch expires ' || to_char(b.expiration_date, 'Mon DD, YYYY') || '.',
      'expiry:' || b.id::text, 'inventory');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public._enqueue_expiring_batch_alerts(uuid) from public, anon, authenticated;

-- Daily job (service role): every branch.
create or replace function public.enqueue_expiring_batch_alerts()
returns int
language sql
security definer
set search_path = public
as $$ select public._enqueue_expiring_batch_alerts(null) $$;
revoke all on function public.enqueue_expiring_batch_alerts() from public, anon, authenticated;
grant execute on function public.enqueue_expiring_batch_alerts() to service_role;

-- Staff app: their own branch only (owners may name any branch).
create or replace function public.staff_check_expiring_batches(p_branch_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.staff_members;
begin
  v := public._require_staff(p_branch_id);
  return public._enqueue_expiring_batch_alerts(coalesce(p_branch_id, v.branch_id));
end;
$$;
revoke all on function public.staff_check_expiring_batches(uuid) from public, anon;
grant execute on function public.staff_check_expiring_batches(uuid) to authenticated;

commit;
