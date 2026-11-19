-- =============================================================================
-- Melai Nuts — Migration 20261119010000: first and last name stored separately
-- =============================================================================
-- Run after 20261119000000_remove_phone_verification.sql. Idempotent, one transaction.
--
-- The website's Create account form now asks for First name and Last name, like the app's
-- (lib/features/auth/screens/register_screen.dart). Both are kept on customer_profiles, next to
-- full_name, which stays the composed "First Last" every existing screen, report and function
-- already reads.
--
--   * The website sends first_name, last_name AND the composed full_name.
--   * A writer that sends only full_name (the app's profile row, older builds, staff tools) gets
--     first_name / last_name filled in by the trigger below, with the same split as the app's
--     PersonName.parse (a lone middle initial is dropped; "Dela Cruz", "De los Reyes" stay whole).
--   * Existing rows are filled in once below.
-- =============================================================================
begin;

alter table public.customer_profiles add column if not exists first_name text;
alter table public.customer_profiles add column if not exists last_name text;
alter table public.customer_profiles drop constraint if exists customer_profiles_first_name_len;
alter table public.customer_profiles add constraint customer_profiles_first_name_len
  check (first_name is null or char_length(first_name) <= 50);
alter table public.customer_profiles drop constraint if exists customer_profiles_last_name_len;
alter table public.customer_profiles add constraint customer_profiles_last_name_len
  check (last_name is null or char_length(last_name) <= 50);

-- The app's PersonName.parse (lib/core/utils/person_name.dart), in SQL.
create or replace function public._split_full_name(p_full_name text, out first_name text, out last_name text)
language plpgsql
immutable
set search_path = public
as $$
declare
  w text[] := regexp_split_to_array(btrim(coalesce(p_full_name, '')), '\s+');
  n int;
  i int;
  last_start int;
  particles constant text[] := array['de', 'del', 'dela', 'delos', 'la', 'las', 'los', 'san', 'santa',
                                     'sta', 'sta.', 'sto', 'sto.', 'santo'];
begin
  if btrim(coalesce(p_full_name, '')) = '' then return; end if;
  n := array_length(w, 1);
  if n = 1 then first_name := w[1]; return; end if;
  -- A lone middle initial ("Juan D. Dela Cruz") is dropped.
  for i in 2 .. n - 1 loop
    if w[i] ~ '^[[:alpha:]]\.?$' then
      w := w[1:i - 1] || w[i + 1:n];
      exit;
    end if;
  end loop;
  n := array_length(w, 1);
  if n = 1 then first_name := w[1]; return; end if;
  last_start := n;
  while last_start > 2 and lower(w[last_start - 1]) = any (particles) loop
    last_start := last_start - 1;
  end loop;
  first_name := array_to_string(w[1:last_start - 1], ' ');
  last_name := array_to_string(w[last_start:n], ' ');
end;
$$;
revoke all on function public._split_full_name(text) from public, anon, authenticated;

create or replace function public._customer_profiles_name_parts()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v record;
begin
  new.first_name := nullif(btrim(new.first_name), '');
  new.last_name := nullif(btrim(new.last_name), '');
  if (tg_op = 'INSERT' and new.first_name is null and new.last_name is null)
     or (tg_op = 'UPDATE' and new.full_name is distinct from old.full_name
         and new.first_name is not distinct from old.first_name
         and new.last_name is not distinct from old.last_name) then
    v := public._split_full_name(new.full_name);
    new.first_name := v.first_name;
    new.last_name := v.last_name;
  end if;
  return new;
end;
$$;
revoke all on function public._customer_profiles_name_parts() from public, anon, authenticated;
drop trigger if exists customer_profiles_name_parts on public.customer_profiles;
create trigger customer_profiles_name_parts
  before insert or update of full_name, first_name, last_name on public.customer_profiles
  for each row execute function public._customer_profiles_name_parts();

-- Customers write their own name parts (same as full_name).
grant insert (first_name, last_name), update (first_name, last_name) on public.customer_profiles to authenticated;

-- Existing rows, once.
update public.customer_profiles cp
   set first_name = s.first_name, last_name = s.last_name
  from public.customer_profiles x
  cross join lateral public._split_full_name(x.full_name) s
 where cp.firebase_uid = x.firebase_uid
   and cp.first_name is null and cp.last_name is null
   and coalesce(btrim(cp.full_name), '') <> '';

comment on column public.customer_profiles.first_name is
  'First name as typed at sign-up (website) or split from full_name (app). full_name stays the composed "First Last".';
comment on column public.customer_profiles.last_name is
  'Last name as typed at sign-up (website) or split from full_name (app).';

commit;
