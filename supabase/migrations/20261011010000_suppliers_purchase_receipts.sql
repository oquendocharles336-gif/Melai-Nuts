-- =============================================================================
-- Suppliers, purchase receipts (supplier invoices) and the OCR review flow
-- =============================================================================
-- Run after 20261011000000_loyalty_cards.sql. Idempotent and additive.
--
-- The flow
--   1. Staff photograph a supplier invoice in the admin website. OCR (Tesseract)
--      turns the photo into text and the website pre-fills a DRAFT receipt:
--      supplier, invoice number/date, and one line per item it could read.
--   2. A person checks every line against the paper: product, quantity, unit cost,
--      batch code, expiry. OCR text is never trusted on its own.
--   3. Only "Approve" posts stock. Each line becomes a FEFO batch through the
--      existing staff_receive_batch (same rules, same stock movements), the
--      variant's cost price is updated to the latest purchase cost, and the
--      receipt is locked. The same supplier invoice cannot be approved twice.
--
-- Who
--   suppliers: any active staff can read; owner or staff with inventory
--   permission can add / edit. Receipts: owner, or staff with inventory permission
--   in their own branch.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Tables
-- -----------------------------------------------------------------------------
create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 2 and 120),
  contact_person text,
  phone text,
  email text,
  address text,
  tin text,
  is_active boolean not null default true,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists suppliers_name_key on public.suppliers (lower(trim(name)));

create sequence if not exists public.purchase_receipt_code_seq;

create table if not exists public.purchase_receipts (
  id uuid primary key default gen_random_uuid(),
  receipt_code text not null unique default ('PR-' || lpad(nextval('public.purchase_receipt_code_seq')::text, 6, '0')),
  branch_id uuid not null references public.branches(id) on delete restrict,
  supplier_id uuid references public.suppliers(id) on delete restrict,
  supplier_invoice_no text,
  invoice_date date,
  status text not null default 'draft' check (status in ('draft', 'approved', 'cancelled')),
  source text not null default 'manual' check (source in ('manual', 'ocr')),
  ocr_text text check (ocr_text is null or char_length(ocr_text) <= 20000),
  ocr_confidence numeric(5, 2) check (ocr_confidence is null or ocr_confidence between 0 and 100),
  document_path text,
  notes text,
  invoice_total numeric(12, 2) check (invoice_total is null or invoice_total >= 0),
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  approved_by text,
  approved_at timestamptz,
  cancelled_by text,
  cancelled_at timestamptz,
  cancel_reason text
);
create index if not exists purchase_receipts_branch_idx on public.purchase_receipts (branch_id, created_at desc);
-- The same supplier invoice can be posted to stock only once.
create unique index if not exists purchase_receipts_invoice_once
  on public.purchase_receipts (supplier_id, lower(trim(supplier_invoice_no)))
  where (status = 'approved' and supplier_id is not null and supplier_invoice_no is not null);

create table if not exists public.purchase_receipt_lines (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.purchase_receipts(id) on delete cascade,
  line_no int not null check (line_no between 1 and 200),
  raw_text text check (raw_text is null or char_length(raw_text) <= 500),
  description text check (description is null or char_length(description) <= 200),
  variant_id uuid references public.product_variants(id) on delete restrict,
  quantity int check (quantity is null or quantity between 1 and 100000),
  unit_cost numeric(10, 2) check (unit_cost is null or unit_cost between 0 and 1000000),
  batch_code text check (batch_code is null or char_length(trim(batch_code)) between 1 and 40),
  expiration_date date,
  batch_id uuid references public.inventory_batches(id) on delete set null,
  unique (receipt_id, line_no)
);

alter table public.suppliers enable row level security;
alter table public.purchase_receipts enable row level security;
alter table public.purchase_receipt_lines enable row level security;
revoke all on public.suppliers, public.purchase_receipts, public.purchase_receipt_lines from anon, authenticated;

-- An approved or cancelled receipt is a record: its lines cannot change.
create or replace function public._trg_purchase_lines_locked()
returns trigger language plpgsql as $$
declare
  v_status text;
begin
  select status into v_status from public.purchase_receipts
  where id = coalesce(new.receipt_id, old.receipt_id);
  if v_status is distinct from 'draft' then
    raise exception 'This receipt is % and can no longer be changed.', v_status;
  end if;
  return coalesce(new, old);
end;
$$;
drop trigger if exists purchase_receipt_lines_locked on public.purchase_receipt_lines;
create trigger purchase_receipt_lines_locked
  before insert or update or delete on public.purchase_receipt_lines
  for each row execute function public._trg_purchase_lines_locked();

-- -----------------------------------------------------------------------------
-- 2. Helpers
-- -----------------------------------------------------------------------------
-- Owner, or active staff with the inventory permission (in their branch when given).
create or replace function public._require_inventory_staff(p_branch_id uuid default null)
returns public.staff_members
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return public._require_staff(p_branch_id, 'inventory');
end;
$$;

create or replace function public._receipt_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', r.id, 'receipt_code', r.receipt_code, 'status', r.status, 'source', r.source,
    'branch_id', r.branch_id, 'branch_name', b.name,
    'supplier_id', r.supplier_id, 'supplier_name', s.name,
    'supplier_invoice_no', r.supplier_invoice_no, 'invoice_date', r.invoice_date,
    'invoice_total', r.invoice_total,
    'ocr_text', r.ocr_text, 'ocr_confidence', r.ocr_confidence, 'document_path', r.document_path,
    'notes', r.notes,
    'created_by', coalesce(cb.full_name, r.created_by), 'created_at', r.created_at,
    'approved_by', coalesce(ab.full_name, r.approved_by), 'approved_at', r.approved_at,
    'cancelled_at', r.cancelled_at, 'cancel_reason', r.cancel_reason,
    'lines_total', (select coalesce(sum(l.quantity * l.unit_cost), 0) from public.purchase_receipt_lines l where l.receipt_id = r.id),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', l.id, 'line_no', l.line_no, 'raw_text', l.raw_text, 'description', l.description,
                'variant_id', l.variant_id,
                'variant_name', case when pv.id is null then null
                                     else p.name || case when pv.label in ('', 'Regular') then '' else ' · ' || pv.label end end,
                'quantity', l.quantity, 'unit_cost', l.unit_cost,
                'line_total', l.quantity * l.unit_cost,
                'batch_code', l.batch_code, 'expiration_date', l.expiration_date, 'batch_id', l.batch_id)
              order by l.line_no), '[]'::jsonb)
              from public.purchase_receipt_lines l
              left join public.product_variants pv on pv.id = l.variant_id
              left join public.products p on p.id = pv.product_id
              where l.receipt_id = r.id))
  from public.purchase_receipts r
  join public.branches b on b.id = r.branch_id
  left join public.suppliers s on s.id = r.supplier_id
  left join public.staff_members cb on cb.firebase_uid = r.created_by
  left join public.staff_members ab on ab.firebase_uid = r.approved_by
  where r.id = p_id
$$;

-- -----------------------------------------------------------------------------
-- 3. Suppliers
-- -----------------------------------------------------------------------------
create or replace function public.staff_list_suppliers(p_include_inactive boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id, 'name', s.name, 'contact_person', s.contact_person, 'phone', s.phone,
             'email', s.email, 'address', s.address, 'tin', s.tin, 'is_active', s.is_active,
             'receipts', (select count(*) from public.purchase_receipts r where r.supplier_id = s.id and r.status = 'approved'))
           order by s.is_active desc, lower(s.name))
    from public.suppliers s
    where s.is_active or coalesce(p_include_inactive, false)), '[]'::jsonb);
end;
$$;

create or replace function public.staff_save_supplier(
  p_id uuid,
  p_name text,
  p_contact_person text default null,
  p_phone text default null,
  p_email text default null,
  p_address text default null,
  p_tin text default null,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_name text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_id uuid;
begin
  v_staff := public._require_inventory_staff();
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    raise exception 'Enter the supplier name (2 to 120 characters).';
  end if;
  if p_email is not null and trim(p_email) <> '' and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'That e-mail address does not look right.';
  end if;
  begin
    if p_id is null then
      insert into public.suppliers (name, contact_person, phone, email, address, tin, is_active, created_by)
      values (v_name, nullif(trim(p_contact_person), ''), nullif(trim(p_phone), ''), nullif(lower(trim(p_email)), ''),
              nullif(trim(p_address), ''), nullif(trim(p_tin), ''), coalesce(p_is_active, true), v_staff.firebase_uid)
      returning id into v_id;
    else
      update public.suppliers
         set name = v_name, contact_person = nullif(trim(p_contact_person), ''), phone = nullif(trim(p_phone), ''),
             email = nullif(lower(trim(p_email)), ''), address = nullif(trim(p_address), ''),
             tin = nullif(trim(p_tin), ''), is_active = coalesce(p_is_active, true), updated_at = now()
       where id = p_id
      returning id into v_id;
      if v_id is null then raise exception 'That supplier could not be found.'; end if;
    end if;
  exception when unique_violation then
    raise exception 'A supplier named "%" already exists.', v_name;
  end;
  perform public._write_audit(v_staff.firebase_uid, v_staff.branch_id,
    case when p_id is null then 'supplier.create' else 'supplier.update' end, 'supplier', v_id::text,
    jsonb_build_object('name', v_name, 'is_active', coalesce(p_is_active, true)));
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Draft receipts (manual or pre-filled by OCR)
--    p_lines: [{"raw_text": "...", "description": "...", "variant_id": "<uuid>|null",
--               "quantity": 10, "unit_cost": 85.5, "batch_code": "...", "expiration_date": "2027-03-01"}]
--    Every field except the line itself may be missing in a draft.
-- -----------------------------------------------------------------------------
create or replace function public.staff_save_purchase_receipt(
  p_receipt_id uuid,
  p_branch_id uuid,
  p_supplier_id uuid,
  p_supplier_invoice_no text,
  p_invoice_date date,
  p_lines jsonb,
  p_source text default 'manual',
  p_ocr_text text default null,
  p_ocr_confidence numeric default null,
  p_document_path text default null,
  p_notes text default null,
  p_invoice_total numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  r public.purchase_receipts;
  v_id uuid := p_receipt_id;
  v_line jsonb;
  v_no int := 0;
  v_variant uuid;
  v_qty int;
  v_cost numeric;
  v_exp date;
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  v_staff := public._require_inventory_staff(p_branch_id);
  if p_branch_id is null or not exists (select 1 from public.branches where id = p_branch_id) then
    raise exception 'Choose the branch that received the goods.';
  end if;
  if p_supplier_id is not null and not exists (select 1 from public.suppliers where id = p_supplier_id) then
    raise exception 'That supplier could not be found.';
  end if;
  if p_invoice_date is not null and (p_invoice_date > v_today or p_invoice_date < v_today - 730) then
    raise exception 'The invoice date must be within the last two years and not in the future.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'The receipt lines are missing.';
  end if;
  if jsonb_array_length(p_lines) > 200 then raise exception 'A receipt can have at most 200 lines.'; end if;
  if coalesce(p_source, 'manual') not in ('manual', 'ocr') then raise exception 'Unknown receipt source.'; end if;

  if v_id is not null then
    select * into r from public.purchase_receipts where id = v_id for update;
    if r.id is null then raise exception 'That receipt could not be found.'; end if;
    perform public._require_inventory_staff(r.branch_id);
    if r.status <> 'draft' then raise exception 'This receipt is % and can no longer be changed.', r.status; end if;
    update public.purchase_receipts
       set branch_id = p_branch_id, supplier_id = p_supplier_id,
           supplier_invoice_no = nullif(trim(p_supplier_invoice_no), ''), invoice_date = p_invoice_date,
           notes = nullif(trim(p_notes), ''), invoice_total = p_invoice_total, updated_at = now(),
           -- keep the OCR evidence of the first scan unless a new scan is sent
           ocr_text = coalesce(p_ocr_text, ocr_text), ocr_confidence = coalesce(p_ocr_confidence, ocr_confidence),
           document_path = coalesce(p_document_path, document_path),
           source = case when p_ocr_text is not null then 'ocr' else source end
     where id = v_id;
    delete from public.purchase_receipt_lines where receipt_id = v_id;
  else
    insert into public.purchase_receipts (branch_id, supplier_id, supplier_invoice_no, invoice_date, status, source,
                                          ocr_text, ocr_confidence, document_path, notes, invoice_total, created_by)
    values (p_branch_id, p_supplier_id, nullif(trim(p_supplier_invoice_no), ''), p_invoice_date, 'draft',
            coalesce(p_source, 'manual'), left(p_ocr_text, 20000), p_ocr_confidence, p_document_path,
            nullif(trim(p_notes), ''), p_invoice_total, v_staff.firebase_uid)
    returning id into v_id;
  end if;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    -- Blank rows from the form are skipped.
    continue when coalesce(nullif(trim(v_line ->> 'description'), ''), nullif(trim(v_line ->> 'raw_text'), ''),
                           nullif(v_line ->> 'variant_id', '')) is null;
    v_no := v_no + 1;
    v_variant := nullif(v_line ->> 'variant_id', '')::uuid;
    if v_variant is not null and not exists (select 1 from public.product_variants where id = v_variant) then
      raise exception 'Line %: that product could not be found.', v_no;
    end if;
    begin
      v_qty := nullif(v_line ->> 'quantity', '')::numeric::int;
      v_cost := round(nullif(v_line ->> 'unit_cost', '')::numeric, 2);
      v_exp := nullif(v_line ->> 'expiration_date', '')::date;
    exception when others then
      raise exception 'Line %: quantity, unit cost or expiry date is not a valid value.', v_no;
    end;
    if v_qty is not null and (v_qty < 1 or v_qty > 100000) then
      raise exception 'Line %: quantity must be between 1 and 100000.', v_no;
    end if;
    if v_cost is not null and (v_cost < 0 or v_cost > 1000000) then
      raise exception 'Line %: unit cost must be 0 or more.', v_no;
    end if;
    insert into public.purchase_receipt_lines
      (receipt_id, line_no, raw_text, description, variant_id, quantity, unit_cost, batch_code, expiration_date)
    values (v_id, v_no, left(v_line ->> 'raw_text', 500), left(nullif(trim(v_line ->> 'description'), ''), 200),
            v_variant, v_qty, v_cost, left(nullif(trim(v_line ->> 'batch_code'), ''), 40), v_exp);
  end loop;

  perform public._write_audit(v_staff.firebase_uid, p_branch_id,
    case when p_receipt_id is null then 'purchase_receipt.draft_create' else 'purchase_receipt.draft_update' end,
    'purchase_receipt', v_id::text,
    jsonb_build_object('source', coalesce(p_source, 'manual'), 'lines', v_no, 'invoice_no', p_supplier_invoice_no));
  return public._receipt_json(v_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Approve: every line must be complete; then stock is posted once.
-- -----------------------------------------------------------------------------
create or replace function public.staff_approve_purchase_receipt(
  p_receipt_id uuid,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  r public.purchase_receipts;
  l public.purchase_receipt_lines;
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_req jsonb := jsonb_build_object('r', p_receipt_id);
  v_prev jsonb;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_batch uuid;
  v_code text;
  v_count int;
  v_result jsonb;
begin
  select * into r from public.purchase_receipts where id = p_receipt_id for update;
  if r.id is null then raise exception 'That receipt could not be found.'; end if;
  v_staff := public._require_inventory_staff(r.branch_id);
  v_prev := public._idem_begin(v_staff.firebase_uid, v_key, 'receipt_approve', v_req);
  if v_prev is not null then return v_prev; end if;

  if r.status = 'approved' then
    raise exception 'This receipt was already approved (stock was posted once).';
  elsif r.status = 'cancelled' then
    raise exception 'This receipt was cancelled.';
  end if;
  if r.supplier_id is null then raise exception 'Choose the supplier before approving.'; end if;
  if r.supplier_invoice_no is null then raise exception 'Enter the supplier''s invoice number before approving.'; end if;
  if exists (select 1 from public.purchase_receipts x
             where x.status = 'approved' and x.supplier_id = r.supplier_id
               and lower(trim(x.supplier_invoice_no)) = lower(trim(r.supplier_invoice_no))) then
    raise exception 'Invoice % from this supplier was already received. It cannot be posted twice.', r.supplier_invoice_no;
  end if;

  select count(*) into v_count from public.purchase_receipt_lines where receipt_id = r.id;
  if v_count = 0 then raise exception 'Add at least one line before approving.'; end if;
  for l in select * from public.purchase_receipt_lines where receipt_id = r.id order by line_no loop
    if l.variant_id is null then raise exception 'Line %: choose the product.', l.line_no; end if;
    if l.quantity is null then raise exception 'Line %: enter the quantity.', l.line_no; end if;
    if l.unit_cost is null then raise exception 'Line %: enter the unit cost.', l.line_no; end if;
    if l.expiration_date is null or l.expiration_date <= v_today then
      raise exception 'Line %: enter an expiry date in the future.', l.line_no;
    end if;
  end loop;
  if exists (select variant_id, coalesce(batch_code, '') from public.purchase_receipt_lines
             where receipt_id = r.id group by 1, 2 having count(*) > 1) then
    raise exception 'The same product appears twice with the same batch code. Merge the lines or give them different batch codes.';
  end if;

  for l in select * from public.purchase_receipt_lines where receipt_id = r.id order by line_no loop
    v_code := coalesce(l.batch_code, r.receipt_code || '-' || l.line_no);
    v_batch := public.staff_receive_batch(r.branch_id, l.variant_id, v_code, l.quantity, l.expiration_date,
                                          coalesce(least(r.invoice_date, v_today), v_today));
    update public.purchase_receipt_lines set batch_id = v_batch, batch_code = v_code where id = l.id;
    update public.stock_movements
       set reference = r.receipt_code, reason = 'Received on ' || r.receipt_code || ' (invoice ' || r.supplier_invoice_no || ')'
     where batch_id = v_batch and movement_type = 'receive';
    insert into public.product_variant_costs (variant_id, cost_price, updated_at)
    values (l.variant_id, l.unit_cost, now())
    on conflict (variant_id) do update set cost_price = excluded.cost_price, updated_at = now();
  end loop;

  -- Lines are filled in above while the receipt is still a draft; from here on
  -- the lock trigger refuses any change to them.
  update public.purchase_receipts
     set status = 'approved', approved_by = v_staff.firebase_uid, approved_at = now(), updated_at = now()
   where id = r.id;

  perform public._write_audit(v_staff.firebase_uid, r.branch_id, 'purchase_receipt.approve', 'purchase_receipt', r.id::text,
    jsonb_build_object('receipt_code', r.receipt_code, 'invoice_no', r.supplier_invoice_no, 'lines', v_count,
                       'total', (select sum(quantity * unit_cost) from public.purchase_receipt_lines where receipt_id = r.id)));
  v_result := public._receipt_json(r.id);
  perform public._idem_finish(v_staff.firebase_uid, v_key, 'receipt_approve', v_req, v_result);
  return v_result;
end;
$$;

create or replace function public.staff_cancel_purchase_receipt(p_receipt_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  r public.purchase_receipts;
  v_reason text := trim(coalesce(p_reason, ''));
begin
  select * into r from public.purchase_receipts where id = p_receipt_id for update;
  if r.id is null then raise exception 'That receipt could not be found.'; end if;
  v_staff := public._require_inventory_staff(r.branch_id);
  if r.status = 'cancelled' then return public._receipt_json(r.id); end if;
  if r.status = 'approved' then
    raise exception 'An approved receipt cannot be cancelled. Correct the stock with an inventory adjustment.';
  end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 200 then
    raise exception 'Give a reason for cancelling (3 to 200 characters).';
  end if;
  update public.purchase_receipts
     set status = 'cancelled', cancelled_by = v_staff.firebase_uid, cancelled_at = now(),
         cancel_reason = v_reason, updated_at = now()
   where id = r.id;
  perform public._write_audit(v_staff.firebase_uid, r.branch_id, 'purchase_receipt.cancel', 'purchase_receipt', r.id::text,
    jsonb_build_object('receipt_code', r.receipt_code, 'reason', v_reason));
  return public._receipt_json(r.id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Reads
-- -----------------------------------------------------------------------------
create or replace function public.staff_get_purchase_receipt(p_receipt_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_branch uuid;
begin
  select branch_id into v_branch from public.purchase_receipts where id = p_receipt_id;
  if v_branch is null then raise exception 'That receipt could not be found.'; end if;
  perform public._require_inventory_staff(v_branch);
  return public._receipt_json(p_receipt_id);
end;
$$;

create or replace function public.staff_list_purchase_receipts(
  p_branch_id uuid default null,
  p_status text default null,
  p_limit int default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
begin
  v_staff := public._require_inventory_staff(p_branch_id);
  if p_branch_id is null and v_staff.role <> 'owner' then
    raise exception 'Choose your branch.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'receipt_code', r.receipt_code, 'status', r.status, 'source', r.source,
             'branch_name', b.name, 'supplier_name', s.name, 'supplier_invoice_no', r.supplier_invoice_no,
             'invoice_date', r.invoice_date, 'created_at', r.created_at, 'approved_at', r.approved_at,
             'lines', (select count(*) from public.purchase_receipt_lines l where l.receipt_id = r.id),
             'total', (select coalesce(sum(l.quantity * l.unit_cost), 0) from public.purchase_receipt_lines l where l.receipt_id = r.id))
           order by r.created_at desc)
    from (select * from public.purchase_receipts r0
          where (p_branch_id is null or r0.branch_id = p_branch_id)
            and (p_status is null or p_status = '' or r0.status = p_status)
          order by r0.created_at desc
          limit greatest(1, least(coalesce(p_limit, 100), 500))) r
    join public.branches b on b.id = r.branch_id
    left join public.suppliers s on s.id = r.supplier_id), '[]'::jsonb);
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Grants
-- -----------------------------------------------------------------------------
revoke all on function public._trg_purchase_lines_locked() from public, anon, authenticated;
revoke all on function public._require_inventory_staff(uuid) from public, anon, authenticated;
revoke all on function public._receipt_json(uuid) from public, anon, authenticated;

revoke all on function public.staff_list_suppliers(boolean) from public, anon;
revoke all on function public.staff_save_supplier(uuid, text, text, text, text, text, text, boolean) from public, anon;
revoke all on function public.staff_save_purchase_receipt(uuid, uuid, uuid, text, date, jsonb, text, text, numeric, text, text, numeric) from public, anon;
revoke all on function public.staff_approve_purchase_receipt(uuid, text) from public, anon;
revoke all on function public.staff_cancel_purchase_receipt(uuid, text) from public, anon;
revoke all on function public.staff_get_purchase_receipt(uuid) from public, anon;
revoke all on function public.staff_list_purchase_receipts(uuid, text, int) from public, anon;

grant execute on function public.staff_list_suppliers(boolean) to authenticated;
grant execute on function public.staff_save_supplier(uuid, text, text, text, text, text, text, boolean) to authenticated;
grant execute on function public.staff_save_purchase_receipt(uuid, uuid, uuid, text, date, jsonb, text, text, numeric, text, text, numeric) to authenticated;
grant execute on function public.staff_approve_purchase_receipt(uuid, text) to authenticated;
grant execute on function public.staff_cancel_purchase_receipt(uuid, text) to authenticated;
grant execute on function public.staff_get_purchase_receipt(uuid) to authenticated;
grant execute on function public.staff_list_purchase_receipts(uuid, text, int) to authenticated;

commit;
