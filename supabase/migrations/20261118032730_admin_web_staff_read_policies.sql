-- Read-only access for staff on the Lovable admin website (Firebase-authenticated).
-- Branch staff see rows of orders in branches they can see; owners see all (staff_can_see_branch handles both).

drop policy if exists "staff: read branch payments" on public.payments;
create policy "staff: read branch payments" on public.payments
  for select to authenticated
  using (exists (select 1 from public.orders o where o.id = payments.order_id and public.staff_can_see_branch(o.branch_id)));

drop policy if exists "staff: read branch order items" on public.order_items;
create policy "staff: read branch order items" on public.order_items
  for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_items.order_id and public.staff_can_see_branch(o.branch_id)));

drop policy if exists "staff: read branch order history" on public.order_status_events;
create policy "staff: read branch order history" on public.order_status_events
  for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_status_events.order_id and public.staff_can_see_branch(o.branch_id)));

drop policy if exists "staff: read branch refund items" on public.refund_items;
create policy "staff: read branch refund items" on public.refund_items
  for select to authenticated
  using (public.staff_has_permission('refunds') and exists (
    select 1 from public.refund_requests r join public.orders o on o.id = r.order_id
    where r.id = refund_items.refund_request_id and public.staff_can_see_branch(o.branch_id)));

drop policy if exists "staff: read loyalty accounts" on public.loyalty_accounts;
create policy "staff: read loyalty accounts" on public.loyalty_accounts
  for select to authenticated using (public.is_active_staff());

drop policy if exists "staff: read loyalty history" on public.loyalty_transactions;
create policy "staff: read loyalty history" on public.loyalty_transactions
  for select to authenticated using (public.is_active_staff());

drop policy if exists "staff: read vouchers" on public.vouchers;
create policy "staff: read vouchers" on public.vouchers
  for select to authenticated using (public.is_active_staff());
