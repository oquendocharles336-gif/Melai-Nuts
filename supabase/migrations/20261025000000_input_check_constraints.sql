-- =============================================================================
-- Melai Nuts — Migration 20261025000000: server-side input rules (CHECK constraints)
-- =============================================================================
-- Run after 20261024000000_owner_reports.sql. Idempotent, one transaction.
--
-- WHY
--   The app (lib/core/utils/validation_utils.dart) and the admin website
--   (admin/app/Http/Requests/Rules.php) validate every field, but a modified
--   client can skip that. These CHECK constraints are the same rules, enforced by
--   the database for every writer. Limits match InputLimits in the app; see
--   docs/FORM_FIELDS.md.
--
-- HOW (safe on a live database)
--   The database limits are the outer bounds (e.g. an address line of 1–200
--   characters); the app and website are stricter where it helps the person
--   (e.g. at least 10 characters for a delivery address).
--   Every constraint is added NOT VALID: new and changed rows are checked, rows
--   that already exist are not re-checked (so a legacy value never blocks this
--   migration). Run `alter table ... validate constraint ...` later, after
--   cleaning old data, to also cover existing rows.
--
-- PHONES
--   One stored format: E.164 (+639171234567). A trigger normalises Philippine
--   mobile numbers typed as 0917 123 4567 / 639171234567 / 9171234567 on every
--   table that stores a person's mobile number. Other values (landlines,
--   foreign numbers) are kept as typed but must use phone characters only.
-- =============================================================================
begin;

-- Adds a CHECK constraint once (NOT VALID). Kept after the migration: later
-- migrations may use it too.
create or replace function public._add_check_once(p_table regclass, p_name text, p_expr text)
returns void
language plpgsql
as $$
begin
  if not exists (select 1 from pg_constraint where conrelid = p_table and conname = p_name) then
    execute format('alter table %s add constraint %I check (%s) not valid', p_table, p_name, p_expr);
  end if;
end;
$$;
revoke all on function public._add_check_once(regclass, text, text) from public, anon, authenticated;

-- Phone characters only (digits, +, spaces, dashes, dots, brackets), max 20.
create or replace function public._phone_chars_ok(p text)
returns boolean
language sql
immutable
as $$ select p is null or p = '' or (char_length(p) <= 20 and p ~ '^[0-9+() .-]+$') $$;
grant execute on function public._phone_chars_ok(text) to anon, authenticated;

-- 09171234567 / 0917 123 4567 / 639171234567 / 9171234567 -> +639171234567;
-- anything else is returned trimmed and unchanged. Same rule as PhoneUtils.
create or replace function public.normalize_ph_mobile(p text)
returns text
language sql
immutable
as $$
  select case
    when p is null then null
    when regexp_replace(p, '[\s().-]', '', 'g') ~ '^(\+63|63|0)?9[0-9]{9}$'
      then '+63' || right(regexp_replace(p, '[\s().-]', '', 'g'), 10)
    else btrim(p)
  end
$$;
grant execute on function public.normalize_ph_mobile(text) to anon, authenticated;

create or replace function public._trg_normalize_phone()
returns trigger
language plpgsql
as $$
declare
  v_col text := tg_argv[0];
  v_val text;
begin
  v_val := (to_jsonb(new) ->> v_col);
  if v_val is not null then
    new := jsonb_populate_record(new, jsonb_build_object(v_col, public.normalize_ph_mobile(v_val)));
  end if;
  return new;
end;
$$;

do $$
declare
  r record;
begin
  for r in select * from (values
      ('customer_profiles', 'phone'),
      ('customer_addresses', 'phone'),
      ('orders', 'contact_phone'),
      ('staff_members', 'phone'),
      ('drivers', 'phone'),
      ('suppliers', 'phone')) as t(tbl, col)
  loop
    if exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = r.tbl and column_name = r.col) then
      execute format('drop trigger if exists %I on public.%I', r.tbl || '_normalize_phone', r.tbl);
      execute format(
        'create trigger %I before insert or update of %I on public.%I for each row execute function public._trg_normalize_phone(%L)',
        r.tbl || '_normalize_phone', r.col, r.tbl, r.col);
      perform public._add_check_once(format('public.%I', r.tbl)::regclass, r.tbl || '_phone_format',
        format('public._phone_chars_ok(%I)', r.col));
    end if;
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Catalog
-- -----------------------------------------------------------------------------
select public._add_check_once('public.products', 'products_name_length',
  'char_length(btrim(name)) between 2 and 120');
select public._add_check_once('public.products', 'products_description_length',
  'description is null or char_length(description) <= 2000');
select public._add_check_once('public.products', 'products_price_positive', 'price > 0');
select public._add_check_once('public.products', 'products_sku_format',
  $c$sku is null or sku = '' or (char_length(sku) <= 64 and sku !~ '^\s|\s$')$c$);
select public._add_check_once('public.product_categories', 'product_categories_label_length',
  'char_length(btrim(label)) between 2 and 60');
select public._add_check_once('public.product_variants', 'product_variants_label_length',
  'char_length(btrim(label)) between 1 and 40');
select public._add_check_once('public.product_variants', 'product_variants_price_positive', 'price > 0');
select public._add_check_once('public.product_variants', 'product_variants_sku_format',
  $c$sku is null or sku = '' or (char_length(sku) <= 64 and sku !~ '\s')$c$);
select public._add_check_once('public.product_variants', 'product_variants_badge_length',
  'badge is null or char_length(badge) <= 30');

-- -----------------------------------------------------------------------------
-- Customers
-- -----------------------------------------------------------------------------
select public._add_check_once('public.customer_profiles', 'customer_profiles_full_name_length',
  'char_length(full_name) <= 120');
select public._add_check_once('public.customer_profiles', 'customer_profiles_email_format',
  $c$email = '' or (char_length(email) <= 254 and email ~ '^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$')$c$);
select public._add_check_once('public.customer_addresses', 'customer_addresses_label_length',
  'char_length(btrim(label)) between 1 and 40');
select public._add_check_once('public.customer_addresses', 'customer_addresses_recipient_length',
  'char_length(btrim(recipient_name)) between 2 and 120');
select public._add_check_once('public.customer_addresses', 'customer_addresses_line1_length',
  'char_length(btrim(line1)) between 1 and 200');
select public._add_check_once('public.customer_addresses', 'customer_addresses_city_length',
  'char_length(btrim(city)) between 1 and 80 and char_length(province) <= 80');
select public._add_check_once('public.customer_addresses', 'customer_addresses_postal_code',
  $c$postal_code = '' or postal_code ~ '^[0-9]{4}$'$c$);

-- -----------------------------------------------------------------------------
-- Orders, refunds, stock
-- -----------------------------------------------------------------------------
select public._add_check_once('public.orders', 'orders_customer_notes_length',
  'customer_notes is null or char_length(customer_notes) <= 500');
select public._add_check_once('public.orders', 'orders_address_length',
  'delivery_address_text is null or char_length(delivery_address_text) <= 300');
select public._add_check_once('public.order_items', 'order_items_quantity_positive', 'quantity > 0');
select public._add_check_once('public.order_items', 'order_items_unit_price_nonnegative', 'unit_price >= 0');
select public._add_check_once('public.refund_requests', 'refund_requests_reason_length',
  'char_length(btrim(reason)) between 1 and 200');
select public._add_check_once('public.refund_requests', 'refund_requests_notes_length',
  'notes is null or char_length(notes) <= 1000');
select public._add_check_once('public.refund_items', 'refund_items_quantity_positive', 'quantity > 0');
select public._add_check_once('public.stock_movements', 'stock_movements_reason_length',
  'reason is null or char_length(reason) <= 300');
select public._add_check_once('public.stock_transfers', 'stock_transfers_note_length',
  'note is null or char_length(note) <= 300');
select public._add_check_once('public.stock_transfers', 'stock_transfers_quantity_max', 'quantity <= 99999');
select public._add_check_once('public.inventory_batches', 'inventory_batches_quantity_max',
  'quantity <= 999999 and initial_quantity <= 999999');
select public._add_check_once('public.delivery_stops', 'delivery_stops_issue_reason_length',
  'issue_reason is null or char_length(issue_reason) <= 400');
select public._add_check_once('public.delivery_stops', 'delivery_stops_proof_note_length',
  'proof_note is null or char_length(proof_note) <= 300');
select public._add_check_once('public.vouchers', 'vouchers_code_format',
  $c$code ~ '^[A-Za-z0-9_-]{1,30}$'$c$);

-- -----------------------------------------------------------------------------
-- People and places
-- -----------------------------------------------------------------------------
select public._add_check_once('public.staff_members', 'staff_members_full_name_length',
  'char_length(full_name) <= 120');
select public._add_check_once('public.branches', 'branches_name_length',
  'char_length(btrim(name)) between 2 and 120');
select public._add_check_once('public.branches', 'branches_text_lengths',
  'char_length(coalesce(address, '''')) <= 300 and char_length(coalesce(operating_hours, '''')) <= 120 '
  'and char_length(coalesce(contact_phone, '''')) <= 40');
select public._add_check_once('public.suppliers', 'suppliers_text_lengths',
  'char_length(coalesce(contact_person, '''')) <= 120 and char_length(coalesce(address, '''')) <= 300 '
  'and char_length(coalesce(email, '''')) <= 254 and char_length(coalesce(tin, '''')) <= 20');
select public._add_check_once('public.suppliers', 'suppliers_email_format',
  $c$email is null or email = '' or email ~ '^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$'$c$);

commit;
