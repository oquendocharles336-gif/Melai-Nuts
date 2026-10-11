#!/usr/bin/env bash
# =============================================================================
# Melai Nuts — races for receiving (OCR receipts), RFID cards and HitPay refunds
# (migrations 20261011000000, 20261011010000, 20261011020000)
# =============================================================================
#   1. N simultaneous "Approve" of one receipt (different keys) -> stock posted once
#   2. N different cards registered to one customer at once     -> one active card
#   3. N simultaneous "Send via HitPay" for one refund          -> one attempt (no double refund)
# Needs COMMITTED data, so it creates and removes its own rows (prefix CR- / cr-).
# DEV / staging only.
#
#   DATABASE_URL=postgresql://... bash supabase/tests/receiving_cards_refund_concurrency_test.sh
# =============================================================================
set -uo pipefail
: "${DATABASE_URL:?set DATABASE_URL}"
N="${N:-8}"
PSQL=(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAt)
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1  ($2)"; fail=1; }

cleanup() {
  "${PSQL[@]}" >/dev/null 2>&1 <<'SQL'
set session_replication_role = replica;  -- skip append-only / FK triggers for OUR rows only
create temp table cr_orders as select id from public.orders where branch_id in (select id from public.branches where name like 'CR-%');
create temp table cr_refunds as select id from public.refund_requests where order_id in (select id from cr_orders);
delete from public.refund_gateway_attempts where refund_id in (select id from cr_refunds);
delete from public.refund_status_events where refund_request_id in (select id from cr_refunds);
delete from public.refund_items where refund_request_id in (select id from cr_refunds);
delete from public.refund_requests where id in (select id from cr_refunds);
delete from public.loyalty_card_events where card_id in (select id from public.loyalty_cards where firebase_uid like 'cr-%');
delete from public.loyalty_cards where firebase_uid like 'cr-%';
delete from public.purchase_receipt_lines where receipt_id in (select id from public.purchase_receipts where branch_id in (select id from public.branches where name like 'CR-%'));
delete from public.purchase_receipts where branch_id in (select id from public.branches where name like 'CR-%');
delete from public.suppliers where name like 'CR-%';
delete from public.loyalty_transactions where order_id in (select id from cr_orders) or firebase_uid like 'cr-%';
delete from public.loyalty_accounts where firebase_uid like 'cr-%';
delete from public.notifications where firebase_uid like 'cr-%';
delete from public.payments where order_id in (select id from cr_orders);
delete from public.order_status_events where order_id in (select id from cr_orders);
delete from public.order_items where order_id in (select id from cr_orders);
delete from public.orders where id in (select id from cr_orders);
delete from public.cart_items where cart_id in (select id from public.carts where firebase_uid like 'cr-%');
delete from public.carts where firebase_uid like 'cr-%';
delete from public.customer_profiles where firebase_uid like 'cr-%';
delete from public.staff_request_keys where firebase_uid like 'cr-%';
delete from public.staff_audit_logs where staff_firebase_uid like 'cr-%';
delete from public.staff_notifications where recipient_uid like 'cr-%';
delete from public.product_variant_costs where variant_id in (select v.id from public.product_variants v join public.products p on p.id = v.product_id where p.name like 'CR-%');
delete from public.stock_movements where branch_id in (select id from public.branches where name like 'CR-%');
delete from public.inventory_batches where branch_id in (select id from public.branches where name like 'CR-%');
delete from public.branch_inventory where branch_id in (select id from public.branches where name like 'CR-%');
delete from public.staff_members where firebase_uid like 'cr-%';
delete from public.product_variants where product_id in (select id from public.products where name like 'CR-%');
delete from public.products where name like 'CR-%';
delete from public.product_categories where label like 'CR-%';
delete from public.branches where name like 'CR-%';
SQL
}
trap cleanup EXIT
cleanup

"${PSQL[@]}" >/dev/null <<'SQL'
insert into public.branches (name, address, delivery_fee) values ('CR-A', 'a', 0);
insert into public.product_categories (label) values ('CR-Cat');
insert into public.products (category_id, name, price, unit) select id, 'CR-Nut', 100, 'pack' from public.product_categories where label = 'CR-Cat';
insert into public.product_variants (product_id, label, price) select id, 'Regular', 100 from public.products where name = 'CR-Nut';
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
  select b.id, v.product_id, v.id, 20 from public.branches b, public.product_variants v
  where b.name = 'CR-A' and v.product_id = (select id from public.products where name = 'CR-Nut');
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
  select 'cr-staff', 'CR Staff', 'cr-staff@test.local', 'staff', id, 'active', true, true from public.branches where name = 'CR-A';
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values ('cr-cust', 'CR Cust', 'cr-cust@test.local', '0918');
insert into public.suppliers (name, created_by) values ('CR-Supplier', 'cr-staff');
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point) values ('default', 1, 50, 50)
  on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50;
SQL
BA=$("${PSQL[@]}" -c "select id from public.branches where name='CR-A'")
VAR=$("${PSQL[@]}" -c "select v.id from public.product_variants v join public.products p on p.id=v.product_id where p.name='CR-Nut'")
PROD=$("${PSQL[@]}" -c "select id from public.products where name='CR-Nut'")
SUP=$("${PSQL[@]}" -c "select id from public.suppliers where name='CR-Supplier'")

as_user() { # uid, sql -> result or "ERROR: ..."
  local out
  out=$("${PSQL[@]}" -c "begin; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\",\"email\":\"$1@test.local\",\"email_verified\":true}', true); set local role authenticated; $2; commit;" 2>&1)
  if grep -q 'ERROR' <<<"$out"; then grep -m1 'ERROR' <<<"$out"; else tail -1 <<<"$out"; fi
}
stock() { "${PSQL[@]}" -c "select quantity from public.branch_inventory where branch_id='$BA' and variant_id='$VAR'"; }
tmp=$(mktemp -d)

# --- 1. N simultaneous approvals of one receipt ----------------------------------
RC=$(as_user cr-staff "select public.staff_save_purchase_receipt(null, '$BA', '$SUP', 'CR-INV-1', null,
  jsonb_build_array(jsonb_build_object('variant_id','$VAR','quantity',12,'unit_cost',70,'expiration_date', (current_date + 100)::text))) ->> 'id'")
S0=$(stock)
for i in $(seq 1 "$N"); do
  ( as_user cr-staff "select public.staff_approve_purchase_receipt('$RC', 'cr-approve-key-$i') ->> 'status'" > "$tmp/a$i" ) &
done
wait
S1=$(stock)
OKS=$(grep -c '^approved$' "$tmp"/a* | awk -F: '{s+=$2} END {print s}')
[ "$S1" -eq $((S0 + 12)) ] && ok "$N simultaneous approvals -> stock +12 once" || bad "stock" "before $S0, after $S1"
[ "$OKS" -eq 1 ] && ok "exactly one approval succeeded, the rest were refused" || bad "approvals" "$OKS"
BATCHES=$("${PSQL[@]}" -c "select count(*) from public.inventory_batches where branch_id='$BA' and variant_id='$VAR'")
[ "$BATCHES" -eq 1 ] && ok "one batch created" || bad "batches" "$BATCHES"

# --- 2. N different cards for one customer at once ---------------------------------
for i in $(seq 1 "$N"); do
  ( as_user cr-staff "select public.staff_register_loyalty_card('CC00000$i', 'cr-cust') ->> 'label'" > "$tmp/c$i" ) &
done
wait
ACT=$("${PSQL[@]}" -c "select count(*) from public.loyalty_cards where firebase_uid='cr-cust' and status='active'")
[ "$ACT" -eq 1 ] && ok "$N cards registered at once -> one active card" || bad "active cards" "$ACT"

# --- 3. N simultaneous "Send via HitPay" for one refund -----------------------------
CART=$(as_user cr-cust "select public.sync_customer_cart('$BA', jsonb_build_array(jsonb_build_object('product_id','$PROD','variant_id','$VAR','quantity',1)), null, false) ->> 'cart_id'")
# Online payment is off by default (migration 20261017000000): on for this one order only.
"${PSQL[@]}" -c "update public.payment_settings set online_payment_enabled = true where id = 'default'" >/dev/null 2>&1 || true
ORD=$(as_user cr-cust "select public.place_order('$CART', false, null, 'Online Payment (GCash, Maya, Card)', '', 'cr-online-order-1')")
"${PSQL[@]}" -c "update public.payment_settings set online_payment_enabled = false where id = 'default'" >/dev/null 2>&1 || true
"${PSQL[@]}" >/dev/null -c "select public.hitpay_set_checkout('$ORD', 'cr-preq', 'https://x'); select public.hitpay_apply_payment('$ORD', 'success', 'GCash', 'cr-pay-1', null);"
for st in confirmed preparing readyForPickup completed; do as_user cr-staff "select public.staff_update_order_status('$ORD', '$st')" >/dev/null; done
RF=$(as_user cr-cust "select public.request_refund('$ORD', 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','CR-Nut','variant_label','Regular','quantity',1)))")
as_user cr-staff "select public.staff_review_refund('$RF', 'approve')" >/dev/null
for i in $(seq 1 "$N"); do
  ( as_user cr-staff "select public.staff_begin_gateway_refund('$RF') ->> 'attempt_id'" > "$tmp/r$i" ) &
done
wait
ATT=$("${PSQL[@]}" -c "select count(*) from public.refund_gateway_attempts where refund_id='$RF'")
GOT=$(grep -vc 'ERROR' "$tmp"/r* | awk -F: '{s+=$2} END {print s}')
[ "$ATT" -eq 1 ] && [ "$GOT" -eq 1 ] && ok "$N simultaneous sends -> one HitPay attempt (others refused)" || bad "attempts / callers allowed" "$ATT / $GOT"

rm -rf "$tmp"
echo
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
