-- =============================================================================
-- Melai Nuts — Migration 20261025040000: Terms / Privacy Policy acceptance
-- =============================================================================
-- Run after 20261025030000_pagination.sql. Idempotent, one transaction.
--
-- WHAT
--   * public.legal_acceptances: append-only record of who accepted which version
--     of the Terms and Conditions / Privacy Policy, and when (plus the separate,
--     optional "send me order updates" choice). Readable only by its owner;
--     nobody can edit or delete a row through the API.
--   * terms_version, privacy_version, terms_accepted_at on every profile table
--     (customer_profiles, staff_members, drivers) — the latest acceptance.
--   * accept_legal_terms(terms, privacy, order_updates): records the caller's
--     acceptance (uid from the verified token; the client cannot accept for
--     someone else). Works before the customer profile exists (sign-up), and a
--     profile created later is stamped from the record by a trigger.
--   * my_legal_acceptance(): the caller's latest accepted versions; the app asks
--     again when they differ from the versions it ships (LegalConfig).
-- =============================================================================
begin;

create table if not exists public.legal_acceptances (
  id bigint generated always as identity primary key,
  firebase_uid text not null check (length(firebase_uid) between 1 and 128),
  document text not null check (document in ('terms', 'privacy', 'order_updates')),
  version text not null check (length(version) between 1 and 40),
  accepted_at timestamptz not null default now(),
  unique (firebase_uid, document, version)
);
create index if not exists legal_acceptances_uid_idx
  on public.legal_acceptances (firebase_uid, document, accepted_at desc);

alter table public.legal_acceptances enable row level security;
revoke all on public.legal_acceptances from anon, authenticated;
grant select on public.legal_acceptances to authenticated;
drop policy if exists "own legal acceptances" on public.legal_acceptances;
create policy "own legal acceptances" on public.legal_acceptances for select to authenticated
  using (firebase_uid = (select public.current_firebase_uid()));

-- Append-only, also for SECURITY DEFINER code and the table owner's own tools.
create or replace function public._trg_legal_acceptances_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'legal acceptances are append-only';
end;
$$;
drop trigger if exists legal_acceptances_append_only on public.legal_acceptances;
create trigger legal_acceptances_append_only before update or delete on public.legal_acceptances
  for each row execute function public._trg_legal_acceptances_append_only();

alter table public.customer_profiles add column if not exists terms_version text;
alter table public.customer_profiles add column if not exists privacy_version text;
alter table public.customer_profiles add column if not exists terms_accepted_at timestamptz;
alter table public.staff_members     add column if not exists terms_version text;
alter table public.staff_members     add column if not exists privacy_version text;
alter table public.staff_members     add column if not exists terms_accepted_at timestamptz;
alter table public.drivers           add column if not exists terms_version text;
alter table public.drivers           add column if not exists privacy_version text;
alter table public.drivers           add column if not exists terms_accepted_at timestamptz;

create or replace function public.accept_legal_terms(
  p_terms_version text,
  p_privacy_version text,
  p_order_updates boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid text := public.current_firebase_uid();
  v_terms text := nullif(trim(coalesce(p_terms_version, '')), '');
  v_privacy text := nullif(trim(coalesce(p_privacy_version, '')), '');
begin
  if v_uid is null then raise exception 'Please sign in first.'; end if;
  if v_terms is null or v_privacy is null or length(v_terms) > 40 or length(v_privacy) > 40 then
    raise exception 'Invalid terms version.';
  end if;

  insert into public.legal_acceptances (firebase_uid, document, version)
    values (v_uid, 'terms', v_terms), (v_uid, 'privacy', v_privacy)
    on conflict (firebase_uid, document, version) do nothing;
  if p_order_updates is not null then
    insert into public.legal_acceptances (firebase_uid, document, version)
      values (v_uid, 'order_updates', case when p_order_updates then 'yes' else 'no' end)
      on conflict (firebase_uid, document, version) do nothing;
    -- The optional choice also sets the notification preference (the app sends
    -- it from the first signed-in screen, when the customer profile exists).
    if exists (select 1 from public.customer_profiles where firebase_uid = v_uid) then
      insert into public.notification_preferences (firebase_uid, order_updates, delivery_updates)
        values (v_uid, p_order_updates, p_order_updates)
        on conflict (firebase_uid) do update
          set order_updates = excluded.order_updates, delivery_updates = excluded.delivery_updates;
    end if;
  end if;

  update public.customer_profiles set terms_version = v_terms, privacy_version = v_privacy, terms_accepted_at = now()
   where firebase_uid = v_uid;
  update public.staff_members set terms_version = v_terms, privacy_version = v_privacy, terms_accepted_at = now()
   where firebase_uid = v_uid;
  update public.drivers set terms_version = v_terms, privacy_version = v_privacy, terms_accepted_at = now()
   where firebase_uid = v_uid;

  return jsonb_build_object('terms_version', v_terms, 'privacy_version', v_privacy);
end;
$$;
revoke all on function public.accept_legal_terms(text, text, boolean) from public, anon;
grant execute on function public.accept_legal_terms(text, text, boolean) to authenticated;

create or replace function public.my_legal_acceptance()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'terms_version', (select version from public.legal_acceptances
                       where firebase_uid = public.current_firebase_uid() and document = 'terms'
                       order by accepted_at desc, id desc limit 1),
    'privacy_version', (select version from public.legal_acceptances
                         where firebase_uid = public.current_firebase_uid() and document = 'privacy'
                         order by accepted_at desc, id desc limit 1),
    'accepted_at', (select max(accepted_at) from public.legal_acceptances
                     where firebase_uid = public.current_firebase_uid() and document = 'terms'))
$$;
revoke all on function public.my_legal_acceptance() from public, anon;
grant execute on function public.my_legal_acceptance() to authenticated;

-- A customer profile created after the acceptance (sign-up: consent is given
-- before the e-mail is verified and the profile exists) is stamped from the record.
create or replace function public._trg_profile_stamp_legal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_terms text;
  v_privacy text;
  v_at timestamptz;
  v_updates text;
begin
  select version, accepted_at into v_terms, v_at from public.legal_acceptances
   where firebase_uid = new.firebase_uid and document = 'terms' order by accepted_at desc, id desc limit 1;
  select version into v_privacy from public.legal_acceptances
   where firebase_uid = new.firebase_uid and document = 'privacy' order by accepted_at desc, id desc limit 1;
  if v_terms is not null then
    new.terms_version := v_terms;
    new.privacy_version := v_privacy;
    new.terms_accepted_at := v_at;
  end if;
  return new;
end;
$$;
revoke all on function public._trg_profile_stamp_legal() from public, anon, authenticated;

drop trigger if exists customer_profiles_stamp_legal on public.customer_profiles;
create trigger customer_profiles_stamp_legal before insert on public.customer_profiles
  for each row execute function public._trg_profile_stamp_legal();
drop trigger if exists staff_members_stamp_legal on public.staff_members;
create trigger staff_members_stamp_legal before insert on public.staff_members
  for each row execute function public._trg_profile_stamp_legal();
drop trigger if exists drivers_stamp_legal on public.drivers;
create trigger drivers_stamp_legal before insert on public.drivers
  for each row execute function public._trg_profile_stamp_legal();

commit;
