-- =============================================================================
-- Online (GCash / Maya / card) refunds sent through the HitPay Refund API
-- =============================================================================
-- Run after 20261011010000_suppliers_purchase_receipts.sql. Idempotent, additive.
--
-- Before: an approved online refund was sent by hand in the HitPay dashboard and
-- then marked completed with the reference. That still works. Now the admin
-- website (Laravel) or the hitpay-refund Edge Function (staff app) can send it:
--
--   1. staff_begin_gateway_refund(refund)   -> an attempt row in 'sending'
--      (refund must be approved, payment must be a successful HitPay payment,
--       and no other attempt may be sending / pending / succeeded: the unique
--       index makes a double refund impossible even with two clicks at once)
--   2. the server calls HitPay  POST /v1/refund {payment_id, amount}
--   3. staff_finish_gateway_refund(attempt, 'succeeded' | 'pending' | 'failed', ...)
--        succeeded -> the refund is completed through staff_review_refund (stock,
--                     points, payment 'refunded', customer notification: the
--                     existing triggers)
--        pending   -> HitPay accepted it but has not finished (e-wallets); check
--                     again later with the refund id
--        failed    -> attempt closed with the error; the refund stays approved so
--                     it can be retried or done by hand
--   If the server never hears back (timeout), the attempt stays 'sending' and
--   blocks automatic retries. Check the HitPay dashboard, then either mark the
--   refund completed by hand (existing flow) or mark the attempt failed.
-- =============================================================================

begin;

create table if not exists public.refund_gateway_attempts (
  id uuid primary key default gen_random_uuid(),
  refund_id text not null references public.refund_requests(id) on delete cascade,
  order_id text not null,
  gateway text not null default 'hitpay',
  gateway_payment_id text not null,
  amount numeric(10, 2) not null check (amount > 0),
  status text not null default 'sending' check (status in ('sending', 'pending', 'succeeded', 'failed')),
  gateway_refund_id text,
  error text,
  started_by text not null,
  started_at timestamptz not null default now(),
  finished_by text,
  finished_at timestamptz
);
-- At most one live attempt per refund: never two refunds for one request.
create unique index if not exists refund_gateway_attempts_one_live
  on public.refund_gateway_attempts (refund_id) where (status in ('sending', 'pending', 'succeeded'));
create index if not exists refund_gateway_attempts_refund_idx on public.refund_gateway_attempts (refund_id, started_at desc);

alter table public.refund_gateway_attempts enable row level security;
revoke all on public.refund_gateway_attempts from anon, authenticated;

create or replace function public._gateway_attempt_json(a public.refund_gateway_attempts)
returns jsonb language sql stable as $$
  select jsonb_build_object('attempt_id', a.id, 'refund_id', a.refund_id, 'order_id', a.order_id,
    'gateway', a.gateway, 'gateway_payment_id', a.gateway_payment_id, 'amount', a.amount, 'currency', 'PHP',
    'status', a.status, 'gateway_refund_id', a.gateway_refund_id, 'error', a.error,
    'started_at', a.started_at, 'finished_at', a.finished_at)
$$;

-- -----------------------------------------------------------------------------
-- 1. Begin
-- -----------------------------------------------------------------------------
create or replace function public.staff_begin_gateway_refund(p_refund_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.refund_requests;
  v_staff public.staff_members;
  v_branch uuid;
  v_pay public.payments;
  v_live public.refund_gateway_attempts;
  a public.refund_gateway_attempts;
begin
  select * into r from public.refund_requests where id = p_refund_id for update;
  if r.id is null then raise exception 'That refund request could not be found.'; end if;
  select branch_id into v_branch from public.orders where id = r.order_id;
  v_staff := public._require_staff(v_branch, 'refunds');

  -- 'processing' = the app's "Start processing" step; still nothing has been paid back.
  if r.status not in ('approved', 'processing') then
    raise exception 'Only an approved refund can be sent to HitPay (this one is %).', r.status;
  end if;
  select * into v_pay from public.payments where order_id = r.order_id order by created_at desc limit 1 for update;
  if v_pay.id is null or v_pay.method not in ('gcash', 'maya', 'card') then
    raise exception 'This order was not paid online. Refund the cash and mark it completed instead.';
  end if;
  if v_pay.status <> 'success' then
    raise exception 'The online payment for this order is %, so there is nothing to send back through HitPay.', v_pay.status;
  end if;
  if coalesce(v_pay.gateway, '') <> 'hitpay' or v_pay.gateway_payment_id is null then
    raise exception 'This payment has no HitPay payment id. Send the refund from the HitPay dashboard and mark it completed by hand.';
  end if;
  if r.amount <= 0 or r.amount > v_pay.amount then
    raise exception 'The refund amount does not fit the payment.';
  end if;

  select * into v_live from public.refund_gateway_attempts
  where refund_id = r.id and status in ('sending', 'pending', 'succeeded') limit 1;
  if v_live.id is not null then
    if v_live.status = 'succeeded' then
      raise exception 'This refund was already sent through HitPay.';
    elsif v_live.status = 'pending' then
      raise exception 'HitPay is still processing this refund. Check its status instead of sending it again.';
    else
      raise exception 'A HitPay refund for this request was started at % and has no answer yet. Check the HitPay dashboard before trying again.',
        to_char(v_live.started_at at time zone 'Asia/Manila', 'Mon DD HH12:MI AM');
    end if;
  end if;

  insert into public.refund_gateway_attempts (refund_id, order_id, gateway_payment_id, amount, started_by)
  values (r.id, r.order_id, v_pay.gateway_payment_id, r.amount, v_staff.firebase_uid)
  returning * into a;
  perform public._write_audit(v_staff.firebase_uid, v_branch, 'refund.gateway_send', 'refund_request', r.id,
    jsonb_build_object('attempt_id', a.id, 'amount', a.amount, 'order_id', r.order_id));
  return public._gateway_attempt_json(a);
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Finish (the server reports what HitPay answered)
-- -----------------------------------------------------------------------------
create or replace function public.staff_finish_gateway_refund(
  p_attempt_id uuid,
  p_status text,
  p_gateway_refund_id text default null,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.refund_gateway_attempts;
  r public.refund_requests;
  v_staff public.staff_members;
  v_branch uuid;
  v_ref text := nullif(trim(coalesce(p_gateway_refund_id, '')), '');
begin
  select * into a from public.refund_gateway_attempts where id = p_attempt_id for update;
  if a.id is null then raise exception 'That HitPay refund attempt could not be found.'; end if;
  select * into r from public.refund_requests where id = a.refund_id for update;
  select branch_id into v_branch from public.orders where id = r.order_id;
  v_staff := public._require_staff(v_branch, 'refunds');

  if p_status not in ('succeeded', 'pending', 'failed') then raise exception 'Unknown HitPay refund result.'; end if;
  if a.status = p_status and (v_ref is null or v_ref = a.gateway_refund_id) then
    return public._gateway_attempt_json(a);                       -- same answer twice: no-op
  end if;
  if a.status in ('succeeded', 'failed') then
    raise exception 'This HitPay refund attempt is already %.', a.status;
  end if;
  if a.status = 'pending' and p_status = 'pending' then
    return public._gateway_attempt_json(a);
  end if;
  if p_status in ('succeeded', 'pending') and v_ref is null then
    raise exception 'The HitPay refund id is missing.';
  end if;

  update public.refund_gateway_attempts
     set status = p_status,
         gateway_refund_id = coalesce(v_ref, gateway_refund_id),
         error = case when p_status = 'failed' then left(coalesce(nullif(trim(p_error), ''), 'HitPay refused the refund.'), 300) end,
         finished_by = case when p_status = 'pending' then null else v_staff.firebase_uid end,
         finished_at = case when p_status = 'pending' then null else now() end
   where id = a.id
  returning * into a;

  if p_status = 'succeeded' then
    if r.status in ('approved', 'processing') then
      perform public.staff_review_refund(r.id, 'complete');
    end if;
  end if;

  perform public._write_audit(v_staff.firebase_uid, v_branch, 'refund.gateway_' || p_status, 'refund_request', r.id,
    jsonb_build_object('attempt_id', a.id, 'gateway_refund_id', a.gateway_refund_id, 'error', a.error, 'amount', a.amount));
  return public._gateway_attempt_json(a)
         || jsonb_build_object('refund_status', (select status from public.refund_requests where id = r.id));
end;
$$;

-- A 'sending' attempt with no answer (timeout) after the staff checked the
-- HitPay dashboard and found no refund there: close it so it can be retried.
create or replace function public.staff_abandon_gateway_refund(p_attempt_id uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.refund_gateway_attempts;
  v_branch uuid;
  v_staff public.staff_members;
  v_note text := trim(coalesce(p_note, ''));
begin
  select * into a from public.refund_gateway_attempts where id = p_attempt_id for update;
  if a.id is null then raise exception 'That HitPay refund attempt could not be found.'; end if;
  select o.branch_id into v_branch from public.orders o where o.id = a.order_id;
  v_staff := public._require_staff(v_branch, 'refunds');
  if a.status <> 'sending' then raise exception 'Only an unanswered attempt can be closed (this one is %).', a.status; end if;
  if a.started_at > now() - interval '2 minutes' then
    raise exception 'Wait a few minutes for HitPay to answer before closing this attempt.';
  end if;
  if char_length(v_note) < 5 then
    raise exception 'Write what you checked in the HitPay dashboard (at least 5 characters).';
  end if;
  update public.refund_gateway_attempts
     set status = 'failed', error = left('Closed by staff: ' || v_note, 300),
         finished_by = v_staff.firebase_uid, finished_at = now()
   where id = a.id
  returning * into a;
  perform public._write_audit(v_staff.firebase_uid, v_branch, 'refund.gateway_abandoned', 'refund_request', a.refund_id,
    jsonb_build_object('attempt_id', a.id, 'note', v_note));
  return public._gateway_attempt_json(a);
end;
$$;

-- Attempts for one refund (newest first), for the admin refunds page and the app.
create or replace function public.staff_refund_gateway_attempts(p_refund_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_branch uuid;
begin
  select o.branch_id into v_branch from public.refund_requests r join public.orders o on o.id = r.order_id where r.id = p_refund_id;
  if v_branch is null then raise exception 'That refund request could not be found.'; end if;
  perform public._require_staff(v_branch, 'refunds');
  return coalesce((select jsonb_agg(public._gateway_attempt_json(a) order by a.started_at desc)
                   from public.refund_gateway_attempts a where a.refund_id = p_refund_id), '[]'::jsonb);
end;
$$;

revoke all on function public._gateway_attempt_json(public.refund_gateway_attempts) from public, anon, authenticated;
revoke all on function public.staff_begin_gateway_refund(text) from public, anon;
revoke all on function public.staff_finish_gateway_refund(uuid, text, text, text) from public, anon;
revoke all on function public.staff_abandon_gateway_refund(uuid, text) from public, anon;
revoke all on function public.staff_refund_gateway_attempts(text) from public, anon;
grant execute on function public.staff_begin_gateway_refund(text) to authenticated;
grant execute on function public.staff_finish_gateway_refund(uuid, text, text, text) to authenticated;
grant execute on function public.staff_abandon_gateway_refund(uuid, text) to authenticated;
grant execute on function public.staff_refund_gateway_attempts(text) to authenticated;

commit;
