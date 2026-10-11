#!/usr/bin/env bash
# =============================================================================
# Melai Nuts — test for supabase/repair/20261013_cleanup_seeded_demo_records.sql
# =============================================================================
# Reproduces the old demo seed's rows on a LOCAL test database (plus real-looking
# rows that must never be touched), then:
#   1. runs the clean-up file exactly as shipped (every section ROLLBACK)  -> no change;
#   2. runs it with every section switched to COMMIT and real branch details typed
#      into section D                                                       -> exactly the
#      seeded rows change; orders, payments, sold products and real rows do not;
#   3. runs the COMMIT version again                                       -> no further change.
# It commits its fixtures and removes them at the end (DEV / CI database only).
#
#   DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/melai_sql_test \
#     bash supabase/tests/cleanup_seeded_demo_records_test.sh
# =============================================================================
set -u
: "${DATABASE_URL:?Set DATABASE_URL to a DEV/CI database}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLEANUP="$ROOT/supabase/repair/20261013_cleanup_seeded_demo_records.sql"
PSQL=(psql "$DATABASE_URL" -X -q -At)
PASS=0; FAIL=0
TMP="$(mktemp -d)"

val() { "${PSQL[@]}" -c "$1" 2>/dev/null | head -1; }
check() { # name expected actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS  $1"; else FAIL=$((FAIL+1)); echo "  FAIL  $1   (expected [$2], got [$3])"; fi
}
cleanup() {
  "${PSQL[@]}" >/dev/null 2>&1 <<'SQL'
set session_replication_role = replica;
delete from public.order_items where order_id in (select id from public.orders where firebase_uid = 'cleanup-test-cust');
delete from public.payments where order_id in (select id from public.orders where firebase_uid = 'cleanup-test-cust');
delete from public.orders where firebase_uid = 'cleanup-test-cust';
delete from public.stock_movements where branch_id in (select id from public.branches where name in ('Calamba Branch','Los Baños Branch','Santa Cruz Branch','CLEANUP Real Branch'));
delete from public.branch_inventory where branch_id in (select id from public.branches where name in ('Calamba Branch','Los Baños Branch','Santa Cruz Branch','CLEANUP Real Branch'));
delete from public.product_variants where product_id in (select id from public.products where description like 'CLEANUP%' or name in ('Roasted Cashew','Roasted Peanuts','Chili Garlic Peanuts','Mixed Nuts & Raisins','Melai Nuts Gift Box'));
delete from public.products where description like 'CLEANUP%' or name in ('Roasted Cashew','Roasted Peanuts','Chili Garlic Peanuts','Mixed Nuts & Raisins','Melai Nuts Gift Box');
delete from public.rewards where title in ('₱50 Off Voucher','Free 100g Roasted Cashew','Free Delivery Voucher','CLEANUP Real Reward');
delete from public.promotions where title in ('Fresh Batch Every Friday','CLEANUP Real Promo');
delete from public.branches where name in ('Calamba Branch','Los Baños Branch','Santa Cruz Branch','CLEANUP Real Branch');
delete from public.customer_profiles where firebase_uid = 'cleanup-test-cust';
set session_replication_role = origin;
SQL
}
trap 'cleanup; rm -rf "$TMP"' EXIT
cleanup

# ---- Fixtures: the seed's rows (exact values) + real rows that must stay ----------
"${PSQL[@]}" -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || { echo "fixture setup failed"; exit 1; }
insert into public.branches (name, address, contact_phone, operating_hours, delivery_fee) values
  ('Calamba Branch', 'Poblacion Terminal, National Hwy, Calamba City, Laguna', '(049) 502-1187', 'seed hours', 0),
  ('Los Baños Branch', 'Lopez Ave, Los Baños, Laguna', '(049) 536-4420', 'seed hours', 0),
  ('Santa Cruz Branch', 'National Hwy, Santa Cruz, Laguna', '(049) 501-7765', 'seed hours', 0),
  ('CLEANUP Real Branch', 'A real street', '0917', 'real hours', 25);
insert into public.products (name, price, description) values
  ('Roasted Cashew', 220, 'Slow-roasted Laguna cashews, lightly salted.'),
  ('Roasted Peanuts', 90, 'Crunchy roasted peanuts in shell.'),
  ('Chili Garlic Peanuts', 110, 'Peanuts tossed in chili and garlic seasoning.'),
  ('Mixed Nuts & Raisins', 260, 'Cashew, peanut, almond and raisin blend.'),
  ('Melai Nuts Gift Box', 480, 'Assorted nuts in a gift-ready box.'),
  ('CLEANUP Real Product', 150, 'CLEANUP a product the owner added');
insert into public.product_variants (product_id, label, price) select id, 'Regular', price from public.products
  where name in ('Roasted Cashew','Roasted Peanuts','Chili Garlic Peanuts','Mixed Nuts & Raisins','Melai Nuts Gift Box','CLEANUP Real Product');
-- 50 units of every seeded variant at every seeded branch (15 rows) ...
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select b.id, v.product_id, v.id, 50 from public.branches b cross join public.product_variants v join public.products p on p.id = v.product_id
where b.name in ('Calamba Branch','Los Baños Branch','Santa Cruz Branch') and p.description not like 'CLEANUP%';
-- ... a real stock count that happens to be 50 at the real branch (must stay) ...
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select b.id, v.product_id, v.id, 50 from public.branches b, public.product_variants v join public.products p on p.id = v.product_id
where b.name = 'CLEANUP Real Branch' and p.name = 'CLEANUP Real Product';
-- ... and 3 Santa Cruz rows that staff really moved (not seeded any more).
insert into public.stock_movements (branch_id, product_id, variant_id, movement_type, quantity_change, reason)
select bi.branch_id, bi.product_id, bi.variant_id, 'adjust', 0, 'counted' from public.branch_inventory bi
join public.branches b on b.id = bi.branch_id join public.products p on p.id = bi.product_id
where b.name = 'Santa Cruz Branch' and p.name in ('Roasted Peanuts','Chili Garlic Peanuts','Melai Nuts Gift Box');
insert into public.rewards (title, points_required) values
  ('₱50 Off Voucher', 200), ('Free 100g Roasted Cashew', 350), ('Free Delivery Voucher', 150), ('CLEANUP Real Reward', 99);
insert into public.promotions (title) values ('Fresh Batch Every Friday'), ('CLEANUP Real Promo');
insert into public.customer_profiles (firebase_uid, full_name, email) values ('cleanup-test-cust', 'Cleanup Test', 'c@test.local');
SQL
# Orders that sold Roasted Peanuts and the Gift Box (bypass triggers: only the rows matter here).
"${PSQL[@]}" -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || { echo "order fixture failed"; exit 1; }
set session_replication_role = replica;
insert into public.orders (id, firebase_uid, branch_name, subtotal, total, payment_method, status)
values ('CLEANUP-ORD-1', 'cleanup-test-cust', 'Santa Cruz Branch', 90, 90, 'Cash on Counter Pickup', 'completed'),
       ('CLEANUP-ORD-2', 'cleanup-test-cust', 'Santa Cruz Branch', 480, 480, 'Cash on Counter Pickup', 'completed');
insert into public.order_items (order_id, product_id, product_name, quantity, unit_price)
select 'CLEANUP-ORD-1', id, name, 1, 90 from public.products where name = 'Roasted Peanuts';
insert into public.order_items (order_id, product_id, product_name, quantity, unit_price)
select 'CLEANUP-ORD-2', id, name, 1, 480 from public.products where name = 'Melai Nuts Gift Box';
set session_replication_role = origin;
SQL

snapshot() {
  val "select md5(string_agg(x, '|' order by x)) from (
     select 'inv:' || b.name || ':' || p.name || ':' || bi.quantity as x from public.branch_inventory bi
       join public.branches b on b.id = bi.branch_id join public.products p on p.id = bi.product_id
     union all select 'prod:' || name || ':' || price || ':' || is_active from public.products
     union all select 'rew:' || title || ':' || is_active from public.rewards
     union all select 'promo:' || title || ':' || is_active from public.promotions
     union all select 'br:' || name || ':' || coalesce(address,'-') || ':' || coalesce(contact_phone,'-') || ':' || coalesce(operating_hours,'-') from public.branches
     union all select 'ord:' || id || ':' || status || ':' || total from public.orders
     union all select 'mov:' || count(*) from public.stock_movements) s"
}

echo "== 1. As shipped (every section ROLLBACK): nothing changes"
before="$(snapshot)"
"${PSQL[@]}" -f "$CLEANUP" >/dev/null 2>&1
check "database unchanged after running the file as shipped" "$before" "$(snapshot)"

echo "== 2. Every section switched to COMMIT, real branch details typed in"
sed -e 's/^rollback;  -- change to COMMIT/commit;  -- (test) change to COMMIT/' \
    -e "s/'EDIT real address', 'EDIT real phone', 'EDIT real hours'/'Real address', 'Real phone', 'Real hours'/" \
    "$CLEANUP" > "$TMP/commit.sql"
"${PSQL[@]}" -f "$TMP/commit.sql" > "$TMP/out1.txt" 2>&1
check "12 seeded stock rows set to 0" "12" "$(val "select count(*) from public.stock_movements where reference = 'cleanup-seed-20261013'")"
check "the 3 really-moved Santa Cruz rows keep 50" "3" "$(val "select count(*) from public.branch_inventory bi join public.branches b on b.id=bi.branch_id where b.name='Santa Cruz Branch' and bi.quantity=50")"
check "the real branch's 50 units stay" "50" "$(val "select bi.quantity from public.branch_inventory bi join public.branches b on b.id=bi.branch_id where b.name='CLEANUP Real Branch'")"
check "3 never-sold seeded products hidden" "3" "$(val "select count(*) from public.products where not is_active and name in ('Roasted Cashew','Chili Garlic Peanuts','Mixed Nuts & Raisins')")"
check "sold seeded products stay active" "2" "$(val "select count(*) from public.products where is_active and name in ('Roasted Peanuts','Melai Nuts Gift Box')")"
check "real product untouched" "t" "$(val "select is_active from public.products where name='CLEANUP Real Product'")"
check "seeded rewards deleted (C then C2)" "0" "$(val "select count(*) from public.rewards where title in ('₱50 Off Voucher','Free 100g Roasted Cashew','Free Delivery Voucher')")"
check "seeded promotion deleted (C then C2)" "0" "$(val "select count(*) from public.promotions where title='Fresh Batch Every Friday'")"
check "real reward and promotion untouched" "2" "$(val "select (select count(*) from public.rewards where title='CLEANUP Real Reward' and is_active) + (select count(*) from public.promotions where title='CLEANUP Real Promo' and is_active)")"
check "seeded branch details replaced by the typed ones" "3" "$(val "select count(*) from public.branches where address='Real address' and contact_phone='Real phone' and operating_hours='Real hours'")"
check "real branch details untouched" "A real street" "$(val "select address from public.branches where name='CLEANUP Real Branch'")"
check "orders untouched" "2|570" "$(val "select count(*) || '|' || sum(total)::int from public.orders where firebase_uid='cleanup-test-cust' and status='completed'")"
check "section F reports nothing left" "0|0|0|0|0" "$(val "select seeded_stock_rows||'|'||active_unsold_seed_products||'|'||active_seed_rewards||'|'||active_seed_promotions||'|'||branches_with_seed_address from (
  $(sed -n '/^-- F\./,$p' "$CLEANUP" | grep -v '^--' | sed 's/;$//')) f")"

echo "== 3. Running the COMMIT version again changes nothing"
after="$(snapshot)"
"${PSQL[@]}" -f "$TMP/commit.sql" >/dev/null 2>&1
check "second run is a no-op" "$after" "$(snapshot)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
