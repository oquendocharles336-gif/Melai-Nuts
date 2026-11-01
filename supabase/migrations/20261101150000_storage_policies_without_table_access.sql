-- =============================================================================
-- Melai Nuts — Migration 20261101150000: storage rules that app users can run
-- =============================================================================
-- Run after 20261101120000_pickup_downpayment.sql. Idempotent.
--
-- Every upload and read of ANY file failed with "permission denied for table
-- deliveries". The delivery-proof rules on storage.objects read public.deliveries
-- directly, and app users have no SELECT right on that table. Postgres checks that
-- right for every rule on the table, whichever bucket the request is for, so one
-- rule for delivery proofs also blocked staff profile photos.
--
-- The rules keep their meaning. Only the lookup moves into two functions, which read
-- the table with their own rights and answer yes or no about the caller. App users
-- still cannot read public.deliveries.
-- =============================================================================
begin;

create or replace function public.can_upload_delivery_proof(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.deliveries d
    where d.id = split_part(p_name, '/', 1)
      and d.driver_uid = public.current_firebase_uid()
      and d.driver_status in ('picked_up', 'in_transit'))
$$;
revoke all on function public.can_upload_delivery_proof(text) from public, anon;
grant execute on function public.can_upload_delivery_proof(text) to authenticated;

create or replace function public.can_read_delivery_proof(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.deliveries d
    where d.id = split_part(p_name, '/', 1)
      and (public.staff_can_see_branch(d.branch_id) or d.driver_uid = public.current_firebase_uid()))
$$;
revoke all on function public.can_read_delivery_proof(text) from public, anon;
grant execute on function public.can_read_delivery_proof(text) to authenticated;

do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'objects') then
    execute $p$drop policy if exists "driver uploads own proof" on storage.objects$p$;
    execute $p$create policy "driver uploads own proof" on storage.objects for insert to authenticated
      with check (bucket_id = 'delivery-proofs' and public.can_upload_delivery_proof(name))$p$;

    execute $p$drop policy if exists "staff and driver read proof" on storage.objects$p$;
    execute $p$create policy "staff and driver read proof" on storage.objects for select to authenticated
      using (bucket_id = 'delivery-proofs' and public.can_read_delivery_proof(name))$p$;
  end if;
end
$do$;

commit;
