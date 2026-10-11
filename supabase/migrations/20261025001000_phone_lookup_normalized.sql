-- =============================================================================
-- Melai Nuts — Migration 20261025001000: phone lookups work with any typed format
-- =============================================================================
-- Run after 20261025000000_input_check_constraints.sql. Idempotent, one transaction.
--
-- Phones are now stored as E.164 (+639171234567). A cashier still types the
-- number the way the customer says it (0917 123 4567), so the POS lookup
-- compares both sides in the normalised form. Same behaviour as before for
-- cards, labels and e-mail; still exact matches only (no browsing).
-- =============================================================================
begin;

create index if not exists customer_profiles_phone_norm_idx
  on public.customer_profiles (public.normalize_ph_mobile(phone))
  where phone is not null and phone <> '';

create or replace function public.staff_lookup_customer(p_query text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := trim(coalesce(p_query, ''));
  v_norm text := public._normalize_card_uid(v_q);
  v_phone text := public.normalize_ph_mobile(v_q);
  c public.loyalty_cards;
begin
  perform public._require_staff();
  if length(v_q) < 4 then raise exception 'Enter at least 4 characters to look up a customer.'; end if;

  if v_norm is not null then
    select * into c from public.loyalty_cards where card_uid_hash = public._card_uid_hash(v_norm);
    if c.id is not null and c.status = 'blocked' then
      raise exception 'Loyalty card % is blocked and cannot be used. Look the customer up by e-mail instead.', c.card_label;
    elsif c.id is not null and c.status = 'replaced' then
      raise exception 'Loyalty card % was replaced by a newer card and can no longer be used.', c.card_label;
    end if;
  end if;

  return (
    select coalesce(jsonb_agg(t.j), '[]'::jsonb)
    from (
      select jsonb_build_object(
        'firebase_uid', cp.firebase_uid,
        'full_name', cp.full_name,
        'points_balance', coalesce(la.points_balance, 0)) as j
      from public.customer_profiles cp
      left join public.loyalty_accounts la on la.firebase_uid = cp.firebase_uid
      where cp.firebase_uid <> 'walk-in'
        and (cp.rfid_card_number = v_q
             or upper(cp.rfid_card_number) = upper(v_q)
             or (cp.phone <> '' and public.normalize_ph_mobile(cp.phone) = v_phone)
             or lower(cp.email) = lower(v_q)
             or (c.id is not null and c.status = 'active' and cp.firebase_uid = c.firebase_uid))
      limit 5
    ) t
  );
end;
$$;
revoke all on function public.staff_lookup_customer(text) from public, anon;
grant execute on function public.staff_lookup_customer(text) to authenticated;

commit;
