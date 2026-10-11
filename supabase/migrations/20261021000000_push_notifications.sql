-- =============================================================================
-- Melai Nuts — Migration 20261021000000: push notifications (server-triggered)
-- =============================================================================
-- Run after 20261020000000_staff_orders_variant_ids.sql. Idempotent, one transaction.
--
-- Pushes are created ONLY by the database, never by an app:
--   * every row added to public.notifications (customers: order status, refund
--     decisions, ...) and to public.staff_notifications (branch staff: new orders,
--     low / out of stock, refunds to review, expiring batches) is copied into
--     public.push_outbox for its recipient;
--   * the Edge Function `push-dispatch` (supabase/functions/push-dispatch) sends the
--     outbox through Firebase Cloud Messaging and marks rows sent; it runs on a
--     schedule (docs/PUSH_NOTIFICATIONS.md).
--   * expiring batches: public.enqueue_expiring_batch_alerts() (run daily by the
--     same schedule) notifies branch staff once per batch, within the owner's
--     business_settings.expiry_alert_days (Not set = no expiry alerts).
-- Apps only register / remove their own device token.
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1. Device tokens (one row per device; a device belongs to one account)
-- -----------------------------------------------------------------------------
create table if not exists public.device_push_tokens (
  token text primary key check (char_length(token) between 20 and 4096),
  firebase_uid text not null,
  platform text not null check (platform in ('android', 'ios', 'web', 'macos', 'windows')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists device_push_tokens_uid_idx on public.device_push_tokens (firebase_uid);
alter table public.device_push_tokens enable row level security;
revoke all on public.device_push_tokens from anon, authenticated;

create or replace function public.register_push_token(p_token text, p_platform text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_token text := trim(coalesce(p_token, ''));
begin
  if v_uid is null then raise exception 'Please sign in first.'; end if;
  if char_length(v_token) < 20 or char_length(v_token) > 4096 then raise exception 'Invalid device token.'; end if;
  if p_platform not in ('android', 'ios', 'web', 'macos', 'windows') then raise exception 'Unknown platform.'; end if;
  -- A token moves to whoever signs in on that device (the previous account stops getting its pushes).
  insert into public.device_push_tokens (token, firebase_uid, platform)
  values (v_token, v_uid, p_platform)
  on conflict (token) do update set firebase_uid = excluded.firebase_uid, platform = excluded.platform, updated_at = now();
end;
$$;
revoke all on function public.register_push_token(text, text) from public, anon;
grant execute on function public.register_push_token(text, text) to authenticated;

create or replace function public.unregister_push_token(p_token text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.device_push_tokens
   where token = trim(coalesce(p_token, '')) and firebase_uid = public.current_firebase_uid()
$$;
revoke all on function public.unregister_push_token(text) from public, anon;
grant execute on function public.unregister_push_token(text) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Outbox (service role only)
-- -----------------------------------------------------------------------------
create table if not exists public.push_outbox (
  id bigserial primary key,
  firebase_uid text not null,
  kind text not null,
  title text not null,
  body text not null default '',
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts int not null default 0,
  last_error text
);
create index if not exists push_outbox_unsent_idx on public.push_outbox (created_at) where sent_at is null;
alter table public.push_outbox enable row level security;
revoke all on public.push_outbox from anon, authenticated;
revoke all on sequence public.push_outbox_id_seq from anon, authenticated;

create or replace function public._trg_push_from_customer_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    insert into public.push_outbox (firebase_uid, kind, title, body, data)
    values (new.firebase_uid, 'customer.' || coalesce(new.category, 'general'), new.title, coalesce(new.body, ''),
            jsonb_build_object('notification_id', new.id, 'category', new.category));
  exception when others then
    raise warning 'push outbox insert failed: %', sqlerrm;   -- never block the business change
  end;
  return new;
end;
$$;
drop trigger if exists notifications_push on public.notifications;
create trigger notifications_push after insert on public.notifications
  for each row execute function public._trg_push_from_customer_notification();

create or replace function public._trg_push_from_staff_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    insert into public.push_outbox (firebase_uid, kind, title, body, data)
    values (new.recipient_uid, 'staff.' || coalesce(new.category, 'general'), new.title, coalesce(new.body, ''),
            jsonb_build_object('notification_id', new.id, 'category', new.category, 'reference', new.reference,
                               'branch_id', new.branch_id));
  exception when others then
    raise warning 'push outbox insert failed: %', sqlerrm;
  end;
  return new;
end;
$$;
drop trigger if exists staff_notifications_push on public.staff_notifications;
create trigger staff_notifications_push after insert on public.staff_notifications
  for each row execute function public._trg_push_from_staff_notification();

revoke all on function public._trg_push_from_customer_notification() from public, anon, authenticated;
revoke all on function public._trg_push_from_staff_notification() from public, anon, authenticated;

-- What push-dispatch sends next (service role only): unsent, not given up on.
create or replace function public.push_outbox_claim(p_limit int default 100)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id, 'firebase_uid', o.firebase_uid, 'kind', o.kind, 'title', o.title, 'body', o.body, 'data', o.data,
           'tokens', coalesce((select jsonb_agg(t.token) from public.device_push_tokens t where t.firebase_uid = o.firebase_uid), '[]'::jsonb))
         order by o.id), '[]'::jsonb)
  from (select * from public.push_outbox
         where sent_at is null and attempts < 5 and created_at > now() - interval '2 days'
         order by id limit least(greatest(coalesce(p_limit, 100), 1), 500)) o
$$;

-- p_result: [{"id": 1, "ok": true} | {"id": 2, "ok": false, "error": "...", "dead_tokens": ["..."]}]
create or replace function public.push_outbox_report(p_result jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
begin
  for r in select * from jsonb_array_elements(coalesce(p_result, '[]'::jsonb)) loop
    if coalesce((r ->> 'ok')::boolean, false) then
      update public.push_outbox set sent_at = now(), attempts = attempts + 1, last_error = null where id = (r ->> 'id')::bigint;
    else
      update public.push_outbox set attempts = attempts + 1, last_error = left(coalesce(r ->> 'error', 'failed'), 300)
       where id = (r ->> 'id')::bigint;
    end if;
    delete from public.device_push_tokens
     where token in (select jsonb_array_elements_text(coalesce(r -> 'dead_tokens', '[]'::jsonb)));
  end loop;
  delete from public.push_outbox where created_at < now() - interval '14 days';
end;
$$;
revoke all on function public.push_outbox_claim(int) from public, anon, authenticated;
revoke all on function public.push_outbox_report(jsonb) from public, anon, authenticated;
grant execute on function public.push_outbox_claim(int) to service_role;
grant execute on function public.push_outbox_report(jsonb) to service_role;

-- -----------------------------------------------------------------------------
-- 3. Expiring batches (owner setting; Not set = no alerts)
-- -----------------------------------------------------------------------------
-- business_settings.expiry_alert_days is created by 20261018000000 (owner edits it on
-- Business settings); this guard keeps the migration runnable on its own.
alter table public.business_settings add column if not exists expiry_alert_days int;

create or replace function public.enqueue_expiring_batch_alerts()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days int := (select expiry_alert_days from public.business_settings where id = 'default');
  b record;
  n int := 0;
begin
  if v_days is null then return 0; end if;
  for b in
    select ib.id, ib.branch_id, ib.expiration_date, ib.quantity,
           p.name || ' (' || pv.label || ')' as item
      from public.inventory_batches ib
      join public.product_variants pv on pv.id = ib.variant_id
      join public.products p on p.id = pv.product_id
     where ib.quantity > 0
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
revoke all on function public.enqueue_expiring_batch_alerts() from public, anon, authenticated;
grant execute on function public.enqueue_expiring_batch_alerts() to service_role;

commit;
