-- =============================================================================
-- Melai Nuts — Migration 20261022000000: a warehouse is a branch that only holds stock
-- =============================================================================
-- Run after 20261021000000_push_notifications.sql. Idempotent, one transaction.
--
-- A warehouse is a row in public.branches with is_warehouse = true. It:
--   * never takes customer orders or POS sales (supports_delivery and
--     supports_pickup are forced false, and an order for it is refused);
--   * is hidden from the customer branch picker (the app filters it);
--   * receives stock (Receive Stock / purchase receipts) and sends it to the
--     shops with the existing stock transfers (branch -> branch).
-- The owner marks a branch as warehouse with owner_set_branch_warehouse() or on
-- the admin website (Business settings > Branches).
-- =============================================================================
begin;

alter table public.branches add column if not exists is_warehouse boolean not null default false;
alter table public.branches drop constraint if exists branches_warehouse_sells_nothing;
alter table public.branches add constraint branches_warehouse_sells_nothing
  check (not is_warehouse or (not supports_delivery and not supports_pickup));

create or replace function public._trg_orders_not_at_warehouse()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.branches where id = new.branch_id and is_warehouse) then
    raise exception 'A warehouse does not sell: choose a shop branch.';
  end if;
  return new;
end;
$$;
revoke all on function public._trg_orders_not_at_warehouse() from public, anon, authenticated;
drop trigger if exists orders_not_at_warehouse on public.orders;
create trigger orders_not_at_warehouse before insert on public.orders
  for each row execute function public._trg_orders_not_at_warehouse();

create or replace function public.owner_set_branch_warehouse(p_branch_id uuid, p_is_warehouse boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner public.staff_members;
begin
  v_owner := public._require_owner();
  if p_is_warehouse is null then raise exception 'Choose shop or warehouse.'; end if;
  update public.branches
     set is_warehouse = p_is_warehouse,
         supports_delivery = case when p_is_warehouse then false else supports_delivery end,
         supports_pickup = case when p_is_warehouse then false else supports_pickup end
   where id = p_branch_id;
  if not found then raise exception 'That branch could not be found.'; end if;
  perform public._write_audit(v_owner.firebase_uid, p_branch_id, 'branch.warehouse', 'branch', p_branch_id::text,
    jsonb_build_object('is_warehouse', p_is_warehouse));
  return jsonb_build_object('id', p_branch_id, 'is_warehouse', p_is_warehouse);
end;
$$;
revoke all on function public.owner_set_branch_warehouse(uuid, boolean) from public, anon;
grant execute on function public.owner_set_branch_warehouse(uuid, boolean) to authenticated;

commit;
