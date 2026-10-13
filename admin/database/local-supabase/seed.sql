-- =============================================================================
-- SAMPLE DATA for a LOCAL copy of the Melai Nuts Supabase database (development only).
-- Loaded by admin/database/local-supabase/setup.sh (or setup.ps1). NEVER run against Supabase.
--
-- The owner row uses the psql variables owner_uid / owner_email (setup scripts pass your
-- ADMIN_STAFF_UID / ADMIN_EMAIL from admin/.env, so your usual sign-in works locally).
-- Defaults: 'local-owner' / owner@melai.local.
-- =============================================================================
\set ON_ERROR_STOP 1
\if :{?owner_uid}
\else
  \set owner_uid local-owner
\endif
\if :{?owner_email}
\else
  \set owner_email owner@melai.local
\endif
begin;
set local melai.seed_owner_uid = :'owner_uid';
set local melai.seed_owner_email = :'owner_email';

do $$
declare
  b uuid; bn text; cat uuid; p uuid; v uuid; o text; sup uuid; r uuid;
  branch_ids uuid[] := '{}'; branch_names text[] := '{}';
  var_ids uuid[] := '{}'; prod_ids uuid[] := '{}'; prod_names text[] := '{}'; prices numeric[] := '{}';
  names text[] := array['Garlic Peanuts','Adobo Peanuts','Cashew Classic','Honey Cashew','Pili Nuts','Spicy Peanuts',
                        'Mixed Nuts','Almond Roast','Salted Pistachio','Kasoy Brittle','Chili Garlic Mani','Peanut Butter Jar',
                        'Macadamia','Walnut Halves','Cornick Mix','Green Peas','Sunflower Seeds','Pumpkin Seeds',
                        'Trail Mix','Coated Peanuts','Barquillos','Polvoron','Yema Cashew','Choco Peanuts'];
  i int; d int; n int; qty int; pr numeric; st text; cust text; t timestamptz; k int;
  statuses text[] := array['completed','completed','completed','completed','completed','completed','pending','confirmed','preparing','readyForPickup','cancelled'];
begin
  -- branches
  foreach bn in array array['Calamba','Los Banos','Santa Rosa'] loop
    insert into public.branches (name, address, delivery_fee) values ('Melai '||bn, bn||', Laguna', 30) returning id into b;
    branch_ids := branch_ids || b; branch_names := branch_names || ('Melai '||bn);
  end loop;

  insert into public.product_categories (label) values ('Nuts') returning id into cat;
  for i in 1..array_length(names,1) loop
    pr := 60 + (i * 7) % 140;
    insert into public.products (category_id, name, price, unit) values (cat, names[i], pr, 'pack') returning id into p;
    insert into public.product_variants (product_id, label, price) values (p, 'Regular', pr) returning id into v;
    prod_ids := prod_ids || p; var_ids := var_ids || v; prod_names := prod_names || names[i]; prices := prices || pr;
    for k in 1..3 loop
      insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
        values (branch_ids[k], p, v, (i * 13 + k * 7) % 60);   -- some items end up low / out of stock
    end loop;
  end loop;

  -- people
  insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
    values (current_setting('melai.seed_owner_uid'), 'Local Owner', lower(current_setting('melai.seed_owner_email')), 'owner', null, 'active', true, true);
  for i in 1..9 loop
    insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory)
      values ('local-staff-'||i, 'Staff '||i, 'staff'||i||'@melai.local', 'staff', branch_ids[1 + i % 3], 'active', i % 2 = 0);
  end loop;
  for i in 1..400 loop
    insert into public.customer_profiles (firebase_uid, full_name, email, phone, rfid_card_number)
      values ('local-cust-'||i, 'Customer '||i, 'cust'||i||'@melai.local', '0917'||lpad(i::text, 7, '0'), 'CARD-'||i);
  end loop;
  insert into public.business_settings (id) values ('default') on conflict (id) do nothing;

  -- ~4,300 orders over the last 180 days, one item each, paid ones with a payment row
  for d in 0..179 loop
    for n in 1..(18 + (d % 11)) loop
      k := 1 + (d + n) % 3; i := 1 + (d * 7 + n * 3) % array_length(names,1);
      qty := 1 + (d + n) % 4; pr := prices[i];
      st := case when d < 3 then statuses[1 + (d + n) % array_length(statuses,1)] else (case when (d+n) % 23 = 0 then 'cancelled' else 'completed' end) end;
      cust := case when n % 3 = 0 then 'walk-in' else 'local-cust-'||(1 + (d * 31 + n) % 400) end;
      t := (now() at time zone 'Asia/Manila')::date - d + interval '9 hours' + (n * interval '23 minutes');
      t := t at time zone 'Asia/Manila';
      insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method, created_at)
        values (cust, branch_ids[k], branch_names[k], false, st, qty*pr, 0, 0, qty*pr, 'Cash (In-store)', t) returning id into o;
      insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
        values (o, prod_ids[i], var_ids[i], prod_names[i], 'Regular', qty, pr);
      insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number, created_at)
        values (o, cust, case when n % 4 = 0 then 'gcash' else 'cash' end,
                case when st in ('cancelled', 'pending') then 'pending' else 'success' end, qty*pr, o, t);
    end loop;
  end loop;

  -- suppliers + draft purchase receipts
  for i in 1..6 loop
    insert into public.suppliers (name, contact_person, created_by) values ('Supplier '||i, 'Contact '||i, current_setting('melai.seed_owner_uid')) returning id into sup;
    for n in 1..10 loop
      insert into public.purchase_receipts (branch_id, supplier_id, supplier_invoice_no, invoice_date, status, created_by, created_at, invoice_total)
        values (branch_ids[1 + n % 3], sup, 'INV-'||i||'-'||n, current_date - n * 3, 'draft', current_setting('melai.seed_owner_uid'), now() - (n * 3 || ' days')::interval, 1000 + n * 50)
        returning id into r;
    end loop;
  end loop;
end $$;

commit;
