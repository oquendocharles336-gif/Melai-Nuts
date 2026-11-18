#!/usr/bin/env bash
# =============================================================================
# Melai Nuts — races for the first-order prepayment (migration 20261118000000)
# =============================================================================
#   1. N first orders at once from ONE brand-new account (one cart per branch)
#        -> exactly one order is created (awaitingDownpayment), all others are refused
#           with "still waiting for its online payment"; no order skips the rule.
#   2. N "paid" webhook events at once for that order
#        -> released once, first_paid_order_at set once.
#   3. After that, N orders at once from the same (now returning) account with
#      Cash on Counter Pickup -> all accepted as normal orders.
# Needs COMMITTED data, so it creates and removes its own rows (prefix FOC- / foc-).
# DEV / staging only.
#
#   DATABASE_URL=postgresql://... bash supabase/tests/first_order_concurrency_test.sh
# =============================================================================
set -uo pipefail
: "${DATABASE_URL:?set DATABASE_URL}"
N="${N:-6}"
PSQL=(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAt)
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1  ($2)"; fail=1; }

cleanup() {
  "${PSQL[@]}" >/dev/null 2>&1 <<'SQL'
set session_replication_role = replica;  -- skip append-only / FK triggers for OUR rows only
create temp table foc_orders as select id from public.orders where firebase_uid like 'foc-%';
delete from public.refund_status_events where refund_request_id in (select id from public.refund_requests where order_id in (select id from foc_orders));
delete from public.refund_requests where order_id in (select id from foc_orders);
delete from public.loyalty_transactions where firebase_uid like 'foc-%';
delete from public.loyalty_accounts where firebase_uid like 'foc-%';
delete from public.notifications where firebase_uid like 'foc-%';
delete from public.order_downpayments where order_id in (select id from foc_orders);
delete from public.payments where order_id in (select id from foc_orders);
delete from public.order_status_events where order_id in (select id from foc_orders);
delete from public.order_items where order_id in (select id from foc_orders);
delete from public.staff_notifications where reference in (select id from foc_orders);
delete from public.orders where id in (select id from foc_orders);
delete from public.cart_items where cart_id in (select id from public.carts where firebase_uid like 'foc-%');
delete from public.carts where firebase_uid like 'foc-%';
delete from public.customer_profiles where firebase_uid like 'foc-%';
delete from public.stock_movements where branch_id in (select id from public.branches where name like 'FOC-%');
delete from public.branch_inventory where branch_id in (select id from public.branches where name like 'FOC-%');
delete from public.product_variants where product_id in (select id from public.products where name like 'FOC-%');
delete from public.products where name like 'FOC-%';
delete from public.product_categories where label like 'FOC-%';
delete from public.branches where name like 'FOC-%';
SQL
}
trap cleanup EXIT
cleanup

as_user() { # uid sql
  "${PSQL[@]}" <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$1","role":"authenticated","email":"$1@test.local","email_verified":true}', true);
set local role authenticated;
$2;
commit;
SQL
}

"${PSQL[@]}" >/dev/null <<SQL
insert into public.branches (name, address, latitude, longitude, delivery_fee)
  select 'FOC-' || n, 'a', 14.2, 121.1, 50 from generate_series(1, $N) n;
insert into public.product_categories (label) values ('FOC-Cat');
insert into public.products (category_id, name, price, unit)
select id, 'FOC-Nut', 100, 'pack' from public.product_categories where label = 'FOC-Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'FOC-Nut';
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select b.id, p.id, v.id, 50 from public.branches b, public.products p join public.product_variants v on v.product_id = p.id
where b.name like 'FOC-%' and p.name = 'FOC-Nut';
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values ('foc-new', 'New', 'foc-new@test.local', '09170000041');
update public.payment_settings set online_payment_enabled = true where id = 'default';
SQL

PROD=$("${PSQL[@]}" -c "select id from public.products where name = 'FOC-Nut'")
VAR=$("${PSQL[@]}" -c "select v.id from public.product_variants v where v.product_id = '$PROD'")
held() { "${PSQL[@]}" -c "select coalesce(sum(50 - quantity), 0) from public.branch_inventory where branch_id in (select id from public.branches where name like 'FOC-%')"; }

cart_for() { # branch number
  local ba
  ba=$("${PSQL[@]}" -c "select id from public.branches where name = 'FOC-$1'")
  as_user foc-new "select (public.sync_customer_cart('$ba', jsonb_build_array(jsonb_build_object('product_id','$PROD','variant_id','$VAR','quantity',1)), null, false) ->> 'cart_id')" | tail -1
}

tmp="$(mktemp -d)"

# --- 1. N first orders at once ---------------------------------------------------------
for i in $(seq 1 "$N"); do echo "$(cart_for "$i")" > "$tmp/cart$i"; done
for i in $(seq 1 "$N"); do
  ( as_user foc-new "select public.place_order('$(cat "$tmp/cart$i")', false, null, 'Online Payment (GCash, QR Ph, Card)', '', 'foc-key-$i', 'half')" > "$tmp/o$i" 2>&1 ) &
done
wait
ORDERS=$("${PSQL[@]}" -c "select count(*) from public.orders where firebase_uid = 'foc-new'")
WAITING=$("${PSQL[@]}" -c "select count(*) from public.orders o join public.order_downpayments d on d.order_id = o.id where o.firebase_uid = 'foc-new' and o.status = 'awaitingDownpayment' and d.kind = 'first_order'")
REFUSED=$(grep -l 'still waiting for its online payment' "$tmp"/o* 2>/dev/null | wc -l)
OTHER=$(grep -L -e 'still waiting for its online payment' -e '^ORD' "$tmp"/o* 2>/dev/null | wc -l)
[ "$ORDERS" = "1" ] && [ "$WAITING" = "1" ] && [ "$REFUSED" -eq $((N - 1)) ] && [ "$OTHER" -eq 0 ] && [ "$(held)" = "1" ] \
  && ok "$N first orders at once -> one created (awaiting payment), $((N - 1)) refused, one unit held" \
  || bad "first orders at once" "orders=$ORDERS waiting=$WAITING refused=$REFUSED other=$OTHER held=$(held)"

ORD=$("${PSQL[@]}" -c "select id from public.orders where firebase_uid = 'foc-new' limit 1")

# --- 2. N paid events at once ----------------------------------------------------------
"${PSQL[@]}" >/dev/null -c "select public.hitpay_set_checkout('$ORD', 'foc-preq', 'https://x')"
for i in $(seq 1 "$N"); do
  ( "${PSQL[@]}" -c "select public.hitpay_apply_payment('$ORD', 'success', 'gcash', 'foc-pay', null, 'foc-preq')" > "$tmp/p$i" 2>&1 ) &
done
wait
ROW=$("${PSQL[@]}" -c "select o.status || '|' || d.status || '|' || (cp.first_paid_order_at is not null) from public.orders o join public.order_downpayments d on d.order_id = o.id join public.customer_profiles cp on cp.firebase_uid = o.firebase_uid where o.id = '$ORD'")
BAD=$(grep -l 'ERROR' "$tmp"/p* 2>/dev/null | wc -l)
[ "$ROW" = "pending|success|true" ] && [ "$BAD" -eq 0 ] \
  && ok "$N paid events at once -> released once, first order used up" \
  || bad "paid events" "row=$ROW errors=$BAD"

# --- 3. Now returning: N cash orders at once are normal orders --------------------------
for i in $(seq 1 "$N"); do echo "$(cart_for "$i")" > "$tmp/rc$i"; done
for i in $(seq 1 "$N"); do
  ( as_user foc-new "select public.place_order('$(cat "$tmp/rc$i")', false, null, 'Cash on Counter Pickup', '', 'foc-ret-$i', null)" > "$tmp/r$i" 2>&1 ) &
done
wait
RET=$("${PSQL[@]}" -c "select count(*) from public.orders o where o.firebase_uid = 'foc-new' and o.status = 'pending' and o.payment_method = 'Cash on Counter Pickup' and not exists (select 1 from public.order_downpayments d where d.order_id = o.id)")
[ "$RET" = "$N" ] && ok "returning customer: $N cash orders at once all accepted normally" \
  || bad "returning orders" "accepted=$RET of $N ($(cat "$tmp"/r* | grep -m1 ERROR))"

rm -rf "$tmp"
echo
[ "$fail" -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
