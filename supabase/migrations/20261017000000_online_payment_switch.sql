-- =============================================================================
-- Melai Nuts — Migration 20261017000000: online payment on/off switch
-- =============================================================================
-- Run after 20261016000000_delivery_pins_app_only.sql. Idempotent, one
-- transaction. Nothing is removed: the HitPay code, the
-- 'Online Payment (GCash, Maya, Card)' label in place_order() and every
-- existing order / payment stay exactly as they are.
--
-- Online payment (HitPay: GCash, Maya, card) is switched OFF for customers for
-- now. While it is off:
--   * a NEW customer order with an online payment label is refused by the
--     database (also from older app builds), with a message that tells the
--     customer to pick Cash on Delivery / Cash on Counter Pickup;
--   * the hitpay-create-payment Edge Function refuses to open a payment page
--     (reads the same switch);
--   * in-store POS sales ('GCash (In-store)', 'Card (In-store)', ...) and
--     cash orders are not affected.
--
-- Turn it back on later (SQL editor, as the owner / postgres):
--   update public.payment_settings set online_payment_enabled = true, updated_at = now()
--   where id = 'default';
-- and build the app with --dart-define=ONLINE_PAYMENT_ENABLED=true
-- (see lib/core/config/payment_config.dart).
-- =============================================================================
begin;

create table if not exists public.payment_settings (
  id text primary key default 'default' check (id = 'default'),
  online_payment_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

insert into public.payment_settings (id, online_payment_enabled)
values ('default', false)
on conflict (id) do nothing;

alter table public.payment_settings enable row level security;

-- Everyone may read the switch (the app can show "temporarily unavailable");
-- nobody but the database owner may change it.
drop policy if exists "anyone reads payment settings" on public.payment_settings;
create policy "anyone reads payment settings" on public.payment_settings
  for select to anon, authenticated using (true);
revoke insert, update, delete on public.payment_settings from anon, authenticated;
grant select on public.payment_settings to anon, authenticated;

create or replace function public.online_payment_enabled()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select online_payment_enabled from public.payment_settings where id = 'default'), false)
$$;

-- Refuses new customer orders paid online while the switch is off.
create or replace function public._trg_orders_online_payment_switch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.payment_method in ('Online Payment (GCash, Maya, Card)', 'GCash E-Wallet', 'Maya / Credit Card')
     and not public.online_payment_enabled() then
    raise exception 'Online payment is temporarily unavailable. Please choose Cash on Delivery or Cash on Counter Pickup.';
  end if;
  return new;
end;
$$;

drop trigger if exists orders_online_payment_switch on public.orders;
create trigger orders_online_payment_switch
  before insert on public.orders
  for each row execute function public._trg_orders_online_payment_switch();

revoke all on function public._trg_orders_online_payment_switch() from public, anon, authenticated;
revoke all on function public.online_payment_enabled() from public;
grant execute on function public.online_payment_enabled() to anon, authenticated, service_role;

commit;
