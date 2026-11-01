#!/usr/bin/env bash
# =============================================================================
# Melai Nuts — races for the pickup downpayment (migrations 20261101083000, 20261101120000)
# =============================================================================
#   1. N "paid" events at once, for one order          -> one release, one notification
#   2. A "paid" event while the time limit runs out    -> one clean outcome, either way:
#        paid in time: order goes to staff, no refund
#        too late:     order cancelled, stock returned once, one refund
#   3. N expiry jobs at once                           -> stock returned once
# Needs COMMITTED data, so it creates and removes its own rows (prefix DPC- / dpc-).
# DEV / staging only.
#
#   DATABASE_URL=postgresql://... bash supabase/tests/cod_downpayment_concurrency_test.sh
# =============================================================================
set -uo pipefail
: "${DATABASE_URL:?set DATABASE_URL}"
N="${N:-8}"
ROUNDS="${ROUNDS:-6}"
PSQL=(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAt)
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1  ($2)"; fail=1; }

cleanup() {
  "${PSQL[@]}" >/dev/null 2>&1 <<'SQL'
set session_replication_role = replica;  -- skip append-only / FK triggers for OUR rows only
create temp table dpc_orders as select id from public.orders where branch_id in (select id from public.branches where name like 'DPC-%');
delete from public.refund_status_events where refund_request_id in (select id from public.refund_requests where order_id in (select id from dpc_orders));
delete from public.refund_requests where order_id in (select id from dpc_orders);
delete from public.loyalty_transactions where order_id in (select id from dpc_orders) or firebase_uid like 'dpc-%';
delete from public.loyalty_accounts where firebase_uid like 'dpc-%';
delete from public.notifications where firebase_uid like 'dpc-%';
delete from public.order_downpayments where order_id in (select id from dpc_orders);
delete from public.payments where order_id in (select id from dpc_orders);
delete from public.order_status_events where order_id in (select id from dpc_orders);
delete from public.order_items where order_id in (select id from dpc_orders);
delete from public.orders where id in (select id from dpc_orders);
delete from public.cart_items where cart_id in (select id from public.carts where firebase_uid like 'dpc-%');
delete from public.carts where firebase_uid like 'dpc-%';
delete from public.customer_addresses where firebase_uid like 'dpc-%';
delete from public.customer_profiles where firebase_uid like 'dpc-%';
delete from public.staff_notifications where recipient_uid like 'dpc-%';
delete from public.staff_audit_logs where staff_firebase_uid like 'dpc-%';
delete from public.stock_movements where branch_id in (select id from public.branches where name like 'DPC-%');
delete from public.branch_inventory where branch_id in (select id from public.branches where name like 'DPC-%');
delete from public.staff_members where firebase_uid like 'dpc-%';
delete from public.product_variants where product_id in (select id from public.products where name like 'DPC-%');
delete from public.products where name like 'DPC-%';
delete from public.product_categories where label like 'DPC-%';
delete from public.branches where name like 'DPC-%';
SQL
  "${PSQL[@]}" >/dev/null 2>&1 <<'SQL'
update public.business_settings
   set cod_downpayment_type = null, cod_downpayment_value = null,
       cod_downpayment_min_order = null, cod_downpayment_expiry_minutes = null, cod_downpayment_pickup_days = null
 where id = 'default';
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

"${PSQL[@]}" >/dev/null <<'SQL'
insert into public.branches (name, address, latitude, longitude, delivery_fee) values ('DPC-A', 'a', 14.2, 121.1, 50);
insert into public.product_categories (label) values ('DPC-Cat');
insert into public.products (category_id, name, price, unit)
select id, 'DPC-Nut', 100, 'pack' from public.product_categories where label = 'DPC-Cat';
insert into public.product_variants (product_id, label, price)
select id, 'Regular', 100 from public.products where name = 'DPC-Nut';
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
select b.id, p.id, v.id, 500 from public.branches b, public.products p join public.product_variants v on v.product_id = p.id
where b.name = 'DPC-A' and p.name = 'DPC-Nut';
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status)
select 'dpc-staff', 'Staff', 'dpc-staff@test.local', 'staff', id, 'active' from public.branches where name = 'DPC-A';
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values ('dpc-cust', 'Cust', 'dpc-cust@test.local', '09170000021');
insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city, latitude, longitude)
values ('dpc-cust', 'Cust', '09170000021', '1 Test St', 'Calamba', 14.205, 121.156);
update public.payment_settings set online_payment_enabled = true where id = 'default';
insert into public.business_settings (id) values ('default') on conflict (id) do nothing;
update public.business_settings set cod_downpayment_type = 'percent', cod_downpayment_value = 30, cod_downpayment_expiry_minutes = 30, cod_downpayment_pickup_days = 2 where id = 'default';
SQL

BA=$("${PSQL[@]}" -c "select id from public.branches where name = 'DPC-A'")
PROD=$("${PSQL[@]}" -c "select id from public.products where name = 'DPC-Nut'")
VAR=$("${PSQL[@]}" -c "select v.id from public.product_variants v where v.product_id = '$PROD'")
stock() { "${PSQL[@]}" -c "select quantity from public.branch_inventory where branch_id = '$BA' and variant_id = '$VAR'"; }

new_order() { # idempotency key
  local cart
  cart=$(as_user dpc-cust "select (public.sync_customer_cart('$BA', jsonb_build_array(jsonb_build_object('product_id','$PROD','variant_id','$VAR','quantity',1)), null, false) ->> 'cart_id')" | tail -1)
  as_user dpc-cust "select public.place_order('$cart', false, null, 'Cash on Counter Pickup', '', '$1')" | tail -1
}

tmp="$(mktemp -d)"

# --- 1. N "paid" events at once --------------------------------------------------
ORD=$(new_order dpc-key-1)
"${PSQL[@]}" >/dev/null -c "select public.hitpay_set_checkout('$ORD', 'dpc-preq', 'https://x')"
for i in $(seq 1 "$N"); do
  ( "${PSQL[@]}" -c "select public.hitpay_apply_payment('$ORD', 'success', 'gcash', 'dpc-pay', null, 'dpc-preq')" > "$tmp/p$i" 2>&1 ) &
done
wait
STATUS=$("${PSQL[@]}" -c "select status from public.orders where id = '$ORD'")
NOTES=$("${PSQL[@]}" -c "select count(*) from public.staff_notifications where recipient_uid = 'dpc-staff' and reference = '$ORD'")
BAD=$(grep -l 'ERROR' "$tmp"/p* 2>/dev/null | wc -l)
[ "$STATUS" = "pending" ] && [ "$NOTES" = "1" ] && [ "$BAD" -eq 0 ] \
  && ok "$N simultaneous paid events -> released once, staff told once" \
  || bad "paid events" "status=$STATUS notes=$NOTES errors=$BAD"

# --- 2. Payment against expiry -----------------------------------------------------
in_time=0; too_late=0; broken=0
for r in $(seq 1 "$ROUNDS"); do
  before=$(stock)
  ORD=$(new_order "dpc-race-$r")
  "${PSQL[@]}" >/dev/null -c "select public.hitpay_set_checkout('$ORD', 'dpc-preq-$r', 'https://x')"
  "${PSQL[@]}" >/dev/null -c "update public.order_downpayments set expires_at = now() - interval '1 minute' where order_id = '$ORD'"
  ( "${PSQL[@]}" -c "select public.hitpay_apply_payment('$ORD', 'success', 'gcash', 'dpc-pay-$r', null, 'dpc-preq-$r')" > "$tmp/a$r" 2>&1 ) &
  ( "${PSQL[@]}" -c "select public.expire_unpaid_cod_downpayments()" > "$tmp/e$r" 2>&1 ) &
  wait
  # The job skips an order locked by the payment, so run it once more: it must change nothing new.
  "${PSQL[@]}" >/dev/null -c "select public.expire_unpaid_cod_downpayments()"
  row=$("${PSQL[@]}" -c "select o.status, d.status, (select count(*) from public.refund_requests r where r.order_id = o.id) from public.orders o join public.order_downpayments d on d.order_id = o.id where o.id = '$ORD'")
  now=$(stock)
  case "$row" in
    "pending|success|0")
      [ "$now" -eq "$((before - 1))" ] && in_time=$((in_time + 1)) || broken=$((broken + 1)) ;;
    "cancelled|success|1")
      [ "$now" -eq "$before" ] && too_late=$((too_late + 1)) || broken=$((broken + 1)) ;;
    *) broken=$((broken + 1)); echo "  unexpected outcome: $row" ;;
  esac
done
[ "$broken" -eq 0 ] \
  && ok "$ROUNDS payment-against-expiry races -> always one clean outcome (in time: $in_time, too late: $too_late)" \
  || bad "payment against expiry" "$broken broken of $ROUNDS"

# --- 3. N expiry jobs at once ------------------------------------------------------
before=$(stock)
ORD=$(new_order dpc-key-3)
"${PSQL[@]}" >/dev/null -c "update public.order_downpayments set expires_at = now() - interval '1 minute' where order_id = '$ORD'"
for i in $(seq 1 "$N"); do
  ( "${PSQL[@]}" -c "select public.expire_unpaid_cod_downpayments()" > "$tmp/j$i" 2>&1 ) &
done
wait
TOTAL=$(cat "$tmp"/j* | awk '{s+=$1} END {print s+0}')
STATUS=$("${PSQL[@]}" -c "select status from public.orders where id = '$ORD'")
now=$(stock)
[ "$STATUS" = "cancelled" ] && [ "$now" -eq "$before" ] && [ "$TOTAL" -eq 1 ] \
  && ok "$N simultaneous expiry jobs -> cancelled once, stock returned once" \
  || bad "expiry jobs" "status=$STATUS stock=$now before=$before cancelled=$TOTAL"

rm -rf "$tmp"
echo
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
