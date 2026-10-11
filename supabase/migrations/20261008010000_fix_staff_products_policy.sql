-- Fix: "staff read all products" had no TO clause, so it applied to anon too.
-- anon cannot execute is_active_staff(), which made every signed-out read of
-- public.products fail (guest catalog, product search). Scope it to authenticated.
-- Idempotent. Requires 20261001000000.
begin;
drop policy if exists "staff read all products" on public.products;
create policy "staff read all products" on public.products
  for select to authenticated using (public.is_active_staff());
commit;
